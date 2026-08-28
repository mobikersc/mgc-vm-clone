#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.8.0"

TENANT=""
REGION="br-se1"
IMAGE_ID=""
VM_NAME="my-clone-vm"
MACHINE_TYPE="BV4-8-40"
AZ="br-se1-c"
VPC_NAME="vpc_default"
SSH_KEY=""
SECURITY_GROUP_ID=""
ASSOCIATE_PUBLIC_IP="true"
EXECUTE=0
WAIT_TIMEOUT=1800
POLL_SECONDS=10
SSH_USER="ubuntu"
IDENTITY_FILE=""

usage() {
cat <<'EOF'
mgc_vm_create_from_custom_image_v0.8.sh

Cria e valida uma VM a partir de uma Custom Image ACTIVE.

Defaults:
  machine type: BV4-8-40
  AZ:           br-se1-c
  VPC:          vpc_default
  public IPv4:  true
  SSH user:     ubuntu

SEM --execute:
  - confirma tenant
  - confirma Custom Image ACTIVE
  - valida machine type/AZ
  - valida VPC
  - lista/valida SSH keys
  - opcionalmente valida Security Group
  - NÃO cria VM

COM --execute:
  - cria VM
  - captura ID
  - aguarda running/completed
  - mostra IPs
  - se --identity-file for informado, aguarda SSH e valida cloud-init

Uso:
  ./mgc_vm_create_from_custom_image_v0.8.sh \
    --tenant UUID \
    --image-id UUID \
    --ssh-key NOME_DA_CHAVE

Opções:
  --tenant <uuid>
  --image-id <uuid>
  --name <nome>                default: my-clone-vm
  --region <regiao>            default: br-se1
  --machine-type <nome>        default: BV4-8-40
  --az <zona>                  default: br-se1-c
  --vpc-name <nome>            default: vpc_default
  --ssh-key <nome>             obrigatório para --execute
  --security-group-id <uuid>   opcional; sem ele usa SG padrão
  --no-public-ip
  --identity-file <path>       opcional; valida SSH/cloud-init
  --ssh-user <usuario>         default: ubuntu
  --timeout <segundos>         default: 1800
  --poll <segundos>            default: 10
  --execute
EOF
}

log(){ printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant) TENANT="${2:?}"; shift 2 ;;
    --image-id) IMAGE_ID="${2:?}"; shift 2 ;;
    --name) VM_NAME="${2:?}"; shift 2 ;;
    --region) REGION="${2:?}"; shift 2 ;;
    --machine-type) MACHINE_TYPE="${2:?}"; shift 2 ;;
    --az) AZ="${2:?}"; shift 2 ;;
    --vpc-name) VPC_NAME="${2:?}"; shift 2 ;;
    --ssh-key) SSH_KEY="${2:?}"; shift 2 ;;
    --security-group-id) SECURITY_GROUP_ID="${2:?}"; shift 2 ;;
    --no-public-ip) ASSOCIATE_PUBLIC_IP="false"; shift ;;
    --identity-file) IDENTITY_FILE="${2:?}"; shift 2 ;;
    --ssh-user) SSH_USER="${2:?}"; shift 2 ;;
    --timeout) WAIT_TIMEOUT="${2:?}"; shift 2 ;;
    --poll) POLL_SECONDS="${2:?}"; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "$VERSION"; exit 0 ;;
    *) die "Opção desconhecida: $1" ;;
  esac
done

[[ -n "$TENANT" ]] || die "Informe --tenant"
[[ -n "$IMAGE_ID" ]] || die "Informe --image-id"

for c in mgc python3 grep sed awk date; do need "$c"; done

if [[ -n "$IDENTITY_FILE" ]]; then
  need ssh
  [[ -f "$IDENTITY_FILE" ]] || die "Identity file não encontrado: $IDENTITY_FILE"
  IDENTITY_FILE="$(readlink -f "$IDENTITY_FILE")"
fi

TMP="$(mktemp -d /tmp/mgc-vm-create.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

clean_text() {
  python3 - "$1" <<'PY'
import re,sys
s=open(sys.argv[1],"rb").read().decode("utf-8","replace")
s=re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]","",s)
s=s.replace("\r","\n")
print(s,end="")
PY
}

