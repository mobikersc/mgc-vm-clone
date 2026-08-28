#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.6.1"

SOURCE=""
OUTPUT=""
EXECUTE=0

NBD_DEV=""
NBD_CONNECTED=0
MOUNT_DIR=""
ROOT_PART=""

usage() {
cat <<'EOF'
mgc_vm_fix_network_v0.6.1.sh

Cria uma nova cópia da imagem portable removendo o netplan herdado
que contém MAC fixo, deixando o cloud-init recriar a rede no primeiro
boot da VM na Magalu Cloud.

SOURCE nunca é modificado.

Uso preflight:
  ./mgc_vm_fix_network_v0.6.1.sh \
    --source /var/tmp/vm-export/source-portable.qcow2

Execução:
  ./mgc_vm_fix_network_v0.6.1.sh \
    --source /var/tmp/vm-export/source-portable.qcow2 \
    --execute

Por padrão cria:
  <source-sem-.qcow2>-mgc.qcow2
EOF
}

log(){ printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE="${2:?}"; shift 2 ;;
    --output) OUTPUT="${2:?}"; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "$VERSION"; exit 0 ;;
    *) die "Opção desconhecida: $1" ;;
  esac
done

[[ -n "$SOURCE" ]] || { usage; die "Informe --source"; }
[[ -f "$SOURCE" ]] || die "Arquivo não encontrado: $SOURCE"

SOURCE="$(readlink -f "$SOURCE")"

if [[ -z "$OUTPUT" ]]; then
  dir="$(dirname "$SOURCE")"
  base="$(basename "$SOURCE" .qcow2)"
  OUTPUT="$dir/${base}-mgc.qcow2"
elif [[ "$OUTPUT" != /* ]]; then
  OUTPUT="$(pwd)/$OUTPUT"
fi

[[ "$SOURCE" != "$OUTPUT" ]] || die "Source e output não podem ser iguais."

for c in qemu-img qemu-nbd lsblk partprobe partx udevadm mount umount \
         grep find sha256sum cp awk sed stat numfmt; do
  need "$c"
done

sudo -v || die "sudo é necessário."
sudo modprobe nbd max_part=63 2>/dev/null || true

cleanup() {
  local rc=$?
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    sudo umount "$MOUNT_DIR" >/dev/null 2>&1 || true
    sudo rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  if [[ "$NBD_CONNECTED" -eq 1 && -n "$NBD_DEV" ]]; then
    sudo qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

choose_nbd() {
  local d name
  for d in /dev/nbd{0..31}; do
    [[ -b "$d" ]] || continue
    name="${d##*/}"
    if [[ ! -s "/sys/block/$name/pid" ]]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

attach() {
  local image="$1"
  local readonly="$2"

  NBD_DEV="$(choose_nbd)" || die "Nenhum NBD livre."

  if [[ "$readonly" -eq 1 ]]; then
    sudo qemu-nbd --read-only --format=qcow2 --connect="$NBD_DEV" "$image"
  else
    sudo qemu-nbd --format=qcow2 --connect="$NBD_DEV" "$image"
  fi

  NBD_CONNECTED=1
  sudo partprobe "$NBD_DEV" || true
  sudo partx -u "$NBD_DEV" >/dev/null 2>&1 || true
  sudo udevadm settle
  sleep 1
}

find_and_mount_root() {
  local readonly="$1"
  local dev fstype opts

  while read -r dev fstype; do
    [[ -b "$dev" ]] || continue

    case "$fstype" in
      ext3|ext4)
        [[ "$readonly" -eq 1 ]] && opts="ro,noload" || opts="rw"
        ;;
      xfs|btrfs)
        [[ "$readonly" -eq 1 ]] && opts="ro" || opts="rw"
        ;;
      *)
        continue
        ;;
    esac

    MOUNT_DIR="$(mktemp -d /tmp/mgc-netfix-root.XXXXXX)"

    if sudo mount -o "$opts" "$dev" "$MOUNT_DIR" 2>/dev/null; then
      if [[ -f "$MOUNT_DIR/etc/os-release" && -d "$MOUNT_DIR/etc/cloud" ]]; then
        ROOT_PART="$dev"
        return 0
      fi
      sudo umount "$MOUNT_DIR" || true
    fi

    sudo rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
    MOUNT_DIR=""
  done < <(
    lsblk -lnp -o NAME,FSTYPE "$NBD_DEV" |
      awk '$1 ~ /^\/dev\/nbd[0-9]+p[0-9]+$/ {print $1,$2}'
  )

  return 1
}

detach() {
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    sudo umount "$MOUNT_DIR"
    sudo rmdir "$MOUNT_DIR"
    MOUNT_DIR=""
  fi
  if [[ "$NBD_CONNECTED" -eq 1 ]]; then
    sudo qemu-nbd --disconnect "$NBD_DEV"
    NBD_CONNECTED=0
    NBD_DEV=""
    sudo udevadm settle
  fi
}

log "Validando source..."
qemu-img check "$SOURCE" >/dev/null
ok "Source QCOW2 íntegro."

