#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.4.6"

VM_REF=""
REGION=""
SSH_USER="ubuntu"
SSH_HOST=""
SSH_KEY=""
OUTPUT_DIR=""
DISK_OVERRIDE=""

EXECUTE=0
QUIESCE_DOCKER=0
FREEZE_ROOT=0
SAFETY_SNAPSHOT=0
REUSE_SNAPSHOT_ID=""
KEEP_RAW=0
FORCE=0
VM_STOPPED_BY_SCRIPT=0

SNAPSHOT_TIMEOUT=3600
VM_TIMEOUT=600
SSH_TIMEOUT=600

usage() {
cat <<'EOF'
mgc_vm_export_v0.4.6.sh
Exporta o disco inteiro de uma VM MGC para um QCOW2 local.

IMPORTANTE:
  * Sem --execute, o script faz APENAS preflight.
  * O disco é lido pela própria VM via SSH.
  * --quiesce-docker interrompe workloads Docker durante a captura.
  * --freeze-root congela escritas no filesystem raiz durante a captura.
  * --safety-snapshot desliga a VM, cria snapshot consistente e a religa
    antes da exportação. Isso gera indisponibilidade adicional.

Uso:
  ./mgc_vm_export_v0.4.6.sh \
    --vm <nome-ou-uuid> \
    --region <região> \
    --ssh-host <ip> \
    [opções]

Obrigatórios:
  --vm <nome-ou-uuid>
  --region <br-se1|br-ne1|br-mgl1>
  --ssh-host <ip-ou-hostname>

SSH:
  --ssh-user <user>       Padrão: ubuntu
  --ssh-key <arquivo>     Chave SSH específica

Exportação:
  --execute               Autoriza efetivamente a captura
  --disk </dev/vda>       Sobrescreve autodetecção do disco
  --output-dir <dir>      Diretório de saída
  --quiesce-docker        Para Docker/containerd antes da captura e religa no fim
  --freeze-root           Congela / durante TODA a leitura do disco (avançado; exige --force)
  --safety-snapshot       Para VM -> snapshot -> inicia VM -> exporta
  --snapshot-id <uuid>     Reutiliza snapshot existente; não para a VM
  --keep-raw              Mantém o RAW sparse intermediário
  --force                 Aceita alguns avisos de preflight não fatais

Timeouts:
  --snapshot-timeout <s>  Padrão: 3600
  --vm-timeout <s>        Padrão: 600
  --ssh-timeout <s>       Padrão: 600

Exemplo recomendado para o Alfred:
  ./mgc_vm_export_v0.4.6.sh \
    --vm <VM_UUID> \
    --region br-se1 \
    --ssh-user ubuntu \
    --ssh-host <SOURCE_VM_IP> \
    --quiesce-docker \
    --safety-snapshot

O comando acima é somente preflight.

Para executar de verdade:
  ./mgc_vm_export_v0.4.6.sh \
    --vm <VM_UUID> \
    --region br-se1 \
    --ssh-user ubuntu \
    --ssh-host <SOURCE_VM_IP> \
    --quiesce-docker \
    --safety-snapshot \
    --execute
EOF
}

log(){ printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }

need(){
  command -v "$1" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $1"
}

is_uuid(){
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

sanitize_name(){
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]_-' '-'
}

human_bytes(){
  numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"
}

clean_json_file() {
  local raw="$1"
  local clean="$2"

  python3 - "$raw" "$clean" <<'PY'
import json, re, sys
from pathlib import Path

raw_path = Path(sys.argv[1])
clean_path = Path(sys.argv[2])

data = raw_path.read_bytes().decode("utf-8", errors="replace")

ansi_re = re.compile(
    r'(?:\x1B[@-_][0-?]*[ -/]*[@-~])'
    r'|(?:\x1B\][^\x07]*(?:\x07|\x1B\\))'
)
data = ansi_re.sub('', data)

decoder = json.JSONDecoder()

for m in re.finditer(r'[\{\[]', data):
    try:
        obj, _ = decoder.raw_decode(data[m.start():])
    except json.JSONDecodeError:
        continue

    clean_path.write_text(
        json.dumps(obj, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8"
    )
    sys.exit(0)

sys.exit(1)
PY
}

run_mgc_json() {
  local clean="$1"
  local raw="$2"
  local err="$3"
  shift 3

  if ! NO_COLOR=1 CLICOLOR=0 TERM=dumb mgc "$@" >"$raw" 2>"$err"; then
    return 1
  fi

  clean_json_file "$raw" "$clean" || return 2
  jq -e . "$clean" >/dev/null 2>&1 || return 2
}

normalize_instances() {
  jq '
    if type == "array" then .
    elif (.instances? | type) == "array" then .instances
    elif (.items? | type) == "array" then .items
    elif (.results? | type) == "array" then .results
    elif (.data? | type) == "array" then .data
    elif (.data?.instances? | type) == "array" then .data.instances
    else []
    end
  ' "$1"
}

normalize_snapshots() {
  jq '
    if type == "array" then .
    elif (.snapshots? | type) == "array" then .snapshots
    elif (.items? | type) == "array" then .items
    elif (.results? | type) == "array" then .results
    elif (.data? | type) == "array" then .data
    elif (.data?.snapshots? | type) == "array" then .data.snapshots
    else []
    end
  ' "$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm) VM_REF="${2:?}"; shift 2 ;;
    --region) REGION="${2:?}"; shift 2 ;;
    --ssh-user) SSH_USER="${2:?}"; shift 2 ;;
    --ssh-host) SSH_HOST="${2:?}"; shift 2 ;;
    --ssh-key) SSH_KEY="${2:?}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:?}"; shift 2 ;;
    --disk) DISK_OVERRIDE="${2:?}"; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    --quiesce-docker) QUIESCE_DOCKER=1; shift ;;
    --freeze-root) FREEZE_ROOT=1; shift ;;
    --safety-snapshot) SAFETY_SNAPSHOT=1; shift ;;
    --snapshot-id) REUSE_SNAPSHOT_ID="${2:?}"; shift 2 ;;
    --keep-raw) KEEP_RAW=1; shift ;;
    --force) FORCE=1; shift ;;
    --snapshot-timeout) SNAPSHOT_TIMEOUT="${2:?}"; shift 2 ;;
    --vm-timeout) VM_TIMEOUT="${2:?}"; shift 2 ;;
    --ssh-timeout) SSH_TIMEOUT="${2:?}"; shift 2 ;;
    --version) echo "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opção desconhecida: $1" ;;
  esac