extract_uuid() {
  python3 - "$1" <<'PY'
import re,sys
s=open(sys.argv[1],"rb").read().decode("utf-8","replace")
s=re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]","",s)
m=re.search(r'(?i)\b([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b',s)
print(m.group(1) if m else "")
PY
}

parse_status() {
  python3 - "$1" <<'PY'
import json,re,sys
raw=open(sys.argv[1],"rb").read().decode("utf-8","replace")
raw=re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]","",raw).replace("\r","\n")
m1=re.search(r'(?mi)^[ \t]*state[ \t]*:[ \t]*["\']?([^"\'\s]+)',raw)
m2=re.search(r'(?mi)^[ \t]*status[ \t]*:[ \t]*["\']?([^"\'\s]+)',raw)
if m1 or m2:
    print((m1.group(1).lower() if m1 else "")+"|"+(m2.group(1).lower() if m2 else ""))
    raise SystemExit
dec=json.JSONDecoder(); obj=None
for i,c in enumerate(raw):
    if c not in "[{": continue
    try: obj,_=dec.raw_decode(raw[i:]); break
    except: pass
def find(d,key):
    if isinstance(d,dict):
        if isinstance(d.get(key),str): return d[key].lower()
        for v in d.values():
            r=find(v,key)
            if r:return r
    elif isinstance(d,list):
        for v in d:
            r=find(v,key)
            if r:return r
    return ""
print((find(obj,"state") if obj is not None else "")+"|"+
      (find(obj,"status") if obj is not None else ""))
PY
}

extract_ips() {
  python3 - "$1" <<'PY'
import re,sys,ipaddress
raw=open(sys.argv[1],"rb").read().decode("utf-8","replace")
raw=re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]","",raw)
seen=[]
for m in re.finditer(r'(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])',raw):
    ip=m.group(0)
    try: a=ipaddress.ip_address(ip)
    except: continue
    if ip not in seen: seen.append(ip)
for ip in seen:
    a=ipaddress.ip_address(ip)
    print(("private" if a.is_private else "public")+"|"+ip)
PY
}

current_tenant() {
  local f="$TMP/tenant-current.txt"
  mgc auth tenant current >"$f" 2>&1 || return 1
  python3 - "$f" <<'PY'
import re,sys
s=open(sys.argv[1],"rb").read().decode("utf-8","replace")
s=re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]","",s).replace("\r","\n")
m=re.search(r'(?mi)^[ \t]*uuid[ \t]*:[ \t]*["\']?([0-9a-f-]{36})',s)
print(m.group(1) if m else "")
PY
}

switch_tenant() {
  local cur
  cur="$(current_tenant || true)"
  if [[ "$cur" != "$TENANT" ]]; then
    log "Selecionando tenant destino..."
    mgc auth tenant set "$TENANT" >"$TMP/tenant-set.txt" 2>&1 || die "Falha ao selecionar tenant."
  fi
  cur="$(current_tenant || true)"
  [[ "$cur" == "$TENANT" ]] || die "Tenant ativo incorreto."
}

switch_tenant
ok "Tenant destino confirmado."

echo
echo "============================================================"
echo " PREFLIGHT - CRIAÇÃO DA VM"
echo "============================================================"
echo "VM:             $VM_NAME"
echo "Image ID:       $IMAGE_ID"
echo "Machine type:   $MACHINE_TYPE"
echo "AZ:             $AZ"
echo "VPC:            $VPC_NAME"
echo "Public IPv4:    $ASSOCIATE_PUBLIC_IP"
echo "SSH key:        ${SSH_KEY:-NÃO INFORMADA}"
echo "Security Group: ${SECURITY_GROUP_ID:-padrão da plataforma}"
echo

log "Validando Custom Image..."
IMG="$TMP/image-get.txt"
mgc virtual-machine images custom get --id "$IMAGE_ID" --region "$REGION" -o json -r >"$IMG" 2>&1 \
  || { cat "$IMG" >&2; die "Não consegui consultar a Custom Image."; }

