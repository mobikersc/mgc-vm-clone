#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.7.4"

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
RESUME_BUCKET=""

TMP=""
CURRENT_OS_KEY_ID=""
CURRENT_OS_KEY_NAME=""
CUSTOM_IMAGE_ID=""
CUSTOM_IMAGE_STATUS=""
PRESIGNED_URL=""

usage() {
cat <<'EOF'
mgc_vm_import_tenant_v0.7.4.sh

Importa ou RETOMA a importação de uma Custom Image no tenant destino.

Modo normal:
  cria key temporária + bucket + upload + presign + Custom Image.

Modo retomada:
  --resume-bucket <bucket>
  reutiliza o bucket já existente e NÃO reenvia o QCOW2.

Uso para o caso atual:
  ./mgc_vm_import_tenant_v0.7.4.sh \
    --image /var/tmp/vm-export/source-portable-mgc.qcow2 \
    --tenant <TARGET_TENANT_UUID> \
    --region br-se1 \
    --name my-vm-clone \
    --resume-bucket <EXISTING_BUCKET>

Acrescente --execute para efetivamente registrar/revalidar a Custom Image.

Opções:
  --image <qcow2>
  --tenant <uuid>
  --region <region>
  --name <nome>
  --disk <GB>        default 40
  --ram <GB>         default 8
  --vcpu <n>         default 4
  --resume-bucket <nome>
  --timeout <s>      default 5400
  --poll <s>         default 20
  --keep-temp
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
    --image) IMAGE="${2:?}"; shift 2 ;;
    --tenant) TENANT="${2:?}"; shift 2 ;;
    --region) REGION="${2:?}"; shift 2 ;;
    --name) CUSTOM_IMAGE_NAME="${2:?}"; shift 2 ;;
    --disk) DISK_GB="${2:?}"; shift 2 ;;
    --ram) RAM_GB="${2:?}"; shift 2 ;;
    --vcpu) VCPU="${2:?}"; shift 2 ;;
    --resume-bucket) RESUME_BUCKET="${2:?}"; shift 2 ;;
    --timeout) WAIT_TIMEOUT="${2:?}"; shift 2 ;;
    --poll) POLL_SECONDS="${2:?}"; shift 2 ;;
    --keep-temp) KEEP_TEMP=1; shift ;;
    --execute) EXECUTE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "$VERSION"; exit 0 ;;
    *) die "Opção desconhecida: $1" ;;
  esac
done

[[ -n "$IMAGE" ]] || die "Informe --image"
[[ -n "$TENANT" ]] || die "Informe --tenant"
[[ -n "$CUSTOM_IMAGE_NAME" ]] || die "Informe --name"
[[ -f "$IMAGE" ]] || die "Imagem não encontrada: $IMAGE"

IMAGE="$(readlink -f "$IMAGE")"
OBJECT="$(basename "$IMAGE")"

for c in mgc qemu-img sha256sum stat numfmt python3 curl od grep sed awk date; do
  need "$c"
done

TMP="$(mktemp -d /tmp/mgc-import-resume.XXXXXX)"
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

extract_uuid_field() {
  python3 - "$1" <<'PY'
import re,sys
s=open(sys.argv[1],"rb").read().decode("utf-8","replace")
s=re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]","",s).replace("\r","\n")
m=re.search(r'(?mi)^[ \t]*uuid[ \t]*:[ \t]*["\']?([0-9a-f-]{36})',s)
if not m:
    m=re.search(r'(?i)\b([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\b',s)
if m: print(m.group(1))
PY
}

current_tenant() {
  local f="$TMP/tenant-current.txt"
  mgc auth tenant current >"$f" 2>&1 || return 1
  extract_uuid_field "$f"
}

switch_tenant() {
  local wanted="$1"
  local cur
  cur="$(current_tenant || true)"
  if [[ "$cur" != "$wanted" ]]; then
    mgc auth tenant set "$wanted" >"$TMP/tenant-set.txt" 2>&1 \
      || die "Falha ao trocar para tenant $wanted."
  fi
  cur="$(current_tenant || true)"
  [[ "$cur" == "$wanted" ]] || die "Tenant atual não corresponde ao destino."
}

