#!/usr/bin/env bash
set -Eeuo pipefail

HOST=""
USER_NAME="ubuntu"
IDENTITY_FILE=""
EXPECTED_OLD_MACHINE_ID=""
TIMEOUT=10

usage() {
cat <<'EOF'
mgc_vm_validate_clone_v0.9.sh

Valida uma VM clonada após o primeiro boot:
- acesso SSH
- machine-id inicializado
- cloud-init concluído
- hostname
- rede IPv4
- tamanho do filesystem /
- Docker/containerd
- containers existentes
- netplan gerado no destino
- chaves SSH host regeneradas

Uso:
  ./mgc_vm_validate_clone_v0.9.sh --host <TARGET_VM_IP>

Opcional:
  --user ubuntu
  --identity-file ~/.ssh/chave
  --old-machine-id <machine-id-da-origem>
EOF
}

ok(){ printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:?}"; shift 2 ;;
    --user) USER_NAME="${2:?}"; shift 2 ;;
    --identity-file) IDENTITY_FILE="${2:?}"; shift 2 ;;
    --old-machine-id) EXPECTED_OLD_MACHINE_ID="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opção desconhecida: $1" ;;
  esac
done

[[ -n "$HOST" ]] || die "Informe --host"
command -v ssh >/dev/null || die "ssh não encontrado"

SSH_ARGS=(
  -o BatchMode=yes
  -o ConnectTimeout="$TIMEOUT"
  -o StrictHostKeyChecking=accept-new
)

if [[ -n "$IDENTITY_FILE" ]]; then
  [[ -f "$IDENTITY_FILE" ]] || die "Chave privada não encontrada: $IDENTITY_FILE"
  SSH_ARGS+=(-i "$IDENTITY_FILE")
fi

echo "============================================================"
echo " VALIDAÇÃO FINAL DO CLONE"
echo "============================================================"
echo "Host: $USER_NAME@$HOST"
echo

if ssh "${SSH_ARGS[@]}" "$USER_NAME@$HOST" 'true' >/dev/null 2>&1; then
  ok "SSH acessível."
else
  die "Não consegui acessar a VM via SSH."
fi

REMOTE_OUT="$(
ssh "${SSH_ARGS[@]}" "$USER_NAME@$HOST" bash -s <<'REMOTE'
set -u

echo "__HOSTNAME__"
hostname

echo "__MACHINE_ID__"
cat /etc/machine-id 2>/dev/null || true

echo "__CLOUD_INIT__"
cloud-init status --long 2>/dev/null || cloud-init status 2>/dev/null || true

echo "__IP__"
ip -brief -4 address 2>/dev/null || true

echo "__ROOT_FS__"
df -B1 / | tail -n1

echo "__LSBLK__"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS 2>/dev/null || true

echo "__DOCKER__"
systemctl is-active docker 2>/dev/null || true

echo "__CONTAINERD__"
systemctl is-active containerd 2>/dev/null || true

echo "__CONTAINERS__"
if command -v docker >/dev/null 2>&1; then
  docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null || sudo docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null || true
fi

echo "__NETPLAN_FILES__"
find /etc/netplan -maxdepth 1 -type f -printf '%f\n' 2>/dev/null || true

echo "__NETPLAN_CONTENT__"
for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
  [[ -f "$f" ]] || continue
  echo "--- $f"
  cat "$f"
done 2>/dev/null || true

echo "__SSH_HOST_KEYS__"
find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*_key.pub' -printf '%f\n' 2>/dev/null || true
REMOTE
)"

section() {
  local name="$1"
  awk -v start="__${name}__" '
    $0==start {p=1; next}
    /^__[A-Z0-9_]+__$/ && p {exit}
    p {print}
  ' <<<"$REMOTE_OUT"
}