IMG_STATUS="$(parse_status "$IMG" | awk -F'|' '{print ($2!=""?$2:$1)}')"
[[ "$IMG_STATUS" == "active" ]] || die "Custom Image não está active (status=${IMG_STATUS:-?})."
ok "Custom Image ACTIVE."

log "Validando machine type e disponibilidade na AZ..."
MT="$TMP/machine-type.txt"
mgc virtual-machine machine-types list --name "$MACHINE_TYPE" --availability-zone "$AZ" \
  --region "$REGION" -o json -r >"$MT" 2>&1 \
  || { cat "$MT" >&2; die "Falha ao consultar machine type."; }

if clean_text "$MT" | grep -Fq "$MACHINE_TYPE"; then
  ok "$MACHINE_TYPE disponível em $AZ."
else
  warn "$MACHINE_TYPE não apareceu para $AZ."
  warn "Machine types disponíveis nessa AZ:"
  mgc virtual-machine machine-types list --availability-zone "$AZ" --region "$REGION" \
    -o table 2>/dev/null | head -40 || true
  die "Escolha outro machine type/AZ."
fi

log "Validando VPC..."
VPCS="$TMP/vpcs.txt"
mgc network vpcs list --region "$REGION" -o json -r >"$VPCS" 2>&1 \
  || { cat "$VPCS" >&2; die "Falha ao listar VPCs."; }

if clean_text "$VPCS" | grep -Fq "$VPC_NAME"; then
  ok "VPC '$VPC_NAME' encontrada."
else
  warn "VPC '$VPC_NAME' não encontrada."
  warn "VPCs disponíveis:"
  clean_text "$VPCS" | head -80 >&2
  die "Informe outra VPC com --vpc-name."
fi

log "Validando SSH keys..."
KEYS="$TMP/ssh-keys.txt"
mgc profile ssh-keys list -o json -r >"$KEYS" 2>&1 \
  || { cat "$KEYS" >&2; die "Falha ao listar SSH keys."; }

if [[ -z "$SSH_KEY" ]]; then
  echo
  warn "Nenhuma --ssh-key foi informada."
  echo "SSH keys disponíveis no perfil:"
  clean_text "$KEYS" | sed -n '1,120p'
  echo
  echo "Rode novamente este MESMO script com:"
  echo "  --ssh-key <nome>"
  echo
  echo "O parâmetro usa o campo name da chave, não o ID."
  exit 0
fi

if clean_text "$KEYS" | grep -Fq "$SSH_KEY"; then
  ok "SSH key '$SSH_KEY' encontrada."
else
  warn "SSH key '$SSH_KEY' não encontrada."
  clean_text "$KEYS" | sed -n '1,120p' >&2
  die "Escolha uma chave existente."
fi

if [[ -n "$SECURITY_GROUP_ID" ]]; then
  log "Validando Security Group..."
  SG="$TMP/sg.txt"
  mgc network security-groups get --security-group-id "$SECURITY_GROUP_ID" \
    --region "$REGION" -o json -r >"$SG" 2>&1 \
    || { cat "$SG" >&2; die "Security Group inválido."; }
  ok "Security Group encontrado."
fi

echo
echo "============================================================"
echo " RESULTADO DO PREFLIGHT"
echo "============================================================"
echo "Custom Image:   OK"
echo "Machine type:   OK"
echo "AZ:             OK"
echo "VPC:            OK"
echo "SSH key:        OK"
echo "Security Group: $([[ -n "$SECURITY_GROUP_ID" ]] && echo OK || echo 'usar padrão')"
echo
echo "Nenhuma VM foi criada."

if [[ "$EXECUTE" -eq 0 ]]; then
  echo
  echo "Para criar a VM, repita acrescentando:"
  echo "  --execute"
  exit 0
fi

echo
echo "============================================================"
echo " CRIANDO VM"
echo "============================================================"

CREATE="$TMP/vm-create.txt"
ARGS=(
  virtual-machine instances create
  --name="$VM_NAME"
  --image.id="$IMAGE_ID"
  --machine-type.name="$MACHINE_TYPE"
  --availability-zone="$AZ"
  --network.associate-public-ip="$ASSOCIATE_PUBLIC_IP"
  --network.vpc.name="$VPC_NAME"
  --ssh-key-name="$SSH_KEY"
  --region="$REGION"
  -o json
  -r
)

