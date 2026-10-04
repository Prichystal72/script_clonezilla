#!/usr/bin/env bash
# Matice kombinací: souborový systém × tabulka oddílů × velikost (i velké disky) × operace × režim.
# Disky jsou ŘÍDKÉ soubory v $W připojené jako loop – zabírají jen zapsaná data, žádný skutečný disk.
# Potřebuje Linux s rootem (WSL2 / VM).
# Spuštění:  sudo bash test/test-matrix.sh            (vše)
#            sudo bash test/test-matrix.sh 'exfat'    (jen případy, jejichž název odpovídá regexu)

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W=/var/tmp/restore-matrix
R=(bash "$ROOT/restore.sh" --allow-loop --ui plain)
FILTER=${1:-.}
PASS=0 FAIL=0 RUNNO=0
declare -a SUMMARY=()

[[ ${EUID:-$(id -u)} == 0 ]] || { echo "Spusť jako root (sudo)."; exit 2; }

ok()  { PASS=$((PASS + 1)); CASE_OK=$((CASE_OK + 1)); }
bad() { FAIL=$((FAIL + 1)); CASE_BAD+=("$*"); echo "    ✘ $*"; }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$name"; return 1; fi; }

cleanup() {
    umount /home/partimag 2>/dev/null
    for m in "$W"/mnt*; do umount "$m" 2>/dev/null; done
    local l
    for l in $(losetup -a | grep "$W/" | cut -d: -f1); do losetup -d "$l" 2>/dev/null; done
}
trap cleanup EXIT

# mkloop <proměnná> <soubor> <velikost>  (řídký soubor)
mkloop() {
    local -n _v=$1; local f="$W/$2.img"
    rm -f "$f"; truncate -s "$3" "$f"
    _v=$(losetup -fP --show "$f")
}
dropl() { local f; f=$(losetup -nO BACK-FILE "$1" 2>/dev/null); losetup -d "$1" 2>/dev/null; [[ -n "$f" ]] && rm -f "$f"; }
rescan() { partx -u "$1" 2>/dev/null; udevadm settle 2>/dev/null; local i; for (( i = 0; i < 50; i++ )); do [[ -b "${1}p1" ]] && return 0; sleep 0.1; done; }

rs() {
    RUNNO=$((RUNNO + 1))
    LAST_LOG="$W/logs/$(printf "%03d" "$RUNNO")-$1.log"; shift
    printf '%b' "${STDIN:-}" | "${R[@]}" "$@" >"$LAST_LOG" 2>&1
    RC=$?
}

fsums() {
    local dev=$1 m="$W/mnt-sum" t
    mkdir -p "$m"
    t=$(blkid -c /dev/null -s TYPE -o value "$dev")
    case "$t" in
        ntfs) mount -t ntfs-3g -o ro "$dev" "$m" || return 1 ;;
        swap) blkid -c /dev/null -s UUID -o value "$dev"; return 0 ;;
        *)    mount -o ro "$dev" "$m" || return 1 ;;
    esac
    (cd "$m" && find . -type f ! -path './System Volume Information/*' -print0 | sort -z | xargs -0 -r sha256sum)
    umount "$m"
}
fstype() { blkid -c /dev/null -s TYPE -o value "$1"; }
fsuuid() { blkid -c /dev/null -s UUID -o value "$1"; }
psize()  { blockdev --getsize64 "$1"; }
pstart() { cat "/sys/class/block/${1##*/}/start"; }
u16() { dd if="$1" bs=1 skip="$2" count=2 status=none | od -An -tu2 | tr -d ' '; }
u32() { dd if="$1" bs=1 skip="$2" count=4 status=none | od -An -tu4 | tr -d ' '; }
u64() { dd if="$1" bs=1 skip="$2" count=8 status=none | od -An -tu8 | tr -d ' '; }
u8()  { dd if="$1" bs=1 skip="$2" count=1 status=none | od -An -tu1 | tr -d ' '; }
# Velikost souborového systému v bajtech (podle jeho vlastních metadat)
fsbytes() {
    local dev=$1 t s
    t=$(fstype "$dev")
    case "$t" in
        vfat)  s=$(u16 "$dev" 19); (( s )) || s=$(u32 "$dev" 32); echo $(( s * $(u16 "$dev" 11) )) ;;
        exfat) echo $(( $(u64 "$dev" 72) << $(u8 "$dev" 108) )) ;;
        ntfs)  echo $(( ( $(u64 "$dev" 40) + 1 ) * $(u16 "$dev" 11) )) ;;
        ext*)  dumpe2fs -h "$dev" 2>/dev/null | awk -F: '/^Block count/{c=$2} /^Block size/{s=$2} END{print c*s}' ;;
        *)     psize "$dev" ;;
    esac
}
# FS vyplňuje oddíl: rozdíl < max(4 MiB, 0,5 %)
fills() { local p f tol; p=$(psize "$1"); f=$(fsbytes "$1"); tol=$(( p / 200 )); (( tol < 4194304 )) && tol=4194304; (( f <= p && p - f < tol )); }
fsck_ok() {
    case "$(fstype "$1")" in
        vfat)  # fsck.fat 4.2 hlásí jako chybu každý popisek s diakritikou (i z Windows) – jen tuto hlášku tolerovat
               local o; o=$(fsck.vfat -n "$1" 2>&1) && return 0
               ! grep -vE "^fsck.fat|Volume label .* is not valid|Auto-removing label|Leaving filesystem unchanged|files, .* clusters|^$" <<<"$o" | grep -q . ;;
        exfat) fsck.exfat -n "$1" ;;
        ntfs)  ntfsfix -n "$1" ;;
        ext*)  e2fsck -fn "$1" ;;
        *)     true ;;
    esac
}

