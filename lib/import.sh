#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.7.2"

IMAGE=""
TENANT=""
REGION="br-se1"
CUSTOM_IMAGE_NAME=""
DISK_GB=40
RAM_GB=8
VCPU=4
WAIT_TIMEOUT=5400
POLL_SECONDS=20
EXECUTE=0
KEEP_TEMP=0

TEMP_KEY_ID=""
BUCKET=""
OBJECT=""
CUSTOM_IMAGE_ID=""
IMPORT_SUCCEEDED=0
ORIGINAL_TENANT=""

usage() {
cat <<'EOF'
mgc_vm_import_tenant_v0.7.2.sh

Orquestra a importação de um QCOW2 já preparado para outro tenant MGC.

SEM --execute:
  - valida o QCOW2
  - valida SHA256 (se existir .sha256)
  - valida limite de 25 GB
  - verifica acesso ao tenant de destino
  - NÃO cria API key, bucket ou Custom Image

COM --execute:
  1. seleciona tenant de destino sem imprimir tokens
  2. cria API key temporária de Object Storage
  3. cria bucket privado temporário
  4. faz upload do QCOW2
  5. gera presigned GET URL de 72h
  6. registra Custom Image
  7. aguarda status=active
  8. em sucesso, remove bucket e revoga a API key temporária
     (use --keep-temp para manter)

A criação da VM é propositalmente a próxima etapa, pois depende de
VPC/subnet/security-group/SSH key do tenant de destino.

Uso:
  ./mgc_vm_import_tenant_v0.7.2.sh \
    --image /var/tmp/vm-export/source-portable-mgc.qcow2 \
    --tenant UUID_DO_TENANT \
    --name my-vm-clone

Execução:
  mesmo comando + --execute

Opções:
  --image <qcow2>            QCOW2 final
  --tenant <uuid>            Tenant de destino
  --region <regiao>          default: br-se1
  --name <nome>              nome da Custom Image
  --disk <GB>                default: 40
  --ram <GB>                 default: 8
  --vcpu <n>                 default: 4
  --timeout <segundos>       default: 5400
  --poll <segundos>          default: 20
  --keep-temp                não remove bucket/API key após sucesso
  --execute                  executa de verdade
  --version
  -h, --help
EOF
}

log(){ printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="${2:?}"; shift 2 ;;
    --tenant) TENANT="${2:?}"; shift 2 ;;
    --region) REGION="${2:?}"; shift 2 ;;
    --name) CUSTOM_IMAGE_NAME="${2:?}"; shift 2 ;;
    --disk) DISK_GB="${2:?}"; shift 2 ;;
    --ram) RAM_GB="${2:?}"; shift 2 ;;
    --vcpu) VCPU="${2:?}"; shift 2 ;;
    --timeout) WAIT_TIMEOUT="${2:?}"; shift 2 ;;
    --poll) POLL_SECONDS="${2:?}"; shift 2 ;;
    --keep-temp) KEEP_TEMP=1; shift ;;
    --execute) EXECUTE=1; shift ;;
    --version) echo "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opção desconhecida: $1" ;;
  esac
done

[[ -n "$IMAGE" ]] || { usage; die "Informe --image"; }
[[ -n "$TENANT" ]] || { usage; die "Informe --tenant"; }
[[ -n "$CUSTOM_IMAGE_NAME" ]] || { usage; die "Informe --name"; }
[[ -f "$IMAGE" ]] || die "Imagem não encontrada: $IMAGE"

IMAGE="$(readlink -f "$IMAGE")"
OBJECT="$(basename "$IMAGE")"

for c in mgc qemu-img sha256sum stat python3 grep sed awk date numfmt; do
  need "$c"
done