current_os_key() {
  local f="$TMP/os-key-current.txt"
  mgc object-storage api-key current >"$f" 2>&1 || return 1

  CURRENT_OS_KEY_ID="$(extract_uuid_field "$f")"
  CURRENT_OS_KEY_NAME="$(
    clean_text "$f" |
      sed -nE 's/^[[:space:]]*name:[[:space:]]*"?([^"]+)"?[[:space:]]*$/\1/p' |
      head -n1
  )"
}

extract_any_uuid() {
  python3 - "$1" <<'PY'
import re,sys
s=open(sys.argv[1],"rb").read().decode("utf-8","replace")
s=re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]","",s)
m=re.search(r'(?i)\b([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b',s)
print(m.group(1) if m else "")
PY
}

extract_presigned_url() {
  python3 - "$1" <<'PY'
import re,sys
s=open(sys.argv[1],"rb").read().decode("utf-8","replace")
s=re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]","",s)
m=re.search(r'https://[^\s"\'<>]+',s)
print(m.group(0) if m else "")
PY
}

find_image_by_name() {
  local f="$TMP/image-list.raw"
  local j="$TMP/image-list.json"

  CUSTOM_IMAGE_ID=""
  CUSTOM_IMAGE_STATUS=""

  mgc virtual-machine images list \
      --name "$CUSTOM_IMAGE_NAME" \
      --region "$REGION" \
      -o json -r >"$f" 2>&1 || return 1

  python3 - "$f" "$CUSTOM_IMAGE_NAME" >"$j" <<'PY'
import json,re,sys
raw=open(sys.argv[1],"rb").read().decode("utf-8","replace")
raw=re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]","",raw)
name=sys.argv[2]

dec=json.JSONDecoder()
obj=None
for i,c in enumerate(raw):
    if c not in "[{": continue
    try:
        obj,_=dec.raw_decode(raw[i:])
        break
    except Exception:
        pass

if obj is None:
    raise SystemExit(1)

matches=[]
def walk(x):
    if isinstance(x,dict):
        if x.get("name")==name:
            matches.append(x)
        for v in x.values(): walk(v)
    elif isinstance(x,list):
        for v in x: walk(v)
walk(obj)

if not matches:
    print("{}")
else:
    x=matches[0]
    out={
      "id": x.get("id") or x.get("uuid") or "",
      "status": x.get("status") or x.get("state") or "",
      "name": x.get("name",""),
      "platform": x.get("platform",""),
    }
    print(json.dumps(out))
PY

  CUSTOM_IMAGE_ID="$(python3 - "$j" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("id",""))
PY
)"
  CUSTOM_IMAGE_STATUS="$(python3 - "$j" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(str(d.get("status","")).lower())
PY
)"
}

wait_catalog_by_name() {
  local timeout="${1:-600}"
  local start now

  start="$(date +%s)"
  while true; do
    find_image_by_name || true

    if [[ -n "$CUSTOM_IMAGE_ID" ]]; then
      ok "Imagem encontrada no catálogo: ID=$CUSTOM_IMAGE_ID status=${CUSTOM_IMAGE_STATUS:-?}"
      return 0
    fi

    now="$(date +%s)"
    if (( now - start >= timeout )); then
      return 1
    fi

    printf '\r[INFO] Aguardando imagem aparecer no catálogo por nome... ' >&2
    sleep "$POLL_SECONDS"
  done
}

wait_image() {
  local start now f id="$1"
  start="$(date +%s)"

  while true; do
    f="$TMP/custom-get.raw"
    if mgc virtual-machine images custom get \
        --id "$id" \
        --region "$REGION" \
        -o json -r >"$f" 2>&1; then

      CUSTOM_IMAGE_STATUS="$(
        python3 - "$f" <<'PY'
import json,re,sys
raw=open(sys.argv[1],"rb").read().decode("utf-8","replace")
raw=re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]","",raw)
dec=json.JSONDecoder(); obj=None
for i,c in enumerate(raw):
    if c not in "[{": continue
    try: obj,_=dec.raw_decode(raw[i:]); break
    except: pass
