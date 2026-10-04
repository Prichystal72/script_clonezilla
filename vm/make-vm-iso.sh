#!/usr/bin/env bash
# Vytvoří upravenou kopii ISO Clonezilly pro testování restore.sh ve VM (originál se nemění).
# Přidá do ISO vm/start.sh a do hlavního bootovacího menu dvě položky (viz vm/patch-syslinux.py):
#   AUTOMATICKY restore.sh (výchozí) a Clonezilla live RUCNE (1024x768).
# Použití (Linux / WSL, potřebuje xorriso a python3):
#   bash vm/make-vm-iso.sh clonezilla-live-3.3.3-37-amd64.iso clonezilla-live-3.3.3-37-amd64-vm.iso
# Totéž pro flashku: vm/make-flash.sh.

set -euo pipefail
SRC=${1:?původní ISO}
OUT=${2:?výstupní ISO}
HERE="$(cd "$(dirname "$0")" && pwd)"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
command -v xorriso >/dev/null || { echo "Chybí xorriso (sudo apt install xorriso)"; exit 3; }
[[ "$SRC" != "$OUT" ]] || { echo "Výstup musí být jiný soubor než původní ISO."; exit 2; }

sed 's/\r$//' "$HERE/start.sh" >"$W/start.sh"
xorriso -osirrox on -indev "$SRC" -extract /syslinux/isolinux.cfg "$W/isolinux.cfg" \
    -extract /syslinux/syslinux.cfg "$W/syslinux.cfg" >/dev/null 2>&1
python3 "$HERE/patch-syslinux.py" "$W/isolinux.cfg" "$W/syslinux.cfg"

rm -f "$OUT"
xorriso -indev "$SRC" -outdev "$OUT" \
    -map "$W/isolinux.cfg" /syslinux/isolinux.cfg -map "$W/syslinux.cfg" /syslinux/syslinux.cfg \
    -map "$W/start.sh" /start.sh -boot_image any replay >/dev/null 2>&1
echo "Hotovo: $OUT"