done

[[ -n "$VM_REF" ]] || { usage; die "Informe --vm"; }
[[ -n "$REGION" ]] || die "Informe --region"
[[ -n "$SSH_HOST" ]] || die "Informe --ssh-host"

if [[ "$SAFETY_SNAPSHOT" -eq 1 && -n "$REUSE_SNAPSHOT_ID" ]]; then
  die "Use --safety-snapshot OU --snapshot-id, não os dois."
fi

need mgc
need jq
need python3
need ssh
need dd
need sha256sum
need numfmt

TS="$(date +%Y%m%d-%H%M%S)"
SAFE_VM="$(sanitize_name "$VM_REF")"
OUTPUT_DIR="${OUTPUT_DIR:-./mgc-vm-export-${SAFE_VM}-${TS}}"
mkdir -p "$OUTPUT_DIR"

SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ConnectionAttempts=1
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=4
  -o StrictHostKeyChecking=accept-new
)

if [[ -n "$SSH_KEY" ]]; then
  [[ -r "$SSH_KEY" ]] || die "Chave SSH não pode ser lida: $SSH_KEY"
  SSH_OPTS+=(-i "$SSH_KEY")
fi

ssh_cmd(){
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$@"
}

INSTANCE_JSON="$OUTPUT_DIR/instance.json"

locate_vm() {
  local raw="$OUTPUT_DIR/instance-locate.raw"
  local json="$OUTPUT_DIR/instance-locate.json"
  local err="$OUTPUT_DIR/instance-locate.stderr"

  if is_uuid "$VM_REF"; then
    if ! run_mgc_json "$json" "$raw" "$err" \
        virtual-machine instances get \
        --id "$VM_REF" \
        --region "$REGION" \
        -o json; then
      [[ -s "$err" ]] && cat "$err" >&2
      die "Não consegui consultar a VM por UUID."
    fi

    jq '
      if (.instance? | type) == "object" then .instance
      elif (.data? | type) == "object" then .data
      else .
      end
    ' "$json" >"$INSTANCE_JSON"
    return
  fi

  if ! run_mgc_json "$json" "$raw" "$err" \
      virtual-machine instances list \
      --name "$VM_REF" \
      --control.limit 1000 \
      --region "$REGION" \
      -o json; then
    [[ -s "$err" ]] && cat "$err" >&2
    die "Não consegui listar VMs."
  fi

  normalize_instances "$json" >"$OUTPUT_DIR/instances-normalized.json"

  local count
  count="$(jq --arg n "$VM_REF" '[.[] | select(.name == $n)] | length' "$OUTPUT_DIR/instances-normalized.json")"

  [[ "$count" -eq 1 ]] || die "Esperava exatamente uma VM chamada '$VM_REF'; encontrei $count."

  jq --arg n "$VM_REF" '.[] | select(.name == $n)' \
    "$OUTPUT_DIR/instances-normalized.json" >"$OUTPUT_DIR/instance-selected.json"

  local id
  id="$(jq -r '.id // .uuid // empty' "$OUTPUT_DIR/instance-selected.json")"
  [[ -n "$id" ]] || die "VM localizada sem UUID."

  if run_mgc_json "$json" "$raw" "$err" \
      virtual-machine instances get \
      --id "$id" \
      --region "$REGION" \
      -o json; then

    jq '
      if (.instance? | type) == "object" then .instance
      elif (.data? | type) == "object" then .data
      else .
      end
    ' "$json" >"$INSTANCE_JSON"
  else
    cp "$OUTPUT_DIR/instance-selected.json" "$INSTANCE_JSON"
  fi
}

refresh_vm() {
  local vm_id="$1"
  local tag="${2:-refresh}"
  local raw="$OUTPUT_DIR/${tag}.raw"
  local json="$OUTPUT_DIR/${tag}.json"
  local err="$OUTPUT_DIR/${tag}.stderr"

  run_mgc_json "$json" "$raw" "$err" \
    virtual-machine instances get \
    --id "$vm_id" \
    --region "$REGION" \
    -o json || return 1

  jq '
    if (.instance? | type) == "object" then .instance
    elif (.data? | type) == "object" then .data
    else .
    end
  ' "$json"
}