TMPDIR_RUN="$(mktemp -d /tmp/mgc-vm-import.XXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# MGC CLI às vezes mistura output de terminal com JSON.
# Extrai o primeiro objeto/array JSON válido quando possível.
clean_json() {
  local input="$1"
  local output="$2"

  python3 - "$input" "$output" <<'PY'
import json, re, sys
src, dst = sys.argv[1], sys.argv[2]
raw = open(src, "rb").read().decode("utf-8", "replace")
raw = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", raw)

dec = json.JSONDecoder()
for i, ch in enumerate(raw):
    if ch not in "[{":
        continue
    try:
        obj, _ = dec.raw_decode(raw[i:])
    except Exception:
        continue
    with open(dst, "w", encoding="utf-8") as f:
        json.dump(obj, f)
    sys.exit(0)
sys.exit(1)
PY
}

extract_uuid() {
  local raw_file="$1"
  local json_file="${2:-}"

  if [[ -n "$json_file" && -s "$json_file" ]]; then
    python3 - "$json_file" <<'PY'
import json,sys,re
d=json.load(open(sys.argv[1]))
def walk(x):
    if isinstance(x, dict):
        for k,v in x.items():
            if k.lower() in ("id","uuid") and isinstance(v,str):
                if re.fullmatch(r"[0-9a-fA-F-]{36}",v):
                    print(v); return True
            if walk(v): return True
    elif isinstance(x,list):
        for v in x:
            if walk(v): return True
    return False
walk(d)
PY
    return
  fi

  grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' \
    "$raw_file" | head -n1 || true
}

current_tenant_uuid() {
  local out="$TMPDIR_RUN/tenant-current.txt"

  mgc auth tenant current >"$out" 2>&1 || return 1

  python3 - "$out" <<'PY'
import re, sys

raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace")

# Remove ANSI/controle de terminal.
raw = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", raw)
raw = raw.replace("\r", "\n")

# Preferimos explicitamente o campo uuid: do tenant current.
m = re.search(
    r"(?mi)^[ \t]*uuid[ \t]*:[ \t]*['\"]?"
    r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
    raw,
)
if m:
    print(m.group(1))
    raise SystemExit(0)

# Fallback: qualquer UUID isolado no output.
m = re.search(
    r"(?i)\b([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b",
    raw,
)
if m:
    print(m.group(1))
    raise SystemExit(0)

raise SystemExit(1)
PY
}

switch_tenant_silent() {
  local uuid="$1"
  # tenant set pode imprimir access/refresh tokens; nunca mostramos stdout/stderr.
  if ! mgc auth tenant set "$uuid" >"$TMPDIR_RUN/tenant-set.txt" 2>&1; then
    die "Falha ao selecionar tenant $uuid."
  fi

  local now
  now="$(current_tenant_uuid || true)"
  [[ "$now" == "$uuid" ]] || die "Tenant ativo não corresponde ao solicitado."
}

echo "============================================================"
echo " PREFLIGHT - IMPORTAÇÃO PARA OUTRO TENANT"
echo "============================================================"
echo "Imagem:          $IMAGE"
echo "Tenant destino: $TENANT"
echo "Região:          $REGION"
echo "Custom Image:    $CUSTOM_IMAGE_NAME"
echo "Requisitos:      ${VCPU} vCPU / ${RAM_GB} GB RAM / ${DISK_GB} GB disk"
echo

log "Validando QCOW2..."
CHECK_OUTPUT="$(qemu-img check "$IMAGE" 2>&1)" || {
  echo "$CHECK_OUTPUT"
  die "qemu-img check falhou."
}
ok "QCOW2 íntegro."

INFO_JSON="$TMPDIR_RUN/qemu-info.json"
qemu-img info --output=json "$IMAGE" >"$INFO_JSON"

FORMAT="$(python3 - "$INFO_JSON" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("format",""))
PY
)"
VIRTUAL_SIZE="$(python3 - "$INFO_JSON" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("virtual-size",0))
PY
)"
FILE_SIZE="$(stat -c %s "$IMAGE")"

