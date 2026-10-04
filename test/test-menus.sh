#!/usr/bin/env bash
# Průchod menu 5–9 přes klávesnici (textové rozhraní) na loop discích a kontrola výsledku zvenku.
# Potřebuje Linux s rootem (WSL2 / VM). Pracuje jen se soubory v $W.
# Spuštění: sudo bash test/test-menus.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W=/var/tmp/restore-menus
R=(bash "$ROOT/restore.sh" --allow-loop --ui plain)
PASS=0 FAIL=0 RUNNO=0
[[ ${EUID:-$(id -u)} == 0 ]] || { echo "Spusť jako root (sudo)."; exit 2; }

ok()  { PASS=$((PASS + 1)); echo "  ✔ $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  ✘ $*"; }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; return 1; fi; }
cleanup() {
    umount /home/partimag 2>/dev/null; for m in "$W"/mnt*; do umount "$m" 2>/dev/null; done
    local l; for l in $(losetup -a | grep "$W/" | cut -d: -f1); do losetup -d "$l" 2>/dev/null; done
}
trap cleanup EXIT
mkloop() { local -n _v=$1; local f="$W/$2.img"; rm -f "$f"; truncate -s "$3" "$f"; shift 3
    if (( $# )); then "$@" "$f" >/dev/null 2>&1; fi
    _v=$(losetup -fP --show "$f"); udevadm settle 2>/dev/null; local i; for (( i = 0; i < 50; i++ )); do [[ $# -eq 0 || -b "${_v}p1" ]] && break; sleep 0.1; done; }
rs() { RUNNO=$((RUNNO + 1)); LAST_LOG="$W/logs/$(printf "%02d" "$RUNNO")-$1.log"; shift
    printf '%b' "${STDIN:-}" | "${R[@]}" "$@" >"$LAST_LOG" 2>&1; RC=$?; }
showlog() { echo "    --- konec logu $LAST_LOG ---"; tail -n 15 "$LAST_LOG" | sed 's/^/    | /'; }
fsums() { local m="$W/mnt-sum"; mkdir -p "$m"; mount -o ro "$1" "$m" || return 1
    (cd "$m" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum); umount "$m"; }
psize() { blockdev --getsize64 "$1"; }
pstart() { cat "/sys/class/block/${1##*/}/start"; }
# index disku v nabídce (všechny disky v pořadí lsblk) a oddílu v nabídce part_select (oddíly nechráněných loop disků)
didx() { lsblk -dnro NAME | grep -vE '^(sr|zram|ram|fd)' | grep -n "^${1#/dev/}\$" | cut -d: -f1; }
pidx() { lsblk -lnpo NAME,TYPE,MOUNTPOINT | awk '$2=="part" && $1 ~ /\/dev\/loop/ && $3=="" {print $1}' | grep -n "^$1\$" | cut -d: -f1; }
imgidx() { mount -o ro "${IMG}p1" "$W/mnt"; (cd "$W/mnt" && find . -maxdepth 3 -type f -name parts | sed 's|^\./||; s|/parts$||' | sort | grep -n "^$1\$" | cut -d: -f1); umount "$W/mnt"; }

cleanup; rm -rf "$W"; mkdir -p "$W/logs" "$W/mnt"
IMG=""; mkloop IMG images 4G sgdisk -n1:0:0 -t1:8300
mkfs.ext4 -q -L IMAGES "${IMG}p1"; IMGP=${IMG#/dev/}p1
mkm() { printf 'label: dos\nlabel-id: 0x4d454e55\nunit: sectors\n\nstart=2048, size=614400, type=c\nstart=616448, type=83\n' | sfdisk -q "$1"; }
M=""; mkloop M menu-m 2G mkm
mkfs.vfat -F32 -n FATM "${M}p1" >/dev/null; mkfs.ext4 -q -L EXTM "${M}p2"
mount "${M}p1" "$W/mnt"; head -c 20M /dev/urandom >"$W/mnt/a.bin"; mkdir -p "$W/mnt/D"; for i in $(seq 20); do echo "$i" >"$W/mnt/D/f$i"; done; umount "$W/mnt"
mount "${M}p2" "$W/mnt"; head -c 30M /dev/urandom >"$W/mnt/b.bin"; umount "$W/mnt"
S1=$(fsums "${M}p1"); S2=$(fsums "${M}p2")
rs save --source-dev "$IMGP" --save-disk "${M#/dev/}" --name MENU
check "příprava: záloha MENU" [ "$RC" = 0 ] || showlog
m=${M#/dev/}

echo "== 5/1 Informace o záloze + ověření dat (chkimg)"
STDIN="5\n1\n$(imgidx MENU)\n1\n0\n"; rs m51 --source-dev "$IMGP"
check "5/1 kód 0" [ "$RC" = 0 ] || showlog
check "5/1 oddíly mají data" grep -q "všechny oddíly z 'parts' mají data" "$LAST_LOG"
check "5/1 chkimg p1 v pořádku" grep -q "${m}p1 v pořádku" "$LAST_LOG"
check "5/1 chkimg p2 v pořádku" grep -q "${m}p2 v pořádku" "$LAST_LOG"
check "5/1 SHA1SUMS OK" grep -qE "zst\.aa: OK" "$LAST_LOG"

echo "== 5/2 Prohlížení obsahu zálohy"
STDIN="5\n2\n$(imgidx MENU)\n2\n/var/tmp\n0\n"; rs m52 --source-dev "$IMGP"
check "5/2 kód 0" [ "$RC" = 0 ] || showlog
check "5/2 oddíl byl připojený" grep -q "je připojený v" "$LAST_LOG"
check "5/2 po skončení nic nepřipojeno ani dočasný soubor" bash -c "! losetup -a | grep -q restore-view && ! ls /var/tmp/restore-view-* 2>/dev/null"

echo "== 6 Informace o discích"
STDIN="6\n$(didx "$M")\n0\n"; rs m6
check "6 kód 0" [ "$RC" = 0 ] || showlog
check "6 tabulka oddílů disku" grep -q "label-id: 0x4d454e55" "$LAST_LOG"
check "6 TRIM a SMART řádky" bash -c "grep -q 'TRIM:' '$LAST_LOG' && grep -q -- '-- SMART --' '$LAST_LOG'"

echo "== 8/1 Kontrola FS (jen kontrola a oprava)"
STDIN="8\n1\n$(pidx "${M}p2")\n0\n0\n"; rs m81
check "8/1 kontrola kód 0" [ "$RC" = 0 ] || showlog
check "8/1 výsledek: bez chyb" grep -q "bez chyb" "$LAST_LOG"
STDIN="8\n1\n$(pidx "${M}p1")\n1\n0\n"; rs m81r
check "8/1 oprava FAT kód 0" [ "$RC" = 0 ] || showlog
check "8/1 oprava FAT: výsledek" grep -qE "bez chyb|opraveny" "$LAST_LOG"

echo "== 7 Editor: zmenšit ext4, změnit LABEL, přesunout na konec, zmenšit FAT"
# 1=velikost, 2=přesun, 3=smazat, 4=LABEL, 5=zarovnání, 6=zpět, 7=provést, 8=odejít
STDIN="7\n$(didx "$M")\n1\n2\n-300M\n4\n2\nNOVY\n2\n2\nend\n1\n1\n-100M\n7\n${m}\n8\n0\n"; rs m7
check "7 kód 0" [ "$RC" = 0 ] || showlog
check "7 plán proveden" grep -q "Plán editoru proveden" "$LAST_LOG" || showlog
partx -u "$M"; sleep 1
check "7 p1 FAT zmenšen o 100 MiB" [ "$(psize "${M}p1")" = $(( (614400 - 204800) * 512 )) ]
check "7 p1 soubory FAT" [ "$(fsums "${M}p1")" = "$S1" ]
check "7 p1 fsck" fsck.vfat -n "${M}p1"
check "7 p2 ext4 soubory" [ "$(fsums "${M}p2")" = "$S2" ]
check "7 p2 LABEL NOVY" [ "$(blkid -c /dev/null -s LABEL -o value "${M}p2")" = NOVY ]
check "7 p2 přesunut na konec disku" [ $(( $(pstart "${M}p2") * 512 + $(psize "${M}p2") )) -ge $(( 2 * 1073741824 - 2 * 1048576 )) ]
check "7 p2 e2fsck" e2fsck -fn "${M}p2"
STDIN="7\n$(didx "$M")\n3\n1\n${m}p1\n7\n${m}\n8\n0\n"; rs m7d
check "7 smazání oddílu kód 0" [ "$RC" = 0 ] || showlog
partx -u "$M"; sleep 1
check "7 p1 smazán, p2 zůstal" bash -c "[ ! -b ${M}p1 ] && [ -b ${M}p2 ]"

echo "== 8/2 Boot: obnova boot kódu MBR ze zálohy, záložní GPT na konec disku"
dd if=/dev/zero of="$M" bs=446 count=1 conv=notrunc status=none
STDIN="8\n2\n3\n$(didx "$M")\n$(imgidx MENU)\n${m}\n0\n"; rs m82 --source-dev "$IMGP"
check "8/2 MBR kód 0" [ "$RC" = 0 ] || showlog
mount -o ro "${IMG}p1" "$W/mnt"; WANT=$(head -c 446 "$W/mnt/MENU/${m}-mbr" | sha1sum); umount "$W/mnt"
check "8/2 boot kód MBR = záloha" [ "$(head -c 446 "$M" | sha1sum)" = "$WANT" ]
G=""; mkloop G menu-g 512M
printf 'label: gpt\n\nsize=100M, type=L\n' | sfdisk -q "$G"; losetup -d "$G"
truncate -s 1G "$W/menu-g.img"; G=$(losetup -fP --show "$W/menu-g.img"); sleep 1
check "8/2 příprava: záložní GPT není na konci" bash -c "! sgdisk -v $G | grep -q 'No problems found'"
STDIN="8\n2\n4\n$(didx "$G")\n0\n"; rs m82g
check "8/2 GPT kód 0" [ "$RC" = 0 ] || showlog
check "8/2 GPT bez chyb (sgdisk -v)" bash -c "sgdisk -v $G | grep -q 'No problems found'"

echo "== 8/3 Převod MBR → GPT → MBR"
C=""; mkc() { printf 'label: dos\nunit: sectors\n\nstart=2048, size=409600, type=83\n' | sfdisk -q "$1"; }
mkloop C menu-c 512M mkc; mkfs.ext4 -q -L CONV "${C}p1"
mount "${C}p1" "$W/mnt"; head -c 5M /dev/urandom >"$W/mnt/c.bin"; umount "$W/mnt"; SC=$(fsums "${C}p1"); c=${C#/dev/}
STDIN="8\n3\n$(didx "$C")\n${c}\n0\n"; rs m83a
check "8/3 MBR→GPT kód 0" [ "$RC" = 0 ] || showlog
partx -u "$C"; sleep 1
check "8/3 tabulka je GPT" [ "$(blkid -c /dev/null -s PTTYPE -o value "$C")" = gpt ]
check "8/3 data beze změny" [ "$(fsums "${C}p1")" = "$SC" ]
STDIN="8\n3\n$(didx "$C")\n${c}\n0\n"; rs m83b
check "8/3 GPT→MBR kód 0" [ "$RC" = 0 ] || showlog
partx -u "$C"; sleep 1
check "8/3 tabulka je MBR" [ "$(blkid -c /dev/null -s PTTYPE -o value "$C")" = dos ]
check "8/3 data beze změny" [ "$(fsums "${C}p1")" = "$SC" ]

echo "== 9/1 Bezpečné smazání (wipefs)"
STDIN="9\n1\n$(didx "$C")\n1\n${c}\n1\n${c}\n0\n"; rs m91
check "9/1 kód 0" [ "$RC" = 0 ] || showlog
check "9/1 disk bez tabulky a signatur" bash -c "[ -z \"\$(blkid -c /dev/null -p $C 2>/dev/null)\" ] && ! sfdisk -d $C >/dev/null 2>&1"

echo "== 9/3 Nastavení: komprese gzip → nová záloha v gzip"
# 9 → 3 nastavení: 2 = komprese → 2 = gzip; prázdný vstup = zpět; pak 3/1 záloha disku G (název GZ)
# výběr v záloze nabízí jen nechráněné disky – spočítat pořadí G mezi nimi
gi=$(lsblk -dnro NAME | grep -vE '^(sr|zram|ram|fd)' | grep '^loop' | grep -vx "${IMG#/dev/}" | grep -n "^${G#/dev/}\$" | cut -d: -f1)
STDIN="9\n3\n2\n2\n\n3\n1\n${gi}\nGZ\n0\n"; rs m93 --source-dev "$IMGP"
check "9/3 kód 0" [ "$RC" = 0 ] || showlog
mount -o ro "${IMG}p1" "$W/mnt"
check "9/3 záloha v gzip" compgen -G "$W/mnt/GZ/*.gz.aa"
umount "$W/mnt"

echo "== 9/2 Předání Clonezille (ve WSL ocs-sr není → srozumitelná hláška)"
if command -v ocs-sr >/dev/null; then
    echo "  – přeskočeno: ocs-sr je k dispozici (předání se zkouší ve skutečné Clonezille v QEMU)"
else
    STDIN="9\n2\n0\n"; rs m92
    check "9/2 kód 0" [ "$RC" = 0 ] || showlog
    check "9/2 hláška" grep -qE "ocs-sr není k dispozici|ocs-sr" "$LAST_LOG"
fi

echo
echo "Výsledek: $PASS OK, $FAIL chyb   (logy: $W/logs)"
(( FAIL == 0 ))