if [[ -n "$SECURITY_GROUP_ID" ]]; then
  ARGS+=(--network.interface.security-groups="[{\"id\":\"$SECURITY_GROUP_ID\"}]")
fi

log "Enviando criação da VM..."
mgc "${ARGS[@]}" >"$CREATE" 2>&1 || { cat "$CREATE" >&2; die "Falha ao criar VM."; }

VM_ID="$(extract_uuid "$CREATE")"
[[ -n "$VM_ID" ]] || { cat "$CREATE" >&2; die "Create aceito, mas não consegui capturar o ID da VM."; }
ok "VM criada: ID=$VM_ID"

log "Aguardando VM ficar running/completed..."
START="$(date +%s)"
STATE=""
STATUS=""

while true; do
  GET="$TMP/vm-get.txt"
  if mgc virtual-machine instances get --id "$VM_ID" --region "$REGION" -o json -r >"$GET" 2>&1; then
    PAIR="$(parse_status "$GET")"
    STATE="${PAIR%%|*}"
    STATUS="${PAIR#*|}"
  fi

  printf '\r[INFO] VM state=%-10s status=%-12s' "${STATE:-?}" "${STATUS:-?}" >&2

  if [[ "$STATE" == "running" && "$STATUS" == "completed" ]]; then
    echo >&2
    ok "VM running/completed."
    break
  fi

  case "$STATE|$STATUS" in
    *error*|*failed*|*failure*)
      echo >&2
      cat "$GET" >&2
      die "VM entrou em estado de erro."
      ;;
  esac

  NOW="$(date +%s)"
  (( NOW - START < WAIT_TIMEOUT )) || { echo >&2; die "Timeout aguardando VM."; }
  sleep "$POLL_SECONDS"
done

echo
echo "IPs detectados:"
extract_ips "$GET" | while IFS='|' read -r scope ip; do
  printf '  %-8s %s\n' "$scope" "$ip"
done

PUBLIC_IP="$(extract_ips "$GET" | awk -F'|' '$1=="public"{print $2; exit}')"
PRIVATE_IP="$(extract_ips "$GET" | awk -F'|' '$1=="private"{print $2; exit}')"

if [[ -n "$IDENTITY_FILE" && -n "$PUBLIC_IP" ]]; then
  log "Aguardando SSH em $SSH_USER@$PUBLIC_IP..."
  SSH_DEADLINE=$(( $(date +%s) + WAIT_TIMEOUT ))
  while true; do
    if ssh -i "$IDENTITY_FILE" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=5 "$SSH_USER@$PUBLIC_IP" 'true' >/dev/null 2>&1; then
      ok "SSH disponível."
      break
    fi
    (( $(date +%s) < SSH_DEADLINE )) || die "Timeout aguardando SSH."
    sleep 10
  done

  echo
  echo "============================================================"
  echo " VALIDAÇÃO DO CLONE"
  echo "============================================================"
  ssh -i "$IDENTITY_FILE" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    "$SSH_USER@$PUBLIC_IP" \
    'set -e
     echo "hostname=$(hostname)"
     echo "machine-id=$(cat /etc/machine-id)"
     echo "cloud-init:"
     cloud-init status --long 2>/dev/null || cloud-init status 2>/dev/null || true
     echo
     echo "network:"
     ip -brief address
     echo
     echo "docker:"
     systemctl is-active docker 2>/dev/null || true
     docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || true'
fi

echo
echo "============================================================"
echo " VM CRIADA"
echo "============================================================"
echo "Name:       $VM_NAME"
echo "ID:         $VM_ID"
echo "Image ID:   $IMAGE_ID"
echo "AZ:         $AZ"
echo "Type:       $MACHINE_TYPE"
echo "Private IP: ${PRIVATE_IP:-não identificado}"
echo "Public IP:  ${PUBLIC_IP:-não identificado}"
echo

if [[ -z "$IDENTITY_FILE" ]]; then
  echo "Para validar SSH automaticamente, informe:"
  echo "  --identity-file /caminho/da_chave_privada"
fi