[[ "$FORMAT" == "qcow2" ]] || die "Formato não é qcow2: $FORMAT"

printf 'Virtual size:    %s GiB\n' "$(( VIRTUAL_SIZE / 1024 / 1024 / 1024 ))"
printf 'Arquivo físico:  %s\n' "$(numfmt --to=iec-i --suffix=B "$FILE_SIZE")"

MGC_MAX=$((25 * 1000 * 1000 * 1000))
(( FILE_SIZE <= MGC_MAX )) || die "Arquivo ultrapassa 25 GB."
ok "Imagem abaixo do limite de 25 GB."

SHA_FILE="${IMAGE}.sha256"
if [[ -f "$SHA_FILE" ]]; then
  log "Validando SHA256 existente..."
  (
    cd "$(dirname "$IMAGE")"
    sha256sum -c "$(basename "$SHA_FILE")"
  ) >/dev/null || die "SHA256 não confere."
  ok "SHA256 confere."
else
  warn "Arquivo .sha256 não encontrado; calculando apenas para conferência."
  sha256sum "$IMAGE" >"$TMPDIR_RUN/image.sha256"
fi

ORIGINAL_TENANT="$(current_tenant_uuid || true)"
if [[ -z "$ORIGINAL_TENANT" ]]; then
  warn "Não consegui extrair o UUID de 'mgc auth tenant current'."
  warn "O output bruto foi preservado apenas no diretório temporário interno."
  die "Não consegui identificar o tenant atual."
fi
log "Tenant atual identificado: $ORIGINAL_TENANT"

log "Validando acesso ao tenant de destino..."
if [[ "$ORIGINAL_TENANT" != "$TENANT" ]]; then
  switch_tenant_silent "$TENANT"
fi
ok "Tenant de destino acessível."

# Em preflight restauramos o contexto original para não mudar o ambiente local.
if [[ "$EXECUTE" -eq 0 && "$ORIGINAL_TENANT" != "$TENANT" ]]; then
  switch_tenant_silent "$ORIGINAL_TENANT"
fi

echo
echo "============================================================"
echo " RESULTADO DO PREFLIGHT"
echo "============================================================"
echo "QCOW2:             OK"
echo "SHA256:            OK"
echo "Limite 25 GB:      OK"
echo "Tenant destino:    OK"
echo
echo "Nenhum bucket, API key ou Custom Image foi criado."

if [[ "$EXECUTE" -eq 0 ]]; then
  echo
  echo "Para executar, repita o mesmo comando acrescentando:"
  echo "  --execute"
  exit 0
fi

# Garante tenant destino novamente em execução.
switch_tenant_silent "$TENANT"

echo
echo "============================================================"
echo " EXECUÇÃO - IMPORTAÇÃO"
echo "============================================================"

STAMP="$(date +%Y%m%d-%H%M%S)"
KEY_NAME="vm-import-${STAMP}"
BUCKET="mgc-vm-import-${TENANT:0:8}-${STAMP}-$RANDOM"
BUCKET="$(tr '[:upper:]' '[:lower:]' <<<"$BUCKET")"

log "Criando API key temporária de Object Storage..."
KEY_RAW="$TMPDIR_RUN/key-create.raw"
KEY_JSON="$TMPDIR_RUN/key-create.json"

if ! mgc object-storage api-key create \
    --name "$KEY_NAME" \
    --description "Temporary VM custom-image import" \
    -o json -r >"$KEY_RAW" 2>&1; then
  cat "$KEY_RAW" >&2
  die "Falha ao criar API key temporária."
fi

clean_json "$KEY_RAW" "$KEY_JSON" >/dev/null 2>&1 || true
TEMP_KEY_ID="$(extract_uuid "$KEY_RAW" "$KEY_JSON")"
[[ -n "$TEMP_KEY_ID" ]] || die "API key criada, mas não consegui identificar o UUID."