wait_vm_state() {
  local vm_id="$1"
  local wanted="$2"
  local timeout="$3"
  local start now state status

  start="$(date +%s)"
  while true; do
    local data
    data="$(refresh_vm "$vm_id" "wait-vm-${wanted}")" || {
      sleep 5
      continue
    }

    state="$(jq -r '.state // empty' <<<"$data")"
    status="$(jq -r '.status // empty' <<<"$data")"

    printf '\r[INFO] VM state=%-12s status=%-12s aguardando=%s' \
      "${state:-?}" "${status:-?}" "$wanted" >&2

    if [[ "$state" == "$wanted" ]]; then
      echo >&2
      return 0
    fi

    now="$(date +%s)"
    (( now - start < timeout )) || {
      echo >&2
      return 1
    }

    sleep 5
  done
}

wait_ssh() {
  local timeout="$1"
  local start now
  start="$(date +%s)"

  while true; do
    if ssh_cmd true >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    (( now - start < timeout )) || return 1
    sleep 5
  done
}

validate_existing_snapshot() {
  local snap_id="$1"
  local get_raw="$OUTPUT_DIR/snapshot-reuse-get.raw"
  local get_json="$OUTPUT_DIR/snapshot-reuse-get.json"
  local get_err="$OUTPUT_DIR/snapshot-reuse-get.stderr"
  local snap_state snap_status snap_name

  log "Validando snapshot existente: $snap_id"

  if ! run_mgc_json "$get_json" "$get_raw" "$get_err" \
      virtual-machine snapshots get \
      --id "$snap_id" \
      --region "$REGION" \
      -o json; then
    [[ -s "$get_err" ]] && cat "$get_err" >&2
    die "Não consegui consultar o snapshot informado."
  fi

  snap_state="$(jq -r '.state // .snapshot.state // .data.state // empty' "$get_json")"
  snap_status="$(jq -r '.status // .snapshot.status // .data.status // empty' "$get_json")"
  snap_name="$(jq -r '.name // .snapshot.name // .data.name // empty' "$get_json")"

  echo
  echo "Snapshot existente:"
  echo "  ID:     $snap_id"
  echo "  Nome:   ${snap_name:-?}"
  echo "  State:  ${snap_state:-?}"
  echo "  Status: ${snap_status:-?}"
  echo

  if [[ "$snap_state" != "available" ]]; then
    die "Snapshot ainda não está disponível (state=${snap_state:-?})."
  fi

  if [[ -n "$snap_status" && "$snap_status" != "completed" ]]; then
    die "Snapshot não está concluído (status=${snap_status})."
  fi

  SNAPSHOT_ID="$snap_id"
  SNAPSHOT_NAME="$snap_name"

  echo "$SNAPSHOT_ID" >"$OUTPUT_DIR/snapshot-id.txt"
  echo "$SNAPSHOT_NAME" >"$OUTPUT_DIR/snapshot-name.txt"

  ok "Snapshot existente está available/completed."
}

create_safety_snapshot() {
  local vm_id="$1"
  local vm_name="$2"
  local initial_state="$3"
  local snap_name snap_raw snap_json snap_err snap_id

  snap_name="export-$(sanitize_name "$vm_name")-${TS}"
  snap_raw="$OUTPUT_DIR/snapshot-create.raw"
  snap_json="$OUTPUT_DIR/snapshot-create.json"
  snap_err="$OUTPUT_DIR/snapshot-create.stderr"

  log "Criando snapshot de segurança: $snap_name"

  if ! run_mgc_json "$snap_json" "$snap_raw" "$snap_err" \
      virtual-machine snapshots create \
      --name "$snap_name" \
      --instance.id "$vm_id" \
      --region "$REGION" \
      --no-confirm \
      -o json; then
    [[ -s "$snap_err" ]] && cat "$snap_err" >&2
    die "Falha ao criar snapshot de segurança."
  fi

  snap_id="$(jq -r '.id // .uuid // .snapshot.id // .data.id // empty' "$snap_json")"

  if [[ -z "$snap_id" ]]; then
    log "ID não veio diretamente; procurando snapshot por nome..."
    local list_raw="$OUTPUT_DIR/snapshot-list.raw"
    local list_json="$OUTPUT_DIR/snapshot-list.json"
    local list_err="$OUTPUT_DIR/snapshot-list.stderr"

    run_mgc_json "$list_json" "$list_raw" "$list_err" \
      virtual-machine snapshots list \
      --name "$snap_name" \
      --control.limit 1000 \
      --region "$REGION" \
      -o json || die "Snapshot criado, mas não consegui localizá-lo."

    normalize_snapshots "$list_json" >"$OUTPUT_DIR/snapshot-list-normalized.json"
    snap_id="$(jq -r --arg n "$snap_name" \
      '[.[] | select(.name == $n)] | sort_by(.created_at // "") | last | (.id // .uuid // empty)' \
      "$OUTPUT_DIR/snapshot-list-normalized.json")"
  fi

  [[ -n "$snap_id" ]] || die "Não consegui determinar o ID do snapshot."

  echo "$snap_id" >"$OUTPUT_DIR/snapshot-id.txt"
  echo "$snap_name" >"$OUTPUT_DIR/snapshot-name.txt"

  log "Snapshot ID: $snap_id"
  log "Aguardando snapshot ficar available..."

  local start now snap_state snap_status
  start="$(date +%s)"

  while true; do
    local get_raw="$OUTPUT_DIR/snapshot-get.raw"
    local get_json="$OUTPUT_DIR/snapshot-get.json"
    local get_err="$OUTPUT_DIR/snapshot-get.stderr"

    if run_mgc_json "$get_json" "$get_raw" "$get_err" \
        virtual-machine snapshots get \
        --id "$snap_id" \
        --region "$REGION" \
        -o json; then

      snap_state="$(jq -r '.state // .snapshot.state // .data.state // empty' "$get_json")"
      snap_status="$(jq -r '.status // .snapshot.status // .data.status // empty' "$get_json")"

      printf '\r[INFO] Snapshot state=%-12s status=%-12s' \
        "${snap_state:-?}" "${snap_status:-?}" >&2

      if [[ "$snap_state" == "available" && \
            ( -z "$snap_status" || "$snap_status" == "completed" ) ]]; then
        echo >&2
        ok "Snapshot disponível e concluído."
        break
      fi

      if [[ "$snap_state" =~ ^(error|failed|failure)$ || \
            "$snap_status" =~ ^(error|failed|failure)$ ]]; then
        echo >&2
        die "Snapshot em erro: state=$snap_state status=$snap_status"
      fi
    fi

    now="$(date +%s)"
    (( now - start < SNAPSHOT_TIMEOUT )) || {
      echo >&2
      die "Timeout aguardando snapshot (state=${snap_state:-?}, status=${snap_status:-?})."
    }

    sleep 10
  done

  SNAPSHOT_ID="$snap_id"
  SNAPSHOT_NAME="$snap_name"
}

