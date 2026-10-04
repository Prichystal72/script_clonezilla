#!/usr/bin/env bash
# Vytvoří (nebo aktualizuje) malý virtuální disk VMware se skriptem restore.sh (FAT32, popisek RESTORE).
# VM musí být vypnutá. Potřebuje root, qemu-img, sfdisk, mkfs.vfat (Linux / WSL).
# Použití:
#   sudo bash vm/make-script-disk.sh restore.sh "/cesta/k/VM/scripts.vmdk" [velikost, výchozí 1G]
# Disk se v .vmx přidá řádky: scsi0.present = "TRUE", scsi0.virtualDev = "lsilogic",
#   scsi0:0.present = "TRUE", scsi0:0.fileName = "scripts.vmdk"
# Pozor: soubor scripts.vmdk se přepíše (kopie restore.sh je jediný jeho obsah).

set -euo pipefail
SCRIPT=${1:?restore.sh}
OUT=${2:?cílový scripts.vmdk}
SIZE=${3:-1G}
[[ ${EUID:-$(id -u)} == 0 ]] || { echo "Spusť jako root (sudo)."; exit 2; }
W=$(mktemp -d)
L=""
cleanup() {
    umount "$W/mnt" 2>/dev/null || true
    if [[ -n "$L" ]]; then losetup -d "$L" 2>/dev/null || true; fi
    rm -rf "$W"
}
trap cleanup EXIT
mkdir -p "$W/mnt"
truncate -s "$SIZE" "$W/scripts.raw"
printf 'label: dos\nstart=2048, type=c\n' | sfdisk -q "$W/scripts.raw"
L=$(losetup -fP --show "$W/scripts.raw")
sleep 1
mkfs.vfat -F32 -n RESTORE "${L}p1" >/dev/null
mount "${L}p1" "$W/mnt"
cp "$SCRIPT" "$W/mnt/restore.sh"
sync
umount "$W/mnt"
losetup -d "$L"; L=""
qemu-img convert -f raw -O vmdk -o subformat=monolithicSparse "$W/scripts.raw" "$OUT"
echo "Hotovo: $OUT ($SIZE, FAT32, RESTORE/restore.sh)"
