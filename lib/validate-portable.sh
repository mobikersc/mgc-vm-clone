#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.6.2"

IMAGE=""
NBD_DEV=""
NBD_CONNECTED=0
MOUNT_DIR=""
ROOT_PART=""
FAIL=0
WARN=0

usage() {
cat <<'EOF'
mgc_vm_validate_portable_v0.6.2.sh

Valida uma imagem QCOW2 portável antes do upload como Custom Image.

Checagens:
  - qemu-img check
  - arquitetura/formato/tamanho
  - root filesystem
  - Ubuntu/cloud-init
  - /var/lib/cloud vazio
  - machine-id = uninitialized ou vazio
  - SSH host keys ausentes
  - authorized_keys ausentes
  - netplan exibido e analisado para DHCP/IP/MAC fixos
  - limite MGC de 25 GB

Uso:
  ./mgc_vm_validate_portable_v0.6.2.sh \
    --image /var/tmp/vm-export/source-portable.qcow2
EOF
}

log(){ printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn(){ WARN=$((WARN+1)); printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
bad(){ FAIL=$((FAIL+1)); printf '\033[1;31m[FALHA]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "$VERSION"; exit 0 ;;
    *) die "Opção desconhecida: $1" ;;
  esac
done

[[ -n "$IMAGE" ]] || { usage; die "Informe --image"; }
[[ -f "$IMAGE" ]] || die "Arquivo não encontrado: $IMAGE"
IMAGE="$(readlink -f "$IMAGE")"

for c in qemu-img qemu-nbd lsblk partprobe partx udevadm mount umount \
         sha256sum grep find awk sed stat numfmt; do
  need "$c"
done

sudo -v || die "sudo é necessário."

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
      echo "$d"; return 0
    fi
  done
  return 1
}

sudo modprobe nbd max_part=63 2>/dev/null || true

echo "============================================================"
echo " VALIDAÇÃO QCOW2 PORTÁVEL"
echo "============================================================"
echo "Imagem: $IMAGE"
echo

log "Validando estrutura QCOW2..."
CHECK="$(qemu-img check "$IMAGE" 2>&1)" || {
  echo "$CHECK"
  die "qemu-img check falhou."
}
echo "$CHECK"
ok "QCOW2 estruturalmente válido."

INFO="$(qemu-img info --output=json "$IMAGE")"
FORMAT="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("format",""))' <<<"$INFO")"
VIRTUAL_SIZE="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("virtual-size",0))' <<<"$INFO")"
FILE_SIZE="$(stat -c %s "$IMAGE")"

[[ "$FORMAT" == "qcow2" ]] && ok "Formato qcow2." || bad "Formato inesperado: $FORMAT"

printf 'Virtual size: %s\n' "$(numfmt --to=iec-i --suffix=B "$VIRTUAL_SIZE")"
printf 'File size:    %s\n' "$(numfmt --to=iec-i --suffix=B "$FILE_SIZE")"

MGC_MAX=$((25 * 1000 * 1000 * 1000))
if (( FILE_SIZE <= MGC_MAX )); then
  ok "Arquivo abaixo do limite MGC de 25 GB."
else
  bad "Arquivo ultrapassa 25 GB."
fi

log "Conectando imagem somente leitura..."
NBD_DEV="$(choose_nbd)" || die "Nenhum NBD livre."
sudo qemu-nbd --read-only --format=qcow2 --connect="$NBD_DEV" "$IMAGE"
NBD_CONNECTED=1
sudo partprobe "$NBD_DEV" || true
sudo partx -u "$NBD_DEV" >/dev/null 2>&1 || true
sudo udevadm settle
sleep 1

ROOT_PART=""
while read -r dev fstype; do
  [[ -b "$dev" ]] || continue
  case "$fstype" in
    ext3|ext4) opts="ro,noload" ;;
    xfs|btrfs) opts="ro" ;;
    *) continue ;;
  esac

  MOUNT_DIR="$(mktemp -d /tmp/mgc-validate-root.XXXXXX)"
  if sudo mount -o "$opts" "$dev" "$MOUNT_DIR" 2>/dev/null; then
    if [[ -f "$MOUNT_DIR/etc/os-release" && -d "$MOUNT_DIR/usr" ]]; then
      ROOT_PART="$dev"
      break
    fi
    sudo umount "$MOUNT_DIR" || true
  fi
  sudo rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
  MOUNT_DIR=""
done < <(lsblk -lnp -o NAME,FSTYPE "$NBD_DEV" | awk '$1 ~ /^\/dev\/nbd[0-9]+p[0-9]+$/ {print $1,$2}')

[[ -n "$ROOT_PART" ]] || die "Não localizei a partição root."
ok "Root encontrada em $ROOT_PART."

OS="$(sudo sh -c ". '$MOUNT_DIR/etc/os-release'; printf '%s' \"\$PRETTY_NAME\"" 2>/dev/null || true)"
echo "OS: $OS"