# --- zdrojový disk ------------------------------------------------------------
# mksrc <proměnná> <název> <velikost> <dos63|dos|gpt> <spec>…   spec = fs:velikost[:boot]
#   fs: fat16 fat32 exfat ntfs ext4 swap efi msr rec   velikost: 500M, 8G, rest
declare -A TYPE_DOS=([fat16]=6 [fat32]=c [exfat]=7 [ntfs]=7 [ext4]=83 [swap]=82 [efi]=ef [rec]=27)
declare -A TYPE_GPT=([fat16]=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 [fat32]=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
    [exfat]=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 [ntfs]=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
    [ext4]=0FC63DAF-8483-4772-8E79-3D69D8477DE4 [swap]=0657FD6D-A4AB-43C4-84E5-0933C84B4F4F
    [efi]=C12A7328-F81F-11D2-BA4B-00A0C93EC93B [msr]=E3C9E316-0B5C-4DB8-817D-F92DF00215AE
    [rec]=DE94BBA4-06D1-4D40-A16A-BFD50179D6AC)
SRC_FS=() SRC_SUM=() SRC_UUID=() SRC_LABELID="" SRC_FLABEL=()
# Popisek jako z české Windows: "NOVŮ SVAZEK" v kódové stránce 852 (Ů = 0xDE) v boot sektoru i v kořenovém adresáři
cz_label() {
    local dev=$1 bits=$2 lo root bps res nf fsz
    if (( bits == 32 )); then lo=71; else lo=43; fi
    bps=$(u16 "$dev" 11); res=$(u16 "$dev" 14); nf=$(u8 "$dev" 16)
    if (( bits == 32 )); then fsz=$(u32 "$dev" 36); root=$(( (res + nf * fsz + ($(u32 "$dev" 44) - 2) * $(u8 "$dev" 13)) * bps ))
    else fsz=$(u16 "$dev" 22); root=$(( (res + nf * fsz) * bps )); fi
    local lab; lab=$(printf 'NOV\xde SVAZEK')
    printf '%s' "$lab" | dd of="$dev" bs=1 seek="$lo" conv=notrunc status=none
    (( bits == 32 )) && printf '%s' "$lab" | dd of="$dev" bs=1 seek=$(( 6 * 512 + lo )) conv=notrunc status=none
    printf '%s' "$lab" | dd of="$dev" bs=1 seek="$root" conv=notrunc status=none
}
flabel() { LC_ALL=C fatlabel "$1" 2>/dev/null | tail -n 1; }
mksrc() {
    local -n _d=$1; local name=$2 size=$3 tbl=$4; shift 4
    local spec fs sz fl i=0 start line script p
    mkloop _d "$name" "$size"
    if [[ "$tbl" == gpt ]]; then script=$'label: gpt\n'; else script=$'label: dos\nlabel-id: 0x5ec0de01\n'; fi
    script+=$'unit: sectors\n\n'
    for spec in "$@"; do
        IFS=: read -r fs sz fl <<<"$spec"
        i=$((i + 1)); line=""
        if [[ "$tbl" == dos63 && $i == 1 ]]; then line="start=63, "; fi
        [[ "$sz" != rest ]] && line+="size=$sz, "
        if [[ "$tbl" == gpt ]]; then line+="type=${TYPE_GPT[$fs]}"; else line+="type=${TYPE_DOS[$fs]}"; fi
        [[ "$fl" == boot && "$tbl" != gpt ]] && line+=", bootable"
        script+="$line"$'\n'
    done
    printf '%s' "$script" | sfdisk -q "$_d" || { echo "sfdisk selhal: $script"; return 1; }
    rescan "$_d"
    SRC_FS=() SRC_SUM=() SRC_UUID=()
    i=0
    for spec in "$@"; do
        IFS=: read -r fs sz fl <<<"$spec"
        i=$((i + 1)); p="${_d}p$i"; start=$(pstart "$p")
        case "$fs" in
            fat16)     mkfs.fat -F 16 -n "F16_$i" "$p" >/dev/null
                       [[ "$fl" == cz ]] && cz_label "$p" 16 ;;
            fat32|efi) mkfs.fat -F 32 -n "F32_$i" "$p" >/dev/null
                       [[ "$fl" == cz ]] && cz_label "$p" 32 ;;
            exfat)     mkfs.exfat -L "EXF_$i" "$p" >/dev/null ;;
            ntfs|rec)  mkfs.ntfs -Q -q -L "NTFS_$i" -p "$start" -H 255 -S 63 "$p" >/dev/null 2>&1 ;;
            ext4)      mkfs.ext4 -q -L "EXT_$i" "$p" ;;
            swap)      mkswap -L "SWP_$i" "$p" >/dev/null ;;
            msr)       : ;;
        esac
        SRC_FS[i]=$fs
        if [[ "$fs" != @(msr|swap) ]]; then
            local m="$W/mnt-fill"; mkdir -p "$m"
            if [[ "$fs" == @(ntfs|rec) ]]; then mount -t ntfs-3g "$p" "$m"; else mount "$p" "$m"; fi
            head -c 3M /dev/urandom >"$m/big.bin"; mkdir -p "$m/DIR/SUB"
            local k; for k in $(seq 40); do echo "soubor $k $name" >"$m/DIR/f$k.txt"; done
            head -c 200K /dev/urandom >"$m/DIR/SUB/mid.bin"
            umount "$m"
        fi
        if [[ "$fs" == msr ]]; then SRC_SUM[i]=""; SRC_UUID[i]=""; continue; fi
        SRC_SUM[i]=$(fsums "$p"); SRC_UUID[i]=$(fsuuid "$p"); SRC_FLABEL[i]=""
        [[ "$fs" == @(fat16|fat32|efi) ]] && SRC_FLABEL[i]=$(flabel "$p")
    done
    SRC_LABELID=$(sfdisk -d "$_d" 2>/dev/null | sed -n 's/^label-id: //p')
}

