#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.5.3-nbd"

SOURCE=""
OUTPUT=""
EXECUTE=0
KEEP_EXISTING_OUTPUT=0
REMOVE_AUTH_KEYS=1
CLEAN_LOGS=1
CLEAN_MACHINE_ID=1
REMOVE_SSH_HOSTKEYS=1
CLEAN_CLOUD_NETWORK=1

MOUNT_DIR=""
NBD_DEV=""
NBD_CONNECTED=0
KPARTX_ACTIVE=0
ROOT_PART=""
PARTITION_MODE=""

usage() {
cat <<'EOF'
mgc_vm_prepare_image_v0.5.3_nbd.sh

Prepara uma cópia QCOW2 para Custom Image usando qemu-nbd.
Não depende de virt-inspector/libguestfs.

O SOURCE nunca é modificado.

Sem --execute:
  - conecta o QCOW2 somente leitura
  - força/procura partições via kernel/partx/kpartx
  - detecta a partição root
  - inspeciona Ubuntu/cloud-init/netplan
  - desmonta e desconecta tudo

Com --execute:
  - copia SOURCE -> OUTPUT
  - conecta a CÓPIA em modo escrita
  - limpa cloud-init/machine-id/SSH keys/authorized_keys
  - valida QCOW2 e SHA256

Uso:
  ./mgc_vm_prepare_image_v0.5.3_nbd.sh \
    --source /var/tmp/vm-export/source.qcow2

  ./mgc_vm_prepare_image_v0.5.3_nbd.sh \
    --source /var/tmp/vm-export/source.qcow2 \
    --execute

Opções:
  --source <qcow2>
  --output <qcow2>
  --execute
  --keep-existing-output
  --keep-authorized-keys
  --keep-cloud-init-logs
  --keep-machine-id
  --keep-ssh-hostkeys
  --keep-cloud-network
  -h, --help
  --version

Dependências principais:
  qemu-img qemu-nbd lsblk fdisk partprobe partx mount umount

Fallback opcional:
  kpartx
  Ubuntu/Debian: sudo apt install -y kpartx
EOF
}

log(){ printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $1"; }
has(){ command -v "$1" >/dev/null 2>&1; }

human_bytes(){
  numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 bytes"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE="${2:?}"; shift 2 ;;
    --output) OUTPUT="${2:?}"; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    --keep-existing-output) KEEP_EXISTING_OUTPUT=1; shift ;;
    --keep-authorized-keys) REMOVE_AUTH_KEYS=0; shift ;;
    --keep-cloud-init-logs) CLEAN_LOGS=0; shift ;;
    --keep-machine-id) CLEAN_MACHINE_ID=0; shift ;;
    --keep-ssh-hostkeys) REMOVE_SSH_HOSTKEYS=0; shift ;;
    --keep-cloud-network) CLEAN_CLOUD_NETWORK=0; shift ;;
    --version) echo "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opção desconhecida: $1" ;;
  esac
done

[[ -n "$SOURCE" ]] || { usage; die "Informe --source"; }
[[ -f "$SOURCE" ]] || die "Arquivo não encontrado: $SOURCE"

SOURCE="$(readlink -f "$SOURCE")"

if [[ -z "$OUTPUT" ]]; then
  dir="$(dirname "$SOURCE")"
  base="$(basename "$SOURCE")"
  base="${base%.qcow2}"
  OUTPUT="$dir/${base}-portable.qcow2"