log "Localizando VM no tenant atual..."
locate_vm

VM_ID="$(jq -r '.id // .uuid // empty' "$INSTANCE_JSON")"
VM_NAME="$(jq -r '.name // empty' "$INSTANCE_JSON")"
VM_STATE="$(jq -r '.state // empty' "$INSTANCE_JSON")"
VM_STATUS="$(jq -r '.status // empty' "$INSTANCE_JSON")"
VM_AZ="$(jq -r '
  if (.availability_zone? | type) == "string" then .availability_zone
  elif (.availability_zone? | type) == "object" then (.availability_zone.name // .availability_zone.id // empty)
  else (.zone // empty)
  end
' "$INSTANCE_JSON")"
VM_MT_NAME="$(jq -r '
  if (.machine_type? | type) == "object" then (.machine_type.name // empty)
  elif (.machine_type? | type) == "string" then .machine_type
  else (.machine_type_name // empty)
  end
' "$INSTANCE_JSON")"

[[ -n "$VM_ID" ]] || die "Não consegui identificar o UUID da VM."
[[ -n "$VM_NAME" ]] || VM_NAME="$VM_REF"

ok "VM localizada: $VM_NAME ($VM_ID)"

log "Validando SSH e sudo..."
ssh_cmd true >/dev/null 2>"$OUTPUT_DIR/ssh.stderr" || {
  cat "$OUTPUT_DIR/ssh.stderr" >&2
  die "SSH indisponível."
}

ssh_cmd 'sudo -n true' >/dev/null 2>"$OUTPUT_DIR/sudo.stderr" || {
  cat "$OUTPUT_DIR/sudo.stderr" >&2
  die "É necessário sudo sem prompt para ler o block device."
}
ok "SSH e sudo disponíveis."

REMOTE_INFO="$OUTPUT_DIR/remote-disk-info.txt"

ssh_cmd 'sudo -n bash -s' >"$REMOTE_INFO" <<'REMOTE'
set -Eeuo pipefail

ROOT_SOURCE="$(findmnt -n -o SOURCE /)"
ROOT_REAL="$(readlink -f "$ROOT_SOURCE")"

# Caminha da partição/LV usada em / até o block device do tipo "disk".
# Não parseia os caracteres visuais da árvore do lsblk.
CURRENT="$ROOT_REAL"
PARENT_DISK=""

for _ in $(seq 1 16); do
  TYPE="$(lsblk -dn -o TYPE "$CURRENT" 2>/dev/null | head -n1 | tr -d '[:space:]')"

  if [[ "$TYPE" == "disk" ]]; then
    PARENT_DISK="$CURRENT"
    break
  fi

  PKNAME="$(lsblk -dn -o PKNAME "$CURRENT" 2>/dev/null | head -n1 | tr -d '[:space:]')"
  [[ -n "$PKNAME" ]] || break

  if [[ "$PKNAME" == /dev/* ]]; then
    CURRENT="$PKNAME"
  else
    CURRENT="/dev/$PKNAME"
  fi
done

[[ -n "$PARENT_DISK" && -b "$PARENT_DISK" ]] || {
  echo "ERROR=no_parent_disk"
  echo "ROOT_SOURCE=$ROOT_SOURCE"
  echo "ROOT_REAL=$ROOT_REAL"
  echo "LAST_DEVICE=${CURRENT:-}"
  exit 2
}

DISK_SIZE="$(blockdev --getsize64 "$PARENT_DISK")"
ROOT_FSTYPE="$(findmnt -n -o FSTYPE /)"
ROOT_USED="$(df -B1 --output=used / | tail -1 | tr -d ' ')"
ROOT_AVAIL="$(df -B1 --output=avail / | tail -1 | tr -d ' ')"

printf 'ROOT_SOURCE=%s\n' "$ROOT_SOURCE"
printf 'ROOT_REAL=%s\n' "$ROOT_REAL"
printf 'ROOT_FSTYPE=%s\n' "$ROOT_FSTYPE"
printf 'PARENT_DISK=%s\n' "$PARENT_DISK"
printf 'DISK_SIZE=%s\n' "$DISK_SIZE"
printf 'ROOT_USED=%s\n' "$ROOT_USED"
printf 'ROOT_AVAIL=%s\n' "$ROOT_AVAIL"

echo "LSBLK_BEGIN"
lsblk -b -p -o NAME,KNAME,PKNAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
echo "LSBLK_END"

echo "SERVICES_BEGIN"
for svc in docker.service docker.socket containerd.service; do
  printf '%s=' "$svc"
  systemctl is-active "$svc" 2>/dev/null || true
done
echo "SERVICES_END"

printf 'REMOTE_ZSTD='
if command -v zstd >/dev/null 2>&1; then
  echo yes
else
  echo no
fi

printf 'FSFREEZE='
if command -v fsfreeze >/dev/null 2>&1; then
  echo yes
else
  echo no
fi
REMOTE

kv(){
  grep -m1 "^$1=" "$REMOTE_INFO" | cut -d= -f2-
}

ROOT_SOURCE="$(kv ROOT_SOURCE)"
ROOT_REAL="$(kv ROOT_REAL)"
AUTO_DISK="$(kv PARENT_DISK)"
DISK_SIZE="$(kv DISK_SIZE)"
ROOT_USED="$(kv ROOT_USED)"
ROOT_FSTYPE="$(kv ROOT_FSTYPE)"
REMOTE_ZSTD="$(kv REMOTE_ZSTD)"
REMOTE_FSFREEZE="$(kv FSFREEZE)"

DISK="${DISK_OVERRIDE:-$AUTO_DISK}"

[[ "$DISK" == /dev/* ]] || die "Disco detectado inválido: '$DISK'"
[[ "$DISK_SIZE" =~ ^[0-9]+$ ]] || die "Não consegui obter tamanho do disco."

if [[ -n "$DISK_OVERRIDE" && "$DISK_OVERRIDE" != "$AUTO_DISK" ]]; then
  warn "Você sobrescreveu o disco detectado: auto=$AUTO_DISK override=$DISK_OVERRIDE"
  [[ "$FORCE" -eq 1 ]] || die "Use --force se isso for realmente intencional."
fi

LOCAL_ZSTD="no"
if command -v zstd >/dev/null 2>&1; then
  LOCAL_ZSTD="yes"
fi

USE_ZSTD=0
if [[ "$REMOTE_ZSTD" == "yes" && "$LOCAL_ZSTD" == "yes" ]]; then
  USE_ZSTD=1
fi

if [[ "$FREEZE_ROOT" -eq 1 && "$REMOTE_FSFREEZE" != "yes" ]]; then
  die "--freeze-root solicitado, mas fsfreeze não existe na VM."
fi

OUT_BASE="$(sanitize_name "$VM_NAME")-${TS}"
RAW_FILE="$OUTPUT_DIR/${OUT_BASE}.raw"
QCOW_FILE="$OUTPUT_DIR/${OUT_BASE}.qcow2"
SHA_FILE="$QCOW_FILE.sha256"
QEMU_INFO="$OUTPUT_DIR/qemu-img-info.json"
META_FILE="$OUTPUT_DIR/metadata.json"

LOCAL_FREE="$(df -PB1 "$OUTPUT_DIR" | awk 'NR==2 {print $4}')"

SNAPSHOT_ID=""
SNAPSHOT_NAME=""

if [[ -n "$REUSE_SNAPSHOT_ID" ]]; then
  validate_existing_snapshot "$REUSE_SNAPSHOT_ID"
fi

echo
echo "============================================================"
echo " PREFLIGHT DE EXPORTAÇÃO"
echo "============================================================"
printf 'VM:                 %s\n' "$VM_NAME"
printf 'UUID:               %s\n' "$VM_ID"
printf 'Região/AZ:          %s / %s\n' "$REGION" "${VM_AZ:-?}"
printf 'Machine type:       %s\n' "${VM_MT_NAME:-?}"
printf 'Estado atual:       %s / %s\n' "${VM_STATE:-?}" "${VM_STATUS:-?}"
printf 'SSH:                %s@%s\n' "$SSH_USER" "$SSH_HOST"
printf 'Root filesystem:    %s (%s)\n' "$ROOT_SOURCE" "$ROOT_FSTYPE"
printf 'Disco inteiro:      %s\n' "$DISK"
printf 'Tamanho virtual:    %s\n' "$(human_bytes "$DISK_SIZE")"
printf 'Uso do root:        %s\n' "$(human_bytes "$ROOT_USED")"
printf 'Espaço local livre: %s\n' "$(human_bytes "$LOCAL_FREE")"
printf 'Compressão stream:  %s\n' "$([[ "$USE_ZSTD" -eq 1 ]] && echo zstd || echo nenhuma)"
printf 'Parar Docker:       %s\n' "$([[ "$QUIESCE_DOCKER" -eq 1 ]] && echo SIM || echo NÃO)"
printf 'fsfreeze em /:      %s\n' "$([[ "$FREEZE_ROOT" -eq 1 ]] && echo SIM || echo NÃO)"
if [[ -n "$REUSE_SNAPSHOT_ID" ]]; then
  printf 'Snapshot segurança: REUTILIZAR %s\n' "$REUSE_SNAPSHOT_ID"
else
  printf 'Snapshot segurança: %s\n' "$([[ "$SAFETY_SNAPSHOT" -eq 1 ]] && echo CRIAR || echo NÃO)"
fi
printf 'Manter RAW:         %s\n' "$([[ "$KEEP_RAW" -eq 1 ]] && echo SIM || echo NÃO)"
echo

if [[ "$FREEZE_ROOT" -eq 1 ]]; then
  warn "ATENÇÃO: --freeze-root manterá / bloqueado para escrita durante TODA a cópia do disco."
  warn "Para o fluxo de clonagem, prefira --quiesce-docker + --safety-snapshot sem fsfreeze."
fi

echo "Layout remoto:"
sed -n '/LSBLK_BEGIN/,/LSBLK_END/p' "$REMOTE_INFO" | sed '1d;$d'
echo

# O raw será sparse, mas a conversão precisa de espaço adicional.
# Não bloqueia usando tamanho virtual como requisito, pois isso derrotaria o
# propósito do sparse; apenas avisa em cenários evidentemente apertados.
# Durante qemu-img convert, RAW e QCOW2 coexistem.
# No pior caso o RAW sparse pode ainda alocar grande parte do disco virtual
# se blocos livres do guest contiverem dados antigos não zerados.
MIN_RECOMMENDED=$(( DISK_SIZE + ROOT_USED + 5 * 1024 * 1024 * 1024 ))

if (( LOCAL_FREE < MIN_RECOMMENDED )); then
  warn "Espaço local abaixo da margem recomendada."
  warn "Livre:        $(human_bytes "$LOCAL_FREE")"
  warn "Recomendado:  $(human_bytes "$MIN_RECOMMENDED")"
  warn "Motivo: durante a conversão RAW e QCOW2 coexistem temporariamente."

  if [[ "$EXECUTE" -eq 1 && "$FORCE" -ne 1 ]]; then
    die "Libere espaço, use --output-dir em um filesystem maior ou use --force para assumir o risco."
  fi
fi

if [[ "$EXECUTE" -eq 0 ]]; then
  echo "============================================================"
  echo " MODO PREFLIGHT — NADA FOI ALTERADO"
  echo "============================================================"
  echo
  echo "Para iniciar a captura, repita o comando acrescentando:"
  echo "  --execute"
  echo
  if [[ "$QUIESCE_DOCKER" -eq 1 ]]; then
    echo "Docker/containerd ficarão parados durante a cópia do disco."
  fi
  if [[ "$FREEZE_ROOT" -eq 1 ]]; then
    echo "O filesystem / ficará congelado para escrita durante a cópia."
  fi
  if [[ "$SAFETY_SNAPSHOT" -eq 1 ]]; then
    echo "A VM será desligada para criar o snapshot e religada antes da captura."
  elif [[ -n "$REUSE_SNAPSHOT_ID" ]]; then
    echo "O snapshot existente será validado; a VM NÃO será parada para criar outro."
  fi
  exit 0
fi

# qemu-img só é necessário quando a exportação real for executada.
need qemu-img

echo
echo "============================================================"
echo " EXECUÇÃO AUTORIZADA"
echo "============================================================"

if [[ "$FREEZE_ROOT" -eq 1 && "$FORCE" -ne 1 ]]; then
  die "--freeze-root é uma operação avançada e prolongada. Se realmente quiser usá-la, acrescente --force."
fi

if [[ "$QUIESCE_DOCKER" -eq 0 && "$FREEZE_ROOT" -eq 0 ]]; then
  warn "Você está exportando uma VM ativa sem quiesce nem fsfreeze."
  warn "A imagem pode conter inconsistências de filesystem/aplicação."
  if [[ "$FORCE" -ne 1 ]]; then
    die "Use --quiesce-docker e/ou --freeze-root, ou --force para aceitar o risco."
  fi
fi

ORIGINAL_VM_STATE="$VM_STATE"

ensure_vm_started_if_we_stopped_it(){
  if [[ "$VM_STOPPED_BY_SCRIPT" -eq 1 ]]; then
    warn "Proteção de saída: religando a VM que foi parada pelo script..."
    mgc virtual-machine instances start \
      --id "$VM_ID" \
      --region "$REGION" \
      --no-confirm >/dev/null 2>&1 || true
    wait_vm_state "$VM_ID" "running" "$VM_TIMEOUT" >/dev/null 2>&1 || true
    VM_STOPPED_BY_SCRIPT=0
  fi
}

snapshot_phase_cleanup(){
  local rc=$?
  ensure_vm_started_if_we_stopped_it || true
  exit "$rc"
}

# Durante a fase de snapshot, qualquer falha após o stop tenta religar a VM.
trap snapshot_phase_cleanup EXIT INT TERM

if [[ "$SAFETY_SNAPSHOT" -eq 1 ]]; then
  if [[ "$VM_STATE" == "running" ]]; then
    log "Desligando VM para snapshot consistente..."
    mgc virtual-machine instances stop \
      --id "$VM_ID" \
      --region "$REGION" \
      --no-confirm >/dev/null

    # A partir daqui o script assume responsabilidade por religar a VM,
    # mesmo que o polling do estado falhe ou estoure timeout.
    VM_STOPPED_BY_SCRIPT=1

    wait_vm_state "$VM_ID" "stopped" "$VM_TIMEOUT" \
      || die "Timeout esperando VM parar."
    ok "VM parada."
  elif [[ "$VM_STATE" != "stopped" ]]; then
    die "Estado da VM não é running/stopped: $VM_STATE"
  fi

  create_safety_snapshot "$VM_ID" "$VM_NAME" "$VM_STATE"

  if [[ "$ORIGINAL_VM_STATE" == "running" ]]; then
    log "Religando VM..."
    mgc virtual-machine instances start \
      --id "$VM_ID" \
      --region "$REGION" \
      --no-confirm >/dev/null

    wait_vm_state "$VM_ID" "running" "$VM_TIMEOUT" \
      || die "Timeout esperando VM iniciar."

    log "Aguardando SSH voltar..."
    wait_ssh "$SSH_TIMEOUT" || die "VM iniciou, mas SSH não voltou no timeout."
    VM_STOPPED_BY_SCRIPT=0
    ok "VM e SSH disponíveis novamente."
  fi
fi

# A fase de snapshot terminou; substituímos o trap pelo cleanup da exportação.
trap - EXIT HUP INT TERM

SERVICES_FILE="$OUTPUT_DIR/services-to-resume.txt"
: >"$SERVICES_FILE"
SERVICES_QUIESCED=0

resume_services(){
  if [[ "$SERVICES_QUIESCED" -eq 1 && -s "$SERVICES_FILE" ]]; then
    warn "Religando serviços que estavam ativos antes da exportação..."
    # containerd antes do docker
    if grep -qx 'containerd.service' "$SERVICES_FILE"; then
      ssh_cmd 'sudo -n systemctl start containerd.service' >/dev/null 2>&1 || true
    fi
    if grep -qx 'docker.socket' "$SERVICES_FILE"; then
      ssh_cmd 'sudo -n systemctl start docker.socket' >/dev/null 2>&1 || true
    fi
    if grep -qx 'docker.service' "$SERVICES_FILE"; then
      ssh_cmd 'sudo -n systemctl start docker.service' >/dev/null 2>&1 || true
    fi
    SERVICES_QUIESCED=0
  fi
}

cleanup(){
  local rc=$?
  resume_services || true
  ensure_vm_started_if_we_stopped_it || true
  if [[ $rc -ne 0 ]]; then
    warn "Exportação interrompida/fracassou. RAW parcial, se existir, foi preservado:"
    warn "  $RAW_FILE"
  fi
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

if [[ "$QUIESCE_DOCKER" -eq 1 ]]; then
  log "Identificando serviços Docker/containerd ativos..."
  for svc in containerd.service docker.socket docker.service; do
    if ssh_cmd "systemctl is-active --quiet '$svc'"; then
      echo "$svc" >>"$SERVICES_FILE"
    fi
  done

  if [[ -s "$SERVICES_FILE" ]]; then
    log "Parando Docker/containerd..."

    # A partir daqui o trap assume responsabilidade por religar qualquer
    # serviço que estava ativo, mesmo se o systemctl stop falhar parcialmente.
    SERVICES_QUIESCED=1

    ssh_cmd "sudo -n systemctl stop docker.service docker.socket containerd.service"
    ok "Workloads Docker quiescidos."
  else
    log "Nenhum serviço Docker/containerd ativo."
  fi
fi

log "Executando sync antes da captura..."
ssh_cmd 'sudo -n sync'

rm -f "$RAW_FILE" "$QCOW_FILE" "$SHA_FILE"

echo
echo "============================================================"
echo " CAPTURA DO DISCO"
echo "============================================================"
echo "Origem:  $SSH_HOST:$DISK"
echo "Destino: $RAW_FILE"
echo

# O script remoto roda integralmente como root para que, depois do fsfreeze,
# não haja uma nova chamada sudo tentando escrever logs no filesystem congelado.
if [[ "$USE_ZSTD" -eq 1 ]]; then
  log "Usando stream comprimido com zstd."

  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" \
    "sudo -n bash -s -- '$DISK' '$FREEZE_ROOT'" <<'REMOTE' \
    | zstd -d -c \
    | dd of="$RAW_FILE" bs=16M conv=sparse status=progress
set -Eeuo pipefail
DISK="$1"
FREEZE="$2"
FROZEN=0

cleanup_remote(){
  rc=$?
  if [[ "$FROZEN" -eq 1 ]]; then
    echo "[REMOTE] Descongelando / ..." >&2
    fsfreeze -u / || true
    FROZEN=0
  fi
  exit "$rc"
}
trap cleanup_remote EXIT HUP INT TERM

sync

if [[ "$FREEZE" -eq 1 ]]; then
  echo "[REMOTE] Congelando filesystem / para escrita..." >&2
  fsfreeze -f /
  FROZEN=1
  echo "[REMOTE] Filesystem congelado." >&2
fi

echo "[REMOTE] Lendo $DISK ..." >&2
dd if="$DISK" bs=16M iflag=fullblock status=progress | zstd -T0 -1 -c
REMOTE

else
  warn "zstd não disponível nos dois lados; transferindo RAW sem compressão de rede."

  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" \
    "sudo -n bash -s -- '$DISK' '$FREEZE_ROOT'" <<'REMOTE' \
    | dd of="$RAW_FILE" bs=16M conv=sparse status=progress
set -Eeuo pipefail
DISK="$1"
FREEZE="$2"
FROZEN=0

cleanup_remote(){
  rc=$?
  if [[ "$FROZEN" -eq 1 ]]; then
    echo "[REMOTE] Descongelando / ..." >&2
    fsfreeze -u / || true
    FROZEN=0
  fi
  exit "$rc"
}
trap cleanup_remote EXIT HUP INT TERM

sync

if [[ "$FREEZE" -eq 1 ]]; then
  echo "[REMOTE] Congelando filesystem / para escrita..." >&2
  fsfreeze -f /
  FROZEN=1
  echo "[REMOTE] Filesystem congelado." >&2
fi

echo "[REMOTE] Lendo $DISK ..." >&2
dd if="$DISK" bs=16M iflag=fullblock status=progress
REMOTE
fi

RAW_SIZE="$(stat -c %s "$RAW_FILE")"
RAW_ALLOC="$(du -B1 "$RAW_FILE" | awk '{print $1}')"

if [[ "$RAW_SIZE" -ne "$DISK_SIZE" ]]; then
  die "RAW incompleto: esperado=$DISK_SIZE obtido=$RAW_SIZE"
fi

ok "RAW completo."
echo "Tamanho lógico RAW:    $(human_bytes "$RAW_SIZE")"
echo "Espaço alocado RAW:    $(human_bytes "$RAW_ALLOC")"

# O filesystem pode voltar a escrever depois da captura.
resume_services

log "Convertendo RAW sparse para QCOW2 comprimido..."
qemu-img convert \
  -p \
  -f raw \
  -O qcow2 \
  -c \
  "$RAW_FILE" \
  "$QCOW_FILE"

log "Validando estrutura QCOW2..."
qemu-img check "$QCOW_FILE" | tee "$OUTPUT_DIR/qemu-img-check.txt"

qemu-img info --output=json "$QCOW_FILE" >"$QEMU_INFO"

QCOW_VIRTUAL="$(jq -r '."virtual-size" // 0' "$QEMU_INFO")"
QCOW_ACTUAL="$(stat -c %s "$QCOW_FILE")"

[[ "$QCOW_VIRTUAL" -eq "$DISK_SIZE" ]] || \
  die "Virtual size do QCOW2 não corresponde ao disco de origem."

ok "QCOW2 validado."

log "Calculando SHA256..."
sha256sum "$QCOW_FILE" | tee "$SHA_FILE"

# MGC documenta limite de arquivo de 25 GB para Custom Image.
MGC_MAX_BYTES=$((25 * 1000 * 1000 * 1000))

echo
echo "============================================================"
echo " RESULTADO"
echo "============================================================"
printf 'QCOW2:             %s\n' "$QCOW_FILE"
printf 'Virtual size:      %s\n' "$(human_bytes "$QCOW_VIRTUAL")"
printf 'Arquivo QCOW2:     %s\n' "$(human_bytes "$QCOW_ACTUAL")"
printf 'Limite import MGC: 25 GB\n'
printf 'SHA256:            %s\n' "$SHA_FILE"

if (( QCOW_ACTUAL <= MGC_MAX_BYTES )); then
  echo
  ok "O arquivo está abaixo do limite documentado de 25 GB para Custom Image."
  MGC_SIZE_OK=true
else
  echo
  warn "O QCOW2 ultrapassa 25 GB e não poderá ser importado como Custom Image sem redução."
  MGC_SIZE_OK=false
fi

jq -n \
  --arg schema "mgc-vm-export/v1" \
  --arg script_version "$VERSION" \
  --arg exported_at "$(date -Iseconds)" \
  --arg vm_name "$VM_NAME" \
  --arg vm_id "$VM_ID" \
  --arg region "$REGION" \
  --arg az "${VM_AZ:-}" \
  --arg machine_type "${VM_MT_NAME:-}" \
  --arg ssh_host "$SSH_HOST" \
  --arg root_source "$ROOT_SOURCE" \
  --arg root_real "$ROOT_REAL" \
  --arg root_fstype "$ROOT_FSTYPE" \
  --arg disk "$DISK" \
  --argjson disk_size "$DISK_SIZE" \
  --arg snapshot_id "$SNAPSHOT_ID" \
  --arg snapshot_name "$SNAPSHOT_NAME" \
  --arg qcow2 "$(basename "$QCOW_FILE")" \
  --arg sha256_file "$(basename "$SHA_FILE")" \
  --argjson qcow2_size "$QCOW_ACTUAL" \
  --argjson mgc_size_ok "$MGC_SIZE_OK" \
  '{
    schema: $schema,
    script_version: $script_version,
    exported_at: $exported_at,
    source: {
      vm_name: $vm_name,
      vm_id: $vm_id,
      region: $region,
      availability_zone: $az,
      machine_type: $machine_type,
      ssh_host: $ssh_host,
      root_source: $root_source,
      root_real: $root_real,
      root_fstype: $root_fstype,
      disk: $disk,
      disk_size_bytes: $disk_size
    },
    safety_snapshot: {
      id: $snapshot_id,
      name: $snapshot_name
    },
    artifact: {
      qcow2: $qcow2,
      qcow2_size_bytes: $qcow2_size,
      sha256_file: $sha256_file,
      mgc_custom_image_25gb_ok: $mgc_size_ok
    }
  }' >"$META_FILE"

if [[ "$KEEP_RAW" -eq 0 ]]; then
  log "QCOW2 validado; removendo RAW intermediário..."
  rm -f "$RAW_FILE"
else
  warn "RAW preservado por --keep-raw: $RAW_FILE"
fi

trap - EXIT HUP INT TERM
resume_services

echo
echo "Metadata:"
echo "  $META_FILE"
echo
echo "Próxima etapa:"
echo "  sanitizar a imagem offline (cloud-init/chaves/machine-id)"
echo "  antes de enviá-la ao bucket do tenant de destino."