# Ověření cíle: verify <cíl> <režim> <tabulka> <počet oddílů>
verify() {
    local t=$1 mode=$2 tbl=$3 n=$4 i p last_end disk end
    for (( i = 1; i <= n; i++ )); do
        p="${t}p$i"
        [[ "${SRC_FS[i]}" == msr ]] && { check "p$i (MSR) existuje" test -b "$p"; continue; }
        check "p$i existuje" test -b "$p" || continue
        if [[ "${SRC_FS[i]}" == swap ]]; then check "p$i swap UUID" [ "$(fsuuid "$p")" = "${SRC_UUID[i]}" ]; continue; fi
        check "p$i soubory shodné" [ "$(fsums "$p")" = "${SRC_SUM[i]}" ]
        if fsck_ok "$p" >"$W/logs/fsck.txt" 2>&1; then ok; else bad "p$i fsck čistý"; tail -n 4 "$W/logs/fsck.txt" | sed 's/^/      | /'; fi
        local fb pb
        fb=$(fsbytes "$p" 2>/dev/null); pb=$(psize "$p" 2>/dev/null)
        check "p$i FS vyplňuje oddíl ($(( ${fb:-0} / 1048576 )) z $(( ${pb:-0} / 1048576 )) MiB)" fills "$p"
        check "p$i UUID FS zachované" [ "$(fsuuid "$p")" = "${SRC_UUID[i]}" ]
        [[ -n "${SRC_FLABEL[i]:-}" ]] && check "p$i popisek FAT zachovaný bajt po bajtu" [ "$(flabel "$p")" = "${SRC_FLABEL[i]}" ]
    done
    if [[ "$tbl" == dos63 ]]; then
        check "p1 začíná na sektoru 63" [ "$(pstart "${t}p1")" = 63 ]
        check "p1 bootovací" bash -c "sfdisk -d $t | grep -q '${t}p1 .*bootable'"
    fi
    [[ "$tbl" == gpt ]] && check "GPT vč. zálohy na konci bez chyb (sgdisk -v)" bash -c "sgdisk -v $t | grep -q 'No problems found'"
    [[ "$tbl" != gpt ]] && check "disk signature zachovaná" [ "$(sfdisk -d "$t" 2>/dev/null | sed -n 's/^label-id: //p')" = "$SRC_LABELID" ]
    # FAT16/FAT12 má strop velikosti – disk se celý využít nedá
    if [[ "$mode" == last && " ${SRC_FS[*]} " != *" fat16 "* ]]; then
        # obsazení disku: konec posledního oddílu u konce disku (≤ 2 MiB + GPT záloha)
        disk=$(( $(psize "$t") / 512 )); last_end=0
        # MBR adresuje nejvýš 2^32 sektorů (2 TiB) – dál se disk využít nedá
        [[ "$tbl" != gpt ]] && (( disk > 4294967296 )) && disk=4294967296
        for (( i = 1; i <= n; i++ )); do
            [[ -b "${t}p$i" ]] || continue
            end=$(( $(pstart "${t}p$i") + $(psize "${t}p$i") / 512 ))
            (( end > last_end )) && last_end=$end
        done
        check "oddíly vyplňují disk (volno $(( (disk - last_end) / 2048 )) MiB)" [ $(( disk - last_end )) -le $(( 4096 + 34 )) ]
    fi
}