elif [[ "$OUTPUT" != /* ]]; then
  OUTPUT="$(pwd)/$OUTPUT"
fi

[[ "$SOURCE" != "$OUTPUT" ]] || die "SOURCE e OUTPUT não podem ser iguais."

for c in qemu-img qemu-nbd lsblk fdisk partprobe partx mount umount udevadm \
         sha256sum numfmt cp awk grep sed find; do
  need "$c"
done

sudo -v || die "sudo é necessário."

WORK_BASE="${OUTPUT%.qcow2}"
PRE_DIR="${WORK_BASE}.nbd-preflight"
mkdir -p "$PRE_DIR"

cleanup() {
  local rc=$?

  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    sudo umount "$MOUNT_DIR/boot/efi" >/dev/null 2>&1 || true
    sudo umount "$MOUNT_DIR/boot" >/dev/null 2>&1 || true
    sudo umount "$MOUNT_DIR" >/dev/null 2>&1 || true
    sudo rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  MOUNT_DIR=""

  if [[ "$KPARTX_ACTIVE" -eq 1 && -n "$NBD_DEV" ]]; then
    sudo kpartx -d "$NBD_DEV" >/dev/null 2>&1 || true
    KPARTX_ACTIVE=0
  fi

  if [[ "$NBD_CONNECTED" -eq 1 && -n "$NBD_DEV" ]]; then
    sudo qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
    NBD_CONNECTED=0
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

active_nbd_count() {
  local count=0 d name
  for d in /dev/nbd*; do
    [[ -b "$d" ]] || continue
    name="${d##*/}"
    [[ -s "/sys/block/$name/pid" ]] && count=$((count+1))
  done
  echo "$count"
}

ensure_nbd_module() {
  log "Verificando módulo nbd..."

  if [[ ! -d /sys/module/nbd ]]; then
    sudo modprobe nbd max_part=32
    return
  fi

  local max_part="?"
  if [[ -r /sys/module/nbd/parameters/max_part ]]; then
    max_part="$(cat /sys/module/nbd/parameters/max_part)"
  fi

  log "nbd já carregado; max_part=$max_part"

  # Se foi carregado sem partições e não existe nenhum NBD em uso,
  # recarrega com max_part=32.
  if [[ "$max_part" =~ ^[0-9]+$ && "$max_part" -lt 16 ]]; then
    local active
    active="$(active_nbd_count)"
    if [[ "$active" -eq 0 ]]; then
      warn "nbd foi carregado com max_part=$max_part; recarregando com max_part=32."
      sudo modprobe -r nbd
      sudo modprobe nbd max_part=32
    else
      warn "nbd max_part=$max_part, mas há $active NBD(s) em uso; não vou descarregar o módulo."
      warn "Se as partições não aparecerem, usarei kpartx."
    fi
  fi
}

save_nbd_diagnostics() {
  local tag="$1"

  {
    echo "=== date ==="
    date -Iseconds
    echo
    echo "=== nbd ==="
    echo "$NBD_DEV"
    echo
    echo "=== max_part ==="
    cat /sys/module/nbd/parameters/max_part 2>/dev/null || true
    echo
    echo "=== lsblk ==="
    lsblk -p -o NAME,KNAME,PKNAME,SIZE,TYPE,FSTYPE,PARTTYPE,PARTLABEL,MOUNTPOINTS "$NBD_DEV" 2>&1 || true
    echo
    echo "=== fdisk ==="
    sudo fdisk -l "$NBD_DEV" 2>&1 || true
    echo
    echo "=== partx ==="
    sudo partx --show "$NBD_DEV" 2>&1 || true
    echo
    echo "=== mapper ==="
    ls -l /dev/mapper 2>&1 || true
  } >"$PRE_DIR/${tag}-nbd-diagnostics.txt"
}

kernel_partition_candidates() {
  lsblk -lnp -o NAME,TYPE "$NBD_DEV" 2>/dev/null |
    awk '$2=="part"{print $1}'
}

mapper_partition_candidates() {
  local base="${NBD_DEV##*/}"
  find /dev/mapper -maxdepth 1 -type l -o -type b 2>/dev/null |
    grep -E "/${base}p?[0-9]+$" || true
}

partition_candidates() {
  kernel_partition_candidates
  if [[ "$KPARTX_ACTIVE" -eq 1 ]]; then
    mapper_partition_candidates
  fi
}