# Não mostramos output do set, pois algumas versões da CLI exibem secret.
if ! mgc object-storage api-key set --uuid "$TEMP_KEY_ID" \
    >"$TMPDIR_RUN/key-set.txt" 2>&1; then
  die "Falha ao selecionar API key temporária."
fi
ok "API key temporária criada e selecionada (UUID ocultado no fluxo normal)."

log "Criando bucket privado temporário: $BUCKET"
if ! mgc object-storage buckets create \
    --bucket "$BUCKET" \
    --private \
    --region "$REGION" \
    --no-confirm \
    >"$TMPDIR_RUN/bucket-create.txt" 2>&1; then
  cat "$TMPDIR_RUN/bucket-create.txt" >&2
  die "Falha ao criar bucket."
fi
ok "Bucket criado."

log "Enviando QCOW2 (${OBJECT})..."
if ! mgc object-storage objects upload \
    "$IMAGE" \
    "$BUCKET" \
    --region "$REGION" \
    >"$TMPDIR_RUN/upload.txt" 2>&1; then
  cat "$TMPDIR_RUN/upload.txt" >&2
  warn "Bucket mantido para diagnóstico: $BUCKET"
  warn "API key temporária mantida para diagnóstico."
  exit 2
fi
ok "Upload concluído."

log "Gerando URL presigned GET válida por 72h..."
PRESIGN_RAW="$TMPDIR_RUN/presign.raw"
if ! mgc object-storage objects presign \
    "s3://${BUCKET}/${OBJECT}" \
    --expires-in 72h \
    --method GET \
    --region "$REGION" \
    >"$PRESIGN_RAW" 2>&1; then
  cat "$PRESIGN_RAW" >&2
  warn "Bucket mantido para diagnóstico: $BUCKET"
  exit 3
fi

PRESIGNED_URL="$(python3 - "$PRESIGN_RAW" <<'PY'
import re,sys
s=open(sys.argv[1],encoding="utf-8",errors="replace").read()
m=re.search(r'https://[^\s"\'<>]+',s)
print(m.group(0) if m else "")
PY
)"
[[ -n "$PRESIGNED_URL" ]] || die "Não consegui extrair a URL presigned."
ok "URL presigned gerada (não será exibida)."

log "Registrando Custom Image: $CUSTOM_IMAGE_NAME"
IMG_RAW="$TMPDIR_RUN/custom-create.raw"
IMG_JSON="$TMPDIR_RUN/custom-create.json"

if ! mgc virtual-machine images custom create \
    --name="$CUSTOM_IMAGE_NAME" \
    --url="$PRESIGNED_URL" \
    --platform="linux" \
    --architecture="x86/64" \
    --license="unlicensed" \
    --version="1.0" \
    --description="Imported by mgc_vm_import_tenant_v0.7.2" \
    --uefi=true \
    --requirements.disk="$DISK_GB" \
    --requirements.ram="$RAM_GB" \
    --requirements.vcpu="$VCPU" \
    --region "$REGION" \
    -o json -r >"$IMG_RAW" 2>&1; then
  cat "$IMG_RAW" >&2
  warn "Bucket mantido para diagnóstico: $BUCKET"
  exit 4
fi

clean_json "$IMG_RAW" "$IMG_JSON" >/dev/null 2>&1 || true
CUSTOM_IMAGE_ID="$(extract_uuid "$IMG_RAW" "$IMG_JSON")"
[[ -n "$CUSTOM_IMAGE_ID" ]] || die "Custom Image foi enviada, mas não consegui identificar o ID."
ok "Custom Image registrada."

log "Aguardando Custom Image ficar active..."
START_TS="$(date +%s)"
LAST_STATUS=""