# Index disku v nabídce (pořadí lsblk bez sr/zram/ram/fd)
didx() { lsblk -dnro NAME | grep -vE '^(sr|zram|ram|fd)' | grep -n "^${1#/dev/}\$" | cut -d: -f1; }
declare -A MODE_IDX=([last]=1 [proportional]=2 [manual]=3 [fixed]=4)

# run_case <název> <image|clone> <režim> <tabulka> <velikost zdroje> <velikost cíle> <očekávaný kód> <sizes|-> <spec>…
run_case() {
    local name=$1 op=$2 mode=$3 tbl=$4 ssize=$5 tsize=$6 want=$7 sizes=$8; shift 8
    [[ "$name" =~ $FILTER ]] || return 0
    CASE_OK=0 CASE_BAD=()
    echo "== $name  ($op, režim $mode, $tbl, $ssize → $tsize)"
    local S T extra=()
    mksrc S "src-$name" "$ssize" "$tbl" "$@" || { bad "příprava zdroje"; SUMMARY+=("✘ $name: příprava zdroje selhala"); return; }
    mkloop T "dst-$name" "$tsize"
    [[ "$sizes" != - ]] && extra=(--sizes "$sizes")
    local imgp=$IMGP
    [[ "$name" == fatimg-* ]] && imgp=$IMGP2
    if [[ "$op" == image ]]; then
        rs "$name-save" --source-dev "$imgp" --save-disk "${S#/dev/}" --name "M-$name"
        check "záloha kód 0" [ "$RC" = 0 ]
        rs "$name-restore" --source-dev "$imgp" --image "M-$name" --target "${T#/dev/}" --mode "$mode" --yes-i-know "${T#/dev/}" "${extra[@]}"
    else
        local in
        in="4\n$(didx "$S")\n$(didx "$T")\n${MODE_IDX[$mode]}\n"
        if [[ "$sizes" != - ]]; then in+="${sizes//,/\\n}\n"; fi
        STDIN="${in}${T#/dev/}\n0\n" rs "$name-clone"
    fi
    if [[ "$want" != 0 ]]; then
        check "očekávaný kód $want (je $RC)" [ "$RC" = "$want" ]
        check "cíl nezapsán" [ -z "$(blkid -c /dev/null -s PTTYPE -o value "$T")" ]
    elif [[ "$RC" != 0 ]]; then
        bad "kód $RC (log: $LAST_LOG)"; tail -n 6 "$LAST_LOG" | sed 's/^/      | /'
    else
        rescan "$T"
        verify "$T" "$mode" "$tbl" "$#"
        if [[ "$op" == clone ]] && grep -q 'Hotovo\|Klon' "$LAST_LOG"; then :; fi
    fi
    if (( ${#CASE_BAD[@]} )); then SUMMARY+=("✘ $name: ${CASE_BAD[*]}  [$LAST_LOG]"); else SUMMARY+=("✔ $name ($CASE_OK kontrol)"); fi
    [[ -n "${KEEP:-}" ]] || { dropl "$S"; dropl "$T"; }
}

cleanup; rm -rf "$W"; mkdir -p "$W/logs"
echo "== Disk s obrazy (řídký 400 GB, ext4)"
IMG=""
mkloop IMG images 400G
printf 'label: gpt\nunit: sectors\n\ntype=0FC63DAF-8483-4772-8E79-3D69D8477DE4\n' | sfdisk -q "$IMG"; rescan "$IMG"
mkfs.ext4 -q -L IMAGES -E lazy_itable_init=1,lazy_journal_init=1 "${IMG}p1"
IMGP=${IMG#/dev/}p1
echo "== Druhý disk s obrazy: FAT32 (jako flashka z Windows) – případy fatimg-*"
IMG2=""
mkloop IMG2 images-fat 64G
printf 'label: dos\nunit: sectors\n\nstart=2048, type=c\n' | sfdisk -q "$IMG2"; rescan "$IMG2"
mkfs.fat -F 32 -n ZALOHY "${IMG2}p1" >/dev/null
IMGP2=${IMG2#/dev/}p1

# --- 1) flashka / jeden oddíl (MBR 1 MiB jako z Windows) -----------------------
for fs in fat32 exfat ntfs ext4; do
    for op in image clone; do
        run_case "usb-$fs-$op-grow-8G-64G"   $op last  dos 8G  64G 0 - "$fs:rest"
        run_case "usb-$fs-$op-shrink-64G-8G" $op last  dos 64G 8G  0 - "$fs:rest"
    done
    run_case "usb-$fs-image-same-8G-8G"   image fixed dos 8G 8G   0 - "$fs:rest"
    run_case "usb-$fs-image-grow-8G-1T"   image last  dos 8G 1T   0 - "$fs:rest"
    run_case "usb-$fs-image-mbr-8G-3T"    image last  dos 8G 3T   0 - "$fs:rest"
done
run_case "usb-fat16-image-grow-1G-8G"   image last dos 1G 8G   0 - "fat16:rest"
# český popisek z Windows (NOVŮ SVAZEK v CP852) – FAT se při změně velikosti vytváří znovu
run_case "cz-fat32-image-shrink-16G-8G" image last dos 16G 8G 0 - "fat32:rest:cz"
run_case "cz-fat32-clone-grow-8G-64G"   clone last dos 8G 64G 0 - "fat32:rest:cz"
run_case "cz-fat16-image-grow-1G-4G"    image last dos 1G 4G  0 - "fat16:rest:cz"
run_case "cz-dual-image-proportional"   image proportional dos 22G 15G 0 - "fat32:15G:cz" "fat32:rest"
run_case "usb-fat16-clone-grow-1G-8G"   clone last dos 1G 8G   0 - "fat16:rest"
run_case "usb-fat16-image-shrink-2G-1G" image last dos 2G 1G   0 - "fat16:rest"

# --- 2) Beckhoff: MBR od sektoru 63, NTFS bootovací --------------------------------
run_case "beckhoff-ntfs-image-4G-120G"      image last   dos63 4G 120G 0 -   "ntfs:rest:boot"
run_case "beckhoff-ntfs-clone-4G-120G"      clone last   dos63 4G 120G 0 -   "ntfs:rest:boot"
run_case "beckhoff-ntfs-image-shrink-8G-2G" image last   dos63 8G 2G   0 -   "ntfs:rest:boot"
run_case "beckhoff-ntfs-image-manual-20G"   image manual dos63 4G 64G  0 20G "ntfs:rest:boot"
run_case "beckhoff-ntfs-clone-manual-20G"   clone manual dos63 4G 64G  0 20G "ntfs:rest:boot"
run_case "beckhoff-fat16-image-512M-8G"     image last   dos63 512M 8G 0 -   "fat16:rest:boot"

# --- 3) Windows MBR: System Reserved + NTFS ----------------------------------------
for m in last proportional fixed; do
    run_case "win7-image-$m-16G-64G" image $m dos 16G 64G 0 - "ntfs:500M:boot" "ntfs:rest"
done
run_case "win7-image-manual-16G-64G" image manual dos 16G 64G 0 "1G,max" "ntfs:500M:boot" "ntfs:rest"
run_case "win7-image-shrink-64G-16G" image last   dos 64G 16G 0 -     "ntfs:500M:boot" "ntfs:rest"
run_case "win7-clone-shrink-64G-16G" clone last   dos 64G 16G 0 -     "ntfs:500M:boot" "ntfs:rest"
run_case "dual-fat32-exfat-clone-8G-64G" clone proportional dos 8G 64G 0 - "fat32:2G" "exfat:rest"

# --- 4) Windows GPT: EFI + MSR + NTFS + Recovery -----------------------------------
run_case "win11-image-64G-1T"     image last gpt 64G 1T  0 - "efi:100M" "msr:16M" "ntfs:62G" "rec:rest"
run_case "win11-image-64G-32G"    image last gpt 64G 32G 0 - "efi:100M" "msr:16M" "ntfs:62G" "rec:rest"
run_case "win11-clone-64G-1T"     clone last gpt 64G 1T  0 - "efi:100M" "msr:16M" "ntfs:62G" "rec:rest"

# --- 5) Linux GPT: EFI + ext4 + swap, velké disky ----------------------------------
run_case "linux-image-32G-3T"     image last gpt 32G 3T  0 - "efi:512M" "swap:1G" "ext4:rest"
run_case "linux-image-3T-128G"    image last gpt 3T  128G 0 - "efi:512M" "swap:1G" "ext4:rest"
run_case "linux-clone-32G-3T"     clone last gpt 32G 3T  0 - "efi:512M" "swap:1G" "ext4:rest"

# --- 5b) zálohy na FAT32 (flashka z Windows): dočasná data nesmí jít na FAT (limit 4 GiB, bez řídkých souborů)
run_case "fatimg-cz-dual-proportional"  image proportional dos 22G 15G 0 - "fat32:15G:cz" "fat32:rest"
run_case "fatimg-fat32-shrink-16G-8G"   image last dos 16G 8G 0 - "fat32:rest"
run_case "fatimg-fat32-grow-8G-64G"     image last dos 8G 64G 0 - "fat32:rest"
run_case "fatimg-exfat-grow-8G-64G"     image last dos 8G 64G 0 - "exfat:rest"
run_case "fatimg-ntfs-shrink-16G-8G"    image last dos 16G 8G 0 - "ntfs:rest"

# --- 6) nevejde se → konec před zápisem -------------------------------------------
# prázdný ext4 3 TB má ~50 GB metadat (tabulky inodů) – na 32 GB se bezpečně odmítne
run_case "toosmall-ext4-3T-32G"   image last gpt 3T  32G 4 - "efi:512M" "swap:1G" "ext4:rest"
run_case "toosmall-image-ntfs"    image last dos 8G 20M 4 - "ntfs:rest"

echo
echo "================ SOUHRN ================"
printf '%s\n' "${SUMMARY[@]}"
echo "Výsledek: $PASS OK, $FAIL chyb   (logy: $W/logs)"
(( FAIL == 0 ))