expose_partitions() {
  log "Solicitando releitura da tabela GPT..."
  sudo partprobe "$NBD_DEV" || true
  sudo partx -u "$NBD_DEV" >/dev/null 2>&1 || \
    sudo partx -a "$NBD_DEV" >/dev/null 2>&1 || true
  sudo udevadm settle
  sleep 1

  local count
  count="$(kernel_partition_candidates | wc -l)"

  if [[ "$count" -gt 0 ]]; then
    PARTITION_MODE="kernel"
    ok "Kernel expôs $count partição(ões) em ${NBD_DEV}p*."
    return 0
  fi

  warn "Kernel não criou nós de partição ${NBD_DEV}p*."

  if ! has kpartx; then
    warn "kpartx não está instalado."
    return 1
  fi

  log "Tentando fallback com kpartx..."
  sudo kpartx -av "$NBD_DEV" >"$PRE_DIR/kpartx-add.txt" 2>&1
  KPARTX_ACTIVE=1
  sudo udevadm settle
  sleep 1

  count="$(mapper_partition_candidates | wc -l)"

  if [[ "$count" -gt 0 ]]; then
    PARTITION_MODE="kpartx"
    ok "kpartx expôs $count partição(ões) em /dev/mapper."
    return 0
  fi

  return 1
}

attach_image() {
  local image="$1"
  local readonly="$2"

  ensure_nbd_module

  NBD_DEV="$(choose_nbd)" || die "Nenhum /dev/nbdX livre."
  log "Usando $NBD_DEV"

  if [[ "$readonly" -eq 1 ]]; then
    sudo qemu-nbd \
      --read-only \
      --format=qcow2 \
      --connect="$NBD_DEV" \
      "$image"
  else
    sudo qemu-nbd \
      --format=qcow2 \
      --connect="$NBD_DEV" \
      "$image"
  fi

  NBD_CONNECTED=1
  sudo udevadm settle
  sleep 1

  save_nbd_diagnostics "before-partition-scan"

  if ! expose_partitions; then
    save_nbd_diagnostics "partition-scan-failed"
    echo
    warn "Não consegui expor as partições da imagem."
    warn "Diagnóstico salvo em:"
    warn "  $PRE_DIR/partition-scan-failed-nbd-diagnostics.txt"
    echo
    if ! has kpartx; then
      warn "Instale kpartx e tente novamente:"
      warn "  sudo apt install -y kpartx"
    fi
    return 1
  fi

  save_nbd_diagnostics "after-partition-scan"

  # Diagnóstico adicional, somente leitura: registra estado do ext filesystem.
  # Não executa correção.
  if has e2fsck; then
    while IFS= read -r p; do
      [[ -b "$p" ]] || continue
      local pfs
      pfs="$(lsblk -dn -o FSTYPE "$p" 2>/dev/null | head -n1 | tr -d '[:space:]')"
      case "$pfs" in
        ext2|ext3|ext4)
          sudo e2fsck -fn "$p" \
            >"$PRE_DIR/e2fsck-$(basename "$p").txt" 2>&1 || true
          ;;
      esac
    done < <(partition_candidates)
  fi
}

detect_root_partition() {
  local readonly="$1"
  local dev fstype opts

  ROOT_PART=""

  while IFS= read -r dev; do
    [[ -n "$dev" && -b "$dev" ]] || continue

    fstype="$(lsblk -dn -o FSTYPE "$dev" 2>/dev/null | head -n1 | tr -d '[:space:]')"

    # /dev/mapper entries nem sempre exibem FSTYPE imediatamente;
    # blkid é fallback.
    if [[ -z "$fstype" ]] && has blkid; then
      fstype="$(sudo blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
    fi

    case "$fstype" in
      ext2|ext3|ext4|xfs|btrfs) ;;
      *) continue ;;
    esac

    MOUNT_DIR="$(mktemp -d /tmp/mgc-qcow-root.XXXXXX)"

    # IMPORTANTE:
    # Em ext3/ext4, "mount -o ro" ainda pode tentar journal replay e portanto
    # escrever no block device. Como o QCOW2 mestre está conectado ao qemu-nbd
    # com --read-only, isso pode fazer o mount falhar.
    #
    # No preflight usamos ro,noload para uma inspeção 100% sem escrita.
    # Na CÓPIA em modo RW usamos mount normal para permitir journal recovery.
    if [[ "$readonly" -eq 1 ]]; then
      case "$fstype" in
        ext3|ext4) opts="ro,noload" ;;
        *)         opts="ro" ;;
      esac
    else
      opts="rw"
    fi

    mount_err="$PRE_DIR/mount-$(basename "$dev").stderr"
    : >"$mount_err"

    log "Testando $dev ($fstype) com mount -o $opts..."

    if sudo mount -o "$opts" "$dev" "$MOUNT_DIR" 2>"$mount_err"; then
      if [[ -f "$MOUNT_DIR/etc/os-release" && -d "$MOUNT_DIR/etc" && -d "$MOUNT_DIR/usr" ]]; then
        ROOT_PART="$dev"
        ok "Partição root encontrada: $ROOT_PART"
        return 0
      fi

      log "$dev montou, mas não parece ser a raiz do sistema."
      sudo umount "$MOUNT_DIR" || true
    else
      warn "Mount falhou para $dev ($fstype)."
      if [[ -s "$mount_err" ]]; then
        sed 's/^/       /' "$mount_err" >&2
      fi
    fi

    sudo rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
    MOUNT_DIR=""
  done < <(partition_candidates)

  return 1
}

