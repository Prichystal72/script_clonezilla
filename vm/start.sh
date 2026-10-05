#!/bin/bash
# Startovací skript pro Clonezillu: nastaví větší písmo, najde restore.sh na flashce / disku (VM)
# a spustí ho. Spouští ho položka bootovacího menu "AUTOMATICKY restore.sh"
# (ocs_live_run="sudo bash /run/live/medium/start.sh"); ručně: sudo bash /run/live/medium/start.sh
setfont Lat2-Terminus24x12 2>/dev/null || true
clear
echo "Hledám restore.sh na flashce nebo disku..."
# 1. vlastní bootovací médium (flashka s Clonezillou, ISO ve VM) – každé spouští svou verzi skriptu
for B in /run/live/medium /usr/lib/live/mount/medium /lib/live/mount/medium; do
    if [[ -f "$B/restore.sh" ]]; then
        echo "Nalezeno na bootovacím médiu: $B"
        cd / && bash "$B/restore.sh"
        echo
        echo "restore.sh skončil. Příkazový řádek: napiš příkaz, restart: sudo reboot"
        exec bash
    fi
done
# 2. ostatní oddíly (starší VM s diskem scripts.vmdk)
M=/mnt/rs
mkdir -p "$M"
for d in $(lsblk -lnpo NAME,TYPE | awk '$2=="part"{print $1}'); do
    if mount -o ro "$d" "$M" 2>/dev/null; then
        if [[ -f "$M/restore.sh" ]]; then
            echo "Nalezeno: $d"
            umount "$M"
            mount "$d" "$M" 2>/dev/null || mount -o ro "$d" "$M"
            bash "$M/restore.sh"
            cd / && umount "$M" 2>/dev/null
            echo
            echo "restore.sh skončil. Příkazový řádek: napiš příkaz, restart: sudo reboot"
            exec bash
        fi
        umount "$M"
    fi
done
echo "restore.sh nebyl nalezen na žádném oddílu (flashka / disk VM)."
echo "Zkontroluj připojení flashky nebo disku: lsblk"
exec bash
