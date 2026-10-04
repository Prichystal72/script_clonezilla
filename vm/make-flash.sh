#!/usr/bin/env bash
# Připraví flashku s Clonezillou, aby se chovala stejně jako ISO ve VM:
# výchozí položka menu "AUTOMATICKY restore.sh" (větší písmo, bez dotazů, rovnou restore.sh).
# Na flashku zkopíruje restore.sh a start.sh a upraví menu BIOS (syslinux) i UEFI (grub); původní soubory uloží jako .bak.
# Použití (Linux / WSL): bash vm/make-flash.sh /cesta/ke/flashce     např. WSL: /mnt/e  (E: ve Windows)
#   WSL: nejdřív  sudo mkdir -p /mnt/e && sudo mount -t drvfs E: /mnt/e
# Zapisuje jen na zadanou flashku. BIOS menu: syslinux/*.cfg, UEFI menu: boot/grub/grub.cfg (původní soubory *.bak).

set -euo pipefail
F=${1:?kořen flashky, např. /mnt/e}
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[[ -f "$F/syslinux/syslinux.cfg" && -d "$F/live" ]] || { echo "$F nevypadá jako flashka s Clonezillou (chybí syslinux/syslinux.cfg nebo live/)."; exit 2; }
[[ -f "$ROOT/restore.sh" ]] || { echo "Chybí $ROOT/restore.sh"; exit 2; }

cp "$ROOT/restore.sh" "$F/restore.sh"
sed 's/\r$//' "$HERE/start.sh" >"$F/start.sh"
[[ -f "$F/syslinux/syslinux.cfg.bak" ]] || cp "$F/syslinux/syslinux.cfg" "$F/syslinux/syslinux.cfg.bak"
python3 "$HERE/patch-syslinux.py" "$F/syslinux/syslinux.cfg"
# stejné menu pro isolinux.cfg, pokud na flashce je
if [[ -f "$F/syslinux/isolinux.cfg" ]]; then
    [[ -f "$F/syslinux/isolinux.cfg.bak" ]] || cp "$F/syslinux/isolinux.cfg" "$F/syslinux/isolinux.cfg.bak"
    python3 "$HERE/patch-syslinux.py" "$F/syslinux/isolinux.cfg"
fi
# UEFI menu (GRUB)
if [[ -f "$F/boot/grub/grub.cfg" ]]; then
    [[ -f "$F/boot/grub/grub.cfg.bak" ]] || cp "$F/boot/grub/grub.cfg" "$F/boot/grub/grub.cfg.bak"
    python3 "$HERE/patch-grub.py" "$F/boot/grub/grub.cfg"
fi
sync
echo "Hotovo: restore.sh, start.sh a menu (BIOS i UEFI) na $F (zálohy menu: *.bak)."