while true; do
  GET_RAW="$TMPDIR_RUN/custom-get.raw"
  GET_JSON="$TMPDIR_RUN/custom-get.json"

  if mgc virtual-machine images custom get \
      --id "$CUSTOM_IMAGE_ID" \
      --region "$REGION" \
      -o json -r >"$GET_RAW" 2>&1; then

    rm -f "$GET_JSON"
    clean_json "$GET_RAW" "$GET_JSON" >/dev/null 2>&1 || true

    if [[ -s "$GET_JSON" ]]; then
      LAST_STATUS="$(python3 - "$GET_JSON" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for path in [
    ("status",), ("state",),
    ("image","status"), ("image","state"),
    ("data","status"), ("data","state")
]:
    x=d
    try:
        for k in path: x=x[k]
        if isinstance(x,str):
            print(x.lower()); raise SystemExit
    except Exception:
        pass
print("")
PY
)"
    else
      LAST_STATUS="$(sed -nE 's/^[[:space:]]*(status|state):[[:space:]]*"?([^"[:space:]]+)"?.*/\2/p' "$GET_RAW" | head -n1 | tr '[:upper:]' '[:lower:]')"
    fi
  fi

  printf '\r[INFO] Custom Image status=%-12s' "${LAST_STATUS:-?}" >&2

  case "$LAST_STATUS" in
    active)
      echo >&2
      IMPORT_SUCCEEDED=1
      ok "Custom Image ACTIVE."
      break
      ;;
    error|failed|failure|deleted|deleting)
      echo >&2
      warn "Import terminou em estado inesperado: $LAST_STATUS"
      warn "Bucket mantido para diagnóstico: $BUCKET"
      warn "Custom Image ID: $CUSTOM_IMAGE_ID"
      exit 5
      ;;
  esac

  NOW_TS="$(date +%s)"
  if (( NOW_TS - START_TS >= WAIT_TIMEOUT )); then
    echo >&2
    warn "Timeout aguardando Custom Image."
    warn "Último status: ${LAST_STATUS:-desconhecido}"
    warn "Bucket mantido para diagnóstico: $BUCKET"
    warn "Custom Image ID: $CUSTOM_IMAGE_ID"
    exit 6
  fi

  sleep "$POLL_SECONDS"
done

if [[ "$IMPORT_SUCCEEDED" -eq 1 && "$KEEP_TEMP" -eq 0 ]]; then
  log "Removendo bucket temporário..."
  if mgc object-storage buckets delete \
      "$BUCKET" \
      --recursive \
      --region "$REGION" \
      --no-confirm \
      >"$TMPDIR_RUN/bucket-delete.txt" 2>&1; then
    ok "Bucket temporário removido."
  else
    warn "Não consegui remover o bucket automaticamente: $BUCKET"
  fi

  log "Revogando API key temporária..."
  if mgc object-storage api-key revoke \
      --uuid "$TEMP_KEY_ID" \
      --no-confirm \
      >"$TMPDIR_RUN/key-revoke.txt" 2>&1; then
    ok "API key temporária revogada."
  else
    warn "Não consegui revogar a API key temporária automaticamente."
    warn "UUID da key temporária: $TEMP_KEY_ID"
  fi
fi

echo
echo "============================================================"
echo " IMPORTAÇÃO CONCLUÍDA"
echo "============================================================"
echo "Tenant:          $TENANT"
echo "Custom Image:    $CUSTOM_IMAGE_NAME"
echo "Custom Image ID: $CUSTOM_IMAGE_ID"
echo "Status:          active"
echo "Região:          $REGION"
echo
if [[ "$KEEP_TEMP" -eq 1 ]]; then
  echo "Recursos temporários foram mantidos (--keep-temp):"
  echo "Bucket:          $BUCKET"
  echo "API key UUID:    $TEMP_KEY_ID"
else
  echo "Bucket/API key temporários: limpeza solicitada."
fi
echo
echo "PRÓXIMA ETAPA:"
echo "  criar a VM usando esta Custom Image."
echo "  Para isso precisaremos escolher:"
echo "    - availability zone"
echo "    - machine type"
echo "    - VPC/subnet"
echo "    - security group"
echo "    - SSH key"