def pick(x):
    if isinstance(x,dict):
        for k in ("status","state"):
            v=x.get(k)
            if isinstance(v,str): return v.lower()
        for v in x.values():
            r=pick(v)
            if r:return r
    elif isinstance(x,list):
        for v in x:
            r=pick(v)
            if r:return r
    return ""
print(pick(obj) if obj is not None else "")
PY
      )"
    fi

    printf '\r[INFO] Custom Image status=%-12s' "${CUSTOM_IMAGE_STATUS:-?}" >&2

    case "$CUSTOM_IMAGE_STATUS" in
      active)
        echo >&2
        ok "Custom Image ACTIVE."
        return 0
        ;;
      error|failed|failure|deleted|deleting)
        echo >&2
        return 2
        ;;
    esac

    now="$(date +%s)"
    if (( now-start >= WAIT_TIMEOUT )); then
      echo >&2
      return 3
    fi
    sleep "$POLL_SECONDS"
  done
}

cleanup_temp_resources() {
  [[ "$KEEP_TEMP" -eq 1 ]] && return 0
  [[ -n "$RESUME_BUCKET" ]] || return 0

  log "Removendo bucket temporário..."
  if mgc object-storage buckets delete \
      "$RESUME_BUCKET" --recursive --region "$REGION" --no-confirm \
      >"$TMP/bucket-delete.txt" 2>&1; then
    ok "Bucket removido."
  else
    warn "Não consegui remover bucket automaticamente: $RESUME_BUCKET"
  fi

  # Só revoga automaticamente uma key criada pelo nosso fluxo.
  if [[ -n "$CURRENT_OS_KEY_ID" && "$CURRENT_OS_KEY_NAME" == vm-import-* ]]; then
    log "Revogando API key temporária..."
    if mgc object-storage api-key revoke \
        --uuid "$CURRENT_OS_KEY_ID" --no-confirm \
        >"$TMP/key-revoke.txt" 2>&1; then
      ok "API key temporária revogada."
    else
      warn "Não consegui revogar API key temporária."
    fi
  else
    warn "API key atual não parece temporária; não será revogada automaticamente."
  fi
}

echo "============================================================"
echo " RETOMADA DA IMPORTAÇÃO"
echo "============================================================"
echo "Imagem local:    $IMAGE"
echo "Tenant:          $TENANT"
echo "Região:          $REGION"
echo "Nome da imagem:  $CUSTOM_IMAGE_NAME"
echo "Bucket existente:${RESUME_BUCKET:+ $RESUME_BUCKET}"
echo

log "Validando QCOW2 local..."
qemu-img check "$IMAGE" >/dev/null || die "QCOW2 local inválido."
ok "QCOW2 local íntegro."

FILE_SIZE="$(stat -c %s "$IMAGE")"
(( FILE_SIZE <= 25*1000*1000*1000 )) || die "Imagem acima de 25 GB."

SHA_FILE="${IMAGE}.sha256"
if [[ -f "$SHA_FILE" ]]; then
  (
    cd "$(dirname "$IMAGE")"
    sha256sum -c "$(basename "$SHA_FILE")" >/dev/null
  ) || die "SHA256 local não confere."
  ok "SHA256 local confere."
fi

switch_tenant "$TENANT"
ok "Tenant destino confirmado."

current_os_key || die "Não consegui consultar a API key atual de Object Storage."
[[ -n "$CURRENT_OS_KEY_ID" ]] || die "Não consegui identificar a API key atual."
ok "Credencial de Object Storage ativa."

if [[ -z "$RESUME_BUCKET" ]]; then
  die "Para este caso use --resume-bucket com o bucket preservado pelo v0.7.2."
fi