inspect_guest() {
  local os_pretty hostname machine_id cloud_status

  os_pretty="$(sudo sh -c ". '$MOUNT_DIR/etc/os-release'; printf '%s' \"\$PRETTY_NAME\"" 2>/dev/null || true)"
  hostname="$(sudo cat "$MOUNT_DIR/etc/hostname" 2>/dev/null || true)"
  machine_id="$(sudo cat "$MOUNT_DIR/etc/machine-id" 2>/dev/null || true)"

  if [[ -x "$MOUNT_DIR/usr/bin/cloud-init" ]]; then
    cloud_status="presente"
  else
    cloud_status="NÃO ENCONTRADO"
  fi

  echo
  echo "============================================================"
  echo " GUEST DETECTADO VIA NBD"
  echo "============================================================"
  printf 'NBD:                 %s\n' "$NBD_DEV"
  printf 'Partições via:       %s\n' "$PARTITION_MODE"
printf 'Mount preflight:     %s\n' "$([[ "$ROOT_PART" =~ nbd ]] && echo 'somente leitura; ext4 usa noload' || echo 'somente leitura')"
  printf 'Root partition:      %s\n' "$ROOT_PART"
  printf 'OS:                  %s\n' "${os_pretty:-?}"
  printf 'Hostname atual:      %s\n' "${hostname:-?}"
  printf 'cloud-init:          %s\n' "$cloud_status"
  printf 'machine-id atual:    %s\n' "${machine_id:-?}"
  echo

  echo "Partições:"
  lsblk -p -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL,MOUNTPOINTS "$NBD_DEV" || true
  if [[ "$KPARTX_ACTIVE" -eq 1 ]]; then
    echo
    echo "Mappings kpartx:"
    mapper_partition_candidates | sed 's/^/  /'
  fi

  echo
  echo "Netplan encontrado:"
  if sudo find "$MOUNT_DIR/etc/netplan" -maxdepth 1 -type f \
      \( -name '*.yaml' -o -name '*.yml' \) -print 2>/dev/null \
      >"$PRE_DIR/netplan-files.txt" &&
     [[ -s "$PRE_DIR/netplan-files.txt" ]]; then
    while IFS= read -r f; do
      echo "  - ${f#$MOUNT_DIR}"
      sudo cat "$f" >"$PRE_DIR/$(basename "$f").txt" 2>/dev/null || true
    done <"$PRE_DIR/netplan-files.txt"
  else
    echo "  (nenhum)"
  fi
}

unmount_and_detach() {
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    sudo umount "$MOUNT_DIR" >/dev/null 2>&1 || true
    sudo rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
    MOUNT_DIR=""
  fi

  if [[ "$KPARTX_ACTIVE" -eq 1 ]]; then
    sudo kpartx -d "$NBD_DEV" >/dev/null 2>&1 || true
    KPARTX_ACTIVE=0
  fi

  if [[ "$NBD_CONNECTED" -eq 1 ]]; then
    sudo qemu-nbd --disconnect "$NBD_DEV"
    NBD_CONNECTED=0
    NBD_DEV=""
    sudo udevadm settle
  fi
}

