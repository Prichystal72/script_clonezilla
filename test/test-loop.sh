#!/usr/bin/env bash
# Testy na loop discích se skutečnými daty (kap. 10.2).
# Potřebuje Linux s rootem (WSL2 / VM). Pracuje JEN se soubory v $W – žádný skutečný disk.
# Spuštění:  sudo bash test/test-loop.sh            (celé)
#            sudo bash test/test-loop.sh legacy     (jen část: backup restore dryrun editor legacy)

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W=/var/tmp/restore-test
R=(bash "$ROOT/restore.sh" --allow-loop --ui plain)
PARTS="${1:-backup restore dryrun editor legacy}"
PASS=0 FAIL=0 RUNNO=0

[[ ${EUID:-$(id -u)} == 0 ]] || { echo "Spusť jako root (sudo)."; exit 2; }

# --- pomocné funkce -------------------------------------------------------------
ok()  { PASS=$((PASS + 1)); echo "  ✔ $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  ✘ $*"; }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }

cleanup() {
    umount /home/partimag 2>/dev/null
    for m in "$W"/mnt*; do umount "$m" 2>/dev/null; done
    local l
    for l in $(losetup -a | grep "$W/" | cut -d: -f1); do losetup -d "$l" 2>/dev/null; done
}
trap cleanup EXIT