log "Validando objeto existente no bucket..."
OBJ_RAW="$TMP/object-list.txt"
mgc object-storage objects list "$RESUME_BUCKET" --region "$REGION" \
  >"$OBJ_RAW" 2>&1 || die "Não consegui listar o bucket existente."

if clean_text "$OBJ_RAW" | grep -Fq "$OBJECT"; then
  ok "Objeto QCOW2 encontrado no bucket."
else
  die "Objeto '$OBJECT' não foi encontrado em '$RESUME_BUCKET'."
fi

log "Gerando nova presigned URL GET de 72h..."
P_RAW="$TMP/presign.txt"
mgc object-storage objects presign \
    "s3://${RESUME_BUCKET}/${OBJECT}" \
    --expires-in 72h --method GET --region "$REGION" \
    >"$P_RAW" 2>&1 || die "Falha ao gerar presigned URL."

PRESIGNED_URL="$(extract_presigned_url "$P_RAW")"
[[ -n "$PRESIGNED_URL" ]] || die "Não consegui extrair presigned URL."
ok "Presigned URL gerada (oculta)."

log "Testando leitura remota dos 4 primeiros bytes..."
MAGIC_FILE="$TMP/qcow.magic"
HTTP_CODE="$(
  curl --silent --show-error --location \
    --range 0-3 \
    --max-filesize 16 \
    --output "$MAGIC_FILE" \
    --write-out '%{http_code}' \
    "$PRESIGNED_URL" || true
)"

MAGIC_HEX="$(od -An -tx1 -N4 "$MAGIC_FILE" 2>/dev/null | tr -d ' \n')"

if [[ "$HTTP_CODE" =~ ^20[06]$ && "$MAGIC_HEX" == "514649fb" ]]; then
  ok "URL remota entrega um QCOW2 válido (magic 514649fb)."
else
  warn "HTTP=$HTTP_CODE magic=${MAGIC_HEX:-?}"
  die "A URL presigned não passou na validação remota."
fi

log "Verificando se a imagem já existe apesar do 500 anterior..."
find_image_by_name || true

if [[ -n "$CUSTOM_IMAGE_ID" ]]; then
  ok "Imagem já encontrada no catálogo: ID=$CUSTOM_IMAGE_ID status=${CUSTOM_IMAGE_STATUS:-?}"

  if [[ "$CUSTOM_IMAGE_STATUS" == "active" ]]; then
    cleanup_temp_resources
    echo
    echo "IMPORTAÇÃO JÁ CONCLUÍDA."
    echo "Custom Image ID: $CUSTOM_IMAGE_ID"
    exit 0
  fi

  if [[ "$EXECUTE" -eq 0 ]]; then
    echo
    echo "A imagem já existe; com --execute o script apenas aguardará o status active."
    exit 0
  fi

  wait_image "$CUSTOM_IMAGE_ID" || {
    warn "Imagem existente não chegou a active. Recursos temporários preservados."
    exit 5
  }

  cleanup_temp_resources
  echo
  echo "IMPORTAÇÃO CONCLUÍDA."
  echo "Custom Image ID: $CUSTOM_IMAGE_ID"
  exit 0
fi

echo
echo "Nenhuma imagem '$CUSTOM_IMAGE_NAME' foi encontrada no catálogo."
echo "O 500 anterior aparentemente não criou o recurso."

if [[ "$EXECUTE" -eq 0 ]]; then
  echo
  echo "Com --execute, tentarei o create novamente usando:"
  echo "  - somente os campos obrigatórios/requisitos"
  echo "  - --uefi como flag booleana canônica"
  echo "  - o mesmo QCOW2 já existente no bucket"
  exit 0
fi

log "Tentando registrar/recuperar Custom Image com o mesmo nome..."
CREATE_RAW="$TMP/custom-create.raw"

set +e
mgc virtual-machine images custom create \
  --name="$CUSTOM_IMAGE_NAME" \
  --url="$PRESIGNED_URL" \
  --platform="linux" \
  --architecture="x86/64" \
  --license="unlicensed" \
  --uefi=true \
  --requirements.disk="$DISK_GB" \
  --requirements.ram="$RAM_GB" \
  --requirements.vcpu="$VCPU" \
  --region="$REGION" \
  -o json -r >"$CREATE_RAW" 2>&1
