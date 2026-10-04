#!/usr/bin/env bash
# Ovládání testovací VM v QEMU (WSL / Linux, KVM): skutečná Clonezilla z ISO, disky = řídké soubory.
# Žádný skutečný disk se nepoužije. Obrazovka se čte snímky (PNG), klávesy se posílají přes monitor QEMU.
#
#   sudo bash test/qvm.sh start ISO [usb:soubor:velikost …] [sata:soubor:velikost …]
#   sudo bash test/qvm.sh shot SOUBOR.png        snímek obrazovky
#   sudo bash test/qvm.sh keys ret 1 2 down spc  klávesy (názvy QEMU: ret spc tab esc up down … ctrl-c)
#   sudo bash test/qvm.sh type "text"            napíše text (a-z 0-9 mezera - . / _ :)
#   sudo bash test/qvm.sh stop
# Disk se skriptem: sata:/cesta/scripts.raw (FAT32 s restore.sh, viz vm/make-script-disk.sh).

set -euo pipefail
Q=/var/tmp/qvm
MON=$Q/monitor.sock
mkdir -p "$Q"

mon() { python3 - "$MON" "$@" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1]); s.settimeout(2)
try: s.recv(4096)
except Exception: pass
for cmd in sys.argv[2:]:
    s.sendall((cmd + '\n').encode()); time.sleep(0.15)
    try: s.recv(65536)
    except Exception: pass
s.close()
PY
}

case "${1:-}" in
    start)
        iso=${2:?ISO}; shift 2
        [[ -S "$MON" ]] && { echo "VM už běží (nejdřív stop)"; exit 2; }
        # shellcheck disable=SC2054  # čárky patří do parametrů QEMU
        args=(-enable-kvm -m 4096 -smp 2 -machine q35 -boot d -cdrom "$iso"
              -vga std -display none -monitor "unix:$MON,server,nowait"
              -device qemu-xhci,id=xhci -device ahci,id=ahci)
        n=0
        for d in "$@"; do
            IFS=: read -r kind file size <<<"$d"
            [[ -e "$file" ]] || truncate -s "$size" "$file"
            n=$((n + 1))
            if [[ "$kind" == usb ]]; then
                args+=(-drive "if=none,id=d$n,file=$file,format=raw" -device "usb-storage,bus=xhci.0,drive=d$n")
            else
                args+=(-drive "if=none,id=d$n,file=$file,format=raw" -device "ide-hd,bus=ahci.$((n - 1)),drive=d$n")
            fi
        done
        setsid nohup qemu-system-x86_64 "${args[@]}" >"$Q/qemu.log" 2>&1 < /dev/null &
        sleep 0.5; pgrep -f "qemu-system-x86_64.*$MON" | head -1 >"$Q/pid"
        for _ in $(seq 50); do [[ -S "$MON" ]] && break; sleep 0.1; done
        echo "VM běží (pid $(cat "$Q/pid"))" ;;
    shot)
        out=${2:?soubor.png}
        mon "screendump $Q/screen.ppm"
        sleep 0.5
        pnmtopng "$Q/screen.ppm" >"$out" 2>/dev/null && echo "$out" ;;
    keys)
        shift; for k in "$@"; do mon "sendkey $k"; done ;;
    type)
        shift; t=$*; ks=()
        for (( i = 0; i < ${#t}; i++ )); do
            c=${t:i:1}
            case "$c" in
                [a-z0-9]) ks+=("$c") ;;
                [A-Z])    ks+=("shift-${c,,}") ;;
                ' ') ks+=(spc) ;; '-') ks+=(minus) ;; '.') ks+=(dot) ;; '/') ks+=(slash) ;;
                '_') ks+=(shift-minus) ;; ':') ks+=(shift-semicolon) ;; ',') ks+=(comma) ;; '=') ks+=(equal) ;;
                *) echo "neznámý znak '$c'"; exit 2 ;;
            esac
        done
        for k in "${ks[@]}"; do mon "sendkey $k"; done ;;
    stop)
        if [[ -f "$Q/pid" ]]; then kill "$(cat "$Q/pid")" 2>/dev/null || true; fi
        rm -f "$MON" "$Q/pid"; echo "VM zastavena" ;;
    *)
        sed -n '2,12p' "$0"; exit 2 ;;
esac