log "Validando QCOW2 mestre..."
qemu-img check "$SOURCE" >"$PRE_DIR/qemu-img-check-source.txt"
qemu-img info --output=json "$SOURCE" >"$PRE_DIR/qemu-img-info-source.json"
ok "QCOW2 mestre íntegro."

FORMAT="$(python3 - "$PRE_DIR/qemu-img-info-source.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("format",""))
PY
)"
VIRTUAL_SIZE="$(python3 - "$PRE_DIR/qemu-img-info-source.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("virtual-size",0))
PY
)"
SOURCE_SIZE="$(stat -c %s "$SOURCE")"

[[ "$FORMAT" == "qcow2" ]] || die "Formato não é qcow2: $FORMAT"

log "Conectando QCOW2 mestre como NBD somente leitura..."
attach_image "$SOURCE" 1 || exit 2

if ! detect_root_partition 1; then
  save_nbd_diagnostics "root-detection-failed"
  die "Partições foram expostas, mas não consegui identificar a root."
fi

inspect_guest

[[ -x "$MOUNT_DIR/usr/bin/cloud-init" ]] || die "cloud-init não encontrado dentro da imagem."

echo
echo "============================================================"
echo " PREFLIGHT - SANITIZAÇÃO NBD"
echo "============================================================"
printf 'Source:              %s\n' "$SOURCE"
printf 'Output:              %s\n' "$OUTPUT"
printf 'Virtual size:        %s\n' "$(human_bytes "$VIRTUAL_SIZE")"
printf 'Arquivo source:      %s\n' "$(human_bytes "$SOURCE_SIZE")"
printf 'Partições via:       %s\n' "$PARTITION_MODE"
printf 'Mount preflight:     %s\n' "$([[ "$ROOT_PART" =~ nbd ]] && echo 'somente leitura; ext4 usa noload' || echo 'somente leitura')"
printf 'Root:                %s\n' "$ROOT_PART"
printf 'Limpar /var/lib/cloud: SIM\n'
printf 'Limpar logs:         %s\n' "$([[ "$CLEAN_LOGS" -eq 1 ]] && echo SIM || echo NÃO)"
printf 'Machine-id:          %s\n' "$([[ "$CLEAN_MACHINE_ID" -eq 1 ]] && echo RESETAR || echo MANTER)"
printf 'SSH host keys:       %s\n' "$([[ "$REMOVE_SSH_HOSTKEYS" -eq 1 ]] && echo REMOVER || echo MANTER)"
printf 'authorized_keys:     %s\n' "$([[ "$REMOVE_AUTH_KEYS" -eq 1 ]] && echo REMOVER || echo MANTER)"
printf 'Netplan cloud-init:  %s\n' "$([[ "$CLEAN_CLOUD_NETWORK" -eq 1 ]] && echo REMOVER-SE-GERADO || echo MANTER)"
echo

unmount_and_detach

if [[ "$EXECUTE" -eq 0 ]]; then
  echo "============================================================"
  echo " MODO PREFLIGHT — SOURCE NÃO FOI ALTERADO"
  echo "============================================================"
  exit 0
fi

if [[ -e "$OUTPUT" && "$KEEP_EXISTING_OUTPUT" -ne 1 ]]; then
  die "Output já existe: $OUTPUT"
fi

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT" "${OUTPUT}.sha256" \
      "${OUTPUT%.qcow2}.qemu-img-info.json" \
      "${OUTPUT%.qcow2}.qemu-img-check.txt"

log "Criando cópia de trabalho..."
cp --reflink=auto --sparse=always "$SOURCE" "$OUTPUT"
ok "QCOW2 mestre preservado."

log "Conectando CÓPIA em modo escrita..."
attach_image "$OUTPUT" 0 || exit 3

if ! detect_root_partition 0; then
  save_nbd_diagnostics "root-detection-copy-failed"
  die "Não consegui localizar root na cópia."
fi

echo
echo "============================================================"
echo " SANITIZANDO A CÓPIA"
echo "============================================================"