CREATE_RC=$?
set -e

# CRÍTICO: o ID precisa vir preferencialmente da resposta do próprio create.
CREATE_ID="$(extract_any_uuid "$CREATE_RAW")"

if [[ "$CREATE_RC" -eq 0 ]]; then
  if [[ -n "$CREATE_ID" ]]; then
    CUSTOM_IMAGE_ID="$CREATE_ID"
    CUSTOM_IMAGE_STATUS="importing"
    ok "Create aceito; ID capturado diretamente: $CUSTOM_IMAGE_ID"
  else
    warn "Create retornou sucesso, mas a CLI não expôs um UUID parseável."
    warn "Vou aguardar o recurso aparecer no catálogo sem repetir o create."
    if ! wait_catalog_by_name 600; then
      warn "A imagem não apareceu no catálogo dentro da janela de recuperação."
      warn "Bucket preservado: $RESUME_BUCKET"
      warn "Não farei outro create automaticamente para evitar duplicidade."
      exit 6
    fi
  fi
else
  CLEAN_CREATE="$TMP/custom-create-clean.txt"
  clean_text "$CREATE_RAW" >"$CLEAN_CREATE"

  HTTP_STATUS="$(
    sed -nE 's/.*Status:[[:space:]]*([0-9]{3}).*/\1/p' "$CLEAN_CREATE" | head -n1
  )"
  REQUEST_ID="$(
    sed -nE 's/.*Request ID:[[:space:]]*([^[:space:]]+).*/\1/p' "$CLEAN_CREATE" | head -n1
  )"
  TRACE_ID="$(
    sed -nE 's/.*MGC Trace ID:[[:space:]]*([^[:space:]]+).*/\1/p' "$CLEAN_CREATE" | head -n1
  )"

  warn "Create retornou erro${HTTP_STATUS:+ HTTP $HTTP_STATUS}."
  [[ -n "$REQUEST_ID" ]] && warn "Request ID: $REQUEST_ID"
  [[ -n "$TRACE_ID" ]] && warn "MGC Trace ID: $TRACE_ID"

  # O nome da Custom Image deve ser único no tenant. Um conflito pode indicar
  # que a tentativa anterior criou o recurso, ainda que ele não esteja visível
  # no catálogo geral durante importing.
  if grep -qiE 'conflict|already exists|already_exist|duplicate|unique|409' "$CLEAN_CREATE"; then
    warn "O backend indica conflito/duplicidade de nome; não criarei outra imagem."
    if ! wait_catalog_by_name "$WAIT_TIMEOUT"; then
      warn "Imagem existente ainda não apareceu no catálogo."
      warn "Bucket preservado: $RESUME_BUCKET"
      exit 7
    fi
  else
    # Para 5xx também aguardamos eventual criação antes de declarar falha.
    warn "Aguardando alguns minutos para verificar se o backend criou o recurso apesar do erro..."
    if ! wait_catalog_by_name 300; then
      warn "Não encontrei a imagem após o erro do create."
      warn "Bucket preservado: $RESUME_BUCKET"
      warn "Não farei nova tentativa automática nesta execução."
      exit 8
    fi
  fi
fi

ok "Custom Image identificada: ID=$CUSTOM_IMAGE_ID status=${CUSTOM_IMAGE_STATUS:-?}"

wait_image "$CUSTOM_IMAGE_ID" || {
  warn "Import não chegou a active. Bucket preservado: $RESUME_BUCKET"
  exit 7
}

cleanup_temp_resources

echo
echo "============================================================"
echo " IMPORTAÇÃO CONCLUÍDA"
echo "============================================================"
echo "Custom Image:    $CUSTOM_IMAGE_NAME"
echo "Custom Image ID: $CUSTOM_IMAGE_ID"
echo "Status:          active"
echo
echo "Próximo passo: criar a VM a partir desta imagem."