log "Inspecionando configuração de rede da source..."
attach "$SOURCE" 1
find_and_mount_root 1 || die "Não consegui localizar root."

NETPLAN="$MOUNT_DIR/etc/netplan/50-cloud-init.yaml"

echo
echo "============================================================"
echo " REDE ATUAL"
echo "============================================================"

if [[ -f "$NETPLAN" ]]; then
  sudo cat "$NETPLAN"
else
  echo "(50-cloud-init.yaml não existe)"
fi
echo

# Procura explicitamente configurações que desabilitam o networking do cloud-init.
NETWORK_DISABLED=0
DISABLE_MATCHES="$(sudo grep -RniE \
  'network:[[:space:]]*\{[[:space:]]*config:[[:space:]]*disabled|config:[[:space:]]*disabled' \
  "$MOUNT_DIR/etc/cloud/cloud.cfg" \
  "$MOUNT_DIR/etc/cloud/cloud.cfg.d" 2>/dev/null || true)"

if [[ -n "$DISABLE_MATCHES" ]]; then
  NETWORK_DISABLED=1
  warn "Encontrei configuração que pode desabilitar networking do cloud-init:"
  echo "$DISABLE_MATCHES"
else
  ok "Não encontrei networking do cloud-init explicitamente desabilitado."
fi

CLOUD_STATE_COUNT="$(
  sudo find "$MOUNT_DIR/var/lib/cloud" -mindepth 1 -print 2>/dev/null | wc -l
)"

if [[ "$CLOUD_STATE_COUNT" -eq 0 ]]; then
  ok "/var/lib/cloud continua vazio."
else
  warn "/var/lib/cloud contém $CLOUD_STATE_COUNT item(ns)."
fi

if [[ -f "$NETPLAN" ]]; then
  if sudo grep -qiE 'macaddress:' "$NETPLAN"; then
    warn "50-cloud-init.yaml contém MAC fixo e precisa ser removido."
  else
    warn "50-cloud-init.yaml existe, mas não contém MAC fixo."
  fi
fi

detach

[[ "$NETWORK_DISABLED" -eq 0 ]] || die "Não vou remover o netplan enquanto cloud-init networking estiver desabilitado."

echo
echo "============================================================"
echo " PREFLIGHT"
echo "============================================================"
echo "Source preservada:   $SOURCE"
echo "Output planejado:    $OUTPUT"
echo "Ação:                remover /etc/netplan/50-cloud-init.yaml"
echo "Motivo:              remover MAC/interface herdados"
echo "Cloud-init state:    limpo"
echo
echo "O cloud-init deverá recriar a rede com os metadados da nova VM."
echo

if [[ "$EXECUTE" -eq 0 ]]; then
  echo "MODO PREFLIGHT — nenhuma alteração realizada."
  exit 0
fi

[[ ! -e "$OUTPUT" ]] || die "Output já existe: $OUTPUT"

log "Criando nova cópia MGC..."
cp --reflink=auto --sparse=always "$SOURCE" "$OUTPUT"
ok "Source preservada."

log "Abrindo cópia em modo escrita..."
attach "$OUTPUT" 0
find_and_mount_root 0 || die "Não consegui localizar root na cópia."

NETPLAN="$MOUNT_DIR/etc/netplan/50-cloud-init.yaml"

if [[ -f "$NETPLAN" ]]; then
  log "Removendo netplan herdado..."
  sudo rm -f "$NETPLAN"
  ok "50-cloud-init.yaml removido."
else
  warn "50-cloud-init.yaml já não existia."
fi

# Reforça que cloud-init fará nova primeira inicialização.
sudo rm -rf "$MOUNT_DIR/var/lib/cloud/"*
printf 'uninitialized\n' | sudo tee "$MOUNT_DIR/etc/machine-id" >/dev/null
sudo sync

detach

log "Validando imagem final..."
CHECK_FILE="${OUTPUT%.qcow2}.qemu-img-check.txt"
INFO_FILE="${OUTPUT%.qcow2}.qemu-img-info.json"
SHA_FILE="${OUTPUT}.sha256"

qemu-img check "$OUTPUT" | tee "$CHECK_FILE"
qemu-img info --output=json "$OUTPUT" >"$INFO_FILE"
sha256sum "$OUTPUT" | tee "$SHA_FILE"

SIZE="$(stat -c %s "$OUTPUT")"
MAX=$((25 * 1000 * 1000 * 1000))

echo
echo "============================================================"
echo " IMAGEM FINAL PARA MGC"
echo "============================================================"
echo "QCOW2:      $OUTPUT"
echo "Tamanho:    $(numfmt --to=iec-i --suffix=B "$SIZE")"
echo "SHA256:     $SHA_FILE"
echo

if (( SIZE <= MAX )); then
  ok "Imagem abaixo de 25 GB."
else
  die "Imagem acima do limite de 25 GB."
fi

echo
echo "Próximo passo: validar esta imagem e então fazer upload no Tenant B."