log "Removendo estado anterior do cloud-init..."
sudo rm -rf "$MOUNT_DIR/var/lib/cloud/"*
ok "/var/lib/cloud limpo."

if [[ "$CLEAN_LOGS" -eq 1 ]]; then
  log "Removendo logs do cloud-init..."
  sudo find "$MOUNT_DIR/var/log" -maxdepth 1 -type f \
    \( -name 'cloud-init.log*' -o -name 'cloud-init-output.log*' \) \
    -delete 2>/dev/null || true
fi

if [[ "$CLEAN_MACHINE_ID" -eq 1 ]]; then
  log "Resetando machine-id..."
  printf 'uninitialized\n' | sudo tee "$MOUNT_DIR/etc/machine-id" >/dev/null

  if [[ -e "$MOUNT_DIR/var/lib/dbus/machine-id" && \
        ! -L "$MOUNT_DIR/var/lib/dbus/machine-id" ]]; then
    sudo rm -f "$MOUNT_DIR/var/lib/dbus/machine-id"
  fi
fi

if [[ "$REMOVE_SSH_HOSTKEYS" -eq 1 ]]; then
  log "Removendo SSH host keys antigas..."
  sudo find "$MOUNT_DIR/etc/ssh" -maxdepth 1 -type f \
    -name 'ssh_host_*' -delete 2>/dev/null || true
fi

if [[ "$REMOVE_AUTH_KEYS" -eq 1 ]]; then
  log "Removendo authorized_keys herdados..."
  sudo rm -f "$MOUNT_DIR/root/.ssh/authorized_keys" 2>/dev/null || true
  sudo find "$MOUNT_DIR/home" -maxdepth 3 -type f \
    -path '*/.ssh/authorized_keys' -delete 2>/dev/null || true
fi

if [[ "$CLEAN_CLOUD_NETWORK" -eq 1 && -d "$MOUNT_DIR/etc/netplan" ]]; then
  log "Avaliando netplan..."
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if sudo grep -qiE 'generated by.*cloud-init|changes to it will not persist|cloud-init' "$f"; then
      warn "Removendo netplan gerado pelo cloud-init: ${f#$MOUNT_DIR}"
      sudo rm -f "$f"
    else
      log "Mantendo netplan não identificado como cloud-init: ${f#$MOUNT_DIR}"
    fi
  done < <(
    sudo find "$MOUNT_DIR/etc/netplan" -maxdepth 1 -type f \
      \( -name '*.yaml' -o -name '*.yml' \) -print
  )
fi

sudo sync
ok "Sanitização offline concluída."

unmount_and_detach

log "Validando QCOW2 portável..."
qemu-img check "$OUTPUT" | tee "${OUTPUT%.qcow2}.qemu-img-check.txt"
qemu-img info --output=json "$OUTPUT" >"${OUTPUT%.qcow2}.qemu-img-info.json"

OUT_SIZE="$(stat -c %s "$OUTPUT")"
OUT_VIRTUAL="$(python3 - "${OUTPUT%.qcow2}.qemu-img-info.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("virtual-size",0))
PY
)"

[[ "$OUT_VIRTUAL" -eq "$VIRTUAL_SIZE" ]] || die "Virtual size mudou."

log "Gerando SHA256..."
sha256sum "$OUTPUT" | tee "${OUTPUT}.sha256"

MGC_MAX_BYTES=$((25 * 1000 * 1000 * 1000))

echo
echo "============================================================"
echo " IMAGEM PORTÁVEL PRONTA"
echo "============================================================"
printf 'Source preservado:   %s\n' "$SOURCE"
printf 'Portable QCOW2:      %s\n' "$OUTPUT"
printf 'Virtual size:        %s\n' "$(human_bytes "$OUT_VIRTUAL")"
printf 'Arquivo final:       %s\n' "$(human_bytes "$OUT_SIZE")"
printf 'SHA256:              %s\n' "${OUTPUT}.sha256"

if (( OUT_SIZE <= MGC_MAX_BYTES )); then
  ok "Imagem abaixo do limite MGC de 25 GB."
else
  warn "Imagem ultrapassa 25 GB."
fi