if [[ -x "$MOUNT_DIR/usr/bin/cloud-init" ]]; then
  ok "cloud-init presente."
else
  bad "cloud-init não encontrado."
fi

echo
echo "=== IDENTIDADE / CLOUD-INIT ==="

if sudo find "$MOUNT_DIR/var/lib/cloud" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
  bad "/var/lib/cloud ainda contém estado."
  sudo find "$MOUNT_DIR/var/lib/cloud" -maxdepth 2 -mindepth 1 -print 2>/dev/null | head -30
else
  ok "/var/lib/cloud vazio."
fi

MID="$(sudo cat "$MOUNT_DIR/etc/machine-id" 2>/dev/null | tr -d '\r\n' || true)"
echo "machine-id: '${MID}'"
case "$MID" in
  ""|"uninitialized") ok "machine-id preparado para regeneração." ;;
  *) bad "machine-id ainda contém identidade anterior." ;;
esac

HOSTKEY_COUNT="$(sudo find "$MOUNT_DIR/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' 2>/dev/null | wc -l)"
if [[ "$HOSTKEY_COUNT" -eq 0 ]]; then
  ok "SSH host keys antigas ausentes."
else
  bad "Ainda existem $HOSTKEY_COUNT SSH host key(s)."
fi

AUTH_COUNT="$(
  {
    sudo find "$MOUNT_DIR/root" -maxdepth 2 -type f -path '*/.ssh/authorized_keys' 2>/dev/null
    sudo find "$MOUNT_DIR/home" -maxdepth 3 -type f -path '*/.ssh/authorized_keys' 2>/dev/null
  } | wc -l
)"
if [[ "$AUTH_COUNT" -eq 0 ]]; then
  ok "authorized_keys herdados ausentes."
else
  bad "Ainda existem $AUTH_COUNT authorized_keys."
fi

echo
echo "=== NETPLAN ==="
NETFILES=()
while IFS= read -r f; do NETFILES+=("$f"); done < <(
  sudo find "$MOUNT_DIR/etc/netplan" -maxdepth 1 -type f \
    \( -name '*.yaml' -o -name '*.yml' \) -print 2>/dev/null
)

if [[ ${#NETFILES[@]} -eq 0 ]]; then
  echo "Nenhum arquivo netplan persistido na imagem."

  NETWORK_DISABLED="$(
    sudo grep -RniE       'network:[[:space:]]*\{[[:space:]]*config:[[:space:]]*disabled|config:[[:space:]]*disabled'       "$MOUNT_DIR/etc/cloud/cloud.cfg"       "$MOUNT_DIR/etc/cloud/cloud.cfg.d" 2>/dev/null || true
  )"

  if [[ -n "$NETWORK_DISABLED" ]]; then
    bad "Não há netplan e o networking do cloud-init parece estar desabilitado."
    echo "$NETWORK_DISABLED"
  else
    ok "Sem netplan herdado e cloud-init networking não está desabilitado."
    ok "A rede poderá ser gerada no primeiro boot com os metadados da nova VM."
  fi
else
  for f in "${NETFILES[@]}"; do
    rel="${f#$MOUNT_DIR}"
    echo "--- $rel ---"
    sudo cat "$f"
    echo

    CONTENT="$(sudo cat "$f")"

    if grep -qiE 'dhcp4:[[:space:]]*true|dhcp6:[[:space:]]*true' <<<"$CONTENT"; then
      ok "$rel contém DHCP habilitado."
    else
      warn "$rel não mostra DHCP explicitamente."
    fi

    if grep -qiE 'addresses:[[:space:]]*\[[^]]|^[[:space:]]*addresses:[[:space:]]*$' <<<"$CONTENT"; then
      bad "$rel contém configuração de endereço estático."
    else
      ok "$rel não contém addresses estáticos evidentes."
    fi

    if grep -qiE 'macaddress:|match:[[:space:]]*$|set-name:' <<<"$CONTENT"; then
      warn "$rel contém match/macaddress/set-name; revise portabilidade entre VMs."
    else
      ok "$rel não fixa MAC/set-name."
    fi

    if grep -qiE 'gateway4:|gateway6:|routes:[[:space:]]*$' <<<"$CONTENT"; then
      warn "$rel contém gateway/rotas explícitos; revisar antes do import."
    fi
  done
fi

echo
echo "=== SHA256 ==="
sha256sum "$IMAGE"

echo
echo "============================================================"
echo " RESULTADO"
echo "============================================================"
echo "Falhas:   $FAIL"
echo "Warnings: $WARN"

if (( FAIL > 0 )); then
  printf '\033[1;31mREPROVADO para upload até corrigir as falhas.\033[0m\n'
  exit 2
elif (( WARN > 0 )); then
  printf '\033[1;33mAPROVADO COM RESSALVAS — revise os warnings de rede.\033[0m\n'
else
  printf '\033[1;32mAPROVADO para upload como Custom Image.\033[0m\n'
fi