# mkloop <proměnná> <název> <velikost> [příkaz pro tabulku nad souborem…]
mkloop() {
    local -n _v=$1; local f="$W/$2.img" i
    rm -f "$f"; truncate -s "$3" "$f"; shift 3
    if (( $# )); then "$@" "$f" >/dev/null 2>&1; fi
    _v=$(losetup -fP --show "$f")
    udevadm settle 2>/dev/null
    for (( i = 0; i < 50; i++ )); do [[ $# -eq 0 || -b "${_v}p1" ]] && break; sleep 0.2; done
}
dropl() { losetup -d "$1" 2>/dev/null; }

# Spustí restore.sh, výstup do logu; návratový kód v RC
rs() {
    RUNNO=$((RUNNO + 1))
    local log
    log="$W/logs/$(printf "%02d" "$RUNNO")-$1.log"; shift
    local input=${STDIN:-}
    printf '%b' "$input" | "${R[@]}" "$@" >"$log" 2>&1
    RC=$?
    LAST_LOG=$log
}
showlog() { echo "    --- konec logu $LAST_LOG ---"; tail -n 25 "$LAST_LOG" | sed 's/^/    | /'; }

# Kontrolní součty všech souborů na oddílu
fsums() {
    local dev=$1 m="$W/mnt-sum" t
    mkdir -p "$m"
    t=$(blkid -c /dev/null -s TYPE -o value "$dev")
    if [[ "$t" == ntfs ]]; then mount -t ntfs-3g -o ro "$dev" "$m" || return 1
    else mount -o ro "$dev" "$m" || return 1; fi
    (cd "$m" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
    umount "$m"
}
fsuuid() { blkid -c /dev/null -s UUID -o value "$1"; }
pstart() { sfdisk -d "$1" 2>/dev/null | awk -v p="$2" '$1==p {for(i=1;i<=NF;i++) if ($i ~ /^start=/) {gsub(/[^0-9]/,"",$(i+1)); print $(i+1)}}'; }
psize()  { blockdev --getsize64 "$1"; }
ptype()  { sfdisk --part-type "$1" "$2" 2>/dev/null; }
puuid()  { sfdisk --part-uuid "$1" "$2" 2>/dev/null; }
# velikost ext4 v bajtech
ext_bytes() { dumpe2fs -h "$1" 2>/dev/null | awk -F: '/^Block count/{c=$2} /^Block size/{s=$2} END{print c*s}'; }
# FS zabírá (téměř) celý oddíl: rozdíl < 4 MiB
fills() { local d=$(( $(psize "$1") - $2 )); (( d >= 0 && d < 4 * 1048576 )); }
hidden() { dd if="$1" bs=1 skip=28 count=4 status=none | od -An -tu4 | tr -d ' '; }

cleanup; rm -rf "$W"; mkdir -p "$W/logs"

# =============================================================================
echo "== 0) Disk s obrazy (loop, ext4 8 GiB)"
IMG=""
mkloop IMG images 8G sgdisk -n1:0:0 -t1:8300
mkfs.ext4 -q -L IMAGES "${IMG}p1"
IMGP=${IMG#/dev/}p1

# =============================================================================
echo "== 1) Zdrojový disk 2 GiB GPT: EFI (FAT32 100 MiB) + ext4"
mkloop SRC src 2G sgdisk -n1:2048:+100M -t1:ef00 -c1:"EFI System" -n2:0:0 -t2:8300 -c2:root
mkfs.vfat -F32 -n EFI "${SRC}p1" >/dev/null
mkfs.ext4 -q -L ROOT "${SRC}p2"
mkdir -p "$W/mnt"
mount "${SRC}p1" "$W/mnt"; mkdir -p "$W/mnt/EFI/BOOT"; head -c 1M /dev/urandom >"$W/mnt/EFI/BOOT/BOOTX64.EFI"; umount "$W/mnt"
mount "${SRC}p2" "$W/mnt"
head -c 40M /dev/urandom >"$W/mnt/data.bin"; mkdir -p "$W/mnt/etc/x"
for i in $(seq 200); do echo "soubor $i" >"$W/mnt/etc/x/f$i.txt"; done
ln -s data.bin "$W/mnt/link"; ln "$W/mnt/etc/x/f1.txt" "$W/mnt/hard"
umount "$W/mnt"
SUM1=$(fsums "${SRC}p1"); SUM2=$(fsums "${SRC}p2")
U1=$(fsuuid "${SRC}p1"); U2=$(fsuuid "${SRC}p2")

# Ověření obnoveného GPT disku: verify_gpt <disk> <má_vyplnit 0|1> <popis>
verify_gpt() {
    local t=$1 full=$2 n=$3
    check "$n: typy oddílů" [ "$(ptype "$t" 1)/$(ptype "$t" 2)" = "$(ptype "$SRC" 1)/$(ptype "$SRC" 2)" ]
    check "$n: PARTUUID" [ "$(puuid "$t" 1)/$(puuid "$t" 2)" = "$(puuid "$SRC" 1)/$(puuid "$SRC" 2)" ]
    check "$n: UUID FS" [ "$(fsuuid "${t}p1")/$(fsuuid "${t}p2")" = "$U1/$U2" ]
    check "$n: fsck.vfat čistý" fsck.vfat -n "${t}p1"
    check "$n: e2fsck čistý" e2fsck -fn "${t}p2"
    check "$n: soubory EFI shodné" [ "$(fsums "${t}p1")" = "$SUM1" ]
    check "$n: soubory ext4 shodné" [ "$(fsums "${t}p2")" = "$SUM2" ]
    if (( full )); then check "$n: ext4 vyplňuje oddíl" fills "${t}p2" "$(ext_bytes "${t}p2")"; fi
}

# =============================================================================
if [[ " $PARTS " == *" backup "* || " $PARTS " == *" restore "* || " $PARTS " == *" dryrun "* ]]; then
echo "== 2) Záloha skriptem (menu 3) + struktura formátu Clonezilly"
rs backup --source-dev "$IMGP" --save-disk "${SRC#/dev/}" --name SRC2G
check "záloha: návratový kód 0" [ "$RC" = 0 ] || showlog
mount -o ro "${IMG}p1" "$W/mnt"
D="$W/mnt/SRC2G"; S=${SRC#/dev/}
for f in disk parts "$S-pt.sf" "$S-pt.parted" "$S-mbr" "$S-gpt-1st" "$S-gpt-2nd" blkid.list dev-fs.list Info-saved-by-cmd.txt SHA1SUMS; do
    check "obraz obsahuje $f" [ -s "$D/$f" ]
done
check "obraz: data p1 (vfat ptcl zst)" compgen -G "$D/${S}p1.vfat-ptcl-img.zst.aa"
check "obraz: data p2 (ext4 ptcl zst)" compgen -G "$D/${S}p2.ext4-ptcl-img.zst.aa"
check "obraz: parts = '${S}p1 ${S}p2'" [ "$(cat "$D/parts")" = "${S}p1 ${S}p2" ]
check "obraz: SHA1SUMS sedí" bash -c "cd '$D' && sha1sum -c --quiet SHA1SUMS"
check "obraz: partclone.chkimg p2" bash -c "cat '$D'/${S}p2.ext4-ptcl-img.zst.* | zstd -dc | partclone.chkimg -s - -L /dev/null >/dev/null 2>&1"
umount "$W/mnt"
fi

# =============================================================================
if [[ " $PARTS " == *" restore "* ]]; then
echo "== 3) Obnova na větší disk (4 GiB) – režimy A–D"
for mode in last proportional fixed manual; do
    mkloop TGT "tgt-$mode" 4G
    STDIN=""; [[ $mode == manual ]] && STDIN='max\n'
    rs "restore-4G-$mode" --source-dev "$IMGP" --image SRC2G --target "${TGT#/dev/}" --mode "$mode" --yes-i-know "${TGT#/dev/}"
    STDIN=""
    if [[ "$RC" == 0 ]]; then ok "4G $mode: obnova proběhla"; else bad "4G $mode: návratový kód $RC"; showlog; fi
    [[ "$RC" == 0 ]] && verify_gpt "$TGT" "$([[ $mode == fixed ]] && echo 0 || echo 1)" "4G $mode"
    if [[ $mode == last ]]; then T4=$TGT; else dropl "$TGT"; fi
done

echo "== 3b) Obnova na menší disk (1,5 GiB) – zmenšení přes dočasný soubor"
for mode in last proportional manual; do
    mkloop TGT "small-$mode" 1536M
    STDIN=""; [[ $mode == manual ]] && STDIN='max\n'
    rs "restore-1.5G-$mode" --source-dev "$IMGP" --image SRC2G --target "${TGT#/dev/}" --mode "$mode" --yes-i-know "${TGT#/dev/}"
    STDIN=""
    if [[ "$RC" == 0 ]]; then ok "1.5G $mode: obnova proběhla"; else bad "1.5G $mode: návratový kód $RC"; showlog; fi
    [[ "$RC" == 0 ]] && verify_gpt "$TGT" 1 "1.5G $mode"
    dropl "$TGT"
done
mkloop TGT small-fixed 1536M
H1=$(sha256sum "$W/small-fixed.img" | cut -d' ' -f1)
rs restore-1.5G-fixed --source-dev "$IMGP" --image SRC2G --target "${TGT#/dev/}" --mode fixed --yes-i-know "${TGT#/dev/}"
check "1.5G fixed: odmítnuto s kódem 4" [ "$RC" = 4 ] || showlog
check "1.5G fixed: cíl nezměněn" [ "$(sha256sum "$W/small-fixed.img" | cut -d' ' -f1)" = "$H1" ]
dropl "$TGT"

mkloop TGT tiny 300M
rs restore-300M --source-dev "$IMGP" --image SRC2G --target "${TGT#/dev/}" --mode last --yes-i-know "${TGT#/dev/}"
check "300M: data se nevejdou → kód 4" [ "$RC" = 4 ] || showlog
check "300M: hláška kolik chybí" grep -q 'chybí' "$LAST_LOG"
dropl "$TGT"
fi

# =============================================================================
if [[ " $PARTS " == *" dryrun "* ]]; then
echo "== 4) --dry-run nic nezapíše"
mkloop TGT dry 4G
H1=$(sha256sum "$W/dry.img" | cut -d' ' -f1)
rs dryrun --dry-run --source-dev "$IMGP" --image SRC2G --target "${TGT#/dev/}" --mode last --yes-i-know "${TGT#/dev/}"
check "dry-run: kód 0" [ "$RC" = 0 ] || showlog
check "dry-run: vypsal příkazy [DRY]" grep -q '\[DRY\] wipefs' "$LAST_LOG"
check "dry-run: cíl beze změny (hash)" [ "$(sha256sum "$W/dry.img" | cut -d' ' -f1)" = "$H1" ]
dropl "$TGT"
fi

# =============================================================================
if [[ " $PARTS " == *" editor "* ]]; then
echo "== 5) Editor oddílů na existujícím disku"
if [[ -z "${T4:-}" ]]; then
    mkloop T4 ed-ext 4G sgdisk -n1:2048:+100M -t1:ef00 -n2:0:0 -t2:8300
    mkfs.vfat -F32 "${T4}p1" >/dev/null; mkfs.ext4 -q "${T4}p2"
    mount "${T4}p2" "$W/mnt"; head -c 40M /dev/urandom >"$W/mnt/data.bin"; umount "$W/mnt"
    SUM2=$(fsums "${T4}p2")
fi
D4=${T4#/dev/}
before=$(psize "${T4}p2")
rs ed-shrink --resize "${D4}p2" --size -1G --yes-i-know "$D4"
check "editor ext4 -1G: kód 0" [ "$RC" = 0 ] || showlog
d=$(( before - $(psize "${T4}p2") ))
check "editor ext4 -1G: oddíl menší o 1 GiB (±1 MiB)" bash -c "(( $d >= 1072693248 && $d <= 1074790400 ))"
check "editor ext4 -1G: FS = oddíl" fills "${T4}p2" "$(ext_bytes "${T4}p2")"
check "editor ext4 -1G: soubory shodné" [ "$(fsums "${T4}p2")" = "$SUM2" ]
check "editor ext4 -1G: e2fsck čistý" e2fsck -fn "${T4}p2"
rs ed-grow --resize "${D4}p2" --size max --yes-i-know "$D4"
check "editor ext4 max: kód 0" [ "$RC" = 0 ] || showlog
check "editor ext4 max: zpět na plnou velikost" [ "$(psize "${T4}p2")" -ge "$before" ]
check "editor ext4 max: FS = oddíl" fills "${T4}p2" "$(ext_bytes "${T4}p2")"
check "editor ext4 max: soubory shodné" [ "$(fsums "${T4}p2")" = "$SUM2" ]
H1=$(fsums "${T4}p2")
rs ed-tiny --resize "${D4}p2" --size 10M --yes-i-know "$D4"
check "editor pod minimum: odmítnuto" [ "$RC" != 0 ]
check "editor pod minimum: hláška" grep -q 'Pod minimum' "$LAST_LOG"
check "editor pod minimum: data beze změny" [ "$(fsums "${T4}p2")" = "$H1" ]

echo "== 5b) Přesun oddílu doprava a doleva"
mkloop MV move 1G sgdisk -n1:2048:+200M -t1:8300
mkfs.ext4 -q -L MOVE "${MV}p1"
mount "${MV}p1" "$W/mnt"; head -c 50M /dev/urandom >"$W/mnt/m.bin"; echo x >"$W/mnt/a"; umount "$W/mnt"
SM=$(fsums "${MV}p1")
rs ed-move-right --move "${MV#/dev/}p1" --start end --yes-i-know "${MV#/dev/}"
check "přesun doprava: kód 0" [ "$RC" = 0 ] || showlog
s=$(pstart "$MV" "${MV}p1")
check "přesun doprava: začátek posunut (teď $s)" [ "${s:-2048}" -gt 2048 ]
check "přesun doprava: soubory shodné" [ "$(fsums "${MV}p1")" = "$SM" ]
rs ed-move-left --move "${MV#/dev/}p1" --start start --yes-i-know "${MV#/dev/}"
check "přesun doleva: kód 0" [ "$RC" = 0 ] || showlog
check "přesun doleva: začátek 2048" [ "$(pstart "$MV" "${MV}p1")" = 2048 ]
check "přesun doleva: soubory shodné" [ "$(fsums "${MV}p1")" = "$SM" ]
check "přesun: e2fsck čistý" e2fsck -fn "${MV}p1"
dropl "$MV"

echo "== 5c) NTFS zmenšení a zvětšení"
mkloop NT ntfs 1G sgdisk -n1:2048:+700M -t1:0700
mkfs.ntfs -Q -q -L NTDATA "${NT}p1" 2>/dev/null
mount -t ntfs-3g "${NT}p1" "$W/mnt"; head -c 60M /dev/urandom >"$W/mnt/w.bin"; mkdir "$W/mnt/Windows"; echo boot >"$W/mnt/Windows/x.ini"; umount "$W/mnt"
SN=$(fsums "${NT}p1"); before=$(psize "${NT}p1")
rs ed-ntfs-shrink --resize "${NT#/dev/}p1" --size -300M --yes-i-know "${NT#/dev/}"
check "NTFS -300M: kód 0" [ "$RC" = 0 ] || showlog
check "NTFS -300M: oddíl menší" [ "$(psize "${NT}p1")" -lt "$before" ]
check "NTFS -300M: soubory shodné" [ "$(fsums "${NT}p1")" = "$SN" ]
check "NTFS -300M: ntfsfix -n OK" ntfsfix -n "${NT}p1"
rs ed-ntfs-grow --resize "${NT#/dev/}p1" --size max --yes-i-know "${NT#/dev/}"
check "NTFS max: kód 0" [ "$RC" = 0 ] || showlog
check "NTFS max: oddíl větší než původně" [ "$(psize "${NT}p1")" -gt "$before" ]
check "NTFS max: soubory shodné" [ "$(fsums "${NT}p1")" = "$SN" ]
dropl "$NT"
fi

# =============================================================================
if [[ " $PARTS " == *" legacy "* ]]; then
echo "== 6) Legacy / Beckhoff: MBR, NTFS od sektoru 63 + FAT16"
P2S=821248
mklegacy() {
    printf 'label: dos\nlabel-id: 0x5d2c8e41\nunit: sectors\n\nstart=63, size=819137, type=7, bootable\nstart=%s, type=6\n' "$P2S" | sfdisk -q "$1"
    head -c 446 /dev/urandom | dd of="$1" bs=1 count=446 conv=notrunc status=none
    head -c $(( 62 * 512 )) /dev/urandom | dd of="$1" bs=512 seek=1 conv=notrunc status=none
}
mkloop LEG legacy 1G mklegacy
mkfs.ntfs -Q -q -p 63 -H 255 -S 63 -L XPE "${LEG}p1"
mkfs.fat -F 16 -h "$P2S" -n CE6 "${LEG}p2" >/dev/null
mount -t ntfs-3g "${LEG}p1" "$W/mnt"; head -c 30M /dev/urandom >"$W/mnt/sys.bin"; echo "[boot loader]" >"$W/mnt/boot.ini"; umount "$W/mnt"
mount "${LEG}p2" "$W/mnt"; head -c 8M /dev/urandom >"$W/mnt/NK.BIN"; mkdir "$W/mnt/BOOT"; echo cfg >"$W/mnt/BOOT/x.cfg"; umount "$W/mnt"
LS1=$(fsums "${LEG}p1"); LS2=$(fsums "${LEG}p2")
MBR=$(head -c 446 "$W/legacy.img" | sha256sum); SIG=$(dd if="$W/legacy.img" bs=1 skip=440 count=4 status=none | od -An -tx1)
HID=$(dd if="$W/legacy.img" bs=512 skip=1 count=62 status=none | sha256sum)
LU1=$(fsuuid "${LEG}p1"); LU2=$(fsuuid "${LEG}p2")
rs legacy-backup --source-dev "$IMGP" --save-disk "${LEG#/dev/}" --name LEGACY
check "legacy záloha: kód 0" [ "$RC" = 0 ] || showlog

verify_legacy() {
    local t=$1 n=$2 img=$3
    check "$n: start p1 = 63" [ "$(pstart "$t" "${t}p1")" = 63 ]
    check "$n: start p2 = $P2S" [ "$(pstart "$t" "${t}p2")" = "$P2S" ]
    check "$n: boot kód MBR shodný" [ "$(head -c 446 "$img" | sha256sum)" = "$MBR" ]
    check "$n: disk signature shodná" [ "$(dd if="$img" bs=1 skip=440 count=4 status=none | od -An -tx1)" = "$SIG" ]
    check "$n: data za MBR shodná" [ "$(dd if="$img" bs=512 skip=1 count=62 status=none | sha256sum)" = "$HID" ]
    check "$n: aktivní oddíl p1" bash -c "sfdisk -d $t | grep '${t}p1' | grep -q bootable"
    check "$n: hidden sectors p1 = 63" [ "$(hidden "${t}p1")" = 63 ]
    check "$n: hidden sectors p2 = $P2S" [ "$(hidden "${t}p2")" = "$P2S" ]
    check "$n: UUID NTFS / FAT" [ "$(fsuuid "${t}p1")/$(fsuuid "${t}p2")" = "$LU1/$LU2" ]
    check "$n: typ FAT16 zachován" [ "$(blkid -p -s VERSION -o value "${t}p2")" = FAT16 ]
    check "$n: soubory NTFS shodné" [ "$(fsums "${t}p1")" = "$LS1" ]
    check "$n: soubory FAT shodné" [ "$(fsums "${t}p2")" = "$LS2" ]
    check "$n: fsck.vfat čistý" fsck.vfat -n "${t}p2"
}
for size in 2G 700M; do
    mkloop TGT "leg-$size" "$size"
    RESTORE_DISABLE_TOOLS=fatresize rs "legacy-$size" --source-dev "$IMGP" --image LEGACY --target "${TGT#/dev/}" --mode last --yes-i-know "${TGT#/dev/}"
    if [[ "$RC" == 0 ]]; then ok "legacy $size: obnova proběhla"; else bad "legacy $size: kód $RC"; showlog; fi
    check "legacy $size: režim legacy rozpoznán" grep -q 'legacy (Beckhoff)' "$LAST_LOG"
    [[ "$RC" == 0 ]] && verify_legacy "$TGT" "legacy $size" "$W/leg-$size.img"
    dropl "$TGT"
done
mkloop TGT leg-2G-fatresize 2G
rs legacy-2G-fatresize --source-dev "$IMGP" --image LEGACY --target "${TGT#/dev/}" --mode last --yes-i-know "${TGT#/dev/}"
if [[ "$RC" == 0 ]]; then ok "legacy 2G (s fatresize): obnova proběhla"; else bad "legacy 2G (s fatresize): kód $RC"; showlog; fi
[[ "$RC" == 0 ]] && verify_legacy "$TGT" "legacy 2G s fatresize" "$W/leg-2G-fatresize.img"
dropl "$TGT"
mount -o ro "${IMG}p1" "$W/mnt"
check "legacy obraz obsahuje CHS geometrii" grep -q '^heads=' "$W/mnt/LEGACY/${LEG#/dev/}-chs.sf"
check "legacy obraz obsahuje data za MBR" [ -s "$W/mnt/LEGACY/${LEG#/dev/}-hidden-data-after-mbr" ]
umount "$W/mnt"
fi


# =============================================================================
if [[ " $PARTS " == *" menu "* || " $PARTS " == *" restore "* ]]; then
echo "== 7) Interaktivní menu (ostrý režim, volby čísly)"
mkloop TGT menu-tgt 3G
# pořadí disků v nabídce = pořadí lsblk (bez sr/zram/ram/fd)
idx=$(lsblk -dnro NAME | grep -vE '^(sr|zram|ram|fd)' | grep -n "^${TGT#/dev/}\$" | cut -d: -f1)
mount -o ro "${IMG}p1" "$W/mnt"
img_idx=$(cd "$W/mnt" && find . -maxdepth 3 -type f -name parts | sed 's|^\./||; s|/parts$||' | sort | grep -n '^SRC2G$' | cut -d: -f1)
umount "$W/mnt"
STDIN="1\n${img_idx}\n${idx}\n1\n${TGT#/dev/}\n0\n"
rs menu-restore --source-dev "$IMGP"
STDIN=""
check "menu: kód 0" [ "$RC" = 0 ] || showlog
check "menu: obnova hotová" grep -q 'Hotovo: obnova na /dev/'"${TGT#/dev/}" "$LAST_LOG" || showlog
[[ "$RC" == 0 ]] && verify_gpt "$TGT" 1 "menu 3G"
dropl "$TGT"
fi

# =============================================================================
if [[ " $PARTS " == *" merge "* ]]; then
echo "== 8) Záloha se 2 disky (CF systém + CF data) → JEDEN cílový disk"
# mkcf <label-id> <příznak> <soubor>  (soubor doplní mkloop jako poslední argument)
mkcf() { printf 'label: dos\nlabel-id: %s\nunit: sectors\n\nstart=63, type=7%s\n' "$1" "$2" | sfdisk -q "$3"; }
mkloop CA cfa 1G mkcf 0x6df0d34f ", bootable"
mkloop CB cfb 600M mkcf 0x1a2b3c4d ""
mkfs.ntfs -Q -q -p 63 -H 255 -S 63 -L SYS "${CA}p1" 2>/dev/null
mkfs.ntfs -Q -q -p 63 -H 255 -S 63 -L DATA "${CB}p1" 2>/dev/null
mount -t ntfs-3g "${CA}p1" "$W/mnt"; head -c 40M /dev/urandom >"$W/mnt/sys.bin"; echo "[boot loader]" >"$W/mnt/boot.ini"; umount "$W/mnt"
mount -t ntfs-3g "${CB}p1" "$W/mnt"; head -c 20M /dev/urandom >"$W/mnt/data.bin"; umount "$W/mnt"
MA=$(fsums "${CA}p1"); MB=$(fsums "${CB}p1"); UA=$(fsuuid "${CA}p1"); UB=$(fsuuid "${CB}p1")
A=${CA#/dev/}; B=${CB#/dev/}
rs merge-backup-a --source-dev "$IMGP" --save-disk "$A" --name TWO
rs merge-backup-b --source-dev "$IMGP" --save-disk "$B" --name TWO-B
# sloučení dvou záloh do jedné vícediskové (jako ukládá Clonezilla savedisk se 2 disky)
mount "${IMG}p1" "$W/mnt"
cp "$W/mnt/TWO-B/"* "$W/mnt/TWO/" 2>/dev/null
# záměrně obrácené pořadí: datový disk první – skript musí bootovací (A) dát na první místo
echo "$B $A" >"$W/mnt/TWO/disk"; echo "${B}p1 ${A}p1" >"$W/mnt/TWO/parts"; rm -rf "$W/mnt/TWO-B"
umount "$W/mnt"

mkloop TGT merge-a 3G
rs merge-A --source-dev "$IMGP" --image TWO --target "${TGT#/dev/}" --mode last --yes-i-know "${TGT#/dev/}"
check "sloučení (A): kód 0" [ "$RC" = 0 ] || showlog
check "sloučení (A): p1 začíná na 63" [ "$(pstart "$TGT" "${TGT}p1")" = 63 ]
check "sloučení (A): p2 existuje" [ -b "${TGT}p2" ]
check "sloučení (A): disk signature z 1. disku" [ "$(dd if="$W/merge-a.img" bs=1 skip=440 count=4 status=none | od -An -tx1 | tr -d ' ')" = "4fd3f06d" ]
check "sloučení (A): hidden sectors p2 = start" [ "$(hidden "${TGT}p2")" = "$(pstart "$TGT" "${TGT}p2")" ]
check "sloučení (A): UUID obou NTFS" [ "$(fsuuid "${TGT}p1")/$(fsuuid "${TGT}p2")" = "$UA/$UB" ]
check "sloučení (A): soubory systému" [ "$(fsums "${TGT}p1")" = "$MA" ]
check "sloučení (A): soubory dat" [ "$(fsums "${TGT}p2")" = "$MB" ]
check "sloučení (A): ntfsfix p1 i p2" bash -c "ntfsfix -n ${TGT}p1 && ntfsfix -n ${TGT}p2"
dropl "$TGT"

mkloop TGT merge-c 3G
rs merge-C --source-dev "$IMGP" --image TWO --target "${TGT#/dev/}" --mode manual --sizes 1200M,max --yes-i-know "${TGT#/dev/}"
check "sloučení (C 1200M+max): kód 0" [ "$RC" = 0 ] || showlog
check "sloučení (C): p1 = 1200 MiB" [ "$(psize "${TGT}p1")" = $(( 1200 * 1048576 )) ]
check "sloučení (C): p2 do konce disku" [ $(( $(pstart "$TGT" "${TGT}p2") * 512 + $(psize "${TGT}p2") )) -ge $(( 3 * 1073741824 - 1048576 )) ]
check "sloučení (C): soubory obou oddílů" [ "$(fsums "${TGT}p1")/$(fsums "${TGT}p2")" = "$MA/$MB" ]
dropl "$TGT"

mkloop TGT merge-small 800M
rs merge-small --source-dev "$IMGP" --image TWO --target "${TGT#/dev/}" --mode manual --sizes 500M,max --yes-i-know "${TGT#/dev/}"
check "sloučení na menší disk (500M+zbytek): kód 0" [ "$RC" = 0 ] || showlog
check "sloučení na menší: soubory obou oddílů" [ "$(fsums "${TGT}p1")/$(fsums "${TGT}p2")" = "$MA/$MB" ]
dropl "$TGT"

mkloop TGT merge-tiny 300M
rs merge-tiny --source-dev "$IMGP" --image TWO --target "${TGT#/dev/}" --mode last --yes-i-know "${TGT#/dev/}"
check "sloučení na 300M: nevejde se → kód 4" [ "$RC" = 4 ] || showlog
dropl "$TGT"; dropl "$CA"; dropl "$CB"
fi
echo
echo "Výsledek: $PASS OK, $FAIL chyb   (logy: $W/logs)"
(( FAIL == 0 ))