HOSTNAME_NOW="$(section HOSTNAME | head -n1)"
MACHINE_ID="$(section MACHINE_ID | head -n1)"
CLOUD="$(section CLOUD_INIT)"
IP_INFO="$(section IP)"
ROOT_LINE="$(section ROOT_FS)"
DOCKER_STATE="$(section DOCKER | head -n1)"
CONTAINERD_STATE="$(section CONTAINERD | head -n1)"
CONTAINERS="$(section CONTAINERS)"
NETPLAN_FILES="$(section NETPLAN_FILES)"
NETPLAN_CONTENT="$(section NETPLAN_CONTENT)"
SSH_HOST_KEYS="$(section SSH_HOST_KEYS)"

echo
echo "Hostname: $HOSTNAME_NOW"

if [[ -n "$MACHINE_ID" && "$MACHINE_ID" != "uninitialized" && "$MACHINE_ID" =~ ^[0-9a-fA-F]{32}$ ]]; then
  ok "machine-id inicializado: $MACHINE_ID"
else
  warn "machine-id inesperado: '${MACHINE_ID:-vazio}'"
fi

if [[ -n "$EXPECTED_OLD_MACHINE_ID" ]]; then
  if [[ "$MACHINE_ID" != "$EXPECTED_OLD_MACHINE_ID" ]]; then
    ok "machine-id é diferente da VM de origem."
  else
    warn "machine-id é IGUAL ao da VM de origem."
  fi
fi

if grep -qiE 'status:[[:space:]]*done|status:[[:space:]]*disabled' <<<"$CLOUD"; then
  ok "cloud-init concluiu."
else
  warn "cloud-init não apareceu como done."
fi

echo
echo "Cloud-init:"
printf '%s\n' "$CLOUD"

echo
echo "Rede IPv4:"
printf '%s\n' "$IP_INFO"
if grep -qE 'UP[[:space:]]+[0-9]+\.' <<<"$IP_INFO"; then
  ok "Interface com IPv4 ativa."
else
  warn "Não detectei IPv4 ativo."
fi

ROOT_BYTES="$(awk '{print $2}' <<<"$ROOT_LINE")"
ROOT_USED="$(awk '{print $3}' <<<"$ROOT_LINE")"
if [[ "$ROOT_BYTES" =~ ^[0-9]+$ ]]; then
  ROOT_GIB="$(python3 - "$ROOT_BYTES" <<'PY'
import sys
print(f"{int(sys.argv[1])/1024**3:.2f}")
PY
)"
  echo
  echo "Filesystem /: ${ROOT_GIB} GiB"
  if (( ROOT_BYTES > 80*1024*1024*1024 )); then
    ok "Filesystem raiz foi expandido para o disco maior."
  else
    warn "Filesystem raiz não parece ter sido expandido para ~100 GB."
  fi
fi

echo
echo "Discos:"
section LSBLK

if [[ "$DOCKER_STATE" == "active" ]]; then
  ok "Docker ativo."
else
  warn "Docker: ${DOCKER_STATE:-não identificado}"
fi

if [[ "$CONTAINERD_STATE" == "active" ]]; then
  ok "containerd ativo."
else
  warn "containerd: ${CONTAINERD_STATE:-não identificado}"
fi

echo
echo "Containers:"
if [[ -n "$CONTAINERS" ]]; then
  printf '%s\n' "$CONTAINERS"
else
  echo "(nenhum listado ou sem permissão)"
fi

echo
echo "Netplan:"
if [[ -n "$NETPLAN_FILES" ]]; then
  printf '%s\n' "$NETPLAN_FILES"
  ok "Configuração de rede existe no destino."
else
  warn "Nenhum arquivo netplan encontrado."
fi

if grep -qi 'macaddress:' <<<"$NETPLAN_CONTENT"; then
  warn "Netplan contém macaddress fixo; revisar portabilidade."
else
  ok "Netplan sem MAC fixo detectado."
fi

HOST_KEY_COUNT="$(grep -c . <<<"$SSH_HOST_KEYS" || true)"
if (( HOST_KEY_COUNT > 0 )); then
  ok "SSH host keys existem no clone ($HOST_KEY_COUNT públicas)."
else
  warn "Não encontrei SSH host keys."
fi

echo
echo "============================================================"
echo " VALIDAÇÃO CONCLUÍDA"
echo "============================================================"
