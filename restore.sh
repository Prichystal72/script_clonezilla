#!/usr/bin/env bash
# Kontrola konců řádků musí být úplně první a každý řádek končí "#", aby fungovala i s CRLF. #
# shellcheck disable=SC2154,SC2178,SC1111   # klíče asoc. polí přes nameref, české uvozovky v textech #
if [[ "$(< "$0")" == *$'\r'* ]]; then printf '%s\n' "CHYBA: $0 obsahuje Windows konce radku (CRLF). Preved soubor na LF (VS Code: vpravo dole CRLF -> LF) nebo spust: dos2unix $0"; exit 1; fi #
# =============================================================================
# restore.sh – univerzální offline nástroj pro obnovu a správu disků v Clonezille
#
# Spouštění:  sudo bash /run/live/medium/restore.sh
# Simulace:   bash restore.sh --simulate=bigger      (bez rootu, nic nezapisuje)
# Nápověda:   bash restore.sh --help
# =============================================================================

set -Eeuo pipefail
shopt -s nullglob extglob

readonly VERSION="1.2.15"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
readonly SCRIPT_PATH SCRIPT_DIR
START_TS=$(date +%s)
readonly START_TS

# --- Návratové kódy (kap. 9) -------------------------------------------------
readonly E_OK=0 E_GEN=1 E_USER=2 E_DEP=3 E_SPACE=4

# --- Nastavení (CLI / menu 15) -----------------------------------------------
SIMULATE=0            # 1 = simulace z fixtures, nikdy nic nespustí
SIM_SCENARIO=""
DRY_RUN=0             # 1 = jen vypisuje měnící příkazy
UI_BACKEND=""         # dialog | whiptail | plain (prázdné = automaticky)
OPT_IMAGE="" OPT_SOURCE_DEV="" OPT_TARGET="" OPT_MODE="" OPT_TMPDIR=""
OPT_YES="" OPT_NO_EFI_FIX=0 OPT_LOG="" OPT_NEW_GUID=0
OPT_RESIZE="" OPT_SIZE="" OPT_MOVE="" OPT_START="" OPT_EDIT=""
OPT_NAME="" OPT_SEPARATE=0   # --name, --separate (každá položka zálohy do samostatného obrazu)
OPT_SAVE_DISKS=() OPT_SAVE_PARTS=()   # --save-disk sda,sdb  --save-part sda1,sdb2
OPT_GROUPS=""        # --groups "sda+sdb,sdc": které zdroje obnovit na který cíl
OPT_SOURCE_DISK=""   # --source-disk sda[,sdb]: které disky z vícediskové zálohy obnovit
OPT_SIZES=""         # --sizes 20G,max: velikosti oddílů pro režim C (manual)
IMG_DIRS=() UNITS=()   # vybrané obrazy a zdroje obnovy "adresář|disk"
KEYMAP_WANT="cz" KEYMAP_CUR=""   # --keymap cz|us|keep
LAST_TARGET="" RESTORE_USED_TARGETS=()
ALLOW_LOOP=0          # --allow-loop: loop zařízení jako disky (jen pro testy)
COMPRESS="zstd"       # komprese pro vytváření obrazů
ACTION="menu"         # menu | restore | list-images | list-disks | info | resize | move | edit

# --- Stav běhu ---------------------------------------------------------------
LOG_FILE=""
LIVE_MEDIUM=""        # cesta k připojené flashce s Clonezillou
LIVE_DISK=""          # např. sda
IMAGES_PART=""        # oddíl s obrazy, např. sdh1
IMAGES_DISK=""        # disk s obrazy, např. sdh
declare -a TMP_MOUNTS=() LOOP_DEVS=() WARNINGS=() DONE_STEPS=()
TMP_LAST="" LOOP_LAST=""

# --- Barvy (jen v terminálu, kap. 9) ------------------------------------------
C_RED="" C_GRN="" C_YEL="" C_BLU="" C_MAG="" C_BLD="" C_OFF=""
color_on() {
    if [[ -t 1 ]]; then
        C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_BLU=$'\e[34m'
        C_MAG=$'\e[35m' C_BLD=$'\e[1m' C_OFF=$'\e[0m'
    fi
}

# =============================================================================
# LOG
# =============================================================================

# Inicializace logu: /tmp/restore-<datum>.log (nebo --log FILE)
log_init() {
    LOG_FILE="${OPT_LOG:-/tmp/restore-$(date +%Y%m%d-%H%M%S).log}"
    if ! : >>"$LOG_FILE" 2>/dev/null; then
        LOG_FILE="$(mktemp 2>/dev/null || echo /dev/null)"
    fi
    _log_file "=== restore.sh $VERSION, start $(date '+%F %T'), argumenty: ${ORIG_ARGS:-} ==="
}

# Zápis do logu bez barev
_log_file() { [[ -n "$LOG_FILE" ]] && printf '%s %s\n' "$(date +%T)" "$*" >>"$LOG_FILE" 2>/dev/null; return 0; }

log()  { _log_file "$*"; printf '%s\n' "$*"; }
info() { _log_file "INFO: $*"; printf '%s\n' "${C_BLU}ℹ${C_OFF} $*"; }
ok()   { _log_file "OK: $*"; printf '%s\n' "${C_GRN}✔${C_OFF} $*"; }
warn() { _log_file "VAROVÁNÍ: $*"; WARNINGS+=("$*"); printf '%s\n' "${C_YEL}⚠ $*${C_OFF}" >&2; }
err()  { _log_file "CHYBA: $*"; printf '%s\n' "${C_RED}✘ $*${C_OFF}" >&2; }

# Hlavička kroku, např. step 2 5 "Obnova sdf2 (ext4, 118 GiB → 476 GiB)"
step() {
    local i=$1 n=$2; shift 2
    _log_file "[$i/$n] $*"
    printf '\n%s\n' "${C_BLD}[$i/$n] $*${C_OFF}"
}

# Ukončení s kódem a hláškou
die() {
    local code=$1; shift
    err "$*"
    exit "$code"
}

# =============================================================================
# RUN – všechny měnící příkazy jdou přes tyto funkce (kap. 10.1)
# =============================================================================

# Textová podoba příkazu (bezpečně ocitovaná)
_cmd_str() {
    local a q out=""
    for a in "$@"; do
        if [[ "$a" =~ ^[A-Za-z0-9_./:=,+@%-]+$ ]]; then q=$a; else printf -v q '%q' "$a"; fi
        out+="${out:+ }$q"
    done
    printf '%s' "$out"
}

# Vypíše příkaz, který by se provedl (simulace / dry-run)
_show_cmd() {
    local tag="DRY"
    (( SIMULATE )) && tag="SIM"
    _log_file "[$tag] $*"
    printf '%s\n' "${C_MAG}[$tag]${C_OFF} $*"
}

# run <příkaz> [arg…] – provede příkaz, v simulaci/dry-runu ho jen vypíše
run() {
    if (( SIMULATE || DRY_RUN )); then
        _show_cmd "$(_cmd_str "$@")"
        DONE_STEPS+=("$(_cmd_str "$@")")
        return 0
    fi
    _log_file "\$ $(_cmd_str "$@")"
    local rc=0
    "$@" || rc=$?
    _log_file "  -> návratový kód $rc"
    if (( rc != 0 )); then
        (( RUN_TRY )) && return "$rc"
        die "$E_GEN" "Příkaz selhal (kód $rc): $(_cmd_str "$@") – další kroky se neprovedou."
    fi
    DONE_STEPS+=("$(_cmd_str "$@")")
    return 0
}

# Příkaz, jehož chyba je očekávaná / ošetřená volajícím: run_try <příkaz…> (vrací kód, nezastaví)
RUN_TRY=0
run_try() {
    local rc=0
    RUN_TRY=1
    run "$@" || rc=$?
    RUN_TRY=0
    return "$rc"
}

# Příkaz s povolenými kódy: run_rc "0 1 2" <příkaz…> (např. e2fsck: 1 = chyby opraveny)
run_rc() {
    local ok=$1 rc=0; shift
    run_try "$@" || rc=$?
    [[ " $ok " == *" $rc "* ]] || die "$E_GEN" "Příkaz selhal (kód $rc): $(_cmd_str "$@") – další kroky se neprovedou."
    return 0
}

# run_in <soubor> <příkaz…> – jako run, ale se stdin ze souboru
run_in() {
    local file=$1; shift
    if (( SIMULATE || DRY_RUN )); then
        _show_cmd "$(_cmd_str "$@") < $file"
        if [[ -r "$file" ]]; then sed 's/^/      | /' "$file"; fi
        return 0
    fi
    _log_file "\$ $(_cmd_str "$@") < $file"
    local rc=0
    "$@" <"$file" || rc=$?
    (( rc == 0 )) || die "$E_GEN" "Příkaz selhal (kód $rc): $(_cmd_str "$@") – další kroky se neprovedou."
}

# run_sh "<roura>" – provede shellový řetězec (roury partclone apod.)
run_sh() {
    if (( SIMULATE || DRY_RUN )); then
        _show_cmd "$1"
        DONE_STEPS+=("$1")
        return 0
    fi
    _log_file "\$ $1"
    local rc=0
    bash -o pipefail -c "$1" || rc=$?
    if (( rc != 0 )); then
        (( RUN_TRY )) && return "$rc"
        die "$E_GEN" "Příkaz selhal (kód $rc): $1 – další kroky se neprovedou."
    fi
}

# Pojistka: v simulaci zablokuje přímé volání zapisujících nástrojů mimo run
sim_guard_install() {
    local c
    for c in dd sfdisk sgdisk wipefs parted partprobe mkfs mkfs.ext4 mkfs.vfat mkfs.fat \
             mkfs.ntfs mkfs.xfs mkfs.btrfs mkswap resize2fs e2fsck ntfsresize ntfsfix \
             ntfsclone fatresize xfs_growfs btrfs blkdiscard nvme hdparm losetup mount \
             umount efibootmgr grub-install partclone.ext4 partclone.ntfs partclone.vfat \
             partclone.fat partclone.dd partclone.xfs partclone.btrfs ocs-sr; do
        eval "${c}() { die \$E_GEN \"SIMULACE: pokus o přímé spuštění '${c}' mimo run – zablokováno\"; }"
    done
}

# =============================================================================
# SYS_* – obaly všech čtecích dotazů na systém (v simulaci čtou fixtures)
# =============================================================================
SIM_DIR=""
SIM_MISSING=""        # ze scenario.conf: nástroje, které v simulaci "chybí"

# Je nástroj dostupný?
sys_have() {
    # RESTORE_DISABLE_TOOLS="fatresize …" – nástroje, které se mají tvářit jako chybějící (testy)
    [[ " ${RESTORE_DISABLE_TOOLS:-} " == *" $1 "* ]] && return 1
    if (( SIMULATE )); then
        [[ " $SIM_MISSING " != *" $1 "* ]]
        return
    fi
    command -v "$1" >/dev/null 2>&1
}

sys_euid() { echo "${EUID:-$(id -u)}"; }

# Výpis všech blokových zařízení ve tvaru lsblk -P (velikosti v bajtech)
sys_lsblk() {
    if (( SIMULATE )); then
        cat "$SIM_DIR/lsblk.P"
        return
    fi
    lsblk -P -b -o NAME,KNAME,PKNAME,TYPE,SIZE,FSTYPE,LABEL,UUID,VENDOR,MODEL,SERIAL,TRAN,ROTA,RM,LOG-SEC,MOUNTPOINT
}

# sfdisk --dump disku (prázdné = disk bez tabulky)
sys_sfdisk_dump() {
    if (( SIMULATE )); then
        local f="$SIM_DIR/sfdisk/$1.dump"
        if [[ -r "$f" ]]; then cat "$f"; fi
        return 0
    fi
    sfdisk --dump "/dev/$1" 2>/dev/null || true
}

# Zařízení, na kterém leží cesta (findmnt -T)
sys_findmnt_src() {
    if (( SIMULATE )); then
        local p
        for p in "${BLK_NAMES[@]}"; do
            if [[ -n "${BLK[$p.MOUNTPOINT]:-}" && "$1" == "${BLK[$p.MOUNTPOINT]}"* ]]; then
                echo "/dev/$p"; return 0
            fi
        done
        return 0
    fi
    findmnt -no SOURCE -T "$1" 2>/dev/null || true
}

# Velikost a obsazení FS z hlavičky obrazu: vypíše "<size_bytes> <used_bytes>"
sys_partclone_info() {
    local imgdir=$1 part=$2 imgtype=$3
    if (( SIMULATE )); then
        awk -v p="$part" '$1==p {print $2, $3}' "$imgdir/sim-partclone-info.txt" 2>/dev/null || true
        return 0
    fi
    [[ "$imgtype" == "ptcl" ]] || return 0
    sys_have partclone.info || return 0
    local out
    out=$(bash -o pipefail -c "$(img_stream_cmd "$imgdir" "$part") | partclone.info -s - 2>&1" 2>/dev/null || true)
    awk '
        /Block size:/   { bs=$3 }
        /Device size:/  { for (i=1;i<=NF;i++) if ($i=="=") ds=$(i+1) }
        /Space in use:/ { for (i=1;i<=NF;i++) if ($i=="=") us=$(i+1) }
        END { if (bs && ds) print ds*bs, us*bs }' <<<"$out"
}

# Nápověda ocs-sr (pro delegaci, kap. 7)
sys_ocs_help() {
    if (( SIMULATE )); then
        echo "(simulace) ocs-sr: -e1 auto -e2 -r -j2 -k1 -icds -scr -p"
        return
    fi
    ocs-sr --help 2>&1 || true
}

# SMART stav disku
sys_smart() {
    if (( SIMULATE )); then echo "SMART overall-health self-assessment test result: PASSED (simulace)"; return; fi
    if sys_have smartctl; then smartctl -H "/dev/$1" 2>&1 | tail -n +4 || true; else echo "smartctl není k dispozici"; fi
}

# Podpora TRIM (DISC-GRAN > 0)
sys_discard() {
    if (( SIMULATE )); then
        if [[ "${BLK[$1.ROTA]:-1}" == 0 ]]; then echo "ano (simulace)"; else echo "ne"; fi
        return
    fi
    local g
    g=$(lsblk -dbno DISC-GRAN "/dev/$1" 2>/dev/null | tr -d ' ')
    if [[ -n "$g" && "$g" != 0 ]]; then echo "ano (granularita $g B)"; else echo "ne"; fi
}

# =============================================================================
# BLK – načtený stav blokových zařízení (asociativní pole "jméno.SLOUPEC")
# =============================================================================
declare -A BLK=()
declare -a BLK_NAMES=() BLK_DISKS=()

blk_load() {
    BLK=() BLK_NAMES=() BLK_DISKS=()
    local line k v name re='^[[:space:]]*([A-Za-z0-9_:-]+)="([^"]*)"(.*)$'
    local -A row
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        row=()
        while [[ "$line" =~ $re ]]; do
            k=${BASH_REMATCH[1]//[-:]/_}
            v=${BASH_REMATCH[2]}
            line=${BASH_REMATCH[3]}
            [[ "$v" == *'\x'* ]] && printf -v v '%b' "$v"
            row[$k]=$v
        done
        name=${row[NAME]:-}
        [[ -z "$name" ]] && continue
        BLK_NAMES+=("$name")
        for k in "${!row[@]}"; do BLK[$name.$k]=${row[$k]}; done
        if [[ "${row[TYPE]:-}" == loop ]] && (( ALLOW_LOOP )); then BLK[$name.TYPE]=disk; row[TYPE]=disk; fi
        [[ "${row[TYPE]:-}" == disk ]] && BLK_DISKS+=("$name")
    done < <(sys_lsblk)
    # lsblk bere FS z databáze udev – čerstvě vytvořený FS tam ještě nemusí být; doplnit přímým čtením
    if (( ! SIMULATE )); then
        for name in "${BLK_NAMES[@]}"; do
            [[ "${BLK[$name.TYPE]:-}" == part && -z "${BLK[$name.FSTYPE]:-}" && -b "/dev/$name" ]] || continue
            while IFS='=' read -r k v; do
                case "$k" in TYPE) BLK[$name.FSTYPE]=$v ;; LABEL) BLK[$name.LABEL]=$v ;; UUID) BLK[$name.UUID]=$v ;; esac
            done < <(blkid -p -o export "/dev/$name" 2>/dev/null || true)
        done
    fi
    return 0
}

# Oddíly (děti) disku
blk_children() {
    local n
    for n in "${BLK_NAMES[@]}"; do
        if [[ "${BLK[$n.PKNAME]:-}" == "$1" ]]; then echo "$n"; fi
    done
    return 0
}

# Rodičovský disk oddílu
blk_parent() { echo "${BLK[$1.PKNAME]:-$1}"; }

# =============================================================================
# CORE – argumenty, kontroly
# =============================================================================

usage() {
    cat <<USAGE
restore.sh $VERSION – offline obnova a správa disků v Clonezille

Interaktivně:   sudo bash restore.sh
Obnova:         restore.sh [--source-dev /dev/sdh1] --image DIR --target sdf
                           --mode last|proportional|fixed|manual
                           [--tmpdir DIR] [--dry-run] [--yes-i-know sdf]
                           [--no-efi-fix] [--new-guid] [--log FILE]
Editor:         restore.sh --resize sdf2 --size 200G|+50G|-20G|max|60%
                restore.sh --move sdf3 --start end|<MiB>
                restore.sh --edit sdf
Záloha:         restore.sh --save-disk sda[,sdb…] [--save-part sda1[,sdb2…]] [--name NÁZEV] [--separate]
                (vše do jednoho obrazu, s --separate každá položka do vlastního)
Víc zdrojů:     --image A,B  --source-disk sda,B:sdb  --groups "sda+B:sdb,sdc"  --target sdf,sdg
Informace:      restore.sh --list-images [DIR] | --list-disks | --info IMAGE
Simulace:       restore.sh --simulate[=SCÉNÁŘ]   (scénáře: $(sim_list | tr '\n' ' '))
Ostatní:        --ui dialog|whiptail|plain  --help  --version

Návratové kódy: 0 OK, 1 chyba, 2 zrušeno/chyba uživatele, 3 chybí závislost, 4 málo místa
USAGE
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --simulate)      SIMULATE=1; SIM_SCENARIO="bigger" ;;
            --simulate=*)    SIMULATE=1; SIM_SCENARIO="${1#*=}" ;;
            --dry-run)       DRY_RUN=1 ;;
            --image)         OPT_IMAGE=${2:?chybí cesta}; shift; [[ "$ACTION" == menu ]] && ACTION=restore ;;
            --source-dev)    OPT_SOURCE_DEV=${2:?chybí zařízení}; shift ;;
            --target)        OPT_TARGET=${2:?chybí disk}; OPT_TARGET=${OPT_TARGET//\/dev\//}; shift ;;
            --mode)          OPT_MODE=${2:?chybí režim}; shift ;;
            --tmpdir)        OPT_TMPDIR=${2:?chybí adresář}; shift ;;
            --yes-i-know)    OPT_YES=${2:?chybí název disku}; OPT_YES=${OPT_YES//\/dev\//}; shift ;;
            --no-efi-fix)    OPT_NO_EFI_FIX=1 ;;
            --new-guid)      OPT_NEW_GUID=1 ;;
            --log)           OPT_LOG=${2:?chybí soubor}; shift ;;
            --ui)            UI_BACKEND=${2:?chybí backend}; shift ;;
            --allow-loop)    ALLOW_LOOP=1 ;;
            --save-disk)     ACTION="save"; IFS=, read -ra _l <<<"${2:?chybí disk}"; OPT_SAVE_DISKS+=("${_l[@]#/dev/}"); shift ;;
            --save-part)     ACTION="save"; IFS=, read -ra _l <<<"${2:?chybí oddíl}"; OPT_SAVE_PARTS+=("${_l[@]#/dev/}"); shift ;;
            --separate)      OPT_SEPARATE=1 ;;
            --groups)        OPT_GROUPS=${2:?chybí skupiny}; shift ;;
            --name)          OPT_NAME=${2:?chybí název}; shift ;;
            --source-disk)   OPT_SOURCE_DISK=${2:?chybí disk}; shift ;;
            --sizes)         OPT_SIZES=${2:?chybí velikosti}; shift ;;
            --keymap)        KEYMAP_WANT=${2:?chybí rozložení}; shift ;;
            --list-images)   ACTION="list-images"
                             if [[ -n "${2:-}" && "$2" != --* ]]; then OPT_IMAGE=$2; shift; fi ;;
            --list-disks)    ACTION="list-disks" ;;
            --info)          ACTION=info; OPT_IMAGE=${2:?chybí obraz}; shift ;;
            --resize)        ACTION=resize; OPT_RESIZE=${2:?chybí oddíl}; OPT_RESIZE=${OPT_RESIZE#/dev/}; shift ;;
            --size)          OPT_SIZE=${2:?chybí velikost}; shift ;;
            --move)          ACTION=move; OPT_MOVE=${2:?chybí oddíl}; OPT_MOVE=${OPT_MOVE#/dev/}; shift ;;
            --start)         OPT_START=${2:?chybí začátek}; shift ;;
            --edit)          ACTION=edit; OPT_EDIT=${2:?chybí disk}; OPT_EDIT=${OPT_EDIT#/dev/}; shift ;;
            -h|--help)       ACTION=help ;;
            -V|--version)    ACTION=version ;;
            *)               usage >&2; die "$E_USER" "Neznámý parametr: $1" ;;
        esac
        shift
    done
    if [[ -n "$OPT_MODE" && "$OPT_MODE" != @(last|proportional|fixed|manual) ]]; then
        die "$E_USER" "Neplatný --mode '$OPT_MODE' (last|proportional|fixed|manual)"
    fi
    # Simulace se nesmí nikdy dostat k ostrému zápisu – přepínač zamkneme
    readonly SIMULATE
}

check_root() {
    if (( SIMULATE )); then
        if [[ "$(sys_euid)" != 0 ]]; then info "Simulace: kontrola root přeskočena."; fi
        return 0
    fi
    if [[ "$(sys_euid)" != 0 ]]; then
        die "$E_USER" "Skript musí běžet jako root. Spusť: sudo bash $SCRIPT_PATH  (nebo bez rootu: --simulate)"
    fi
}

readonly DEPS_REQUIRED="lsblk blkid sfdisk sgdisk parted partprobe wipefs udevadm dd cat awk sed"
readonly DEPS_OPTIONAL="dialog whiptail pv smartctl efibootmgr blkdiscard nvme hdparm rsync partclone.info partclone.chkimg fatresize"

# Tabulka závislostí ✔/✘; chybějící povinné → konec (v simulaci jen výpis)
check_deps() {
    local c missing=() opt_missing=()
    (( BASH_VERSINFO[0] >= 4 )) || die "$E_DEP" "Potřebuji bash ≥ 4 (máš $BASH_VERSION)."
    for c in $DEPS_REQUIRED; do sys_have "$c" || missing+=("$c"); done
    for c in $DEPS_OPTIONAL; do sys_have "$c" || opt_missing+=("$c"); done
    if (( ${#missing[@]} )); then
        log "Povinné nástroje:"
        for c in $DEPS_REQUIRED; do
            if sys_have "$c"; then printf '  %s %s\n' "${C_GRN}✔${C_OFF}" "$c"
            else printf '  %s %s\n' "${C_RED}✘${C_OFF}" "$c"; fi
        done
        if (( SIMULATE )); then
            warn "Simulace: chyběly by povinné nástroje: ${missing[*]}"
        else
            die "$E_DEP" "Chybí povinné nástroje: ${missing[*]}"
        fi
    fi
    if (( ${#opt_missing[@]} )); then info "Volitelné nástroje, které chybí: ${opt_missing[*]}"; fi
    return 0
}

# Kontrola nástrojů podle obsahu obrazu (volá se po výběru obrazu)
check_deps_image() {
    local -n _L=$1
    local n c need=() missing=()
    for n in ${_L[parts]}; do
        case "${_L[$n.imgtype]:-}" in
            ptcl) need+=("partclone.${_L[$n.fs]}") ;;
            ntfs) need+=(ntfsclone) ;;
            dd)   need+=(dd) ;;
        esac
        if [[ -n "${_L[$n.comp]:-}" && "${_L[$n.comp]}" != none ]]; then
            c=$(img_decompressor "${_L[$n.comp]}")
            need+=("${c%% *}")
        fi
    done
    for c in "${need[@]}"; do sys_have "$c" || missing+=("$c"); done
    if (( ${#missing[@]} )); then
        if (( SIMULATE )); then warn "Simulace: k obnově by chyběly: ${missing[*]}"; return 0; fi
        die "$E_DEP" "K obnově tohoto obrazu chybí: ${missing[*]}"
    fi
    return 0
}

# =============================================================================
# UNITS – převody velikostí (interně sektory a bajty)
# =============================================================================
readonly MiB=1048576 GiB=1073741824
SMALL_MEDIA=0         # 1 = malá média (CF/CFast) → velikosti v MiB (kap. 5.7/7)

# Lidsky čitelná velikost z bajtů
human() {
    local b=${1:-0}
    if (( SMALL_MEDIA )) && (( b < 8 * GiB )); then
        awk -v b="$b" 'BEGIN { printf "%d MiB", b/1048576 }'
        return
    fi
    awk -v b="$b" 'BEGIN {
        a = (b < 0) ? -b : b; s = (b < 0) ? "-" : ""
        if (a >= 1099511627776) printf "%s%.2f TiB", s, a/1099511627776
        else if (a >= 1073741824) printf "%s%.1f GiB", s, a/1073741824
        else printf "%s%d MiB", s, a/1048576 }'
}

# Přepočet "200G", "512M", "1.5GiB", "60%", "+20G", "-5G", "max" na bajty.
# parse_size <výraz> <aktuální_bajty> <disk_bajty> <max_bajty>
parse_size() {
    local expr=${1// /} cur=${2:-0} disk=${3:-0} max=${4:-0}
    local sign="" num unit mult
    [[ "$expr" == max ]] && { echo "$max"; return 0; }
    if [[ "$expr" =~ ^([0-9]+([.][0-9]+)?)%$ ]]; then
        awk -v p="${BASH_REMATCH[1]}" -v d="$disk" 'BEGIN { printf "%.0f\n", d*p/100 }'
        return 0
    fi
    [[ "$expr" =~ ^([+-]?)([0-9]+([.][0-9]+)?)([KkMmGgTt]?)(i?[Bb])?$ ]] || return 1
    sign=${BASH_REMATCH[1]} num=${BASH_REMATCH[2]} unit=${BASH_REMATCH[4]^^}
    case "$unit" in
        K) mult=1024 ;; ""|M) mult=$MiB ;; G) mult=$GiB ;; T) mult=$((GiB * 1024)) ;;
    esac
    local val
    val=$(awk -v n="$num" -v m="$mult" 'BEGIN { printf "%.0f\n", n*m }')
    case "$sign" in
        +) echo $(( cur + val )) ;;
        -) echo $(( cur - val )) ;;
        *) echo "$val" ;;
    esac
}

# Zarovnání sektoru na 1 MiB nahoru / dolů (podle velikosti sektoru)
align_up()   { local s=$1 a=$(( MiB / ${2:-512} )); echo $(( (s + a - 1) / a * a )); }
align_down() { local s=$1 a=$(( MiB / ${2:-512} )); echo $(( s / a * a )); }

# =============================================================================
# UI – dialog → whiptail → čistý text (výsledek v UI_REPLY)
# =============================================================================
UI_REPLY=""
UI_DEFAULT=""   # předvolená položka příští nabídky (tag)
UI_EMPTY=0      # ui_checklist: potvrzeno, ale nic neoznačeno
SRC_EXCLUDE=""  # oddíly, které se nesmí nabídnout jako místo pro obrazy (právě se zálohují)

ui_init() {
    if [[ -z "$UI_BACKEND" ]]; then
        if [[ -t 0 && -t 1 ]] && command -v dialog >/dev/null 2>&1; then UI_BACKEND=dialog
        elif [[ -t 0 && -t 1 ]] && command -v whiptail >/dev/null 2>&1; then UI_BACKEND=whiptail
        else UI_BACKEND=plain; fi
    fi
    if [[ "$UI_BACKEND" != plain ]] && ! command -v "$UI_BACKEND" >/dev/null 2>&1; then
        UI_BACKEND=plain
    fi
    ui_make_themes
}

# Barevná témata oken: zelená = ZDROJ (odkud se čte), červená = CÍL (kam se zapisuje), jinak výchozí.
UI_THEME=default UI_TC=""
ui_make_themes() {
    local c up rc="${STATE_DIR:-/tmp}/dialogrc-base"
    [[ "$UI_BACKEND" == dialog ]] || return 0
    dialog --create-rc "$rc" 2>/dev/null || return 0
    for c in green red; do
        up=${c^^}
        sed -E "s/BLUE/$up/g; s/^screen_color = .*/screen_color = (WHITE,$up,ON)/; s/^title_color = .*/title_color = (WHITE,$up,ON)/" "$rc" >"${STATE_DIR:-/tmp}/dialogrc-$c"
    done
}

# ui_theme <green|red|default>
ui_theme() {
    UI_THEME=${1:-default}
    case "$UI_THEME" in green) UI_TC=$C_GRN ;; red) UI_TC=$C_RED ;; *) UI_TC="" ;; esac
    case "$UI_BACKEND" in
        dialog)
            if [[ "$UI_THEME" == default || ! -s "${STATE_DIR:-/tmp}/dialogrc-$UI_THEME" ]]; then unset DIALOGRC
            else export DIALOGRC="${STATE_DIR:-/tmp}/dialogrc-$UI_THEME"; fi ;;
        whiptail)
            case "$UI_THEME" in
                green) export NEWT_COLORS='root=white,green title=green,white actbutton=white,green actlistbox=white,green actsellistbox=white,green' ;;
                red)   export NEWT_COLORS='root=white,red title=red,white actbutton=white,red actlistbox=white,red actsellistbox=white,red' ;;
                *)     unset NEWT_COLORS ;;
            esac ;;
    esac
}

# Čtení řádku v textovém režimu; konec vstupu = ukončení (ochrana proti smyčce)
_ui_read() {
    local prompt=$1
    if ! IFS= read -r -p "$prompt" UI_REPLY; then
        echo
        die "$E_USER" "Konec vstupu – ukončuji."
    fi
    _log_file "  vstup: $UI_REPLY"
}

# Horní řádek obrazovky: kde jsem + nápověda ovládání
UI_STEP=""
_bt() {
    local tag=""
    case "$UI_THEME" in green) tag="[ZDROJ] " ;; red) tag="[CÍL – ZÁPIS] " ;; esac
    printf '%srestore.sh %s%s%s   |   číslo/šipky = výběr · Enter = OK · Esc = zpět' "$tag" "$VERSION" "${UI_STEP:+  ›  }" "$UI_STEP"
}
ui_step() { UI_STEP="${UI_BASE}${UI_BASE:+  ›  }$1"; }
UI_BASE=""

# ui_menu <titulek> <text> <tag> <popis> [<tag> <popis>…]; 1 = zrušeno
# Uživatel volí vždy jen ČÍSLEM: nečíselné tagy se zobrazí jako 1, 2, 3… a převedou zpět na tag.
ui_menu() {
    local title=$1 text=$2; shift 2
    local -a tags=() descs=() items=()
    local i numeric=1
    while (( $# >= 2 )); do
        tags+=("$1"); descs+=("$2")
        [[ "$1" =~ ^[0-9]+$ ]] || numeric=0
        shift 2
    done
    for i in "${!tags[@]}"; do
        if (( numeric )); then items+=("${tags[i]}" "${descs[i]}"); else items+=("$(( i + 1 ))" "${descs[i]}"); fi
    done
    case "$UI_BACKEND" in
        dialog)
            local mh=$(( ${#items[@]} / 2 )) defarg=()
            (( mh > 18 )) && mh=18
            if [[ -n "${UI_DEFAULT:-}" ]]; then
                for i in "${!tags[@]}"; do
                    if [[ "${tags[i]}" == "$UI_DEFAULT" ]]; then
                        if (( numeric )); then defarg=(--default-item "${tags[i]}"); else defarg=(--default-item "$(( i + 1 ))"); fi
                    fi
                done
            fi
            UI_REPLY=$(dialog --clear --backtitle "$(_bt)" --title "$title" "${defarg[@]}" --ok-label "Vybrat" --cancel-label "< Zpět" --menu "$text" 0 0 "$mh" "${items[@]}" 3>&1 1>&2 2>&3) || { UI_DEFAULT=""; return 1; } ;;
        whiptail)
            UI_REPLY=$(whiptail --backtitle "$(_bt)" --title "$title" --ok-button "Vybrat" --cancel-button "< Zpět" --menu "$text" 24 90 16 "${items[@]}" 3>&1 1>&2 2>&3) || return 1 ;;
        *)
            printf '\n%s\n' "${C_BLD}${UI_TC:-}=== $title ===${C_OFF}"
            [[ -n "$text" ]] && printf '%s\n' "$text"
            for (( i = 0; i < ${#items[@]}; i += 2 )); do printf '  %3s) %s\n' "${items[i]}" "${items[i+1]}"; done
            while true; do
                _ui_read "Volba – číslo (Enter = zpět): "
                [[ -z "$UI_REPLY" ]] && return 1
                if [[ "$UI_REPLY" =~ ^[0-9]+$ ]]; then
                    for (( i = 0; i < ${#items[@]}; i += 2 )); do [[ "${items[i]}" == "$UI_REPLY" ]] && break 2; done
                fi
                echo "Neplatná volba – zadej číslo z nabídky."
            done ;;
    esac
    UI_DEFAULT=""
    (( numeric )) || UI_REPLY=${tags[UI_REPLY - 1]}
    _log_file "  volba: $UI_REPLY"
    return 0
}

# ui_checklist <titulek> <text> <tag> <popis> <on|off>…; výsledek "tag1 tag2" (volí se čísly)
ui_checklist() {
    local title=$1 text=$2; shift 2
    UI_EMPTY=0
    local -a tags=() items=() defs=()
    local i x out=""
    while (( $# >= 3 )); do
        tags+=("$1")
        items+=("$(( ${#tags[@]} ))" "$2" "$3")
        [[ "$3" == on ]] && defs+=("${#tags[@]}")
        shift 3
    done
    case "$UI_BACKEND" in
        dialog)
            UI_REPLY=$(dialog --backtitle "$(_bt)" --title "$title" --ok-label "Potvrdit výběr" --cancel-label "< Zpět" --separate-output --checklist "$text
(mezerník = označit/odznačit)" 0 0 "$(( ${#tags[@]} > 18 ? 18 : ${#tags[@]} ))" "${items[@]}" 3>&1 1>&2 2>&3) || return 1 ;;
        whiptail)
            UI_REPLY=$(whiptail --backtitle "$(_bt)" --title "$title" --ok-button "Potvrdit výběr" --cancel-button "< Zpět" --separate-output --checklist "$text" 24 90 16 "${items[@]}" 3>&1 1>&2 2>&3) || return 1 ;;
        *)
            printf '\n%s\n%s\n' "${C_BLD}${UI_TC:-}=== $title ===${C_OFF}" "$text"
            for (( i = 0; i < ${#items[@]}; i += 3 )); do
                printf '  %3s) %s %s\n' "${items[i]}" "${items[i+1]}" "$([[ "${items[i+2]}" == on ]] && echo '[x]' || echo '[ ]')"
            done
            _ui_read "Vyber čísla oddělená mezerou (Enter = výchozí [x], 0 = zpět): "
            [[ "$UI_REPLY" == 0 ]] && return 1
            [[ -z "$UI_REPLY" ]] && UI_REPLY="${defs[*]}" ;;
    esac
    for x in $UI_REPLY; do
        if [[ ! "$x" =~ ^[0-9]+$ ]] || (( x < 1 || x > ${#tags[@]} )); then echo "Neplatná položka: $x"; return 1; fi
        out+="${out:+ }${tags[x - 1]}"
    done
    UI_REPLY=$out
    if [[ -z "$UI_REPLY" ]]; then UI_EMPTY=1; return 1; fi
    UI_EMPTY=0
}

# ui_yesno <text> [výchozí a|n]; 0 = ano
ui_yesno() {
    local text=$1 def=${2:-n}
    case "$UI_BACKEND" in
        dialog)   dialog --backtitle "$(_bt)" --title "Otázka" --yes-label "Ano" --no-label "Ne" --yesno "$text" 0 0; return ;;
        whiptail) whiptail --backtitle "$(_bt)" --title "Otázka" --yes-button "Ano" --no-button "Ne" --yesno "$text" 20 78; return ;;
        *)
            local hint="[1 = ano, 0 = ne; Enter = ne]"
            [[ "$def" == a ]] && hint="[1 = ano, 0 = ne; Enter = ano]"
            _ui_read "$text $hint: "
            [[ -z "$UI_REPLY" ]] && UI_REPLY=$def
            [[ "$UI_REPLY" == [1aAyY]* ]] ;;
    esac
}

# ui_input <text> [výchozí]; výsledek v UI_REPLY, 1 = zrušeno
ui_input() {
    local text=$1 def=${2:-}
    case "$UI_BACKEND" in
        dialog)   UI_REPLY=$(dialog --backtitle "$(_bt)" --title "Zadání" --ok-label "Potvrdit" --cancel-label "< Zpět" --inputbox "$text" 0 76 "$def" 3>&1 1>&2 2>&3) || return 1 ;;
        whiptail) UI_REPLY=$(whiptail --backtitle "$(_bt)" --title "Zadání" --ok-button "Potvrdit" --cancel-button "< Zpět" --inputbox "$text" 14 78 "$def" 3>&1 1>&2 2>&3) || return 1 ;;
        *)
            local p="$text"
            [[ -n "$def" ]] && p+=" [$def]"
            _ui_read "$p: "
            [[ "$UI_REPLY" == q ]] && return 1
            [[ -z "$UI_REPLY" ]] && UI_REPLY=$def ;;
    esac
    return 0
}

# ui_msg <text> – krátká zpráva
ui_msg() {
    case "$UI_BACKEND" in
        dialog)   dialog --backtitle "$(_bt)" --title "Informace" --ok-label "Další >" --msgbox "$1" 0 0 ;;
        whiptail) whiptail --backtitle "$(_bt)" --title "Informace" --ok-button "Další >" --msgbox "$1" 20 78 ;;
        *)        printf '%s\n' "$1" ;;
    esac
    _log_file "MSG: $1"
}

# ui_text <titulek> < text – delší výpis (tabulky); v dialogu jako textbox
ui_text() {
    local title=$1 tmp
    tmp=$(mktemp)
    cat >"$tmp"
    cat "$tmp" >>"$LOG_FILE" 2>/dev/null || true
    case "$UI_BACKEND" in
        dialog)   dialog --backtitle "$(_bt)" --title "$title" --exit-label "Další >" --no-collapse --textbox "$tmp" 0 0 ;;
        whiptail) whiptail --backtitle "$(_bt)" --title "$title" --ok-button "Další >" --scrolltext --textbox "$tmp" 24 100 ;;
        *)        printf '\n%s\n' "${C_BLD}--- $title ---${C_OFF}"; cat "$tmp" ;;
    esac
    rm -f "$tmp"
}

# ui_pause – v textovém režimu počká na Enter (jen interaktivně)
ui_pause() {
    if [[ "$UI_BACKEND" == plain && -t 0 ]]; then
        read -r -p "Enter = pokračovat " _ || true
    fi
    return 0
}

# ui_gauge <titulek> – čte procenta (0–100) ze stdin
ui_gauge() {
    local title=$1
    case "$UI_BACKEND" in
        dialog)   dialog --backtitle "$(_bt)" --title "$title" --gauge "$title" 8 70 0 ;;
        whiptail) whiptail --title "$title" --gauge "$title" 8 70 0 ;;
        *)
            local p bar
            while read -r p; do
                [[ "$p" =~ ^[0-9]+$ ]] || continue
                printf -v bar '%*s' $(( p / 4 )) ''
                printf '\r  %s [%-25s] %3d%%' "$title" "${bar// /#}" "$p"
            done
            echo ;;
    esac
}

# ui_confirm_disk <disk> <souhrn> – potvrzení opsáním názvu disku (kap. 4)
ui_confirm_disk() {
    ui_theme red
    local disk=$1 summary=$2
    printf '%s\n' "$summary" | ui_text "Souhrn před zápisem"
    if [[ -n "$OPT_YES" ]]; then
        if [[ ",$OPT_YES," == *",$disk,"* ]]; then info "Potvrzeno parametrem --yes-i-know $disk"; return 0; fi
        die "$E_USER" "--yes-i-know '$OPT_YES' neodpovídá cílovému disku '$disk'"
    fi
    local warnline="!!! VŠECHNA DATA NA /dev/$disk BUDOU ZNIČENA !!!"
    [[ "$UI_BACKEND" == plain ]] && warnline="${C_RED}${warnline}${C_OFF}"
    ui_input "$warnline  Pro potvrzení opiš název disku: $disk" || return 1
    if [[ "$UI_REPLY" != "$disk" ]]; then
        warn "Potvrzení nesouhlasí ('$UI_REPLY' ≠ '$disk') – operace zrušena."
        return 1
    fi
    _log_file "Potvrzeno opsáním: $disk"
    return 0
}

# Napodobení průběhu (simulace / dry-run)
sim_progress() {
    local title=$1 i
    for i in 0 10 20 30 40 50 60 70 80 90 100; do
        echo "$i"
        if [[ -t 1 ]]; then sleep 0.05; fi
    done | ui_gauge "$title"
}

# =============================================================================
# DISK – názvy, ochrana disků, výpisy
# =============================================================================

# Název oddílu: part_name sda 2 → sda2, nvme0n1 2 → nvme0n1p2, mmcblk0 1 → mmcblk0p1
part_name() {
    local disk=$1 n=$2
    if [[ "$disk" =~ [0-9]$ ]]; then echo "${disk}p${n}"; else echo "${disk}${n}"; fi
}

# Číslo oddílu z názvu (sda12 → 12, nvme0n1p3 → 3)
part_num() { [[ "$1" =~ ([0-9]+)$ ]] && echo "${BASH_REMATCH[1]}"; }

# Najde flashku s Clonezillou (podle mountpointu /run/live/medium; starší Clonezilla: /usr/lib/live/mount/medium)
live_detect() {
    local n mp src
    for n in "${BLK_NAMES[@]}"; do
        mp=${BLK[$n.MOUNTPOINT]:-}
        if [[ "$mp" == /run/live/medium || "$mp" == /lib/live/mount/medium || "$mp" == /usr/lib/live/mount/medium ]]; then
            LIVE_MEDIUM=$mp
            LIVE_DISK=$(blk_parent "$n")
            return 0
        fi
    done
    if (( ! SIMULATE )); then
        for mp in /run/live/medium /usr/lib/live/mount/medium /lib/live/mount/medium; do
            [[ -d "$mp" ]] || continue
            src=$(findmnt -nro SOURCE "$mp" 2>/dev/null | head -1)
            src=${src#/dev/}
            if [[ -n "$src" && -n "${BLK[$src.TYPE]:-}" ]]; then
                LIVE_MEDIUM=$mp
                LIVE_DISK=$(blk_parent "$src")
                return 0
            fi
            [[ -n "$LIVE_MEDIUM" ]] || LIVE_MEDIUM=$mp
        done
    fi
    return 0
}

# Je disk chráněný? Vypíše důvod a vrátí 0, jinak 1 (kap. 4.3)
disk_protect_reason() {
    local d=$1 c mp
    # Testovací režim: cílem smí být jen loop soubor, žádný skutečný disk
    if (( ALLOW_LOOP )) && [[ "$d" != loop* ]]; then echo "testovací režim – jen loop zařízení"; return 0; fi
    if [[ -n "$LIVE_DISK" && "$d" == "$LIVE_DISK" ]]; then echo "flashka s Clonezillou"; return 0; fi
    if [[ -n "${CLONE_SRC:-}" && "$d" == "$CLONE_SRC" ]]; then echo "zdroj klonu"; return 0; fi
    if [[ -n "$IMAGES_DISK" && "$d" == "$IMAGES_DISK" ]]; then echo "disk s obrazy"; return 0; fi
    mp=${BLK[$d.MOUNTPOINT]:-}
    if [[ -n "$mp" ]]; then echo "připojeno: $d → $mp"; return 0; fi
    for c in $(blk_children "$d"); do
        mp=${BLK[$c.MOUNTPOINT]:-}
        if [[ -n "$mp" ]]; then echo "připojeno: $c → $mp"; return 0; fi
    done
    return 1
}

# Disky vhodné pro výpis (bez loop/rom/zram)
disk_all() {
    local d
    for d in "${BLK_DISKS[@]}"; do
        [[ "$d" == loop* ]] && (( ! ALLOW_LOOP )) && continue
        [[ "$d" == @(sr*|zram*|ram*|fd*) ]] && continue
        echo "$d"
    done
    return 0
}

# Je vidět nějaký disk mimo USB (kromě flashky s Clonezillou)?
disk_have_internal() {
    local d
    for d in $(disk_all); do
        [[ "$d" == "$LIVE_DISK" || "${BLK[$d.TRAN]:-}" == usb ]] && continue
        return 0
    done
    return 1
}

# Řadiče disků z /sys (PCI třída 01xx): "adresa třída vendor:device ovladač" na řádek
storage_controllers() {
    local dev cls drv
    for dev in /sys/bus/pci/devices/*; do
        [[ -r "$dev/class" ]] || continue
        cls=$(<"$dev/class")
        [[ "$cls" == 0x01* ]] || continue
        drv=-
        [[ -L "$dev/driver" ]] && drv=$(basename "$(readlink "$dev/driver")")
        echo "${dev##*/} ${cls:2:4} $(<"$dev/vendor"):$(<"$dev/device") $drv"
    done | sed 's/0x//g'
}

# Diagnostika disků a řadičů (jádro, PCI, lsblk, dmesg) – text pro log / okno
storage_diag() {
    local addr cls id drv
    echo "Jádro: $(uname -r) ($(uname -m))"
    echo "Řadiče disků (PCI adresa, třída, ID, ovladač):"
    while read -r addr cls id drv; do
        echo "  $addr  $cls  [$id]  $drv"
    done < <(storage_controllers)
    if sys_have lspci; then
        echo "lspci -nnk:"
        lspci -nnk 2>/dev/null | sed 's/^/  /'
    fi
    echo "Disky (lsblk):"
    lsblk -o NAME,SIZE,TYPE,TRAN,VENDOR,MODEL,FSTYPE,MOUNTPOINT 2>/dev/null | sed 's/^/  /'
    echo "Hlášení jádra o discích (dmesg):"
    dmesg 2>/dev/null | grep -i -E ' ata[0-9]|pata|sata|ahci|ide[0-9]|scsi|nvme| sd[a-z]|mmc' | tail -n 60 | sed 's/^/  /'
    return 0
}

# Po startu: řadiče disků bez ovladače (disky na nich nejsou vidět, např. SATA vedle CF na panelu
# Beckhoff) zkusí oživit načtením ovladače podle PCI ID. Diagnostiku vždy zapíše do logu; když řadič
# zůstane bez ovladače nebo jsou vidět jen USB disky, ukáže okno s radou. Nic nezapisuje na disky.
disk_check_internal() {
    (( SIMULATE || ALLOW_LOOP )) && return 0
    [[ "$ACTION" == menu ]] || return 0

    local addr cls id drv dev i nodrv=() raid=() txt ndisk
    while read -r addr cls id drv; do
        [[ "$drv" == - ]] && nodrv+=("$addr")
    done < <(storage_controllers)
    if (( ${#nodrv[@]} )) || ! disk_have_internal; then
        info "Zkouším načíst ovladače řadičů disků (bez ovladače: ${nodrv[*]:-žádný})."
        ndisk=${#BLK_DISKS[@]}
        for addr in "${nodrv[@]}"; do
            dev=/sys/bus/pci/devices/$addr
            [[ -r "$dev/modalias" ]] && { run_try modprobe -a -q "$(<"$dev/modalias")" || true; }
        done
        # obecný ovladač pro IDE řadiče (CF sloty), které nemají vlastní
        run_try modprobe -a -q ata_generic pata_acpi || true
        for i in 1 2 3 4 5 6; do
            udevadm settle --timeout=5 2>/dev/null || true
            sleep 1
        done
        blk_load
        live_detect
        (( ${#BLK_DISKS[@]} > ndisk )) && ok "Po načtení ovladačů přibyly disky: ${BLK_DISKS[*]}."
    fi

    txt=$(storage_diag)
    _log_file "=== Diagnostika disků ==="
    printf '%s\n' "$txt" >>"$LOG_FILE" 2>/dev/null || true

    nodrv=()
    while read -r addr cls id drv; do
        [[ "$drv" == - ]] && nodrv+=("$addr [$id]")
        [[ "$cls" == 0104 ]] && raid+=("$addr [$id]")
    done < <(storage_controllers)
    if disk_have_internal && (( ! ${#nodrv[@]} )); then
        log_copy_flash
        return 0
    fi

    if disk_have_internal; then
        txt="Některý řadič disků nemá ovladač – disky na něm (např. SSD na SATA) nejsou vidět."$'\n\n'"$txt"
    else
        txt="Clonezilla vidí jen USB disky – interní disk (CF karta, SSD, HDD) jádro nenašlo."$'\n\n'"$txt"
    fi
    txt+=$'\n\nCo s tím:\n'
    if (( ${#nodrv[@]} )); then
        txt+="- Řadič bez ovladače: ${nodrv[*]}. Jádro této Clonezilly ($(uname -m)) ho neumí."$'\n'
        txt+="  V BIOSu panelu zkus jiný režim řadiče (IDE / Compatible / Enhanced), po obnově vrať zpět."$'\n'
    fi
    if (( ${#raid[@]} )); then
        txt+="- Řadič v režimu RAID: ${raid[*]}. V BIOSu přepni na IDE (XP na AHCI nenabootuje)."$'\n'
    fi
    txt+="- Náhradní cesta: disk / CF kartu obnovit nebo zálohovat přes USB adaptér / čtečku."$'\n'
    txt+=$'\n'"Tento výpis je v logu; log se uloží na flashku do restore-logs/."
    warn "Řadič disků bez ovladače nebo chybí interní disk – podrobnosti v logu."
    printf '%s\n' "$txt" | ui_text "Disky: chybí ovladač"
    log_copy_flash
    return 0
}

# Tabulka disků s vyznačením chráněných
disk_table() {
    local d c why
    printf '%-8s %10s  %-16s %-28s %-16s %s\n' DISK VELIKOST TYP "VÝROBCE / MODEL" "SÉRIOVÉ Č." STAV
    for d in $(disk_all); do
        why=$(disk_protect_reason "$d") || why="volný"
        printf '%-8s %10s  %-16s %-28.28s %-16.16s %s\n' "$d" "$(human "${BLK[$d.SIZE]:-0}")" "$(disk_kind "$d")" \
            "$(disk_vendor_model "$d")" "${BLK[$d.SERIAL]:--}" "$why"
        for c in $(blk_children "$d"); do
            printf '   └ %-10s %8s  %-8s %-16.16s %s\n' "$c" "$(human "${BLK[$c.SIZE]:-0}")" \
                "${BLK[$c.FSTYPE]:--}" "${BLK[$c.LABEL]:--}" "${BLK[$c.MOUNTPOINT]:-}"
        done
    done
}

# Výběr cílového disku; výsledek v UI_REPLY. Chráněné disky nelze vybrat.
disk_select_target() {
    ui_theme red
    local title=${1:-"Cílový disk"} d why items=()
    disk_table | ui_text "Disky"
    for d in $(disk_all); do
        if why=$(disk_protect_reason "$d"); then
            items+=("$d" "$(disk_desc "$d" "$why")")
        else
            items+=("$d" "$(disk_desc "$d")")
        fi
    done
    (( ${#items[@]} )) || die "$E_GEN" "Nenalezen žádný disk."
    while true; do
        UI_DEFAULT=""
        for d in $(disk_all); do disk_protect_reason "$d" >/dev/null || { UI_DEFAULT=$d; break; }; done
        ui_menu "$title" "Vyber cílový disk (chráněné nelze použít):" "${items[@]}" || return 1
        d=$UI_REPLY
        if why=$(disk_protect_reason "$d"); then
            if [[ "$why" == připojeno:* ]]; then
                warn "Disk $d má připojené oddíly ($why)."
                if ui_yesno "Odpojit všechny oddíly disku $d?"; then
                    disk_umount_all "$d"
                    UI_REPLY=$d
                    return 0
                fi
            else
                warn "Disk $d nelze použít jako cíl: $why."
            fi
            continue
        fi
        UI_REPLY=$d
        return 0
    done
}

# Odpojí všechny oddíly disku (a vypne swap)
disk_umount_all() {
    local d=$1 c mp
    for c in $d $(blk_children "$d"); do
        mp=${BLK[$c.MOUNTPOINT]:-}
        [[ -z "$mp" ]] && continue
        if [[ "$mp" == "[SWAP]" ]]; then run swapoff "/dev/$c"; else run umount "/dev/$c"; fi
        BLK[$c.MOUNTPOINT]=""
    done
    (( SIMULATE || DRY_RUN )) || blk_load
}

# Po zápisu tabulky: znovu načíst oddíly a POČKAT, až existují (kap. 5.1/7)
# disk_rescan <disk> <čísla oddílů…>
disk_rescan() {
    local disk=$1 n p i maj min; shift
    if (( SIMULATE || DRY_RUN )); then
        run_try partprobe "/dev/$disk" || true
        run_try udevadm settle || true
        return 0
    fi
    sync
    partprobe "/dev/$disk" 2>/dev/null || blockdev --rereadpt "/dev/$disk" 2>/dev/null || true
    udevadm settle --timeout=15 2>/dev/null || true
    for n in "$@"; do
        p=$(part_name "$disk" "$n")
        for (( i = 0; i < 75; i++ )); do
            [[ -b "/dev/$p" ]] && break
            sleep 0.2
        done
        # prostředí bez udev: uzel vytvoříme podle sysfs
        if [[ ! -b "/dev/$p" && -r "/sys/class/block/$p/dev" ]]; then
            IFS=: read -r maj min <"/sys/class/block/$p/dev"
            mknod "/dev/$p" b "$maj" "$min"
            _log_file "uzel /dev/$p vytvořen ručně ($maj:$min)"
        fi
        [[ -b "/dev/$p" ]] || die "$E_GEN" "Oddíl /dev/$p se po zápisu tabulky neobjevil."
    done
    blk_load
    _log_file "Oddíly na /dev/$disk jsou k dispozici: $*"
}

# Souhrn disku pro potvrzení
disk_summary() {
    local d=$1
    printf 'Disk:      /dev/%s\nModel:     %s\nSériové č.: %s\nVelikost:  %s (%s B)\nPřipojení: %s\n' \
        "$d" "${BLK[$d.MODEL]:--}" "${BLK[$d.SERIAL]:--}" "$(human "${BLK[$d.SIZE]:-0}")" "${BLK[$d.SIZE]:-0}" "${BLK[$d.TRAN]:--}"
    local c
    for c in $(blk_children "$d"); do
        printf '  smaže se: %-10s %-8s %-16s %s\n' "$c" "${BLK[$c.FSTYPE]:--}" "${BLK[$c.LABEL]:--}" "$(human "${BLK[$c.SIZE]:-0}")"
    done
}

# =============================================================================
# SOURCE – disk s obrazy (kap. 5.0)
# =============================================================================
readonly PARTIMAG_MP="/home/partimag"   # kde je disk s obrazy připojený (jako v Clonezille)
readonly SRC_FS_OK="ext2 ext3 ext4 ntfs exfat vfat xfs btrfs"

# Oddíl připojený do /home/partimag (pokud je)
src_find_mounted() {
    local n
    for n in "${BLK_NAMES[@]}"; do
        if [[ "${BLK[$n.MOUNTPOINT]:-}" == "$PARTIMAG_MP" ]]; then echo "$n"; return 0; fi
    done
    return 0
}

# Kandidáti na disk s obrazy: oddíly s podporovaným FS mimo flashku
src_candidates() {
    local n
    for n in "${BLK_NAMES[@]}"; do
        [[ "${BLK[$n.TYPE]:-}" == part ]] || continue
        [[ -n "$LIVE_DISK" && "$(blk_parent "$n")" == "$LIVE_DISK" ]] && continue
        [[ " $SRC_FS_OK " == *" ${BLK[$n.FSTYPE]:-none} "* ]] || continue
        echo "$n"
    done
    return 0
}

# Připojí oddíl s obrazy do /home/partimag (ro|rw)
src_mount() {
    local part=$1 mode=${2:-ro} fs=${BLK[$1.FSTYPE]:-}
    if (( ALLOW_LOOP )) && [[ "$part" != loop* ]]; then
        die "$E_USER" "Testovací režim (--allow-loop): disk s obrazy musí být loop zařízení, ne /dev/$part."
    fi
    IMAGES_PART=$part
    IMAGES_DISK=$(blk_parent "$part")
    if (( SIMULATE )); then
        _show_cmd "mount -o $mode /dev/$part $PARTIMAG_MP"
        BLK[$part.MOUNTPOINT]=$PARTIMAG_MP
        src_mark_mounted
        return 0
    fi
    mkdir -p "$PARTIMAG_MP"
    local opts=$mode
    if [[ "$fs" == ntfs ]]; then
        if ! mount -t ntfs-3g -o "$opts" "/dev/$part" "$PARTIMAG_MP" 2>/tmp/restore-mount.err; then
            warn "NTFS na $part nejde připojit ($(head -1 /tmp/restore-mount.err)). Může být „dirty“ nebo Windows hibernované (Fast Startup)."
            if [[ "$mode" == rw ]] && ui_yesno "Spustit ntfsfix na /dev/$part (smaže hibernační soubor)?"; then
                ntfsfix -d "/dev/$part"
                mount -t ntfs-3g -o rw,remove_hiberfile "/dev/$part" "$PARTIMAG_MP"
            else
                info "Zkouším připojit jen pro čtení."
                mount -t ntfs-3g -o ro "/dev/$part" "$PARTIMAG_MP"
            fi
        fi
    else
        mount -o "$opts" "/dev/$part" "$PARTIMAG_MP"
    fi
    _log_file "Připojeno /dev/$part → $PARTIMAG_MP ($mode)"
    src_mark_mounted
    blk_load
}

# Značka "disk s obrazy jsme připojili my" – soubor, aby přežil i akci v subshellu
src_mark_mounted() { echo "$IMAGES_PART" >"$STATE_DIR/srcmount"; }

# Obnoví IMAGES_PART/IMAGES_DISK podle skutečného stavu (i po akci v subshellu)
src_refresh() {
    local p
    if [[ -n "${STATE_DIR:-}" && -s "$STATE_DIR/srcmount" ]]; then
        p=$(<"$STATE_DIR/srcmount")
        if (( SIMULATE )); then BLK[$p.MOUNTPOINT]=$PARTIMAG_MP; fi
    fi
    p=$(src_find_mounted)
    if [[ -n "$p" ]]; then IMAGES_PART=$p; IMAGES_DISK=$(blk_parent "$p"); fi
    return 0
}

# Odpojí disk s obrazy, pokud jsme ho připojili my (volá trap EXIT)
src_umount() {
    [[ -n "${STATE_DIR:-}" && -f "$STATE_DIR/srcmount" ]] || return 0
    if (( SIMULATE )); then
        _show_cmd "umount $PARTIMAG_MP"
    else
        sync
        umount "$PARTIMAG_MP" 2>/dev/null || warn "Nepodařilo se odpojit $PARTIMAG_MP"
    fi
    rm -f "$STATE_DIR/srcmount"
}

# Skutečný adresář s obrazy (v simulaci fixtures)
partimag_dir() {
    if (( SIMULATE )); then
        if [[ -n "$IMAGES_PART" && "${BLK[$IMAGES_PART.MOUNTPOINT]:-}" == "$PARTIMAG_MP" ]]; then
            echo "$SIM_DIR/disks/$IMAGES_PART"
        else
            echo "$SIM_DIR/nonexistent"
        fi
        return
    fi
    echo "$PARTIMAG_MP"
}

# Automatické hledání: oddíl dočasně ro do /tmp/scan/<oddíl>, hledá obrazy
src_scan() {
    local n dir found
    for n in $(src_candidates); do
        if (( SIMULATE )); then
            dir="$SIM_DIR/disks/$n"
            [[ -d "$dir" ]] || continue
            _show_cmd "mount -o ro /dev/$n /tmp/scan/$n"
            img_find "$dir" | sed "s|^$dir|$n: |"
            _show_cmd "umount /tmp/scan/$n"
            continue
        fi
        dir="/tmp/scan/$n"
        mkdir -p "$dir"
        if mount -o ro "/dev/$n" "$dir" 2>/dev/null; then
            TMP_MOUNTS+=("$dir")
            found=$(img_find "$dir" | sed "s|^$dir|$n: |")
            [[ -n "$found" ]] && echo "$found"
            umount "$dir" 2>/dev/null || true
            unset 'TMP_MOUNTS[-1]'
        fi
        rmdir "$dir" 2>/dev/null || true
    done
    return 0
}

# Interaktivní výběr disku s obrazy (kap. 5.0); mode ro|rw
src_select() {
    local mode=${1:-ro} cur n items=() title="Disk s obrazy" text="Vyber oddíl, na kterém jsou obrazy Clonezilly:"
    if [[ "$mode" == rw ]]; then
        ui_theme red
        title="Kam uložit zálohu" text="Vyber oddíl, kam se záloha uloží (složka se zálohou se na něm vytvoří):"
    else
        ui_theme green
    fi
    if [[ -n "$OPT_SOURCE_DEV" ]]; then
        n=${OPT_SOURCE_DEV#/dev/}
        [[ -n "${BLK[$n.TYPE]:-}" ]] || die "$E_USER" "Zařízení $OPT_SOURCE_DEV neexistuje."
        src_mount "$n" "$mode"
        return 0
    fi
    cur=$(src_find_mounted)
    if [[ -n "$cur" && " $SRC_EXCLUDE " == *" $cur "* ]]; then
        die "$E_USER" "Disk s obrazy (/dev/$cur) je zároveň mezi zálohovanými položkami – zálohu nelze uložit sama do sebe."
    fi
    if [[ -n "$cur" ]]; then
        IMAGES_PART=$cur
        IMAGES_DISK=$(blk_parent "$cur")
        if [[ -n "$(img_find "$(partimag_dir)")" ]]; then
            info "Disk s obrazy už je připojený: /dev/$cur → $PARTIMAG_MP"
            if [[ "$mode" == rw ]] && (( ! SIMULATE && ! DRY_RUN )) && findmnt -no OPTIONS "$PARTIMAG_MP" 2>/dev/null | grep -qw ro; then
                mount -o remount,rw "$PARTIMAG_MP" || die "$E_GEN" "Disk s obrazy /dev/$cur nejde přepnout pro zápis."
            fi
            return 0
        fi
        warn "$PARTIMAG_MP je připojený (/dev/$cur), ale neobsahuje žádné obrazy."
    fi
    while true; do
        items=()
        for n in $(src_candidates); do
            [[ " $SRC_EXCLUDE " == *" $n "* ]] && continue
            # pro zápis ne oddíl připojený jinde (např. disk se skriptem)
            [[ "$mode" == rw && -n "${BLK[$n.MOUNTPOINT]:-}" && "${BLK[$n.MOUNTPOINT]}" != "$PARTIMAG_MP" ]] && continue
            items+=("$n" "$n  $(human "${BLK[$n.SIZE]:-0}") ${BLK[$n.FSTYPE]:-} ${BLK[$n.LABEL]:-} (${BLK[$(blk_parent "$n").MODEL]:-})")
        done
        [[ "$mode" == rw ]] || items+=(scan "Automaticky prohledat všechny oddíly (read-only)")
        (( ${#items[@]} )) || { ui_msg "Není kam uložit zálohu – žádný jiný oddíl se souborovým systémem."; return 1; }
        ui_menu "$title" "$text" "${items[@]}" || return 1
        if [[ "$UI_REPLY" == scan ]]; then
            local res
            res=$(src_scan)
            if [[ -z "$res" ]]; then
                ui_msg "Na žádném oddílu nebyl nalezen obraz Clonezilly."
            else
                printf '%s\n' "$res" | ui_text "Nalezené obrazy"
            fi
            continue
        fi
        src_mount "$UI_REPLY" "$mode"
        return 0
    done
}

# =============================================================================
# IMAGE – formát obrazu Clonezilly (kap. 3)
# =============================================================================
readonly KNOWN_COMP="gz zst xz bz2 lz4 lzo lzip uncomp"

# Najde adresáře obrazů (obsahují parts + disk), max. hloubka 3; koš a systémové složky Windows vynechá
img_find() {
    local base=$1 f d
    # shellcheck disable=SC2016  # $RECYCLE.BIN je doslovný název složky (koš Windows)
    local trash='$RECYCLE.BIN'
    [[ -d "$base" ]] || return 0
    while IFS= read -r f; do
        d=${f%/parts}
        if [[ -f "$d/disk" ]]; then echo "$d"; fi
    done < <(find "$base" -maxdepth 3 \( -iname "$trash" -o -iname 'RECYCLER' -o -iname 'System Volume Information' -o -name '.Trash*' \) -prune \
                -o -type f -name parts -print 2>/dev/null | sort)
    return 0
}

# Datové soubory oddílu (seřazené .aa .ab …)
img_datafiles() {
    local dir=$1 part=$2 f
    for f in "$dir/$part".*-img*; do
        [[ "$f" == *.sha* || "$f" == *.md5* || "$f" == *.b2* ]] && continue
        echo "$f"
    done | sort
}

# Rozbor názvu datového souboru → "fs imgtype comp"
img_parse_name() {
    local name=${1##*/} part=$2 rest fs="" itype="" comp=none seg segs=()
    rest=${name#"$part".}
    case "$rest" in
        ntfs-img*)    fs=ntfs; itype=ntfs; rest=${rest#ntfs-img} ;;
        dd-img*)      fs=""; itype="dd"; rest=${rest#dd-img} ;;
        *-ptcl-img*)  fs=${rest%%-ptcl-img*}; itype=ptcl; rest=${rest#*-ptcl-img} ;;
        *-dd-img*)    fs=${rest%%-dd-img*}; itype="dd"; rest=${rest#*-dd-img} ;;
        *)            return 1 ;;
    esac
    IFS=. read -ra segs <<<"${rest#.}"
    for seg in "${segs[@]}"; do
        [[ " $KNOWN_COMP " == *" $seg "* ]] && comp=$seg
    done
    [[ "$comp" == uncomp ]] && comp=none
    echo "${fs:--} $itype $comp"
}

# Dekompresor (paralelní varianta, pokud existuje)
img_decompressor() {
    case "$1" in
        gz)   if sys_have pigz; then echo "pigz -dc"; else echo "gzip -dc"; fi ;;
        zst)  if sys_have pzstd; then echo "pzstd -dc"; else echo "zstd -dc"; fi ;;
        xz)   if sys_have pixz; then echo "pixz -d"; else echo "xz -dc"; fi ;;
        bz2)  if sys_have pbzip2; then echo "pbzip2 -dc"; else echo "bzip2 -dc"; fi ;;
        lz4)  echo "lz4 -dc" ;;
        lzo)  echo "lzop -dc" ;;
        lzip) echo "lzip -dc" ;;
        *)    echo "cat" ;;
    esac
}

# Shellová roura, která vypíše dekomprimovaná data oddílu na stdout
img_stream_cmd() {
    local dir=$1 part=$2 files=() parsed comp
    mapfile -t files < <(img_datafiles "$dir" "$part")
    (( ${#files[@]} )) || return 1
    parsed=$(img_parse_name "${files[0]}" "$part") || return 1
    comp=${parsed##* }
    if [[ "$comp" == none ]]; then
        printf 'cat %s' "$(_cmd_str "${files[@]}")"
    else
        printf 'cat %s | %s' "$(_cmd_str "${files[@]}")" "$(img_decompressor "$comp")"
    fi
}

# Hodnota z blkid.list: img_blkid <dir> <part> <KLÍČ>
img_blkid() {
    local f="$1/blkid.list"
    [[ -r "$f" ]] || return 0
    awk -v d="/dev/$2:" -v k="$3" '$1==d {
        if (match($0, "[ ]" k "=\"[^\"]*\"")) { v=substr($0, RSTART+length(k)+3, RLENGTH-length(k)-4); print v } }' "$f"
}

# Celková velikost dat obrazu v bajtech
img_size() {
    local s
    if (( SIMULATE )); then
        # fixtures mají prázdné datové soubory → odhad: polovina obsazeného místa (komprese)
        awk '{ s += $3 } END { printf "%.0f\n", s / 2 }' "$1/sim-partclone-info.txt" 2>/dev/null || echo 0
        return 0
    fi
    s=$(du -sb "$1" 2>/dev/null | cut -f1) || s=0
    echo "${s:-0}"
}

# =============================================================================
# LAYOUT – datový model rozložení disku (asociativní pole, klíče "n.pole")
#
#   [label]=gpt|dos [disk_id]= [sector]=512 [disk_sectors]= [first_lba]= [last_lba]=
#   [mode]=generic|legacy [parts]="1 2 …" [src_disk]=sda [dir]=<adresář obrazu>
#   [n.start] [n.size] [n.type] [n.uuid] [n.name] [n.attrs] [n.boot]   (z sfdisk)
#   [n.pname] [n.fs] [n.fsuuid] [n.label] [n.img] [n.imgtype] [n.comp] (z obrazu)
#   [n.fssize] [n.used] [n.min] (bajty)  [n.role] [n.class]=grow|fixed
# =============================================================================
# shellcheck disable=SC2034  # NEW se plní přes nameref (layout_compute)
declare -A SRC=() NEW=()

# Načte výstup sfdisk --dump ze stdin do pole
layout_parse_sfdisk() {
    local -n _L=$1
    local line dev rest n k v
    local re_kv='^[[:space:]]*([a-z-]+)=("([^"]*)"|([^,]*))[[:space:]]*,?(.*)$'
    local re_flag='^[[:space:]]*([a-z]+)[[:space:]]*,?(.*)$'
    _L[parts]="" _L[sector]=512 _L[label]="" _L[disk_id]=""
    while IFS= read -r line; do
        case "$line" in
            label:*)       _L[label]=${line#*: } ;;
            label-id:*)    _L[disk_id]=${line#*: } ;;
            first-lba:*)   _L[first_lba]=${line#*: } ;;
            last-lba:*)    _L[last_lba]=${line#*: } ;;
            sector-size:*) _L[sector]=${line#*: } ;;
            /dev/*:*)
                dev=${line%% :*}
                rest=${line#*: }
                n=$(part_num "$dev") || continue
                _L[parts]+="${_L[parts]:+ }$n"
                _L[$n.boot]=0 _L[$n.name]="" _L[$n.uuid]="" _L[$n.attrs]=""
                while [[ -n "${rest// /}" ]]; do
                    if [[ "$rest" =~ $re_kv ]]; then
                        k=${BASH_REMATCH[1]} v=${BASH_REMATCH[3]}${BASH_REMATCH[4]}
                        rest=${BASH_REMATCH[5]}
                        v=${v%% }
                        case "$k" in
                            start|size|type|uuid) _L[$n.$k]=${v// /} ;;
                            name|attrs)            _L[$n.$k]=$v ;;
                        esac
                    elif [[ "$rest" =~ $re_flag ]]; then
                        [[ "${BASH_REMATCH[1]}" == bootable ]] && _L[$n.boot]=1
                        rest=${BASH_REMATCH[2]}
                    else
                        break
                    fi
                done ;;
        esac
    done
    return 0
}

# Načte adresář obrazu do pole (kap. 3)
img_load() {
    local dir=$1
    local -n _I=$2
    local disk n pname f parsed fs type comp info
    [[ -f "$dir/disk" && -f "$dir/parts" ]] || die "$E_USER" "$dir není obraz Clonezilly (chybí disk/parts)."
    disk=${3:-}
    [[ -n "$disk" ]] || read -r disk _ <"$dir/disk"
    [[ -r "$dir/$disk-pt.sf" ]] || die "$E_GEN" "Obraz $dir nemá $disk-pt.sf (tabulku oddílů)."
    _I=()
    layout_parse_sfdisk "$2" <"$dir/$disk-pt.sf"
    _I[src_disk]=$disk
    _I[dir]=$dir
    # Velikost původního disku: *-pt.parted ("Disk /dev/sda: 268435456s"), jinak odhad
    local ds=""
    if [[ -r "$dir/$disk-pt.parted" ]]; then
        ds=$(sed -nE 's|^Disk /dev/[^:]+: ([0-9]+)s.*|\1|p' "$dir/$disk-pt.parted" | head -1)
    fi
    if [[ -z "$ds" ]]; then
        if [[ -n "${_I[last_lba]:-}" ]]; then
            ds=$(( _I[last_lba] + 34 ))
        else
            ds=0
            for n in ${_I[parts]}; do (( _I[$n.start] + _I[$n.size] > ds )) && ds=$(( _I[$n.start] + _I[$n.size] )); done
        fi
    fi
    _I[disk_sectors]=$ds
    for n in ${_I[parts]}; do
        pname=$(part_name "$disk" "$n")
        _I[$n.pname]=$pname
        _I[$n.dir]=$dir
        _I[$n.fs]="" _I[$n.img]="" _I[$n.imgtype]="" _I[$n.comp]="" _I[$n.used]="" _I[$n.fssize]=""
        mapfile -t files < <(img_datafiles "$dir" "$pname")
        if (( ${#files[@]} )) && parsed=$(img_parse_name "${files[0]}" "$pname"); then
            read -r fs type comp <<<"$parsed"
            [[ "$fs" == - ]] && fs=""
            _I[$n.fs]=$fs _I[$n.imgtype]=$type _I[$n.comp]=$comp
            _I[$n.img]=$(printf '%s\n' "${files[@]##*/}" | tr '\n' ' ')
        fi
        [[ -z "${_I[$n.fs]}" ]] && _I[$n.fs]=$(img_blkid "$dir" "$pname" TYPE)
        _I[$n.fatbits]=""
        if [[ "${_I[$n.fs]}" == @(vfat|fat*) ]]; then
            if [[ "${_I[$n.type]^^}" == @(1|11) ]]; then
                _I[$n.fatbits]=12
            elif [[ "$(img_blkid "$dir" "$pname" SEC_TYPE)" == msdos || "${_I[$n.fs]}" == fat16 || "${_I[$n.type]^^}" == @(4|6|E|14|16|1E) ]]; then
                _I[$n.fatbits]=16
            else
                _I[$n.fatbits]=32
            fi
        fi
        _I[$n.fsuuid]=$(img_blkid "$dir" "$pname" UUID)
        _I[$n.label]=$(img_blkid "$dir" "$pname" LABEL)
        f="$dir/swappt-$pname.info"
        if [[ -r "$f" ]]; then
            _I[$n.fs]=swap
            _I[$n.fsuuid]=$(sed -nE 's/.*UUID="([^"]*)".*/\1/p' "$f")
            _I[$n.label]=$(sed -nE 's/.*LABEL="([^"]*)".*/\1/p' "$f")
        fi
        info=$(sys_partclone_info "$dir" "$pname" "${_I[$n.imgtype]}")
        if [[ -n "$info" ]]; then _I[$n.fssize]=${info% *}; _I[$n.used]=${info#* }; fi
    done
    layout_classify "$2"
    layout_detect_legacy "$2"
    layout_min "$2"
}

# Ověření kompletnosti obrazu pro jeden disk (kap. 4.6); vypíše problémy, 1 = neúplný
img_verify() {
    local -n _V=$1
    local n p bad=0
    for p in $(img_disk_parts "${_V[dir]}" "${_V[src_disk]}"); do
        n=$(part_num "$p")
        if [[ " ${_V[parts]} " != *" $n "* ]]; then err "Oddíl $p z 'parts' chybí v tabulce oddílů disku ${_V[src_disk]}."; bad=1; continue; fi
        if [[ -z "${_V[$n.img]}" && "${_V[$n.fs]}" != swap && -n "${_V[$n.fs]}" ]]; then
            err "Oddíl $p (${_V[$n.fs]}) nemá datové soubory."
            bad=1
        fi
    done
    # oddíl v tabulce disku, který se do obrazu nezálohoval (obraz jen vybraných oddílů)
    for n in ${_V[parts]}; do
        [[ "${_V[$n.role]}" == extended || -n "${_V[$n.img]}" ]] && continue
        [[ -n "${_V[$n.fs]}" && "${_V[$n.fs]}" != swap ]] || continue
        p=${_V[$n.pname]}
        if [[ " $(img_disk_parts "${_V[dir]}" "${_V[src_disk]}") " != *" $p "* ]]; then
            err "Oddíl $p (${_V[$n.fs]}) v obrazu není – obraz obsahuje jen vybrané oddíly disku ${_V[src_disk]}, jako celý disk se obnovit nedá (použij obnovu vybraných oddílů)."
            bad=1
        fi
    done
    return "$bad"
}

# Role a třída oddílů (pevné × rostoucí, kap. 5.2)
layout_classify() {
    local -n _C=$1
    local n t role fs size ss=${_C[sector]} ndata=0
    for n in ${_C[parts]}; do
        t=${_C[$n.type]^^} fs=${_C[$n.fs]} size=$(( _C[$n.size] * ss ))
        case "$t" in
            C12A7328-F81F-11D2-BA4B-00A0C93EC93B|EF) role=efi ;;
            E3C9E316-0B5C-4DB8-817D-F92DF00215AE)    role=msr ;;
            DE94BBA4-06D1-4D40-A16A-BFD50179D6AC|27) role=recovery ;;
            21686148-6449-6E6F-744E-656564454649)    role=biosboot ;;
            0657FD6D-A4AB-43C4-84E5-0933C84B4F4F|82) role=swap ;;
            5|F|85)                                  role=extended ;;
            *)                                       role=data ;;
        esac
        [[ "$fs" == swap ]] && role=swap
        if [[ "$role" == data && -z "$fs" ]]; then role=nofs; fi
        if [[ "$role" == data && "$fs" == ext* ]] && (( size <= 2 * GiB )); then role=boot; fi
        if [[ "$role" == data && "$fs" == ntfs && "${_C[$n.label]}" == "System Reserved" ]]; then role=sysres; fi
        if [[ "$role" == data && "$fs" == ntfs ]] && (( size <= 1 * GiB )) && [[ "${_C[$n.name]}" == *[Rr]ecovery* ]]; then role=recovery; fi
        _C[$n.role]=$role
        [[ "$role" == data ]] && ndata=$(( ndata + 1 ))
    done
    for n in ${_C[parts]}; do
        role=${_C[$n.role]}
        # /boot a System Reserved jsou pevné jen tehdy, když existuje jiný datový oddíl
        if [[ "$role" == @(boot|sysres) ]] && (( ndata == 0 )); then _C[$n.role]=data; role=data; fi
        if [[ "$role" == data ]]; then _C[$n.class]=grow; else _C[$n.class]=fixed; fi
    done
}

# Detekce legacy / Beckhoff (kap. 5.7)
layout_detect_legacy() {
    local -n _D=$1
    local n unaligned=0 bytes=$(( _D[disk_sectors] * _D[sector] ))
    _D[mode]=generic
    [[ "${_D[label]}" == dos ]] || return 0
    for n in ${_D[parts]}; do
        (( _D[$n.start] % 2048 )) && unaligned=1
    done
    (( unaligned )) && _D[mode]=legacy
    (( bytes <= 34 * 1000 * 1000 * 1000 )) && SMALL_MEDIA=1
    return 0
}

# Minimální velikost oddílu = obsazeno + rezerva (10 %, min. 1 GiB; u malých médií min. 16 MiB)
layout_min() {
    local -n _M=$1
    local n used res minres=$GiB orig
    (( SMALL_MEDIA )) && minres=$(( 16 * MiB ))
    for n in ${_M[parts]}; do
        orig=$(( _M[$n.size] * _M[sector] ))
        used=${_M[$n.used]:-}
        if [[ -z "$used" ]]; then
            # bez informace o obsazení (ntfsclone/dd/bez FS) nelze zmenšit
            if [[ -n "${_M[$n.img]}" ]]; then _M[$n.min]=$orig; else _M[$n.min]=0; fi
            continue
        fi
        res=$(( used / 10 ))
        (( res < minres )) && res=$minres
        _M[$n.min]=$(( used + res ))
        (( _M[$n.min] > orig )) && _M[$n.min]=$orig
    done
    return 0
}

# Pořadí oddílů podle začátku (bez rozšířeného kontejneru)
layout_order() {
    local -n _O=$1
    local n
    for n in ${_O[parts]}; do
        [[ "${_O[$n.role]}" == extended ]] && continue
        echo "${_O[$n.start]} $n"
    done | sort -n | awk '{print $2}'
}

# Výpočet nového rozložení: layout_compute SRC NEW <cílový_disk> <last|proportional|fixed|manual>
# Vrací 0 = OK, 4 = nevejde se (důvod vypíše)
layout_compute() {
    local -n _S=$1 _N=$2
    local tgt=$3 mode=$4 k n
    _N=()
    for k in "${!_S[@]}"; do _N["$k"]=${_S["$k"]}; done  # kopie zdroje
    local ss=${BLK[$tgt.LOG_SEC]:-512} total end
    if (( ss != _S[sector] )); then
        warn "Velikost sektoru se liší (zdroj ${_S[sector]} B, cíl $ss B) – přepočítávám pozice."
        [[ "${_S[mode]}" == legacy ]] && warn "Legacy systém na disku s jiným sektorem nejspíš nenabootuje."
        for n in ${_S[parts]}; do
            _N[$n.start]=$(align_up $(( _S[$n.start] * _S[sector] / ss )) "$ss")
            _N[$n.size]=$(( _S[$n.size] * _S[sector] / ss ))
        done
    fi
    _N[sector]=$ss
    total=$(( BLK[$tgt.SIZE] / ss ))
    if [[ "${_S[label]}" != gpt ]] && (( total > 4294967296 )); then
        warn "Tabulka MBR adresuje nejvýš $(human $(( 4294967296 * ss ))) – zbytek disku $tgt ($(human $(( (total - 4294967296) * ss )))) zůstane nevyužitý. Celý disk využije jen GPT (menu 8 → 3, pro Windows XP / Beckhoff nevhodné)."
        total=4294967296
    fi
    _N[disk_sectors]=$total
    if [[ "${_S[label]}" == gpt ]]; then end=$(( total - 34 )); _N[last_lba]=$end; else end=$(( total - 1 )); fi
    _N[tgt]=$tgt

    local -a order
    mapfile -t order < <(layout_order "$2")
    # rostoucí oddíl pro režim A: největší datový (při shodě poslední)
    local g="" best=0
    for n in "${order[@]}"; do
        if [[ "${_N[$n.class]}" == grow ]] && (( _N[$n.size] >= best )); then g=$n; best=${_N[$n.size]}; fi
    done
    # legacy: proporcionální režim jen když by se neposunul začátek žádného původního oddílu
    if [[ "$mode" == proportional && "${_S[mode]}" == legacy ]]; then
        local orig_cnt=0
        for n in "${order[@]}"; do (( ${_N[$n.appended]:-0} )) || orig_cnt=$(( orig_cnt + 1 )); done
        if (( orig_cnt > 1 )); then
            info "Legacy režim: začátky oddílů se nemění → místo proporcionálního použiji režim A."
            mode=last
        fi
    fi
    case "$mode" in
        fixed|"") : ;;
        last|manual)
            [[ -z "$g" ]] && { info "Žádný rostoucí oddíl – rozložení zůstane 1:1."; mode=fixed; }
            ;;
    esac
    if [[ "$mode" == @(last|manual) ]]; then
        local -a trailing=()
        local cursor=$(( end + 1 )) i
        for n in "${order[@]}"; do (( _N[$n.start] > _N[$g.start] )) && trailing+=("$n"); done
        # oddíly za rostoucím: v legacy zůstává začátek původních oddílů, přidané (sloučené) se posunou na konec
        for (( i=${#trailing[@]}-1; i>=0; i-- )); do
            n=${trailing[i]}
            if [[ "${_S[mode]}" == legacy ]] && (( ! ${_N[$n.appended]:-0} )); then
                cursor=${_N[$n.start]}
            else
                _N[$n.start]=$(align_down $(( cursor - _N[$n.size] )) "$ss")
                cursor=${_N[$n.start]}
            fi
        done
        _N[$g.size]=$(( cursor - _N[$g.start] ))
    elif [[ "$mode" == proportional ]]; then
        local src_total=${_S[disk_sectors]} prev_end="" last_grow=""
        for n in "${order[@]}"; do
            if [[ "${_N[$n.class]}" == grow ]]; then
                _N[$n.size]=$(align_down "$(awk -v s="${_N[$n.size]}" -v t="$total" -v o="$src_total" 'BEGIN{printf "%.0f", s*t/o}')" "$ss")
                last_grow=$n
            fi
            [[ -n "$prev_end" ]] && _N[$n.start]=$(align_up $(( prev_end + 1 )) "$ss")
            prev_end=$(( _N[$n.start] + _N[$n.size] - 1 ))
        done
        # rozdíl (zaokrouhlení, pevné oddíly) vyrovná poslední rostoucí oddíl – přidá i ubere;
        # oddíly za ním se posunou o stejný kus
        if [[ -n "$last_grow" ]] && (( prev_end != end )); then
            local slack
            if (( prev_end < end )); then
                slack=$(align_down $(( end - prev_end )) "$ss")
            else
                slack=$(( -$(align_up $(( prev_end - end )) "$ss") ))
            fi
            _N[$last_grow.size]=$(( _N[$last_grow.size] + slack ))
            for n in "${order[@]}"; do
                if (( _N[$n.start] > _N[$last_grow.start] )); then _N[$n.start]=$(( _N[$n.start] + slack )); fi
            done
            # poslední oddíl bez dalších za ním dosáhne přesně na konec disku
            if (( _N[$last_grow.start] + _N[$last_grow.size] - 1 < end )); then
                local after=0
                for n in "${order[@]}"; do (( _N[$n.start] > _N[$last_grow.start] )) && after=1; done
                (( after )) || _N[$last_grow.size]=$(( end - _N[$last_grow.start] + 1 ))
            fi
        fi
    fi
    # strop FAT16 (2 GiB) a FAT12: oddíl nesmí být větší, než FS unese (zbytek disku zůstane volný)
    local cap
    for n in "${order[@]}"; do
        case "${_N[$n.fatbits]:-}" in
            16) cap=$(( 2047 * MiB )) ;;
            12) cap=$(( 32 * MiB )) ;;
            *)  continue ;;
        esac
        (( cap < _S[$n.size] * _S[sector] )) && cap=$(( _S[$n.size] * _S[sector] ))
        if (( _N[$n.size] * ss > cap )); then
            _N[$n.size]=$(( cap / ss ))
            warn "Oddíl ${_N[$n.pname]} (FAT${_N[$n.fatbits]}) se zvětší jen na $(human "$cap") – víc FAT${_N[$n.fatbits]} neunese; zbytek místa zůstane nevyužitý."
        fi
    done
    # rozšířený oddíl (MBR) obalí všechny logické
    for n in ${_N[parts]}; do
        if [[ "${_N[$n.role]}" == extended ]]; then
            local maxend=0 m
            for m in ${_N[parts]}; do
                (( m >= 5 )) && (( _N[$m.start] + _N[$m.size] > maxend )) && maxend=$(( _N[$m.start] + _N[$m.size] ))
            done
            (( maxend )) && _N[$n.size]=$(( maxend - _N[$n.start] ))
        fi
    done
    layout_check "$1" "$2"
}

# Kontrola výsledku: vejde se na disk, každý oddíl ≥ minimum (kap. 5.2)
layout_check() {
    local -n _S=$1 _N=$2
    local n ss=${_N[sector]} end bad=0 lack
    if [[ "${_N[label]}" == gpt ]]; then end=${_N[last_lba]}; else end=$(( _N[disk_sectors] - 1 )); fi
    for n in ${_N[parts]}; do
        _N[$n.shrink]=0
        if (( _N[$n.start] + _N[$n.size] - 1 > end )); then
            err "Oddíl ${_N[$n.pname]} se nevejde na disk (končí za koncem disku o $(human $(( (_N[$n.start] + _N[$n.size] - 1 - end) * ss ))))."
            bad=1
        fi
        if (( _N[$n.size] <= 0 )); then
            err "Na oddíl ${_N[$n.pname]} nezbývá žádné místo."
            bad=1
            continue
        fi
        if (( _N[$n.size] * ss < _S[$n.size] * _S[sector] )) && [[ -n "${_N[$n.img]}" ]]; then
            _N[$n.shrink]=1
            lack=$(( ${_N[$n.min]:-0} - _N[$n.size] * ss ))
            if (( lack > 0 )); then
                err "Oddíl ${_N[$n.pname]} (${_N[$n.fs]}): potřeba aspoň $(human "${_N[$n.min]}"), k dispozici $(human $(( _N[$n.size] * ss ))) – chybí $(human "$lack")."
                bad=1
            fi
            [[ "${_N[$n.fs]}" == xfs ]] && warn "XFS nelze zmenšit – oddíl ${_N[$n.pname]} půjde jen přes kopii souborů (kap. 5.4/2)."
        fi
    done
    (( bad )) && return "$E_SPACE"
    return 0
}

# Tabulka původní → nová velikost (vejde se na 100 sloupců konzole)
layout_table() {
    local -n _S=$1 _N=$2
    local n tgt=${_N[tgt]:-} chg o s lab
    printf '%-2s %-10s %-10s %-5s %-10s %10s %10s %10s  %s\n' \
        "#" ZDROJ CÍL FS LABEL PŮVODNÍ NOVÁ OBSAZENO ZMĚNA
    for n in ${_S[parts]}; do
        o=$(( _S[$n.size] * _S[sector] ))
        s=$(( _N[$n.size] * _N[sector] ))
        if (( s > o )); then chg="zvětšit +$(human $(( s - o )))"
        elif (( s < o )); then chg="ZMENŠIT -$(human $(( o - s )))"
        else chg="beze změny"; fi
        (( ${_S[$n.origstart]:-${_S[$n.start]}} * _S[sector] != _N[$n.start] * _N[sector] )) && chg+=", přesun"
        lab=${_S[$n.label]:-}
        [[ -z "$lab" && "${_S[$n.role]}" != data ]] && lab=${_S[$n.role]}
        printf '%-2s %-10s %-10s %-5s %-10.10s %10s %10s %10s  %s\n' "$n" "${_S[$n.pname]}" \
            "$([[ -n "$tgt" ]] && part_name "$tgt" "$n")" "${_S[$n.fs]:--}" "${lab:--}" \
            "$(human "$o")" "$(human "$s")" "$([[ -n "${_S[$n.used]}" ]] && human "${_S[$n.used]}" || echo '?')" "$chg"
    done
    printf 'Disk: %s → %s, tabulka %s, režim: %s\n' "$(human $(( _S[disk_sectors] * _S[sector] )))" \
        "$(human $(( _N[disk_sectors] * _N[sector] )))" "${_S[label]}" \
        "$([[ "${_S[mode]}" == legacy ]] && echo 'legacy (Beckhoff)' || echo 'obecný')"
    layout_bar "$2"
}

# Textový pruh disku [EFI|████ systém ████|░░ volné ░░|Rec]
layout_bar() {
    local -n _B=$1
    local W=70 total=${_B[disk_sectors]} pos=0 n i txt big=0 sum=0 out="[" l r fl fr t
    local -a order sw=() sc=() st=()
    mapfile -t order < <(layout_order "$1")
    # 1) segmenty: šířka úměrná velikosti, ale aspoň tak, aby byl čitelný popisek
    _seg_add() {  # <sektory> <znak> <text>
        local w=$(( $1 * W / total )) min=$(( ${#3} + 2 ))
        (( min > 7 )) && min=7
        (( w < min )) && w=$min
        sw+=("$w"); sc+=("$2"); st+=("$3")
    }
    for n in "${order[@]}"; do
        if (( (_B[$n.start] - pos) * 100 / total >= 1 )); then _seg_add $(( _B[$n.start] - pos )) "░" "volné"; fi
        txt=${_B[$n.label]:-${_B[$n.fs]:-${_B[$n.role]}}}
        case "${_B[$n.role]}" in efi) txt=EFI ;; msr) txt=MSR ;; recovery) txt=Rec ;; sysres) txt=SR ;; esac
        _seg_add "${_B[$n.size]}" "█" "$n:$txt"
        pos=$(( _B[$n.start] + _B[$n.size] ))
    done
    if (( (total - pos) * 100 / total >= 1 )); then _seg_add $(( total - pos )) "░" "volné"; fi
    # 2) přebytek šířky ubere největší segment
    for i in "${!sw[@]}"; do
        sum=$(( sum + sw[i] ))
        (( sw[i] > sw[big] )) && big=$i
    done
    (( sum > W && sw[big] - (sum - W) >= 7 )) && sw[big]=$(( sw[big] - (sum - W) ))
    # 3) vykreslení
    for i in "${!sw[@]}"; do
        t=${st[i]}
        if (( ${#t} + 2 <= sw[i] )); then
            l=$(( (sw[i] - ${#t} - 2) / 2 )); r=$(( sw[i] - ${#t} - 2 - l ))
            printf -v fl '%*s' "$l" ''
            printf -v fr '%*s' "$r" ''
            out+="${fl// /${sc[i]}} $t ${fr// /${sc[i]}}|"
        else
            out+="${t:0:sw[i]}|"
        fi
    done
    printf '%s\n' "${out%|}]"
}

# Sestaví vstup pro sfdisk z pole NEW
layout_to_sfdisk() {
    local -n _T=$1
    local tgt=${_T[tgt]} n line
    echo "label: ${_T[label]}"
    if [[ "${_T[label]}" == dos || "$OPT_NEW_GUID" == 0 ]]; then
        [[ -n "${_T[disk_id]}" ]] && echo "label-id: ${_T[disk_id]}"
    fi
    echo "device: /dev/$tgt"
    echo "unit: sectors"
    # standardních 128 položek GPT: bez toho sfdisk při first-lba 2048 natáhne tabulku až k 2048. sektoru
    # a záložní GPT na konci disku pak přesáhne do posledního oddílu
    [[ "${_T[label]}" == gpt ]] && echo "table-length: 128"
    [[ "${_T[label]}" == gpt && -n "${_T[first_lba]:-}" ]] && echo "first-lba: ${_T[first_lba]}"
    [[ "${_T[label]}" == gpt ]] && echo "last-lba: ${_T[last_lba]}"
    echo "sector-size: ${_T[sector]}"
    echo
    for n in ${_T[parts]}; do
        line="/dev/$(part_name "$tgt" "$n") : start=${_T[$n.start]}, size=${_T[$n.size]}, type=${_T[$n.type]}"
        [[ -n "${_T[$n.uuid]}" ]] && line+=", uuid=${_T[$n.uuid]}"
        [[ -n "${_T[$n.name]}" ]] && line+=", name=\"${_T[$n.name]}\""
        [[ -n "${_T[$n.attrs]}" ]] && line+=", attrs=\"${_T[$n.attrs]}\""
        (( _T[$n.boot] )) && line+=", bootable"
        echo "$line"
    done
}

# =============================================================================
# VÝBĚR A INFORMACE O OBRAZU
# =============================================================================
IMG_DIR=""

# Krátký popis obrazu na jeden řádek
img_oneline() {
    local d=$1 disks parts date
    disks=$(tr '\n' ' ' <"$d/disk"); disks=${disks% }
    parts=$(tr '\n' ' ' <"$d/parts"); parts=${parts% }
    date=$(sed -nE 's/.*(20[0-9]{2}-[0-9]{2}-[0-9]{2}[ _][0-9:]{4,8}).*/\1/p' "$d"/Info-*.txt 2>/dev/null | head -1)
    [[ -z "$date" ]] && date=$(date -r "$d/parts" '+%F %H:%M' 2>/dev/null || echo "?")
    if [[ "$disks" == *" "* ]]; then
        printf '%s | %d disky: %s | %s' "$date" "$(wc -w <<<"$disks")" "$disks" "$parts"
    else
        printf '%s | disk %s | %s' "$date" "$disks" "$parts"
    fi
}

# Přeloží zadání obrazu (cesta nebo název pod partimag) na adresář; výsledek v IMG_RES
img_resolve() {
    local spec=$1
    if [[ -d "$spec" ]]; then IMG_RES=$spec
    elif [[ -d "$(partimag_dir)/$spec" ]]; then IMG_RES="$(partimag_dir)/$spec"
    else die "$E_USER" "Obraz $spec nenalezen."; fi
    [[ -n "$LIVE_MEDIUM" && "$IMG_RES" == "$LIVE_MEDIUM"* ]] && die "$E_USER" "Obraz nesmí ležet na flashce s Clonezillou."
    return 0
}

# Výběr obrazu; výsledek v IMG_DIR (a IMG_DIRS). S argumentem "multi" lze vybrat i několik obrazů najednou
# (--image A,B,… nebo položka "Více záloh najednou").
img_select() {
    ui_theme green
    local multi=${1:-} base list=() d items=() spec t
    local -a specs=()
    IMG_DIRS=()
    if [[ -n "$OPT_IMAGE" ]]; then
        if [[ -n "$multi" ]]; then IFS=, read -ra specs <<<"$OPT_IMAGE"; else specs=("$OPT_IMAGE"); fi
        for spec in "${specs[@]}"; do img_resolve "$spec"; IMG_DIRS+=("$IMG_RES"); done
        IMG_DIR=${IMG_DIRS[0]}
        return 0
    fi
    base=$(partimag_dir)
    mapfile -t list < <(img_find "$base")
    if (( ${#list[@]} == 0 )); then
        ui_msg "V $PARTIMAG_MP (/dev/${IMAGES_PART:-?}) nebyl nalezen žádný obraz Clonezilly (adresář s 'parts' a 'disk', hloubka max. 3)."
        if ui_input "Zadej ručně cestu k obrazu (q = zpět)" ""; then
            [[ -n "$UI_REPLY" && -f "$UI_REPLY/parts" ]] && { IMG_DIR=$UI_REPLY; IMG_DIRS=("$IMG_DIR"); return 0; }
        fi
        return 1
    fi
    for d in "${list[@]}"; do items+=("${d#"$base"/}" "${d#"$base"/}  ($(img_oneline "$d"))"); done
    if [[ -n "$multi" ]] && (( ${#list[@]} > 1 )); then
        items+=("@multi" "Více záloh najednou (sloučit na jeden disk / obnovit na více disků)")
    fi
    ui_menu "Výběr obrazu" "Obrazy na /dev/${IMAGES_PART:-?}:" "${items[@]}" || return 1
    if [[ "$UI_REPLY" == @multi ]]; then
        items=()
        for d in "${list[@]}"; do items+=("${d#"$base"/}" "${d#"$base"/}  ($(img_oneline "$d"))" off); done
        ui_checklist "Výběr záloh" "Které zálohy použít? (zdroje se pak dají sloučit na jeden disk nebo rozdělit na víc disků)" "${items[@]}" || return 1
        for t in $UI_REPLY; do IMG_DIRS+=("$base/$t"); done
    else
        IMG_DIRS=("$base/$UI_REPLY")
    fi
    IMG_DIR=${IMG_DIRS[0]}
}

# Informace o obrazu (menu 6, --info)
img_info() {
    ui_theme green
    local -n _F=$1
    local n
    {
        local x imgs="" dsize=0
        local -a dl=()
        if [[ -n "${_F[dirs]:-}" ]]; then IFS='|' read -ra dl <<<"${_F[dirs]}"; else dl=("${_F[dir]}"); fi
        for x in "${dl[@]}"; do imgs+="${imgs:+, }${x##*/}"; dsize=$(( dsize + $(img_size "$x") )); done
        printf 'Obraz:       %s\n' "$imgs"
        if (( ${#dl[@]} == 1 )); then printf 'Cesta:       %s\n' "${_F[dir]}"; fi
        if [[ -n "${_F[merged]:-}" ]]; then
            printf 'Zdroje:      %s → sloučí se na jeden cíl (oddíly za sebou), tabulka %s\n' "${_F[merged]}" "${_F[label]}"
        else
            printf 'Zdroj. disk: %s, %s, tabulka %s, sektor %s B\n' "${_F[src_disk]}" \
                "$(human $(( _F[disk_sectors] * _F[sector] )))" "${_F[label]}" "${_F[sector]}"
        fi
        printf 'Režim:       %s\n' "$([[ "${_F[mode]}" == legacy ]] && echo 'legacy (Beckhoff) – začátky oddílů se zachovají' || echo obecný)"
        printf 'Velikost dat obrazu: %s\n\n' "$(human "$dsize")"
        printf '%-11s %10s %10s %-6s %-9s %-8s %-6s %11s %11s  %s\n' ODDÍL START SEKTORY FS ROLE TYP KOMPR VELIKOST OBSAZENO LABEL
        for n in ${_F[parts]}; do
            printf '%-11s %10s %10s %-6s %-9s %-8s %-6s %11s %11s  %s%s\n' "${_F[$n.pname]}" "${_F[$n.start]}" "${_F[$n.size]}" \
                "${_F[$n.fs]:--}" "${_F[$n.role]}" "${_F[$n.imgtype]:--}" "${_F[$n.comp]:--}" \
                "$(human $(( _F[$n.size] * _F[sector] )))" "$([[ -n "${_F[$n.used]}" ]] && human "${_F[$n.used]}" || echo '?')" \
                "${_F[$n.label]:-}" "$( (( _F[$n.boot] )) && echo ' [boot]')"
        done
        echo
        layout_bar "$1"
    } | ui_text "Informace o obrazu"
}

# =============================================================================
# FS – změna velikosti a kontrola souborových systémů (kap. 5.3)
# =============================================================================

# Velikost FAT / exFAT souborového systému v bajtech podle boot sektoru (prázdné v simulaci / dry-run)
fat_fs_bytes() {
    local dev=$1 bps sec len shift
    (( SIMULATE || DRY_RUN )) && return 0
    if [[ "$(dd if="$dev" bs=1 skip=3 count=8 status=none 2>/dev/null)" == "EXFAT   " ]]; then
        len=$(dd if="$dev" bs=1 skip=72 count=8 status=none 2>/dev/null | od -An -tu8 | tr -d ' ')
        shift=$(dd if="$dev" bs=1 skip=108 count=1 status=none 2>/dev/null | od -An -tu1 | tr -d ' ')
        [[ "$len" =~ ^[0-9]+$ && "$shift" =~ ^[0-9]+$ ]] && echo $(( len << shift ))
        return 0
    fi
    bps=$(dd if="$dev" bs=1 skip=11 count=2 status=none 2>/dev/null | od -An -tu2 | tr -d ' ')
    sec=$(dd if="$dev" bs=1 skip=19 count=2 status=none 2>/dev/null | od -An -tu2 | tr -d ' ')
    [[ "$sec" =~ ^[0-9]+$ ]] && (( sec )) || sec=$(dd if="$dev" bs=1 skip=32 count=4 status=none 2>/dev/null | od -An -tu4 | tr -d ' ')
    [[ "$bps" =~ ^[0-9]+$ && "$sec" =~ ^[0-9]+$ ]] && echo $(( bps * sec ))
    return 0
}

# Roztažení FS na celý oddíl: fs_grow <fs> <zařízení> [původní_bajty] [začátek_oddílu]
# U FAT se původní velikost i začátek oddílu zjistí samy, když se nezadají (klon, obnova vybraných oddílů).
fs_grow() {
    local fs=$1 dev=$2 old=${3:-} start=${4:-} mp
    case "$fs" in
        ext2|ext3|ext4)
            run_rc "0 1 2" e2fsck -fy "$dev"
            run resize2fs "$dev" ;;
        ntfs)
            run ntfsresize --info --force --no-progress-bar "$dev"
            run ntfsresize --force --no-action "$dev"
            run_sh "echo y | ntfsresize --force --no-progress-bar $dev"
            warn "Windows při prvním startu po změně velikosti NTFS spustí chkdsk – to je v pořádku." ;;
        vfat|fat|fat12|fat16|fat32|exfat)
            [[ -n "$old" ]] || old=$(fat_fs_bytes "$dev")
            [[ -n "$start" ]] || start=$(cat "/sys/class/block/${dev##*/}/start" 2>/dev/null || true)
            if [[ -n "$old" ]]; then
                fs_fat_rebuild "$dev" "$old" "${start:-0}" "$fs"
            elif [[ "$fs" == exfat ]]; then
                warn "exFAT na $dev se nezvětšil (velikost FS se nepodařilo zjistit)."
            else
                warn "FAT na $dev se nezvětšila (fatresize chybí nebo selhal)."
            fi ;;
        xfs|btrfs)
            tmp_mount "$dev" rw; mp=$TMP_LAST
            if [[ "$fs" == xfs ]]; then run xfs_growfs "$mp"; else run btrfs filesystem resize max "$mp"; fi
            tmp_umount "$mp" ;;
        f2fs)
            if sys_have resize.f2fs; then run resize.f2fs "$dev"; else warn "resize.f2fs chybí – $dev se nezvětší."; fi ;;
        swap) : ;;
        *)
            warn "FS '${fs:-neznámý}' na $dev se nezvětšuje (dd / neznámý typ)." ;;
    esac
}

# Zmenšení FS na danou velikost v bajtech (vždy PŘED zmenšením oddílu)
fs_shrink() {
    local fs=$1 dev=$2 bytes=$3
    case "$fs" in
        ext2|ext3|ext4)
            run_rc "0 1 2" e2fsck -fy "$dev"
            run resize2fs "$dev" "$(( bytes / 1024 ))K" ;;
        ntfs)
            run ntfsresize --force --no-action -s "$bytes" "$dev"
            run_sh "echo y | ntfsresize --force --no-progress-bar -s $bytes $dev" ;;
        vfat|fat*)
            if sys_have fatresize && run_try fatresize -s "$bytes" "$dev"; then return 0; fi
            die "$E_GEN" "FAT na $dev nejde zmenšit na místě – použij obnovu z obrazu (kopie souborů)." ;;
        *)
            die "$E_USER" "FS '${fs:-?}' na $dev nelze zmenšit." ;;
    esac
}

# Kontrola FS (menu 10 a po obnově)
fs_check() {
    local fs=$1 dev=$2 repair=${3:-0} rc=0
    case "$fs" in
        ext2|ext3|ext4) if (( repair )); then run_try e2fsck -fy "$dev" || rc=$?; else run_try e2fsck -fn "$dev" || rc=$?; fi ;;
        ntfs)           if (( repair )); then run_try ntfsfix "$dev" || rc=$?; else run_try ntfsfix -n "$dev" || rc=$?; fi ;;
        vfat|fat*)      if (( repair )); then run_try fsck.vfat -a "$dev" || rc=$?; else run_try fsck.vfat -n "$dev" || rc=$?; fi ;;
        exfat)          if (( repair )); then run_try fsck.exfat -y "$dev" || rc=$?; else run_try fsck.exfat -n "$dev" || rc=$?; fi ;;
        xfs)            if (( repair )); then run_try xfs_repair "$dev" || rc=$?; else run_try xfs_repair -n "$dev" || rc=$?; fi ;;
        btrfs)          if (( repair )); then run_try btrfs check --repair "$dev" || rc=$?; else run_try btrfs check --readonly "$dev" || rc=$?; fi ;;
        *)              warn "Pro FS '${fs:-neznámý}' na $dev není kontrola k dispozici."; return 0 ;;
    esac
    if (( rc == 0 )); then ok "Souborový systém $dev ($fs): bez chyb."
    elif (( repair )) && [[ "$fs" == ext* || "$fs" == vfat || "$fs" == fat* ]] && (( rc == 1 )); then ok "Souborový systém $dev ($fs): chyby opraveny."
    else warn "Souborový systém $dev ($fs): kontrola hlásí problém (kód $rc) – podrobnosti výše a v logu."; fi
    return 0
}

# =============================================================================
# RESTORE – hlavní scénář (kap. 5.1)
# =============================================================================

# Volba režimu změny velikosti; výsledek v UI_REPLY
restore_choose_mode() {
    local -n _R=$1
    local nparts
    nparts=$(wc -w <<<"${_R[parts]}")
    if [[ -n "$OPT_MODE" ]]; then UI_REPLY=$OPT_MODE; return 0; fi
    local a_text="A) Poslední/největší datový oddíl zabere zbytek (doporučeno)"
    (( nparts == 1 )) && a_text="A) Oddíl zabere celý disk (doporučeno)"
    ui_menu "Režim změny velikosti" "Jak rozložit oddíly na cílovém disku?" \
        last "$a_text" \
        proportional "B) Proporcionálně podle velikosti disků" \
        manual "C) Zadat velikost každého oddílu ručně" \
        fixed "D) Beze změny 1:1 (jen pokud se vejde)" || return 1
}

# Příkaz obnovy jednoho oddílu
restore_part_cmd() {
    local -n _P=$1
    local n=$2 dst=$3 stream nflag=""
    if [[ "${_P[$n.img]}" == device ]]; then
        # klon: proud partclone přímo ze zdrojového oddílu (stejné zpracování jako obnova z obrazu)
        if [[ "${_P[$n.imgtype]}" == ptcl ]]; then
            # čtecí strana bez výpisu průběhu (-q), jinak se dva průběhy kreslí přes sebe
            echo "partclone.${_P[$n.fs]} -c -q -s /dev/${_P[$n.pname]} -o - -L /tmp/partclone-clone.log 2>>/tmp/partclone-clone.log | partclone.${_P[$n.fs]} -r -s - -o $dst$nflag"
        else
            echo "dd if=/dev/${_P[$n.pname]} bs=4M status=none | dd of=$dst bs=4M status=progress conv=fsync"
        fi
        return 0
    fi
    stream=$(img_stream_cmd "${_P[$n.dir]:-${_P[dir]}}" "${_P[$n.pname]}") || return 1
    case "${_P[$n.imgtype]}" in
        ptcl) echo "$stream | partclone.${_P[$n.fs]} -r -s - -o $dst$nflag" ;;
        ntfs) echo "$stream | ntfsclone --restore-image --overwrite $dst -" ;;
        dd)   echo "$stream | dd of=$dst bs=4M status=progress conv=fsync" ;;
        *)    return 1 ;;
    esac
}

# Zmenšení přes dočasný loop soubor (kap. 5.4/1), FAT a XFS přes kopii souborů (5.4/2)
restore_shrink_part() {
    local -n _S=$1 _N=$2
    local n=$3 dst=$4 fs=${_S[$3.fs]} orig new dir img l
    orig=$(( _S[$n.size] * _S[sector] ))
    new=$(( _N[$n.size] * _N[sector] ))
    dir=$(tmp_workdir)
    info "Oddíl ${_S[$n.pname]} se zmenšuje $(human "$orig") → $(human "$new"): mezikrok přes dočasný soubor v $dir."
    img="$dir/restore-tmp-${_S[$n.pname]}.img"
    run truncate -s "$orig" "$img"
    loop_attach "$img"; l=$LOOP_LAST
    run_sh "$(restore_part_cmd "$1" "$n" "$l")"
    (( SIMULATE || DRY_RUN )) && sim_progress "Obnova do dočasného souboru"
    case "$fs" in
        ext2|ext3|ext4|ntfs)
            fs_shrink "$fs" "$l" "$new"
            # dočasný soubor zkrátit na novou velikost → partclone porovná správné velikosti (bez -C)
            run truncate -s "$new" "$img"
            run losetup -c "$l"
            # -I: po zmenšení je NTFS označený ke kontrole (chkdsk), partclone ho jinak odmítne
            run_sh "partclone.$fs -b -I -s $l -o $dst -L /tmp/partclone-copy.log"
            fs_grow "$fs" "$dst" ;;
        vfat|fat*)
            fs_fat_copy "$l" "$dst" "${_N[$n.start]}" ;;
        exfat)
            fs_exfat_copy "$l" "$dst" ;;
        *)
            fs_copy_files "$fs" "$l" "$dst" "${_S[$n.fsuuid]}" "${_S[$n.label]}" ;;
    esac
    loop_detach "$l"
    run rm -f "$img"
}

# Zdroj obnovy = "jednotka" "adresář|disk": jeden disk z jednoho obrazu (obraz jich může mít víc).
# Název pro uživatele: "sda"; je-li vybráno víc obrazů, "OBRAZ:sda".
unit_name() {
    local dir=${1%%|*} disk=${1#*|}
    if (( ${#IMG_DIRS[@]} > 1 )); then echo "${dir##*/}:$disk"; else echo "$disk"; fi
}

# Zadání z příkazové řádky ("sda" nebo "OBRAZ:sda") → jednotka v UNIT_RES
unit_resolve() {
    local spec=$1 u
    local -a hit=()
    for u in "${UNITS[@]}"; do
        if [[ "$(unit_name "$u")" == "$spec" || "${u#*|}" == "$spec" ]]; then hit+=("$u"); fi
    done
    (( ${#hit[@]} )) || die "$E_USER" "Zdroj '$spec' ve vybraných zálohách není (k dispozici: $(for u in "${UNITS[@]}"; do printf '%s ' "$(unit_name "$u")"; done))."
    (( ${#hit[@]} == 1 )) || die "$E_USER" "Zdroj '$spec' je ve více obrazech – uveď ho jako OBRAZ:disk."
    UNIT_RES=${hit[0]}
}

# Obnova ze zálohy – celý průběh. Zdroje (disky ze zálohy; i z několika záloh) se dají:
#   sloučit na JEDEN cílový disk (oddíly za sebou), obnovit každý na vlastní cílový disk,
#   nebo libovolně seskupit (--groups "sda+sdb,sdc" / volba "Vlastní rozdělení").
restore_disk() {
    local d i u m spec dir how="" k g why
    local -a sel=() targets=() items=() grp=() groups=() specs=() members=() nums=() names=() done_names=()
    blk_load
    live_detect
    ui_step "krok 1/6: disk se zálohami"
    src_select ro || return "$E_USER"
    ui_step "krok 2/6: výběr zálohy"
    img_select multi || return "$E_USER"
    UNITS=()
    for dir in "${IMG_DIRS[@]}"; do
        while read -r d; do UNITS+=("$dir|$d"); done < <(img_disks "$dir")
    done
    IFS=, read -ra targets <<<"$OPT_TARGET"
    if [[ -n "$OPT_TARGET" ]] && (( $(printf '%s\n' "${targets[@]}" | sort -u | wc -l) != ${#targets[@]} )); then
        die "$E_USER" "--target uvádí tentýž disk vícekrát (${targets[*]}). Nic nebylo zapsáno."
    fi
    if [[ -n "$OPT_GROUPS" ]]; then
        IFS=, read -ra specs <<<"$OPT_GROUPS"
        for spec in "${specs[@]}"; do
            IFS=+ read -ra members <<<"$spec"
            grp=()
            for m in "${members[@]}"; do
                unit_resolve "$m"
                [[ ";${sel[*]// /;};" == *";$UNIT_RES;"* ]] && die "$E_USER" "Zdroj '$m' je v --groups použit víckrát."
                grp+=("$UNIT_RES"); sel+=("$UNIT_RES")
            done
            groups+=("$(IFS=';'; echo "${grp[*]}")")
        done
        how=groups
    else
        if [[ -n "$OPT_SOURCE_DISK" ]]; then
            IFS=, read -ra specs <<<"$OPT_SOURCE_DISK"
            for spec in "${specs[@]}"; do unit_resolve "$spec"; sel+=("$UNIT_RES"); done
        else
            sel=("${UNITS[@]}")
        fi
        if (( ${#sel[@]} == 1 )); then how=separate
        elif (( ${#targets[@]} > 1 )); then how=separate
        elif (( ${#targets[@]} == 1 )); then how=merge
        elif [[ -n "$OPT_SOURCE_DISK" ]]; then how=separate
        else
            for u in "${sel[@]}"; do names+=("$(unit_name "$u")"); done
            items=(merge "Sloučit ${names[*]} na JEDEN cílový disk (oddíly za sebou)")
            items+=(separate "Každý zdroj na jiný cílový disk")
            for i in "${!sel[@]}"; do
                u=${sel[i]}
                items+=("only-$i" "Jen $(unit_name "$u")  (oddíly: $(img_disk_parts "${u%%|*}" "${u#*|}"))")
            done
            items+=(custom "Vlastní rozdělení: určit, co půjde na který cílový disk")
            if (( ${#IMG_DIRS[@]} == 1 )); then
                ui_menu "Záloha obsahuje ${#sel[@]} disky" "Záloha ${IMG_DIRS[0]##*/} obsahuje disky: ${names[*]}. Jak obnovit?" "${items[@]}" || return "$E_USER"
            else
                ui_menu "Vybrané zálohy obsahují ${#sel[@]} disků" "K obnově je ${#sel[@]} disků ze ${#IMG_DIRS[@]} záloh: ${names[*]}. Jak je obnovit?" "${items[@]}" || return "$E_USER"
            fi
            case "$UI_REPLY" in
                merge)    how=merge ;;
                separate) how=separate ;;
                only-*)   sel=("${sel[${UI_REPLY#only-}]}"); how=separate ;;
                custom)
                    how=groups
                    nums=()
                    for u in "${sel[@]}"; do
                        while true; do
                            ui_input "Na který cílový disk půjde $(unit_name "$u")? Číslo 1, 2, 3… (stejné číslo = sloučí se na jeden disk, 0 = tento zdroj neobnovovat)" "$(( ${#nums[@]} + 1 ))" || return "$E_USER"
                            [[ "$UI_REPLY" =~ ^[0-9]+$ ]] && break
                            warn "Zadej celé číslo."
                        done
                        nums+=("$UI_REPLY")
                    done
                    for k in $(printf '%s\n' "${nums[@]}" | sort -nu); do
                        (( k == 0 )) && continue
                        grp=()
                        for i in "${!sel[@]}"; do (( nums[i] == k )) && grp+=("${sel[i]}"); done
                        groups+=("$(IFS=';'; echo "${grp[*]}")")
                    done
                    (( ${#groups[@]} )) || { ui_msg "Nic nebylo vybráno k obnově."; return "$E_USER"; } ;;
            esac
        fi
        case "$how" in
            merge)    groups=("$(IFS=';'; echo "${sel[*]}")") ;;
            separate) groups=("${sel[@]}") ;;
        esac
    fi
    if (( ${#targets[@]} && ${#targets[@]} != ${#groups[@]} )); then
        die "$E_USER" "Obnovuje se na ${#groups[@]} cílových disků, ale --target uvádí ${#targets[@]}: zadej např. --target sdf,sdg. Nic nebylo zapsáno."
    fi
    # všechny zadané cíle se zkontrolují PŘED prvním zápisem
    for u in "${targets[@]}"; do
        [[ "${BLK[$u.TYPE]:-}" == disk ]] || die "$E_USER" "Cílový disk $u neexistuje. Nic nebylo zapsáno."
        if why=$(disk_protect_reason "$u"); then die "$E_USER" "Disk $u nelze použít jako cíl: $why. Nic nebylo zapsáno."; fi
        if [[ -n "$OPT_YES" && ",$OPT_YES," != *",$u,"* ]]; then
            die "$E_USER" "--yes-i-know '$OPT_YES' nepotvrzuje cílový disk $u (uveď všechny cíle: --yes-i-know sdf,sdg). Nic nebylo zapsáno."
        fi
    done
    RESTORE_USED_TARGETS=()
    for g in "${!groups[@]}"; do
        IFS=';' read -ra grp <<<"${groups[g]}"
        names=()
        for u in "${grp[@]}"; do names+=("$(unit_name "$u")"); done
        if (( ${#groups[@]} > 1 )); then step "$(( g + 1 ))" "${#groups[@]}" "Cílový disk č. $(( g + 1 )): ${names[*]}"; fi
        restore_one_disk "${targets[g]:-}" "${grp[@]}" || return $?
        RESTORE_USED_TARGETS+=("$LAST_TARGET")
        done_names+=("$(IFS=+; echo "${names[*]}") → $LAST_TARGET")
    done
    if (( ${#groups[@]} > 1 )); then ok "Obnoveno: ${done_names[*]}"; fi
}

# Provedení obnovy (všechny zápisy přes run)
restore_execute() {
    local -n _X=$1 _Y=$2
    local tgt=$3 n i=0 total dst nparts tbl
    [[ "$UI_BACKEND" == plain ]] || clear
    nparts=$(wc -w <<<"${_X[parts]}")
    total=$(( 3 + nparts ))
    i=$((i + 1)); step "$i" "$total" "Smazání staré tabulky oddílů na /dev/$tgt"
    run wipefs -a "/dev/$tgt"
    [[ "${_Y[label]}" == gpt ]] && run sgdisk --zap-all "/dev/$tgt"

    i=$((i + 1)); step "$i" "$total" "Zápis nové tabulky oddílů (${_Y[label]})"
    tbl=$(mktemp)
    layout_to_sfdisk "$2" >"$tbl"
    run_in "$tbl" sfdisk --wipe always --wipe-partitions always "/dev/$tgt"
    rm -f "$tbl"
    # záložní GPT na konec disku zapisuje sfdisk sám (last-lba); sgdisk -e se nevolá – u tabulky
    # s first-lba 2048 chybně hlásí překryv s posledním oddílem. Jen kontrola, bez zápisu:
    if [[ "${_Y[label]}" == gpt ]] && sys_have sgdisk; then run_try sgdisk -v "/dev/$tgt" || warn "sgdisk -v hlásí problém v GPT na /dev/$tgt – viz log."; fi
    if [[ "${_X[label]}" == dos ]]; then
        local mbr="${_X[dir]}/${_X[src_disk]}-mbr" hid="${_X[dir]}/${_X[src_disk]}-hidden-data-after-mbr"
        [[ -r "$mbr" ]] && run dd if="$mbr" of="/dev/$tgt" bs=446 count=1 conv=notrunc status=none
        [[ -r "$hid" ]] && run dd if="$hid" of="/dev/$tgt" bs=512 seek=1 conv=notrunc status=none
    fi
    # shellcheck disable=SC2086  # seznam čísel oddílů se má rozdělit
    disk_rescan "$tgt" ${_Y[parts]}

    for n in ${_X[parts]}; do
        i=$((i + 1))
        dst="/dev/$(part_name "$tgt" "$n")"
        step "$i" "$total" "Obnova $dst (${_X[$n.fs]:-bez FS}, $(human $(( _X[$n.size] * _X[sector] ))) → $(human $(( _Y[$n.size] * _Y[sector] ))))"
        if [[ -z "${_X[$n.img]}" ]]; then
            if [[ "${_X[$n.fs]}" == swap ]]; then
                run mkswap -U "${_X[$n.fsuuid]}" ${_X[$n.label]:+-L "${_X[$n.label]}"} "$dst"
            else
                info "Oddíl $dst nemá data (${_X[$n.role]}) – jen se vytvoří v tabulce."
            fi
            continue
        fi
        if (( _Y[$n.shrink] )); then
            restore_shrink_part "$1" "$2" "$n" "$dst"
            continue
        fi
        run_sh "$(restore_part_cmd "$1" "$n" "$dst")"
        (( SIMULATE || DRY_RUN )) && sim_progress "Obnova $dst"
        if (( _Y[$n.size] * _Y[sector] > _X[$n.size] * _X[sector] )); then
            fs_grow "${_X[$n.fs]}" "$dst" $(( _X[$n.size] * _X[sector] )) "${_Y[$n.start]}"
        fi
    done

    i=$((i + 1)); step "$i" "$total" "Opravy po obnově"
    restore_fixups "$1" "$2" "$tgt"
    info "Zapisuji data na disk (sync)…"
    run sync
    restore_summary "$2" "$tgt"
}

# Opravy bootovatelnosti (kap. 5.5, 5.7)
restore_fixups() {
    local -n _A=$1 _B=$2
    local tgt=$3 n auto moved
    for n in ${_A[parts]}; do
        [[ "${_A[$n.fs]}" == @(ntfs|vfat|fat*) ]] || continue
        moved=0
        (( _B[$n.start] != ${_A[$n.origstart]:-${_A[$n.start]}} )) && moved=1
        [[ "${_A[mode]}" == legacy ]] || (( moved )) || continue
        auto=0
        [[ -n "$OPT_YES" ]] && auto=1
        (( moved )) && auto=1
        info "Kontrola pole hidden sectors (0x1C) na $(part_name "$tgt" "$n"): očekáváno ${_B[$n.start]}."
        fix_hidden_sectors "/dev/$(part_name "$tgt" "$n")" "${_B[$n.start]}" "${_A[$n.fs]}" "$auto"
    done
    for n in ${_A[parts]}; do
        if [[ "${_A[$n.fs]}" == ntfs ]]; then ntfs_sync_backup_boot "/dev/$(part_name "$tgt" "$n")"; fi
    done
    if [[ -n "${_A[merged]:-}" ]]; then
        warn "Disky ${_A[merged]} byly sloučeny na jeden disk. Windows mohou druhému oddílu přidělit jiné písmeno (např. D: → E:) – zkontroluj po prvním startu."
    fi
    if [[ "${_A[mode]}" == legacy ]]; then
        restore_chs_info "${_A[dir]}/${_A[src_disk]}-chs.sf" "$tgt"
        info "Upozornění Beckhoff: licence TwinCAT jsou vázané na hardware panelu."
        [[ "${_A[parts]}" == 1 && "${_A[1.fs]}" == ntfs && "${_A[1.start]}" == 63 ]] && \
            info "XP Embedded: pokud byl při tvorbě obrazu zapnutý EWF/FBWF write filter, změnu velikosti nezaznamená."
    elif [[ "${_A[label]}" == gpt ]] && (( ! OPT_NO_EFI_FIX )); then
        info "UEFI: boot záznam v NVRAM patří počítači, ne disku. Oprava EFI záznamů: menu 8 → 2."
    fi
    return 0
}

# Kontrola / oprava pole hidden sectors v boot sektoru (kap. 5.7/4); auto=1 opraví bez ptaní
fix_hidden_sectors() {
    local dev=$1 want=$2 fs=$3 auto=${4:-0} cur hex bytes total
    if (( SIMULATE || DRY_RUN )); then
        _show_cmd "dd if=$dev bs=1 skip=28 count=4 | od -An -tu4   # čekám $want"
        return 0
    fi
    cur=$(dd if="$dev" bs=1 skip=28 count=4 status=none | od -An -tu4 | tr -d ' ')
    if [[ "$cur" == "$want" ]]; then ok "hidden sectors $dev = $cur"; return 0; fi
    if (( auto )); then
        info "hidden sectors na $dev je $cur, oddíl začíná na $want – opravuji."
    else
        warn "hidden sectors na $dev je $cur, ale oddíl začíná na $want."
        ui_yesno "Opravit hidden sectors na $want?" || return 0
    fi
    hex=$(printf '%08x' "$want")
    bytes="\\x${hex:6:2}\\x${hex:4:2}\\x${hex:2:2}\\x${hex:0:2}"
    printf '%b' "$bytes" | dd of="$dev" bs=1 seek=28 count=4 conv=notrunc status=none
    if [[ "$fs" == ntfs ]]; then
        # záložní boot sektor NTFS leží za posledním sektorem svazku (pole 0x28 = počet sektorů)
        total=$(dd if="$dev" bs=1 skip=40 count=8 status=none | od -An -tu8 | tr -d ' ')
        printf '%b' "$bytes" | dd of="$dev" bs=1 seek=$(( total * 512 + 28 )) count=4 conv=notrunc status=none
    elif [[ "$fs" == @(vfat|fat32) ]] && [[ "$(dd if="$dev" bs=1 skip=82 count=5 status=none)" == FAT32 ]]; then
        printf '%b' "$bytes" | dd of="$dev" bs=1 seek=$(( 6 * 512 + 28 )) count=4 conv=notrunc status=none
    fi
    ok "hidden sectors na $dev opraveno na $want."
}

restore_summary() {
    local -n _Z=$1
    local tgt=$2 dur
    dur=$(( $(date +%s) - START_TS ))
    # udev o novém FS ještě nemusí vědět (hlavně USB) – nechat disk znovu načíst, ať lsblk ukáže skutečný stav
    if (( ! SIMULATE && ! DRY_RUN )); then
        udevadm trigger --action=change "/dev/$tgt" /dev/"$tgt"?* 2>/dev/null || true
        udevadm settle --timeout=10 2>/dev/null || sleep 2
    fi
    {
        if [[ -n "${CLONE_SRC:-}" ]]; then echo "Hotovo: klon /dev/$CLONE_SRC → /dev/$tgt"; else echo "Hotovo: obnova na /dev/$tgt"; fi
        echo "Doba běhu: $(( dur / 60 )) min $(( dur % 60 )) s"
        echo "Log: $LOG_FILE"
        if (( SIMULATE )); then echo "(SIMULACE – nic nebylo zapsáno)"; fi
        if (( DRY_RUN )); then echo "(DRY-RUN – nic nebylo zapsáno)"; fi
        echo
        if (( SIMULATE || DRY_RUN )); then layout_bar "$1"; else lsblk -f "/dev/$tgt"; fi
        if (( ${#WARNINGS[@]} )); then
            echo; echo "Varování:"
            # každé varování jen jednou, dlouhé řádky zalomené na šířku okna
            printf '%s\n' "${WARNINGS[@]}" | awk '!seen[$0]++' | while IFS= read -r w; do
                printf '%s\n' "$w" | fold -s -w 84 | sed '1s/^/  - /; 2,$s/^/    /'
            done
        fi
    } | ui_text "Souhrn"
}

# =============================================================================
# EDITOR ODDÍLŮ (kap. 5.6) – vše se nejdřív plánuje, zapisuje se až po potvrzení
# =============================================================================
declare -A ED=() ED_ORIG_START=()
declare -a ED_UNDO=() ED_PLAN=()

# Kopie asociativního pole: arr_copy <z> <do>
arr_copy() {
    local -n _from=$1 _to=$2
    local k
    _to=()
    for k in "${!_from[@]}"; do _to["$k"]=${_from["$k"]}; done
}

# Načte existující disk do ED (tabulka + FS z lsblk)
editor_load_disk() {
    local disk=$1 n p
    ED=()
    layout_parse_sfdisk ED < <(sys_sfdisk_dump "$disk")
    [[ -n "${ED[label]}" ]] || die "$E_USER" "Disk $disk nemá tabulku oddílů."
    ED[tgt]=$disk
    ED[disk_sectors]=$(( BLK[$disk.SIZE] / ED[sector] ))
    for n in ${ED[parts]}; do
        p=$(part_name "$disk" "$n")
        ED[$n.pname]=$p
        ED[$n.fs]=${BLK[$p.FSTYPE]:-}
        ED[$n.label]=${BLK[$p.LABEL]:-}
        ED[$n.img]="" ED[$n.used]="" ED[$n.min]=""
    done
    layout_classify ED
    layout_detect_legacy ED
}

# Volné místo za oddílem (do dalšího oddílu nebo konce disku), v sektorech
editor_space_after() {
    local n=$1 m end limit
    end=$(( ED[$n.start] + ED[$n.size] ))
    if [[ "${ED[label]}" == gpt ]]; then limit=$(( ED[disk_sectors] - 33 )); else limit=${ED[disk_sectors]}; fi
    for m in ${ED[parts]}; do
        [[ "$m" == "$n" || "${ED[$m.role]}" == extended ]] && continue
        (( ED[$m.start] >= end && ED[$m.start] < limit )) && limit=${ED[$m.start]}
    done
    echo $(( limit - end ))
}

editor_show() {
    local n ss=${ED[sector]}
    {
        printf '%-3s %-12s %11s %11s %11s %-6s %-14s %11s\n' "#" ODDÍL ZAČÁTEK KONEC VELIKOST FS LABEL "VOLNO ZA"
        for n in ${ED[parts]}; do
            printf '%-3s %-12s %11s %11s %11s %-6s %-14.14s %11s\n' "$n" "${ED[$n.pname]}" "${ED[$n.start]}" \
                $(( ED[$n.start] + ED[$n.size] - 1 )) "$(human $(( ED[$n.size] * ss )))" "${ED[$n.fs]:--}" \
                "${ED[$n.label]:--}" "$(human $(( $(editor_space_after "$n") * ss )))"
        done
        echo
        layout_bar ED
        if (( ${#ED_PLAN[@]} )); then echo; echo "Plán (${#ED_PLAN[@]} kroků):"; printf '  %s\n' "${ED_PLAN[@]}"; fi
    } | ui_text "Editor oddílů – /dev/${ED[tgt]}"
}

editor_pick_part() {
    local n items=()
    for n in ${ED[parts]}; do items+=("$n" "${ED[$n.pname]} ${ED[$n.fs]:-} $(human $(( ED[$n.size] * ED[sector] )))"); done
    ui_menu "Oddíl" "Vyber oddíl:" "${items[@]}"
}

editor_resize() {
    local n cur maxb ss=${ED[sector]}
    editor_pick_part || return 0
    n=$UI_REPLY
    cur=$(( ED[$n.size] * ss ))
    maxb=$(( cur + $(editor_space_after "$n") * ss ))
    ui_input "Nová velikost ${ED[$n.pname]} (teď $(human "$cur"), max $(human "$maxb")): 200G, 512M, +20G, -5G, 60%, max" "max" || return 0
    editor_do_resize "$n" "$UI_REPLY" || true
}

editor_move() {
    local n
    editor_pick_part || return 0
    n=$UI_REPLY
    ui_input "Nový začátek ${ED[$n.pname]}: 'end' = doprava na konec volného místa, 'start' = doleva, nebo číslo v MiB" "end" || return 0
    editor_do_move "$n" "$UI_REPLY" || true
}

editor_delete() {
    local n
    editor_pick_part || return 0
    n=$UI_REPLY
    ui_input "Smazání oddílu – opiš jeho název (${ED[$n.pname]})" || return 0
    [[ "$UI_REPLY" == "${ED[$n.pname]}" ]] || { warn "Nesouhlasí, nic se nemaže."; return 0; }
    ED_UNDO+=("$(declare -p ED ED_PLAN)")
    ED_PLAN+=("delete $n   # ${ED[$n.pname]}")
    ED[parts]=$(sed -E "s/(^| )$n( |$)/ /; s/^ +| +$//g" <<<"${ED[parts]}")
}

editor_label() {
    local n
    editor_pick_part || return 0
    n=$UI_REPLY
    ui_input "Nový LABEL pro ${ED[$n.pname]} (${ED[$n.fs]:-?})" "${ED[$n.label]}" || return 0
    if [[ "${ED[$n.fs]}" == @(vfat|fat*) ]] && { LC_ALL=C grep -q '[^ -~]' <<<"$UI_REPLY" || (( ${#UI_REPLY} > 11 )); }; then
        warn "Popisek FAT smí mít nejvýš 11 znaků bez diakritiky (A–Z, 0–9, mezera, _ -)."; return 0
    fi
    ED_UNDO+=("$(declare -p ED ED_PLAN)")
    ED_PLAN+=("label $n $UI_REPLY   # ${ED[$n.pname]}")
    ED[$n.label]=$UI_REPLY
}

editor_align() {
    local n out=""
    for n in ${ED[parts]}; do
        if (( ED[$n.start] * ED[sector] % MiB )); then out+="${ED[$n.pname]}: začátek ${ED[$n.start]} NENÍ zarovnaný na 1 MiB"$'\n'
        else out+="${ED[$n.pname]}: zarovnáno ✔"$'\n'; fi
    done
    printf '%s' "$out" | ui_text "Zarovnání"
}

editor_undo() {
    if (( ${#ED_UNDO[@]} == 0 )); then info "Není co vracet."; return 0; fi
    local snap=${ED_UNDO[-1]}
    unset 'ED_UNDO[-1]'
    snap=${snap//declare -A/declare -gA}
    snap=${snap//declare -a/declare -ga}
    eval "$snap"
}

# Provedení plánu editoru na existujícím disku (kap. 5.6)
editor_apply() {
    local disk=${ED[tgt]} s op n arg dev bk i=0 total
    local -a plan
    (( ${#ED_PLAN[@]} )) || { info "Plán je prázdný."; return 0; }
    mapfile -t plan < <(editor_plan_sorted)
    total=${#plan[@]}
    (( total == ${#ED_PLAN[@]} )) || die "$E_GEN" "Interní chyba: plán má ${#ED_PLAN[@]} kroků, k provedení připraveno $total – nic se nezapíše."
    ui_confirm_disk "$disk" "$(disk_summary "$disk"; echo; echo "Plán (v pořadí provedení):"; printf '  %s\n' "${plan[@]}")" || return 0
    # záloha tabulky oddílů před prvním zápisem
    bk="${OPT_TMPDIR:-/tmp}/pt-backup-$disk-$(date +%Y%m%d-%H%M%S).sf"
    if [[ -n "$(src_find_mounted)" ]] && ! findmnt -no OPTIONS "$PARTIMAG_MP" 2>/dev/null | grep -qw ro; then
        bk="$PARTIMAG_MP/pt-backup-$disk-$(date +%Y%m%d-%H%M%S).sf"
    fi
    run_sh "sfdisk --dump /dev/$disk > '$bk'"
    info "Záloha tabulky: $bk  (obnova: sfdisk /dev/$disk < $bk)"
    for s in "${plan[@]}"; do
        read -r op n arg _ <<<"$s"
        i=$(( i + 1 ))
        dev="/dev/${ED[$n.pname]}"
        step "$i" "$total" "$s"
        case "$op" in
            shrink)
                if [[ "${ED[$n.fs]}" == @(vfat|fat*|exfat) ]]; then
                    # FAT/exFAT nejde zmenšit na místě: data stranou, menší oddíl, nový FS, data zpět
                    fat_save_tmp "$dev" "$(fat_fs_bytes "$dev")" "${ED[$n.fs]}"
                    run_sh "echo ', $(( arg / ED[sector] ))' | sfdisk --no-reread -q --wipe-partitions never -N $n /dev/$disk"
                    disk_rescan "$disk" "$n"
                    fat_restore_tmp "$dev" "${ED[$n.start]}" "${ED[$n.fs]}"
                    fs_check "${ED[$n.fs]}" "$dev" 0
                    DONE_STEPS+=("$s")
                    continue
                fi
                [[ "${ED[$n.fs]}" == swap ]] || fs_shrink "${ED[$n.fs]}" "$dev" "$arg"
                run_sh "echo ', $(( arg / ED[sector] ))' | sfdisk --no-reread -q --wipe-partitions never -N $n /dev/$disk"
                disk_rescan "$disk" "$n"
                [[ "${ED[$n.fs]}" == swap ]] && run mkswap -U "$(blkid -s UUID -o value "$dev" 2>/dev/null)" "$dev"
                fs_check "${ED[$n.fs]}" "$dev" 0 ;;
            grow)
                run_sh "echo ', $(( arg / ED[sector] ))' | sfdisk --no-reread -q --wipe-partitions never -N $n /dev/$disk"
                disk_rescan "$disk" "$n"
                fs_grow "${ED[$n.fs]}" "$dev"
                fs_check "${ED[$n.fs]}" "$dev" 0 ;;
            move)
                run_sh "echo '$arg,' | sfdisk --no-reread -q --wipe-partitions never --move-data=/tmp/sfdisk-move-$disk.log -N $n /dev/$disk"
                disk_rescan "$disk" "$n"
                [[ "${ED[$n.fs]}" == @(ntfs|vfat|fat*) ]] && fix_hidden_sectors "$dev" "$arg" "${ED[$n.fs]}" 1
                fs_check "${ED[$n.fs]}" "$dev" 0 ;;
            delete)
                run sfdisk --no-reread -q --delete "/dev/$disk" "$n"
                disk_rescan "$disk" ;;
            label)
                case "${ED[$n.fs]}" in
                    ext*)      run e2label "$dev" "$arg" ;;
                    ntfs)      run ntfslabel "$dev" "$arg" ;;
                    vfat|fat*) run fatlabel "$dev" "$arg" ;;
                    xfs)       run xfs_admin -L "$arg" "$dev" ;;
                    btrfs)     run btrfs filesystem label "$dev" "$arg" ;;
                    *)         warn "LABEL pro FS '${ED[$n.fs]}' nelze nastavit." ;;
                esac ;;
        esac
        DONE_STEPS+=("$s")
    done
    ok "Plán editoru proveden ($total kroků)."
    ED_PLAN=() ED_UNDO=()
}

# editor_run <disk> [pole] – s polem upravuje navržený layout obnovy, jinak existující disk
editor_run() {
    local disk=$1 arr=${2:-}
    ED_PLAN=() ED_UNDO=()
    if [[ -z "$arr" ]]; then
        local why
        if why=$(disk_protect_reason "$disk"); then die "$E_USER" "Disk $disk nelze upravovat: $why."; fi
    fi
    if [[ -n "$arr" ]]; then arr_copy "$arr" ED; else editor_load_disk "$disk"; fi
    local m; ED_ORIG_START=()
    for m in ${ED[parts]}; do ED_ORIG_START[$m]=${ED[$m.start]}; done
    while true; do
        editor_show
        ui_menu "Editor oddílů – /dev/$disk" "Změny se jen plánují; zápis až po potvrzení." \
            r "Změnit velikost oddílu" m "Přesunout oddíl" d "Smazat oddíl" l "Změnit LABEL" \
            a "Zkontrolovat zarovnání" u "Vrátit poslední změnu" \
            w "$([[ -n "$arr" ]] && echo 'Použít tento layout pro obnovu' || echo 'Provést plán')" \
            x "Zahodit plán a odejít" || return 1
        case "$UI_REPLY" in
            r) editor_resize ;; m) editor_move ;; d) editor_delete ;; l) editor_label ;;
            a) editor_align ;; u) editor_undo ;;
            w) if [[ -n "$arr" ]]; then arr_copy ED "$arr"; layout_check SRC "$arr" || { warn "Layout není platný."; continue; }; return 0
               else editor_apply; fi ;;
            x) return 1 ;;
        esac
    done
}

# =============================================================================
# MENU – položky 2–15 (kap. 6)
# =============================================================================

# Výběr oddílu z nechráněných disků; výsledek v UI_REPLY
part_select() {
    ui_theme red
    local title=$1 d c items=()
    for d in $(disk_all); do
        disk_protect_reason "$d" >/dev/null && continue
        for c in $(blk_children "$d"); do
            items+=("$c" "$c  $(human "${BLK[$c.SIZE]:-0}") ${BLK[$c.FSTYPE]:--} ${BLK[$c.LABEL]:-} (${BLK[$d.MODEL]:-$d})")
        done
    done
    (( ${#items[@]} )) || { ui_msg "Žádný oddíl k dispozici (chráněné disky se nenabízejí)."; return 1; }
    ui_menu "$title" "Vyber oddíl:" "${items[@]}"
}

# Výběr zdrojového disku (ne flashka, ne disk s obrazy)
disk_select_source() {
    ui_theme green
    local d why items=()
    for d in $(disk_all); do
        why=$(disk_protect_reason "$d") || why=""
        [[ "$why" == "flashka s Clonezillou" || "$why" == "disk s obrazy" ]] && continue
        items+=("$d" "$(disk_desc "$d" "$why")")
    done
    (( ${#items[@]} )) || { ui_msg "Žádný zdrojový disk."; return 1; }
    ui_menu "${1:-Zdrojový disk}" "Vyber disk:" "${items[@]}"
}

# Jeden průchod obnovy vybraných oddílů (jeden disk jedné zálohy); 1 = zrušeno
restore_parts_pass() {
    local n sel dst
    src_select ro || return 1
    img_select || return 1
    img_pick_disk "$IMG_DIR" || return 1
    img_load "$IMG_DIR" SRC "$UI_REPLY"
    img_info SRC
    local items=()
    for n in ${SRC[parts]}; do
        [[ -n "${SRC[$n.img]}" ]] && items+=("$n" "${SRC[$n.pname]} ${SRC[$n.fs]} $(human $(( SRC[$n.size] * SRC[sector] )))" off)
    done
    while true; do
        ui_checklist "Oddíly k obnově" "Které oddíly obnovit? Označ MEZERNÍKEM (objeví se [*]), pak Potvrdit." "${items[@]}" && break
        (( UI_EMPTY )) || return 1
        ui_msg "Nic není označené. Najeď na oddíl, stiskni MEZERNÍK (objeví se [*]) a potom Potvrdit výběr."
    done
    sel=$UI_REPLY
    local dbytes sbytes dstart
    for n in $sel; do
        part_select "Cíl pro ${SRC[$n.pname]} (${SRC[$n.fs]}, $(human $(( SRC[$n.size] * SRC[sector] ))))" || return 1
        dst=$UI_REPLY
        if (( BLK[$dst.SIZE] < ${SRC[$n.min]:-0} )); then
            warn "Oddíl $dst je menší než minimum $(human "${SRC[$n.min]}") – přeskakuji."
            continue
        fi
        dbytes=${BLK[$dst.SIZE]} sbytes=$(( SRC[$n.size] * SRC[sector] ))
        dstart=$(cat "/sys/class/block/$dst/start" 2>/dev/null || echo 0)
        ui_confirm_disk "$dst" "$(printf 'Oddíl /dev/%s (%s, %s) bude přepsán obsahem %s (%s, %s).\n' "$dst" \
            "${BLK[$dst.FSTYPE]:--}" "$(human "$dbytes")" "${SRC[$n.pname]}" "${SRC[$n.fs]}" "$(human "$sbytes")")" || continue
        if (( dbytes < sbytes )); then
            # menší cílový oddíl: stejně jako při obnově disku – dočasný soubor, zmenšení FS, kopie
            NEW=()
            # shellcheck disable=SC2034  # NEW čte restore_shrink_part přes nameref
            NEW[sector]=${SRC[sector]} NEW[parts]=$n NEW[$n.size]=$(( dbytes / SRC[sector] )) NEW[$n.start]=$dstart NEW[$n.shrink]=1
            restore_check_tmp SRC NEW
            restore_shrink_part SRC NEW "$n" "/dev/$dst"
        else
            run_sh "$(restore_part_cmd SRC "$n" "/dev/$dst")"
            (( SIMULATE || DRY_RUN )) && sim_progress "Obnova /dev/$dst"
            if (( dbytes > sbytes )); then fs_grow "${SRC[$n.fs]}" "/dev/$dst" "$sbytes" "$dstart"; fi
        fi
        # oddíl je jinde než ve zdroji: boot sektor FAT/NTFS musí znát svůj začátek (hidden sectors)
        if [[ "${SRC[$n.fs]}" == @(ntfs|vfat|fat*) ]] && (( dstart > 0 )); then
            fix_hidden_sectors "/dev/$dst" "$dstart" "${SRC[$n.fs]}" 1
        fi
        [[ "${SRC[$n.fs]}" == ntfs ]] && ntfs_sync_backup_boot "/dev/$dst"
        run sync
        ok "Oddíl /dev/$dst obnoven z ${SRC[$n.pname]}."
    done
    return 0
}

# 2) Obnova vybraných oddílů na existující oddíly. Lze opakovat s dalším diskem / další zálohou,
# takže jde obnovit oddíly z libovolného počtu disků a záloh.
menu_02_restore_parts() {
    while true; do
        restore_parts_pass || return 0
        ui_yesno "Obnovit ještě další oddíly (z jiného disku nebo jiné zálohy)?" n || return 0
    done
}

# Typ oddílu z tabulky (sfdisk) – pro rozpoznání rozšířeného oddílu
part_type() {
    local disk=$1 p=$2
    sys_sfdisk_dump "$disk" | awk -v d="/dev/$p" '$1==d { for (i=1;i<=NF;i++) if ($i ~ /^type=/) { sub(/^type=/,"",$i); sub(/,$/,"",$i); print $i } }'
}

# Metadata jednoho disku v obrazu: tabulka oddílů, MBR / GPT, skrytá data za MBR
backup_write_disk_meta() {
    local dir=$1 disk=$2 label first total
    run_sh "sfdisk --dump /dev/$disk > '$dir/$disk-pt.sf'"
    run_sh "LC_ALL=C parted -s /dev/$disk unit s print > '$dir/$disk-pt.parted' 2>/dev/null || true"
    run_sh "LC_ALL=C parted -s /dev/$disk unit compact print > '$dir/$disk-pt.parted.compact' 2>/dev/null || true"
    run_sh "sfdisk -g /dev/$disk 2>/dev/null | sed -nE 's/.*: ([0-9]+) cylinders, ([0-9]+) heads, ([0-9]+) sectors.*/cylinders=\1\nheads=\2\nsectors=\3/p' > '$dir/$disk-chs.sf' || true"
    run dd if="/dev/$disk" of="$dir/$disk-mbr" bs=512 count=1 status=none
    label=$(sys_sfdisk_dump "$disk" | sed -n 's/^label: //p')
    if [[ "$label" == gpt ]]; then
        total=$(( BLK[$disk.SIZE] / 512 ))
        run dd if="/dev/$disk" of="$dir/$disk-gpt-1st" bs=512 count=34 status=none
        run dd if="/dev/$disk" of="$dir/$disk-gpt-2nd" bs=512 skip=$(( total - 33 )) count=33 status=none
        run_sh "sgdisk -p /dev/$disk > '$dir/$disk-gpt.gdisk'"
        run_sh "sgdisk -b '$dir/$disk-gpt.sgdisk' /dev/$disk > /dev/null"
    else
        first=$(sys_sfdisk_dump "$disk" | sed -nE 's/.*start= *([0-9]+).*/\1/p' | sort -n | head -1)
        if [[ -n "$first" ]] && (( first > 1 )); then
            run dd if="/dev/$disk" of="$dir/$disk-hidden-data-after-mbr" bs=512 skip=1 count=$(( first - 1 )) status=none
        fi
    fi
}

# Zápis metadat obrazu ve formátu Clonezilly (kap. 3 / 6)
# backup_write_meta <adresář> "<disky>" "<oddíly>"   (víc disků v jednom obrazu = jako savedisk sda sdb)
backup_write_meta() {
    local dir=$1 disks=$2 parts=$3 d p dpaths="" devs=()
    run mkdir -p "$dir"
    run_sh "echo '$disks' > '$dir/disk'"
    run_sh "echo '$parts' > '$dir/parts'"
    for d in $disks; do
        backup_write_disk_meta "$dir" "$d"
        dpaths+=" /dev/$d"
        for p in $(blk_children "$d"); do devs+=("/dev/$p"); done
    done
    run_sh "blkid -c /dev/null ${devs[*]} > '$dir/blkid.list' || true"
    run_sh "{ echo '# <Device name>   <File system>   <Size>'; lsblk -nro NAME,FSTYPE,SIZE ${devs[*]} | awk '{print \"/dev/\" \$1, (\$2==\"\" ? \"-\" : \$2), \$3}'; } > '$dir/dev-fs.list'"
    run_sh "lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MODEL,SERIAL$dpaths > '$dir/Info-lsblk.txt'"
    run_sh "echo 'Image was saved by restore.sh $VERSION at $(date -u '+%F %T') UTC' > '$dir/Info-saved-by-cmd.txt'"
    run_sh "echo 'This image was saved by Clonezilla-compatible restore.sh at $(date -u '+%F %T') UTC' > '$dir/clonezilla-img'"
}

# Příkaz zálohy oddílu (partclone → komprese → split po 4 GiB kvůli FAT32)
backup_part_cmd() {
    local dev=$1 fs=$2 out=$3 comp_cmd ext tool
    case "$COMPRESS" in
        zstd) comp_cmd="zstd -T0 -q -c"; ext=zst ;;
        gzip) if sys_have pigz; then comp_cmd="pigz -c"; else comp_cmd="gzip -c"; fi; ext=gz ;;
        *)    comp_cmd="cat"; ext=uncomp ;;
    esac
    case "$fs" in
        ext2|ext3|ext4|ntfs|vfat|xfs|btrfs|f2fs|exfat) tool="partclone.$fs" ;;
        *) tool="" ;;
    esac
    if [[ -n "$tool" ]] && sys_have "$tool"; then
        echo "$tool -c -s $dev -o - -L /tmp/partclone-save.log | $comp_cmd | split -a 2 -b 4096m - '$out.$fs-ptcl-img.$ext.'"
    else
        echo "partclone.dd -s $dev -o - -L /tmp/partclone-save.log | $comp_cmd | split -a 2 -b 4096m - '$out.dd-img.$ext.'"
    fi
}

# Záloha oddílů do adresáře obrazu (data, swap info)
backup_parts_data() {
    local dir=$1; shift
    local p fs i=0 n=$#
    for p in "$@"; do
        i=$((i + 1))
        fs=${BLK[$p.FSTYPE]:-}
        step "$i" "$n" "Záloha /dev/$p (${fs:-bez FS}, $(human "${BLK[$p.SIZE]:-0}"))"
        if [[ "$fs" == swap ]]; then
            run_sh "printf 'UUID=\"%s\"\nLABEL=\"%s\"\n' \"\$(blkid -s UUID -o value /dev/$p)\" \"\$(blkid -s LABEL -o value /dev/$p)\" > '$dir/swappt-$p.info'"
            continue
        fi
        [[ "$fs" == @(LVM2_member|linux_raid_member|crypto_LUKS) ]] && warn "$p ($fs) se zálohuje jen jako surová data (dd)."
        run_sh "$(backup_part_cmd "/dev/$p" "$fs" "$dir/$p")"
        (( SIMULATE || DRY_RUN )) && sim_progress "Záloha /dev/$p"
    done
    return 0
}

# Kontrolní součty obrazu
backup_checksums() { run_sh "cd '$1' && sha1sum -- *.*-img.* > SHA1SUMS"; }

# Rozbor položek zálohy: disk = celý disk, oddíl = jen on. Naplní BK_DISKS, BK_PARTS, BK_SWAPS
# (dohromady může být cokoliv: víc disků, víc oddílů, oddíly z různých disků, disk + oddíl jiného disku).
BK_DISKS=() BK_PARTS=() BK_SWAPS=()
backup_resolve() {
    local it d p t why n
    local -A whole=() picked=()
    BK_DISKS=() BK_PARTS=() BK_SWAPS=()
    (( $# )) || die "$E_USER" "Není co zálohovat."
    for it in "$@"; do
        it=${it#/dev/}
        case "${BLK[$it.TYPE]:-}" in
            disk)
                why=$(disk_protect_reason "$it") && die "$E_USER" "Disk $it nelze zálohovat: $why."
                whole[$it]=1
                [[ " ${BK_DISKS[*]} " == *" $it "* ]] || BK_DISKS+=("$it") ;;
            part)
                d=$(blk_parent "$it")
                picked[$it]=1
                [[ " ${BK_DISKS[*]} " == *" $d "* ]] || BK_DISKS+=("$d") ;;
            *) die "$E_USER" "'$it' není disk ani oddíl." ;;
        esac
    done
    for d in "${BK_DISKS[@]}"; do
        n=$(( ${#BK_PARTS[@]} + ${#BK_SWAPS[@]} ))
        for p in $(blk_children "$d"); do
            t=$(part_type "$d" "$p")
            if [[ -n "${whole[$d]:-}" ]]; then
                [[ "${t^^}" == @(5|F|85) ]] && continue          # rozšířený oddíl (MBR) se neukládá
                if [[ "${BLK[$p.FSTYPE]:-}" == swap ]]; then BK_SWAPS+=("$p"); else BK_PARTS+=("$p"); fi
            elif [[ -n "${picked[$p]:-}" ]]; then
                [[ "${t^^}" == @(5|F|85) ]] && die "$E_USER" "Oddíl $p je rozšířený kontejner – zálohuj jeho logické oddíly."
                [[ -z "${BLK[$p.MOUNTPOINT]:-}" ]] || die "$E_USER" "Oddíl $p je připojený (${BLK[$p.MOUNTPOINT]})."
                BK_PARTS+=("$p")
            fi
        done
        if [[ -n "${whole[$d]:-}" ]] && (( n == ${#BK_PARTS[@]} + ${#BK_SWAPS[@]} )); then
            die "$E_USER" "Disk $d nemá žádný oddíl k zálohování."
        fi
    done
    (( ${#BK_PARTS[@]} + ${#BK_SWAPS[@]} )) || die "$E_USER" "Vybrané položky neobsahují žádný oddíl k zálohování."
    return 0
}

# JEDEN obraz ze všech položek: backup_do <název> <položka…>
backup_do() {
    local name=$1 dir; shift
    dir="$PARTIMAG_MP/$name"
    backup_resolve "$@"
    (( SIMULATE )) || [[ ! -e "$dir" ]] || die "$E_USER" "Obraz $dir už existuje."
    info "Záloha ${BK_DISKS[*]} ($*) → $dir (komprese $COMPRESS)"
    backup_write_meta "$dir" "${BK_DISKS[*]}" "${BK_PARTS[*]}"
    if (( ${#BK_SWAPS[@]} )); then backup_parts_data "$dir" "${BK_SWAPS[@]}"; fi
    backup_parts_data "$dir" "${BK_PARTS[@]}"
    backup_checksums "$dir"
    ok "Obraz $name je hotový: $dir"
}

# Záloha libovolné kombinace: backup_run <název|""> <zvlášť 0|1> <položka…>
# zvlášť=0 → všechny položky do jednoho obrazu, zvlášť=1 → každá položka do vlastního obrazu (NÁZEV-položka).
# Nejdřív se zkontrolují všechny položky a názvy, teprve potom se začne zapisovat.
backup_run() {
    local name=$1 sep=$2 it i stamp
    shift 2
    local -a items=() names=() groups=()
    stamp=$(date +%Y%m%d-%H%M)
    for it in "$@"; do
        it=${it#/dev/}
        [[ " ${items[*]} " == *" $it "* ]] || items+=("$it")
    done
    (( ${#items[@]} )) || die "$E_USER" "Není co zálohovat."
    if (( sep && ${#items[@]} > 1 )); then
        for it in "${items[@]}"; do
            groups+=("$it")
            if [[ -n "$name" ]]; then names+=("$name-$it"); else names+=("img-$it-$stamp"); fi
        done
    else
        groups+=("${items[*]}")
        names+=("${name:-img-$(IFS=-; echo "${items[*]}")-$stamp}")
    fi
    for i in "${!groups[@]}"; do
        [[ "${names[i]}" =~ ^[A-Za-z0-9._+-]+$ ]] || die "$E_USER" "Název obrazu '${names[i]}' smí obsahovat jen písmena, číslice a . _ + -"
        # shellcheck disable=SC2086  # položky se mají rozdělit
        backup_resolve ${groups[i]}
        (( SIMULATE )) || [[ ! -e "$PARTIMAG_MP/${names[i]}" ]] || die "$E_USER" "Obraz $PARTIMAG_MP/${names[i]} už existuje – nic nebylo zapsáno."
    done
    for i in "${!groups[@]}"; do
        if (( ${#groups[@]} > 1 )); then step "$(( i + 1 ))" "${#groups[@]}" "Obraz ${names[i]}"; fi
        # shellcheck disable=SC2086
        backup_do "${names[i]}" ${groups[i]}
    done
    if (( ${#groups[@]} > 1 )); then ok "Hotovo: ${#groups[@]} obrazů (${names[*]})"; fi
    # data z mezipaměti na disk – teprve potom je záloha opravdu hotová (USB disk se může odpojit)
    info "Zapisuji data na disk (sync)…"
    run sync
    # souhrn: kde je záloha, jak je velká a jestli sedí kontrolní součty
    local sum="" d chk sz
    for i in "${!names[@]}"; do
        d="$PARTIMAG_MP/${names[i]}"
        if (( SIMULATE || DRY_RUN )); then chk="(simulace)"; sz="?"
        else
            if (cd "$d" && sha1sum -c --quiet SHA1SUMS >/dev/null 2>&1); then chk="kontrolní součty OK"; else chk="CHYBA kontrolních součtů!"; fi
            sz=$(human "$(du -sb "$d" 2>/dev/null | cut -f1)")
        fi
        sum+="Obraz:  ${names[i]}"$'\n'"Místo:  /dev/${IMAGES_PART:-?} → $d"$'\n'"Obsah:  $(tr '\n' ' ' <"$d/disk" 2>/dev/null) / oddíly $(tr '\n' ' ' <"$d/parts" 2>/dev/null)"$'\n'"Velikost: $sz, $chk"$'\n\n'
    done
    sum+="Data jsou zapsaná na disku. Disk se zálohou odpoj až po návratu do hlavního menu (nejlépe po vypnutí VM / Clonezilly)."
    [[ "$UI_BACKEND" == plain ]] || ui_msg "Záloha hotová.

$sum"
    [[ "$UI_BACKEND" == plain ]] && printf '%s\n%s' "Záloha hotová." "$sum"
    return 0
}

# Výběr položek zálohy (zaškrtávací seznam); výsledek v UI_REPLY. mode: disks | parts | both
backup_pick_items() {
    ui_theme green
    local mode=$1 d c why title items=()
    for d in $(disk_all); do
        why=$(disk_protect_reason "$d") || why=""
        case "$mode" in
            disks)
                [[ -n "$why" ]] && continue
                items+=("$d" "$(disk_desc "$d")" off) ;;
            parts)
                [[ -n "$why" ]] && continue
                for c in $(blk_children "$d"); do
                    items+=("$c" "$c  $(human "${BLK[$c.SIZE]:-0}") ${BLK[$c.FSTYPE]:--} ${BLK[$c.LABEL]:-} (${BLK[$d.MODEL]:-$d})" off)
                done ;;
            both)
                [[ -n "$why" ]] && continue
                items+=("$d" "CELÝ DISK $(disk_desc "$d")" off)
                for c in $(blk_children "$d"); do
                    items+=("$c" "   └ oddíl $c  $(human "${BLK[$c.SIZE]:-0}") ${BLK[$c.FSTYPE]:--} ${BLK[$c.LABEL]:-}" off)
                done ;;
        esac
    done
    (( ${#items[@]} )) || { ui_msg "Žádná položka k zálohování (chráněné disky se nenabízejí)."; return 1; }
    case "$mode" in
        disks) title="Disky k zálohování" ;;
        parts) title="Oddíly k zálohování" ;;
        *)     title="Disky a oddíly k zálohování" ;;
    esac
    while true; do
        ui_checklist "$title" "Co zálohovat? Položku označ MEZERNÍKEM (objeví se [*]), pak Potvrdit. Lze označit i více položek." "${items[@]}" && return 0
        (( UI_EMPTY )) || return 1
        ui_msg "Nic není označené. V seznamu najeď na položku, stiskni MEZERNÍK (objeví se [*]) a potom Potvrdit výběr."
    done
}

# Záloha z menu: backup_menu <disks|parts|both>
backup_menu() {
    local mode=$1 sep=0 name base
    local -a it=()
    backup_pick_items "$mode" || return 0
    read -ra it <<<"$UI_REPLY"
    # oddíly zálohovaných položek nesmí být místem pro uložení
    local x c
    SRC_EXCLUDE=""
    for x in "${it[@]}"; do
        if [[ "${BLK[$x.TYPE]:-}" == disk ]]; then
            for c in $(blk_children "$x"); do SRC_EXCLUDE+=" $c"; done
        else
            SRC_EXCLUDE+=" $x"
        fi
    done
    src_select rw || return 0
    ui_theme red
    if (( ${#it[@]} > 1 )); then
        ui_menu "Počet obrazů" "Vybráno: ${it[*]}. Jak to uložit?" \
            one "Všechno do JEDNOHO obrazu (jako Clonezilla savedisk / saveparts)" \
            sep "Každou položku do SAMOSTATNÉHO obrazu" || return 0
        [[ "$UI_REPLY" == sep ]] && sep=1
    fi
    if (( sep )); then
        base="img-$(date +%Y%m%d-%H%M)"
        ui_input "Předpona názvů obrazů (vzniknou PŘEDPONA-${it[0]}, PŘEDPONA-${it[1]}…)" "$base" || return 0
    else
        base="img-$(IFS=-; echo "${it[*]}")-$(date +%Y%m%d-%H%M)"
        ui_input "Název obrazu" "$base" || return 0
    fi
    name=$UI_REPLY
    backup_run "$name" "$sep" "${it[@]}"
}

# 3) Vytvoření obrazu disku (jednoho i více)
menu_03_backup_disk() { backup_menu disks; }

# 4) Vytvoření obrazu oddílů (jednoho i více, i z různých disků)
menu_04_backup_part() { backup_menu parts; }

# 3/3) Disky i oddíly dohromady
menu_03_backup_mixed() { backup_menu both; }

# Obsazené místo FS v bajtech (připojení jen pro čtení); prázdné, když to nejde
fs_used_bytes() {
    local dev=$1 fs=$2 m used
    (( SIMULATE )) && return 0
    [[ "$fs" == @(swap|"") ]] && return 0
    m=$(mktemp -d)
    if [[ "$fs" == ntfs ]]; then mount -t ntfs-3g -o ro "$dev" "$m" 2>/dev/null || { rmdir "$m"; return 0; }
    else mount -o ro "$dev" "$m" 2>/dev/null || { rmdir "$m"; return 0; }; fi
    used=$(df -B1 --output=used "$m" 2>/dev/null | tail -1 | tr -d ' ')
    umount "$m"; rmdir "$m"
    [[ "$used" =~ ^[0-9]+$ ]] && echo "$used"
    return 0
}

# Načte zdrojový DISK pro klon do pole jako obraz: clone_load <pole> <disk>
# Metadata (MBR, data za MBR, CHS) se jen přečtou do dočasné složky, data se čtou přímo z oddílů.
clone_load() {
    local -n _C=$1
    local s=$2 n d pname first ver
    _C=()
    layout_parse_sfdisk "$1" < <(sys_sfdisk_dump "$s")
    [[ -n "${_C[label]:-}" ]] || { ui_msg "Disk $s nemá tabulku oddílů."; return 1; }
    d=$(mktemp -d "${STATE_DIR:-/tmp}/clone.XXXXXX")
    if (( ! SIMULATE )); then
        dd if="/dev/$s" of="$d/$s-mbr" bs=512 count=1 status=none 2>/dev/null || true
        if [[ "${_C[label]}" == dos ]]; then
            first=$(sys_sfdisk_dump "$s" | sed -nE 's/.*start= *([0-9]+).*/\1/p' | sort -n | head -1)
            if [[ -n "$first" ]] && (( first > 1 )); then
                dd if="/dev/$s" of="$d/$s-hidden-data-after-mbr" bs=512 skip=1 count=$(( first - 1 )) status=none 2>/dev/null || true
            fi
        fi
        sfdisk -g "/dev/$s" 2>/dev/null | sed -nE 's/.*: ([0-9]+) cylinders, ([0-9]+) heads, ([0-9]+) sectors.*/cylinders=\1\nheads=\2\nsectors=\3/p' >"$d/$s-chs.sf" || true
    fi
    _C[src_disk]=$s _C[dir]=$d _C[disk_sectors]=$(( BLK[$s.SIZE] / _C[sector] ))
    for n in ${_C[parts]}; do
        pname=$(part_name "$s" "$n")
        _C[$n.pname]=$pname _C[$n.dir]=$d
        _C[$n.fs]=${BLK[$pname.FSTYPE]:-} _C[$n.label]=${BLK[$pname.LABEL]:-} _C[$n.fsuuid]=${BLK[$pname.UUID]:-}
        _C[$n.img]="" _C[$n.imgtype]="" _C[$n.comp]="" _C[$n.used]="" _C[$n.fssize]="" _C[$n.fatbits]=""
        if [[ -n "${_C[$n.fs]}" && "${_C[$n.fs]}" != swap ]]; then
            _C[$n.img]=device
            if sys_have "partclone.${_C[$n.fs]}"; then _C[$n.imgtype]="ptcl"; else _C[$n.imgtype]="dd"; fi
            _C[$n.used]=$(fs_used_bytes "/dev/$pname" "${_C[$n.fs]}")
        fi
        if [[ "${_C[$n.fs]}" == vfat ]]; then
            ver=""
            (( SIMULATE )) || ver=$(blkid -p -s VERSION -o value "/dev/$pname" 2>/dev/null || true)
            case "$ver" in FAT12) _C[$n.fatbits]=12 ;; FAT16) _C[$n.fatbits]=16 ;; *) _C[$n.fatbits]=32 ;; esac
        fi
    done
    layout_classify "$1"
    layout_detect_legacy "$1"
    layout_min "$1"
}

# 5) Klon disk → disk – stejný průběh jako obnova z obrazu (zvětšení, zmenšení, režimy A–D, boot kód, hidden sectors)
menu_05_clone() {
    local s t mode rc=0 summary
    disk_select_source "Zdrojový disk klonu" || return 0
    s=$UI_REPLY
    clone_load SRC "$s" || return 0
    check_deps_image SRC
    CLONE_SRC=$s   # zdroj nesmí být cílem
    disk_select_target "Cílový disk klonu ($s → ?)" || return 0
    t=$UI_REPLY
    [[ "${BLK[$t.SIZE]:-0}" -lt 64000000000 ]] && [[ "${SRC[mode]}" == legacy ]] && SMALL_MEDIA=1
    restore_choose_mode SRC || return 0
    mode=$UI_REPLY
    if [[ "$mode" == manual ]]; then
        layout_compute SRC NEW "$t" last >/dev/null 2>&1 || true
        layout_ask_sizes SRC NEW "$t" || rc=$?
    else
        layout_compute SRC NEW "$t" "$mode" || rc=$?
    fi
    layout_table SRC NEW | ui_text "Rozložení klonu $s → $t: původní → nové"
    if (( rc == E_SPACE )); then
        die "$E_SPACE" "Data z disku $s se na disk $t nevejdou. Nic nebylo zapsáno."
    elif (( rc )); then
        return "$E_USER"
    fi
    restore_check_tmp SRC NEW
    summary=$(
        disk_summary "$t"
        echo
        echo "Klon: /dev/$s → /dev/$t"
        echo "Režim: $mode, $([[ "${SRC[mode]}" == legacy ]] && echo 'legacy (Beckhoff)' || echo obecný)"
        echo
        layout_table SRC NEW
    )
    ui_confirm_disk "$t" "$summary" || return 0
    restore_execute SRC NEW "$t"
    LAST_TARGET=$t
}

# Spuštění čtecího příkazu (ověření apod.) – v simulaci jen výpis
ro_sh() {
    if (( SIMULATE )); then _show_cmd "$1"; return 0; fi
    _log_file "\$ $1"
    bash -o pipefail -c "$1"
}

# 6) Informace o obrazu + ověření integrity (všechny disky v obrazu)
menu_06_image_info() {
    local n d chk=0
    local -a disks=()
    src_select ro || return 0
    img_select || return 0
    mapfile -t disks < <(img_disks "$IMG_DIR")
    (( ${#disks[@]} > 1 )) && info "Záloha obsahuje ${#disks[@]} disky: ${disks[*]}"
    if sys_have partclone.chkimg && ui_yesno "Ověřit i data obrazu přes partclone.chkimg (může trvat dlouho)?"; then chk=1; fi
    for d in "${disks[@]}"; do
        img_load "$IMG_DIR" SRC "$d"
        img_info SRC
        if img_verify SRC; then ok "Disk $d: všechny oddíly z 'parts' mají data."; fi
        (( chk )) || continue
        for n in ${SRC[parts]}; do
            [[ "${SRC[$n.imgtype]}" == ptcl ]] || continue
            step "$n" "$(wc -w <<<"${SRC[parts]}")" "Kontrola ${SRC[$n.pname]}"
            if ro_sh "$(img_stream_cmd "$IMG_DIR" "${SRC[$n.pname]}") | partclone.chkimg -s - -L /tmp/partclone-chk.log"; then ok "${SRC[$n.pname]} v pořádku"
            else err "${SRC[$n.pname]}: obraz je poškozený!"; fi
        done
    done
    if (( chk )) && [[ -r "$IMG_DIR/SHA1SUMS" ]]; then ro_sh "cd '$IMG_DIR' && sha1sum -c SHA1SUMS"; fi
    return 0
}

# 7) Připojení obsahu obrazu (obnova do dočasného souboru, mount jen pro čtení)
menu_07_mount_image() {
    local n items=() tmp l mp
    src_select ro || return 0
    img_select || return 0
    img_pick_disk "$IMG_DIR" || return 0
    img_load "$IMG_DIR" SRC "$UI_REPLY"
    for n in ${SRC[parts]}; do
        [[ -n "${SRC[$n.img]}" ]] && items+=("$n" "${SRC[$n.pname]} ${SRC[$n.fs]} $(human $(( SRC[$n.size] * SRC[sector] )))")
    done
    (( ${#items[@]} )) || { ui_msg "Obraz neobsahuje žádný oddíl s daty."; return 0; }
    ui_menu "Prohlížení obrazu" "Který oddíl připojit?" "${items[@]}" || return 0
    n=$UI_REPLY
    ui_input "Adresář pro dočasný soubor (potřeba až $(human $(( SRC[$n.size] * SRC[sector] ))), řídký soubor)" "${OPT_TMPDIR:-/tmp}" || return 0
    tmp="$UI_REPLY/restore-view-${SRC[$n.pname]}.img"
    run truncate -s $(( SRC[$n.size] * SRC[sector] )) "$tmp"
    loop_attach "$tmp"; l=$LOOP_LAST
    run_sh "$(restore_part_cmd SRC "$n" "$l")"
    (( SIMULATE || DRY_RUN )) && sim_progress "Rozbalení ${SRC[$n.pname]}"
    tmp_mount "$l" ro; mp=$TMP_LAST
    ui_msg "Obsah oddílu ${SRC[$n.pname]} je připojený v $mp (jen pro čtení). Prohlédni si ho v jiné konzoli (Alt+F2) nebo po ukončení skriptu; po potvrzení se odpojí a dočasný soubor smaže."
    ui_pause
    tmp_umount "$mp"
    loop_detach "$l"
    run rm -f "$tmp"
}

# 8) Informace o discích
menu_08_disk_info() {
    local d items=()
    disk_table | ui_text "Disky"
    for d in $(disk_all); do items+=("$d" "$(disk_desc "$d")"); done
    ui_menu "Detail disku" "Vyber disk:" "${items[@]}" || return 0
    d=$UI_REPLY
    {
        echo "== /dev/$d =="
        printf 'Model: %s  Sériové: %s  Sběrnice: %s  Sektor: %s B  SSD: %s\n' "${BLK[$d.MODEL]:--}" "${BLK[$d.SERIAL]:--}" \
            "${BLK[$d.TRAN]:--}" "${BLK[$d.LOG_SEC]:-?}" "$([[ "${BLK[$d.ROTA]:-1}" == 0 ]] && echo ano || echo ne)"
        echo "TRIM: $(sys_discard "$d")"
        echo; echo "-- Tabulka oddílů (sfdisk --dump) --"
        sys_sfdisk_dump "$d"
        echo; echo "-- SMART --"
        sys_smart "$d"
    } | ui_text "Disk $d"
}

# 9) Editor oddílů
menu_09_editor() {
    local d
    disk_select_target "Disk pro editor oddílů" || return 0
    d=$UI_REPLY
    editor_run "$d" || true
}

# 10) Kontrola / oprava FS
menu_10_fsck() {
    local p repair=0
    part_select "Kontrola souborového systému" || return 0
    p=$UI_REPLY
    ui_yesno "Opravovat chyby (jinak jen kontrola)?" && repair=1
    fs_check "${BLK[$p.FSTYPE]:-}" "/dev/$p" "$repair"
}

# 11) Opravy bootu
menu_11_boot() {
    local d
    ui_menu "Opravy bootu" "" \
        efi "Vytvořit UEFI boot záznam (efibootmgr)$(menu_avail efibootmgr)" \
        grub "Reinstalace GRUB přes chroot" \
        mbr "Obnovit boot kód MBR (446 B) z obrazu" \
        gpt "Přesunout záložní GPT na konec disku" || return 0
    local what=$UI_REPLY
    disk_select_target "Disk" || return 0
    d=$UI_REPLY
    case "$what" in
        efi)  if (( ! SIMULATE )) && [[ ! -d /sys/firmware/efi ]]; then
                  ui_msg "Počítač je spuštěný v režimu BIOS (Legacy) – UEFI boot záznam z něj zapsat nejde. Spusť Clonezillu v režimu UEFI."
                  return 0
              fi
              ui_input "Číslo EFI oddílu" "1" || return 0
              run efibootmgr -c -d "/dev/$d" -p "$UI_REPLY" -L "Windows Boot Manager" -l '\EFI\Microsoft\Boot\bootmgfw.efi'
              info "Záznam v NVRAM platí jen pro tento počítač." ;;
        grub) part_select "Kořenový oddíl Linuxu" || return 0
              local r=$UI_REPLY m=/tmp/restore-chroot
              run mkdir -p "$m"; run mount "/dev/$r" "$m"
              for x in dev proc sys run; do run mount --bind "/$x" "$m/$x"; done
              local grc=0
              run_try chroot "$m" grub-install "/dev/$d" || grc=$?
              (( grc )) || run_try chroot "$m" update-grub || grc=$?
              for x in run sys proc dev; do run_try umount "$m/$x" || true; done
              run_try umount "$m" || true
              if (( grc )); then err "Reinstalace GRUB selhala (kód $grc) – je /dev/$r kořenový oddíl Linuxu s balíčkem grub?"
              else ok "GRUB na /dev/$d přeinstalován."; fi ;;
        mbr)  src_select ro || return 0
              img_select || return 0
              local s; read -r s _ <"$IMG_DIR/disk"
              [[ -r "$IMG_DIR/$s-mbr" ]] || { ui_msg "Záloha ${IMG_DIR##*/} neobsahuje boot kód MBR ($s-mbr)."; return 0; }
              ui_confirm_disk "$d" "$(disk_summary "$d"; echo "Zapíše se boot kód MBR (446 B) ze zálohy ${IMG_DIR##*/}; tabulka oddílů zůstane.")" || return 0
              run dd if="$IMG_DIR/$s-mbr" of="/dev/$d" bs=446 count=1 conv=notrunc status=none
              ok "Boot kód MBR na /dev/$d obnoven ze zálohy ${IMG_DIR##*/}." ;;
        gpt)  [[ "$(sys_sfdisk_dump "$d" | sed -n 's/^label: //p')" == gpt ]] || { ui_msg "Disk /dev/$d nemá tabulku GPT."; return 0; }
              run sfdisk --relocate gpt-bak-std "/dev/$d"
              ok "Záložní GPT je na konci disku /dev/$d." ;;
    esac
}

# 12) Převod MBR ↔ GPT
menu_12_convert() {
    local d label
    disk_select_target "Převod tabulky oddílů" || return 0
    d=$UI_REPLY
    label=$(sys_sfdisk_dump "$d" | sed -n 's/^label: //p')
    warn "Převod tabulky může znemožnit boot (BIOS ↔ UEFI). Data oddílů zůstávají, ale udělej si zálohu."
    ui_confirm_disk "$d" "$(disk_summary "$d"; echo "Aktuální tabulka: ${label:-žádná}")" || return 0
    local bk
    bk="/tmp/backup-pt-$d-$(date +%Y%m%d%H%M).sf"
    if [[ -n "$(src_find_mounted)" ]]; then
        findmnt -no OPTIONS "$PARTIMAG_MP" 2>/dev/null | grep -qw ro && run mount -o remount,rw "$PARTIMAG_MP"
        bk="$PARTIMAG_MP/backup-pt-$d-$(date +%Y%m%d%H%M).sf"
    fi
    run_sh "sfdisk --dump /dev/$d > '$bk'"
    info "Záloha tabulky oddílů: $bk (vrácení: sfdisk /dev/$d < $bk)"
    if [[ "$label" == gpt ]]; then
        (( $(sys_sfdisk_dump "$d" | grep -c '^/dev/') <= 4 )) || die "$E_USER" "GPT s více než 4 oddíly nejde převést na MBR (jen 4 primární oddíly)."
        run sgdisk -m "$(sys_sfdisk_dump "$d" | grep -c '^/dev/' | xargs seq -s: 1)" "/dev/$d"
        ok "Disk /dev/$d převeden GPT → MBR."
    else
        run sgdisk -g "/dev/$d"
        ok "Disk /dev/$d převeden MBR → GPT."
    fi
    run_try partprobe "/dev/$d" || true
}

# 13) Bezpečné smazání disku
menu_13_wipe() {
    local d
    disk_select_target "Bezpečné smazání" || return 0
    d=$UI_REPLY
    ui_menu "Metoda smazání /dev/$d" "" \
        wipefs "Smazat signatury a tabulku (rychlé)" \
        discard "TRIM celého disku – blkdiscard (SSD)$(menu_avail blkdiscard)" \
        nvme "NVMe format --ses=1$(menu_avail nvme)" \
        ata "ATA Secure Erase (hdparm)$(menu_avail hdparm)" || return 0
    local how=$UI_REPLY
    ui_confirm_disk "$d" "$(disk_summary "$d"; echo "Metoda: $how – NEVRATNÉ")" || return 0
    ui_yesno "Opravdu NEVRATNĚ smazat /dev/$d ($how)?" || return 0
    ui_confirm_disk "$d" "Druhé potvrzení." || return 0
    case "$how" in
        wipefs)  run wipefs -a "/dev/$d"; run sgdisk --zap-all "/dev/$d" ;;
        discard) run blkdiscard -f "/dev/$d" ;;
        nvme)    run nvme format "/dev/$d" --ses=1 ;;
        ata)     run hdparm --user-master u --security-set-pass p "/dev/$d"
                 run hdparm --user-master u --security-erase p "/dev/$d" ;;
    esac
}

# 14) Delegace na Clonezillu (ocs-sr)
menu_14_ocs() {
    local tgt opts
    sys_have ocs-sr || { ui_msg "ocs-sr není k dispozici."; return 0; }
    src_select ro || return 0
    img_select || return 0
    disk_select_target "Cíl pro ocs-sr" || return 0
    tgt=$UI_REPLY
    opts="-e1 auto -e2 -r -j2 -k1 -icds -scr -p true"
    sys_ocs_help | grep -q -- '-k1' || warn "ocs-sr --help nezná -k1 – zkontroluj přepínače."
    ui_msg "Příkaz: ocs-sr $opts restoredisk ${IMG_DIR##*/} $tgt"
    ui_confirm_disk "$tgt" "$(disk_summary "$tgt")" || return 0
    [[ "$UI_BACKEND" == plain ]] || clear
    # shellcheck disable=SC2086
    run ocs-sr $opts restoredisk "${IMG_DIR##*/}" "$tgt"
    run sync
    ui_msg "Clonezilla (ocs-sr) dokončila obnovu zálohy ${IMG_DIR##*/} na /dev/$tgt.
Podrobný výpis Clonezilly: /var/log/clonezilla.log"
}

# 15) Nastavení
menu_15_settings() {
    while true; do
        ui_menu "Nastavení" "" \
            dry "Dry-run: $( (( DRY_RUN )) && echo ZAPNUTO || echo vypnuto)" \
            comp "Komprese nových obrazů: $COMPRESS" \
            tmp "Dočasný adresář: ${OPT_TMPDIR:-$PARTIMAG_MP}" \
            ui "Rozhraní: $UI_BACKEND" \
            kbd "Klávesnice: ${KEYMAP_CUR:-$KEYMAP_WANT}" || return 0
        case "$UI_REPLY" in
            dry)  if (( SIMULATE )); then info "V simulaci se nikdy nic nezapisuje."; else DRY_RUN=$(( 1 - DRY_RUN )); fi ;;
            comp) ui_menu "Komprese" "" zstd "zstd -T0 (doporučeno)" gzip "gzip/pigz" none "bez komprese" && COMPRESS=$UI_REPLY ;;
            tmp)  ui_input "Dočasný adresář" "${OPT_TMPDIR:-}" && OPT_TMPDIR=$UI_REPLY ;;
            ui)   ui_menu "Rozhraní" "" dialog dialog whiptail whiptail plain text && UI_BACKEND=$UI_REPLY && ui_init ;;
            kbd)  ui_menu "Klávesnice" "" cz "Y a Z jako na české klávesnici (QWERTZ)" us "americká (QWERTY)" && KEYMAP_WANT=$UI_REPLY && kbd_init ;;
        esac
    done
}

# " (nedostupné: chybí X)", pokud nástroj chybí
menu_avail() {
    local c
    for c in "$@"; do sys_have "$c" || { printf ' (nedostupné: chybí %s)' "$c"; return 0; }; done
    return 0
}

# Spuštění akce menu v subshellu: chyba (die) ukončí jen akci, ne celý skript
menu_action() {
    local rc=0
    # každá akce začíná bez varování z předchozích akcí (souhrn ukazuje jen svoje)
    ( WARNINGS=(); trap action_cleanup EXIT; "$@" ) || rc=$?
    case "$rc" in
        0) ;;
        "$E_USER") info "Akce zrušena." ;;
        "$E_SPACE") err "Akce skončila: nedostatek místa (kód $rc)." ;;
        *) err "Akce skončila s chybou (kód $rc) – podrobnosti v logu $LOG_FILE." ;;
    esac
    # disk se zálohami po akci jen pro čtení: data jsou na disku a odpojení / vypnutí VM je bezpečné
    if (( ! SIMULATE && ! DRY_RUN )) && findmnt -no OPTIONS "$PARTIMAG_MP" 2>/dev/null | grep -qw rw; then
        sync
        mount -o remount,ro "$PARTIMAG_MP" 2>/dev/null || true
    fi
    ui_pause
    blk_load
    live_detect
    src_refresh
}

# Hlavní menu – jen volby 0–9, aby číslo v dialogu vždy vybralo jednoznačně jednu položku
menu_main() {
    local title="restore.sh $VERSION – Clonezilla offline nástroj"
    (( SIMULATE )) && title+=" [SIMULACE: $SIM_SCENARIO]"
    (( DRY_RUN )) && title+=" [DRY-RUN]"
    while true; do
        ui_menu "$title" "Flashka: ${LIVE_DISK:-?}, disk s obrazy: ${IMAGES_DISK:-nepřipojen}" \
            1 "Obnovit obraz na disk (automatický přepočet velikosti)" \
            2 "Obnovit jen vybrané oddíly z obrazu" \
            3 "Vytvořit obraz (disky / oddíly)  →" \
            4 "Klonovat disk → disk (s přepočtem velikosti)" \
            5 "Obraz: informace, ověření, prohlížení obsahu  →" \
            6 "Informace o discích (typ, výrobce, SMART, TRIM)" \
            7 "Editor oddílů: velikost, přesun, smazání, LABEL" \
            8 "Opravy: souborové systémy, boot, MBR ↔ GPT  →" \
            9 "Další: smazání disku, Clonezilla (ocs-sr), nastavení  →" \
            0 "Konec" || return 0
        case "$UI_REPLY" in
            1) menu_action restore_disk ;;
            2) menu_action menu_02_restore_parts ;;
            3) ui_menu "Vytvořit obraz" "Formát kompatibilní s Clonezillou." \
                   1 "Obraz disku (jednoho nebo více)" \
                   2 "Obraz oddílů (jednoho nebo více)" \
                   3 "Disky i oddíly dohromady" || continue
               case "$UI_REPLY" in
                   1) menu_action menu_03_backup_disk ;;
                   2) menu_action menu_04_backup_part ;;
                   3) menu_action menu_03_backup_mixed ;;
               esac ;;
            4) menu_action menu_05_clone ;;
            5) ui_menu "Obraz" "" \
                   1 "Informace o obrazu + ověření integrity$(menu_avail partclone.chkimg)" \
                   2 "Připojit / prohlížet obsah obrazu$(menu_avail losetup)" || continue
               case "$UI_REPLY" in
                   1) menu_action menu_06_image_info ;;
                   2) menu_action menu_07_mount_image ;;
               esac ;;
            6) menu_action menu_08_disk_info ;;
            7) menu_action menu_09_editor ;;
            8) ui_menu "Opravy" "" \
                   1 "Kontrola / oprava souborových systémů" \
                   2 "Opravy bootu (EFI, GRUB, MBR, záložní GPT)" \
                   3 "Převod MBR ↔ GPT$(menu_avail sgdisk)" || continue
               case "$UI_REPLY" in
                   1) menu_action menu_10_fsck ;;
                   2) menu_action menu_11_boot ;;
                   3) menu_action menu_12_convert ;;
               esac ;;
            9) ui_menu "Další" "" \
                   1 "Bezpečné smazání disku" \
                   2 "Přepnutí do Clonezilly (ocs-sr)$(menu_avail ocs-sr)" \
                   3 "Nastavení" || continue
               case "$UI_REPLY" in
                   1) menu_action menu_13_wipe ;;
                   2) menu_action menu_14_ocs ;;
                   3) menu_15_settings ;;
               esac ;;
            0) return 0 ;;
        esac
    done
}

# =============================================================================
# SIMULACE (kap. 10.1)
# =============================================================================
sim_list() {
    local d
    for d in "$SCRIPT_DIR"/sim/*/; do
        [[ -f "$d/scenario.conf" ]] && basename "$d"
    done
    return 0
}

sim_init() {
    SIM_DIR="$SCRIPT_DIR/sim/$SIM_SCENARIO"
    [[ -f "$SIM_DIR/scenario.conf" ]] || die "$E_USER" "Neznámý scénář '$SIM_SCENARIO'. Dostupné: $(sim_list | tr '\n' ' ')"
    local SIM_DESC=""
    # shellcheck source=/dev/null
    source "$SIM_DIR/scenario.conf"
    sim_guard_install
    printf '%s\n' "${C_MAG}${C_BLD}*** SIMULACE '$SIM_SCENARIO': $SIM_DESC – nic se nezapisuje ***${C_OFF}"
}

# =============================================================================
# ÚKLID A TRAPY
# =============================================================================

# Úklid po jedné akci (loop zařízení, dočasné mounty)
action_cleanup() {
    local i
    for (( i=${#TMP_MOUNTS[@]}-1; i>=0; i-- )); do
        if (( SIMULATE )); then _show_cmd "umount ${TMP_MOUNTS[i]}"; else umount "${TMP_MOUNTS[i]}" 2>/dev/null || true; fi
    done
    TMP_MOUNTS=()
    for i in "${LOOP_DEVS[@]}"; do
        if (( SIMULATE )); then _show_cmd "losetup -d $i"; else losetup -d "$i" 2>/dev/null || true; fi
    done
    LOOP_DEVS=()
}

# Kopie logu na flashku do restore-logs/. Live systém má flashku připojenou jen pro čtení –
# na chvíli ji přepojí pro zápis a pak vrátí zpět (FAT; na ISO 9660 zapsat nejde, pak se nic nestane).
log_copy_flash() {
    (( SIMULATE )) && return 0
    [[ -n "$LIVE_MEDIUM" && -d "$LIVE_MEDIUM" && -f "$LOG_FILE" ]] || return 0
    local remount=0
    if [[ ! -w "$LIVE_MEDIUM" ]]; then
        mount -o remount,rw "$LIVE_MEDIUM" 2>/dev/null || return 0
        remount=1
    fi
    mkdir -p "$LIVE_MEDIUM/restore-logs" 2>/dev/null && cp "$LOG_FILE" "$LIVE_MEDIUM/restore-logs/" 2>/dev/null
    sync
    (( remount )) && mount -o remount,ro "$LIVE_MEDIUM" 2>/dev/null
    return 0
}

on_err() {
    local line=$1 cmd=$2 rc=$3
    err "Chyba na řádku $line (kód $rc): $cmd"
}

on_exit() {
    local rc=$?
    set +e
    action_cleanup
    src_umount
    _log_file "=== konec, kód $rc ==="
    log_copy_flash
    [[ -n "${STATE_DIR:-}" ]] && rm -rf "$STATE_DIR"
    (( rc )) && [[ -n "$LOG_FILE" ]] && printf 'Log: %s\n' "$LOG_FILE" >&2
    exit "$rc"
}

# Dočasné připojení (eviduje se pro úklid i při chybě); výsledek v TMP_LAST
# Pozor: volat přímo, NE přes $(…) – evidence by se ztratila v podprocesu.
tmp_mount() {
    local dev=$1 opts=$2 dir
    dir=$(mktemp -d /tmp/restore-mnt.XXXXXX)
    TMP_LAST=$dir
    if (( SIMULATE || DRY_RUN )); then _show_cmd "mount -o $opts $dev $dir"; return 0; fi
    if [[ "$(blkid -c /dev/null -s TYPE -o value "$dev" 2>/dev/null)" == ntfs ]]; then
        mount -t ntfs-3g -o "$opts" "$dev" "$dir"
    else
        mount -o "$opts" "$dev" "$dir"
    fi
    TMP_MOUNTS+=("$dir")
}

# Odpojení dočasného mountu
tmp_umount() {
    local dir=$1 i
    if (( SIMULATE || DRY_RUN )); then _show_cmd "umount $dir"; rmdir "$dir" 2>/dev/null; return 0; fi
    sync
    umount "$dir"
    rmdir "$dir" 2>/dev/null || true
    for i in "${!TMP_MOUNTS[@]}"; do [[ "${TMP_MOUNTS[i]}" == "$dir" ]] && unset 'TMP_MOUNTS[i]'; done
    return 0
}

# Připojení souboru jako loop zařízení; výsledek v LOOP_LAST (volat přímo, ne přes $(…))
loop_attach() {
    local f=$1
    if (( SIMULATE || DRY_RUN )); then _show_cmd "losetup -f --show $f"; LOOP_LAST=/dev/loopX; return 0; fi
    LOOP_LAST=$(losetup -f --show "$f")
    LOOP_DEVS+=("$LOOP_LAST")
    _log_file "losetup $f → $LOOP_LAST"
}

loop_detach() {
    local l=$1 i
    if (( SIMULATE || DRY_RUN )); then _show_cmd "losetup -d $l"; return 0; fi
    losetup -d "$l"
    for i in "${!LOOP_DEVS[@]}"; do [[ "${LOOP_DEVS[i]}" == "$l" ]] && unset 'LOOP_DEVS[i]'; done
    return 0
}

# Minimální velikost FS v bajtech (s rezervou 10 %, min. 16 MiB); prázdné = nelze zjistit
fs_min_bytes() {
    local fs=$1 dev=$2 out blocks bs min
    (( SIMULATE )) && return 0
    case "$fs" in
        ext2|ext3|ext4)
            e2fsck -fy "$dev" >/dev/null 2>&1 || true
            blocks=$(resize2fs -P "$dev" 2>/dev/null | sed -nE 's/.*minimum size of the filesystem: ([0-9]+).*/\1/p')
            bs=$(dumpe2fs -h "$dev" 2>/dev/null | sed -nE 's/^Block size: +([0-9]+).*/\1/p')
            [[ -n "$blocks" && -n "$bs" ]] && min=$(( blocks * bs )) ;;
        ntfs)
            out=$(ntfsresize --info --force --no-progress-bar "$dev" 2>/dev/null || true)
            min=$(sed -nE 's/.*resize at ([0-9]+) bytes.*/\1/p' <<<"$out" | head -1) ;;
        vfat|fat*|exfat)
            min=$(fs_used_bytes "$dev" "$fs") ;;
    esac
    [[ -z "${min:-}" ]] && return 0
    local res=$(( min / 10 ))
    (( res < 16 * MiB )) && res=$(( 16 * MiB ))
    echo $(( min + res ))
}

# Adresář pro dočasné soubory (u disku s obrazy přepojí pro zápis)
# Kam s dočasnými soubory (řídké obrazy oddílů): --tmpdir, jinak disk s obrazy – ale ne FAT/exFAT
# (FAT pojme soubor jen do 4 GiB, ani jeden neumí řídké soubory) a ne nepřipojený adresář; pak paměť (/tmp)
tmp_base() {
    local fs
    if [[ -n "$OPT_TMPDIR" ]]; then echo "$OPT_TMPDIR"; return 0; fi
    if (( SIMULATE )); then echo "$PARTIMAG_MP"; return 0; fi
    fs=$(findmnt -no FSTYPE "$PARTIMAG_MP" 2>/dev/null || true)
    if [[ -z "$fs" || "$fs" == @(vfat|msdos|exfat) ]]; then echo "/tmp"; else echo "$PARTIMAG_MP"; fi
}

tmp_workdir() {
    local d
    d=$(tmp_base)
    if [[ "$d" == /tmp && -z "$OPT_TMPDIR" ]]; then
        info "Dočasná data se uloží do paměti (/tmp) – disk se zálohami je FAT/exFAT nebo není připojený." >&2
    fi
    if [[ "$d" == "$PARTIMAG_MP" && -z "$OPT_TMPDIR" ]]; then
        if (( ! SIMULATE && ! DRY_RUN )) && findmnt -no OPTIONS "$PARTIMAG_MP" 2>/dev/null | grep -qw ro; then
            info "Disk s obrazy se pro dočasný soubor přepojí pro zápis." >&2
            mount -o remount,rw "$PARTIMAG_MP"
        elif (( SIMULATE || DRY_RUN )); then
            run mount -o remount,rw "$PARTIMAG_MP" >&2
        fi
    fi
    echo "$d"
}

# Bezpečné zvětšení FAT: nejdřív kopie obsahu do dočasného souboru, pak fatresize + kontrola;
# když fatresize chybí, selže nebo kontrola neprojde, FAT se vytvoří znovu ze zálohy (stejné ID, typ, label).
# fs_fat_rebuild <zařízení> <původní_bajty> <začátek_oddílu> [fs]
# Obsazená data FAT/exFAT do dočasného řídkého souboru: fat_save_tmp <zařízení> <bajty FS> <fs> → FAT_TMP_IMG, FAT_TMP_LOOP
FAT_TMP_IMG="" FAT_TMP_LOOP=""
fat_save_tmp() {
    local dev=$1 old=$2 fs=$3 tool="partclone.vfat"
    [[ "$fs" == exfat ]] && tool="partclone.exfat"
    FAT_TMP_IMG="$(tmp_workdir)/restore-fat-$$.img"
    run truncate -s "$old" "$FAT_TMP_IMG"
    loop_attach "$FAT_TMP_IMG"; FAT_TMP_LOOP=$LOOP_LAST
    if sys_have "$tool"; then
        run_sh "$tool -c -q -s $dev -o - -L /tmp/partclone-fat.log 2>>/tmp/partclone-fat.log | $tool -r -s - -o $FAT_TMP_LOOP -L /tmp/partclone-fat.log"
    else
        run dd if="$dev" of="$FAT_TMP_LOOP" bs=4M count=$(( (old + 4 * MiB - 1) / (4 * MiB) )) conv=sparse status=progress
    fi
}
# Nový FS přes celý (nový) oddíl a data z dočasného souboru zpět: fat_restore_tmp <zařízení> <začátek> <fs>
fat_restore_tmp() {
    local dev=$1 start=$2 fs=$3
    if [[ "$fs" == exfat ]]; then fs_exfat_copy "$FAT_TMP_LOOP" "$dev"; else fs_fat_copy "$FAT_TMP_LOOP" "$dev" "$start"; fi
    loop_detach "$FAT_TMP_LOOP"
    run rm -f "$FAT_TMP_IMG"
    FAT_TMP_IMG="" FAT_TMP_LOOP=""
}

fs_fat_rebuild() {
    local dev=$1 old=$2 start=$3 fs=${4:-vfat} dir img l used tool
    dir=$(tmp_workdir)
    img="$dir/restore-fat-$$.img"
    used=$(fs_used_bytes "$dev" "$fs")
    tool="partclone.vfat"; [[ "$fs" == exfat ]] && tool="partclone.exfat"
    local fsname="FAT" usedh="?"
    [[ "$fs" == exfat ]] && fsname="exFAT"
    [[ -n "$used" ]] && usedh=$(human "$used")
    info "Zvětšení $fsname na $dev: obsazená data ($usedh) se dočasně uloží do $dir, pak se $fsname vytvoří znovu přes celý oddíl a data se vrátí (stejné ID a label)."
    run truncate -s "$old" "$img"
    loop_attach "$img"; l=$LOOP_LAST
    # čtou se jen obsazené bloky (partclone), ne celý svazek
    if sys_have "$tool"; then
        step 1 3 "Záloha obsazených dat z $dev"
        run_sh "$tool -c -q -s $dev -o - -L /tmp/partclone-fat.log 2>>/tmp/partclone-fat.log | $tool -r -s - -o $l -L /tmp/partclone-fat.log"
    else
        step 1 3 "Záloha svazku z $dev (dd)"
        run dd if="$dev" of="$l" bs=4M count=$(( (old + 4 * MiB - 1) / (4 * MiB) )) conv=sparse status=progress
    fi
    step 2 3 "Nový $fsname přes celý oddíl $dev a kopie souborů"
    if [[ "$fs" == exfat ]]; then fs_exfat_copy "$l" "$dev"; else fs_fat_copy "$l" "$dev" "$start"; fi
    step 3 3 "Úklid dočasných dat"
    loop_detach "$l"
    run rm -f "$img"
}

# Nová FAT na cíli se stejným volume ID, labelem a typem FAT + kopie souborů + boot kód (kap. 5.7/8)
# Kopie souborů mezi FAT / exFAT s průběhem: files_copy <zdroj> <cíl> [keep = nepřepisovat existující]
files_copy() {
    local src=$1 dst=$2 keep=${3:-}
    if sys_have rsync; then
        run rsync -rt --modify-window=2 --info=progress2 --no-inc-recursive ${keep:+--ignore-existing} "$src/" "$dst/"
    else
        run cp -r ${keep:+-n} --preserve=timestamps "$src/." "$dst/"
    fi
}

# Nový exFAT přes celý cílový oddíl a kopie souborů (stejný label a sériové číslo):
# fs_exfat_copy <zdroj> <cíl>
fs_exfat_copy() {
    local src=$1 dst=$2 uuid label ms md
    if (( SIMULATE || DRY_RUN )); then
        uuid="ABCD-1234" label=""
    else
        uuid=$(blkid -p -s UUID -o value "$src")
        label=$(blkid -p -s LABEL -o value "$src")
    fi
    sys_have mkfs.exfat || die "$E_DEP" "Chybí mkfs.exfat (exfatprogs) – exFAT nelze vytvořit znovu."
    run mkfs.exfat ${label:+-L "$label"} "$dst"    # bez -q: exfatprogs 1.2.0 (Clonezilla 3.1) ho nezná
    if [[ -n "$uuid" ]] && sys_have tune.exfat; then run tune.exfat -I "0x${uuid//-/}" "$dst"; fi
    tmp_mount "$src" ro; ms=$TMP_LAST
    tmp_mount "$dst" rw; md=$TMP_LAST
    files_copy "$ms" "$md"
    tmp_umount "$md"
    tmp_umount "$ms"
    info "exFAT na $dst vytvořen znovu přes celý oddíl (label ${label:--}, sériové číslo $uuid), soubory zkopírovány."
}

# Číslo z boot sektoru (little endian): bpb <zařízení> <offset> <bajtů>
bpb() { dd if="$1" bs=1 skip="$2" count="$3" status=none 2>/dev/null | od -An -tu"$3" | tr -d ' '; }

# Bajtová pozice kořenového adresáře FAT: fat_root_off <zařízení> <12|16|32>
fat_root_off() {
    local dev=$1 bits=$2 bps res nf fsz
    bps=$(bpb "$dev" 11 2); res=$(bpb "$dev" 14 2); nf=$(bpb "$dev" 16 1)
    if (( bits == 32 )); then
        fsz=$(bpb "$dev" 36 4)
        echo $(( (res + nf * fsz + ( $(bpb "$dev" 44 4) - 2 ) * $(bpb "$dev" 13 1)) * bps ))
    else
        fsz=$(bpb "$dev" 22 2)
        echo $(( (res + nf * fsz) * bps ))
    fi
}

# Popisek FAT bajt po bajtu ze zdroje do nového (prázdného) FS: boot sektor + záznam v kořenovém adresáři
# (ten zobrazují Windows). Bez převodu znaků – diakritika v kódové stránce Windows zůstane přesně.
fat_label_copy() {
    local src=$1 dst=$2 bits=$3 lo sroot droot e off
    if (( SIMULATE || DRY_RUN )); then _show_cmd "kopie popisku FAT $src → $dst (boot sektor + kořenový adresář)"; return 0; fi
    if (( bits == 32 )); then lo=71; else lo=43; fi
    dd if="$src" of="$dst" bs=1 skip="$lo" seek="$lo" count=11 conv=notrunc status=none
    (( bits == 32 )) && dd if="$src" of="$dst" bs=1 skip=$(( 6 * 512 + lo )) seek=$(( 6 * 512 + lo )) count=11 conv=notrunc status=none
    # záznam s atributem 0x08 (popisek svazku) v prvních 128 položkách kořenového adresáře zdroje
    sroot=$(fat_root_off "$src" "$bits"); droot=$(fat_root_off "$dst" "$bits")
    [[ "$sroot" =~ ^[0-9]+$ && "$droot" =~ ^[0-9]+$ ]] || return 0
    e=$(dd if="$src" bs=1 skip="$sroot" count=4096 status=none 2>/dev/null | od -An -v -tu1 -w32 |
        awk '{ if ($1 != 0 && $1 != 229 && $12 == 8) { print NR - 1; exit } }')
    [[ -n "$e" ]] || return 0
    off=$(( sroot + e * 32 ))
    # nový FS má kořenový adresář prázdný → popisek do první položky (jméno + atribut, ostatní nuly)
    dd if="$src" of="$dst" bs=1 skip="$off" seek="$droot" count=12 conv=notrunc status=none
    _log_file "popisek FAT zkopírován z $src (položka $e) do $dst"
}

# fs_fat_copy <zdroj> <cíl> <začátek_oddílu_cíle>
fs_fat_copy() {
    local src=$1 dst=$2 start=$3 uuid id label ver bits off cnt ms md
    if (( SIMULATE || DRY_RUN )); then
        uuid="ABCD-1234" label="" ver="FAT16"
    else
        uuid=$(blkid -p -s UUID -o value "$src")
        label=$(blkid -p -s LABEL -o value "$src")
        ver=$(blkid -p -s VERSION -o value "$src")
    fi
    id=${uuid//-/}
    bits=${ver#FAT}; [[ "$bits" == @(12|16|32) ]] || bits=32
    # FAT bez popisku – popisek (i s diakritikou v kódové stránce Windows) se zkopíruje bajt po bajtu
    run mkfs.fat -F "$bits" ${id:+-i "$id"} -h "$start" "$dst"
    fat_label_copy "$src" "$dst" "$bits"
    # boot kód zavaděče (CE/DOS) z původního boot sektoru; BPB nového FS zůstává
    if (( bits == 32 )); then off=90; cnt=420; else off=62; cnt=448; fi
    run dd if="$src" of="$dst" bs=1 skip="$off" seek="$off" count="$cnt" conv=notrunc status=none
    (( bits == 32 )) && run dd if="$src" of="$dst" bs=1 skip=$(( 6 * 512 + off )) seek=$(( 6 * 512 + off )) count="$cnt" conv=notrunc status=none
    tmp_mount "$src" ro; ms=$TMP_LAST
    tmp_mount "$dst" rw; md=$TMP_LAST
    # NK.BIN (Windows CE) se kopíruje jako první, aby ležel souvisle na začátku
    if (( ! SIMULATE && ! DRY_RUN )) && [[ -e "$ms/NK.BIN" || -e "$ms/nk.bin" ]]; then
        run cp --preserve=timestamps "$ms"/[Nn][Kk].[Bb][Ii][Nn] "$md"/
    fi
    files_copy "$ms" "$md" keep
    # varování jen u FAT se systémem (Windows CE, DOS, zavaděč Windows) – u dat je to v pořádku
    local sys="" f
    if (( ! SIMULATE && ! DRY_RUN )); then
        for f in "$md"/*; do
            case "${f##*/}" in [Nn][Kk].[Bb][Ii][Nn]|[Ii][Oo].[Ss][Yy][Ss]|[Bb][Oo][Oo][Tt][Mm][Gg][Rr]|[Nn][Tt][Ll][Dd][Rr]) sys=${f##*/}; break ;; esac
        done
    fi
    tmp_umount "$md"
    tmp_umount "$ms"
    if [[ -n "$sys" ]]; then
        warn "FAT na $dst byla vytvořena znovu (FAT$bits, ID $uuid) a obsahuje systém ($sys) – atributy Skrytý/Systémový se nezachovají, ověř boot na zařízení."
    else
        ok "FAT na $dst vytvořena znovu přes celý oddíl (FAT$bits, ID $uuid, label ${label:--}), soubory zkopírovány."
    fi
}

# Kopie souborů na nový FS se stejným UUID a LABEL (kap. 5.4/2 – XFS apod.)
# fs_copy_files <fs> <zdroj> <cíl> <uuid> <label>
fs_copy_files() {
    local fs=$1 src=$2 dst=$3 uuid=$4 label=$5 ms md
    case "$fs" in
        xfs)        run mkfs.xfs -f -m uuid="$uuid" ${label:+-L "$label"} "$dst" ;;
        ext2|ext3|ext4) run "mkfs.$fs" -F -U "$uuid" ${label:+-L "$label"} "$dst" ;;
        btrfs)      run mkfs.btrfs -f -U "$uuid" ${label:+-L "$label"} "$dst" ;;
        ntfs)       warn "Kopie souborů NTFS ztrácí část metadat (ACL, ADS) – doporučeno zmenšení přes ntfsresize."
                    run mkfs.ntfs -Q ${label:+-L "$label"} "$dst" ;;
        *)          die "$E_GEN" "Kopie souborů pro FS '$fs' není podporována." ;;
    esac
    tmp_mount "$src" ro; ms=$TMP_LAST
    tmp_mount "$dst" rw; md=$TMP_LAST
    if sys_have rsync; then run rsync -aHAXx --numeric-ids "$ms/" "$md/"
    else run_sh "tar -C '$ms' --xattrs --acls -cpf - . | tar -C '$md' --xattrs --acls -xpf -"; fi
    tmp_umount "$md"
    tmp_umount "$ms"
}

# Odhad dočasného místa pro zmenšované oddíly; nedostatek → konec PŘED zápisem
restore_check_tmp() {
    local -n _S=$1 _N=$2
    local n needb=0 tdir avail
    for n in ${_N[parts]}; do
        if (( ${_N[$n.shrink]:-0} )) || { [[ "${_S[$n.fs]}" == @(vfat|fat*|exfat) && -n "${_S[$n.img]}" ]] && (( _N[$n.size] * _N[sector] > _S[$n.size] * _S[sector] )); }; then
            needb=$(( needb + ${_S[$n.used]:-$(( _S[$n.size] * _S[sector] ))} * 11 / 10 ))
        fi
    done
    (( needb )) || return 0
    tdir=$(tmp_base)
    if (( SIMULATE )); then info "Zmenšení potřebuje cca $(human "$needb") dočasného místa v $tdir."; return 0; fi
    avail=$(df -B1 --output=avail "$tdir" 2>/dev/null | tail -1 | tr -d ' ')
    info "Změna velikosti potřebuje cca $(human "$needb") dočasného místa v $tdir (volno $(human "${avail:-0}"))."
    if (( ${avail:-0} < needb )); then
        die "$E_SPACE" "V $tdir není dost místa pro dočasný soubor (chybí $(human $(( needb - ${avail:-0} )))). Zadej jiné místo přes --tmpdir. Nic nebylo zapsáno."
    fi
}

# Volné místo před oddílem (od konce předchozího oddílu), v sektorech
editor_space_before() {
    local n=$1 m s=${ED[$1.start]} prev
    prev=${ED[first_lba]:-2048}
    [[ "${ED[label]}" == dos ]] && prev=1
    for m in ${ED[parts]}; do
        [[ "$m" == "$n" || "${ED[$m.role]}" == extended ]] && continue
        (( ED[$m.start] < s && ED[$m.start] + ED[$m.size] > prev )) && prev=$(( ED[$m.start] + ED[$m.size] ))
    done
    echo $(( s - prev ))
}

# Naplánuje změnu velikosti oddílu n podle výrazu (200G, -5G, max, 60 %…); 1 = odmítnuto
editor_do_resize() {
    local n=$1 expr=$2 cur maxb newb ss=${ED[sector]}
    if [[ " ${ED[parts]} " != *" $n "* ]]; then warn "Oddíl č. $n na disku neexistuje."; return 1; fi
    if [[ "${ED[$n.role]}" == extended || "${ED[$n.fs]}" == @(LVM2_member|linux_raid_member|crypto_LUKS|BitLocker) ]]; then
        warn "Oddíl ${ED[$n.pname]} (${ED[$n.fs]:-${ED[$n.role]}}) nelze měnit (LVM/RAID/šifrování)."
        return 1
    fi
    cur=$(( ED[$n.size] * ss ))
    maxb=$(( cur + $(editor_space_after "$n") * ss ))
    if ! newb=$(parse_size "$expr" "$cur" $(( ED[disk_sectors] * ss )) "$maxb"); then
        warn "Nerozumím zadání velikosti '$expr'."; return 1
    fi
    [[ "$expr" == max ]] || newb=$(( newb / MiB * MiB ))
    if (( newb > maxb )); then warn "$(human "$newb") se nevejde (max $(human "$maxb"))."; return 1; fi
    if (( newb == cur )); then info "Velikost se nemění."; return 0; fi
    if (( newb < cur )); then
        if [[ "${ED[$n.fs]}" == xfs ]]; then warn "XFS nejde zmenšit (jen kopií souborů přes obnovu z obrazu)."; return 1; fi
        if [[ -z "${ED[$n.fs]}" || "${ED[$n.fs]}" == swap ]]; then
            [[ "${ED[$n.fs]}" == swap ]] || { warn "Oddíl bez FS nelze bezpečně zmenšit."; return 1; }
        fi
        if [[ -z "${ED[$n.min]}" && "${ED[$n.fs]}" != swap ]]; then
            ED[$n.min]=$(fs_min_bytes "${ED[$n.fs]}" "/dev/${ED[$n.pname]}")
            if [[ -z "${ED[$n.min]}" ]] && (( ! SIMULATE )); then
                warn "Minimální velikost FS '${ED[$n.fs]}' nejde zjistit – zmenšení odmítnuto."; return 1
            fi
        fi
        if [[ -n "${ED[$n.min]}" ]] && (( newb < ED[$n.min] )); then
            warn "Pod minimum FS (${ED[$n.pname]}: min. $(human "${ED[$n.min]}")) nelze zmenšit."; return 1
        fi
    fi
    ED_UNDO+=("$(declare -p ED ED_PLAN)")
    ED[$n.size]=$(( newb / ss ))
    if (( newb < cur )); then
        ED_PLAN+=("shrink $n $newb   # nejdřív FS, pak oddíl: ${ED[$n.pname]} $(human "$cur") → $(human "$newb")")
    else
        ED_PLAN+=("grow $n $newb   # nejdřív oddíl, pak FS: ${ED[$n.pname]} $(human "$cur") → $(human "$newb")")
    fi
    return 0
}

# Naplánuje přesun oddílu n: "end" (doprava na konec volného místa), "start" (doleva), nebo MiB; 1 = odmítnuto
editor_do_move() {
    local n=$1 where=$2 newstart minstart maxstart ss=${ED[sector]}
    if [[ " ${ED[parts]} " != *" $n "* ]]; then warn "Oddíl č. $n na disku neexistuje."; return 1; fi
    [[ "${ED[$n.role]}" == extended ]] && { warn "Rozšířený oddíl nelze přesouvat."; return 1; }
    minstart=$(align_up $(( ED[$n.start] - $(editor_space_before "$n") )) "$ss")
    maxstart=$(align_down $(( ED[$n.start] + $(editor_space_after "$n") )) "$ss")
    case "$where" in
        end)    newstart=$maxstart ;;
        start)  newstart=$minstart ;;
        *)      [[ "$where" =~ ^[0-9]+$ ]] || { warn "Neplatný začátek '$where' (end|start|MiB)."; return 1; }
                newstart=$(( where * MiB / ss )) ;;
    esac
    if (( newstart < minstart || newstart > maxstart )); then
        warn "Začátek $(( newstart * ss / MiB )) MiB je mimo volné místo ($(( minstart * ss / MiB ))–$(( maxstart * ss / MiB )) MiB)."
        return 1
    fi
    if (( newstart == ED[$n.start] )); then info "Oddíl se nepřesouvá."; return 0; fi
    if [[ "${ED[mode]:-}" == legacy || "${ED[$n.fs]}" == ntfs ]]; then
        warn "Přesun začátku ${ED[$n.pname]} mění pozici oddílu – u Windows/legacy systémů může přestat bootovat (kap. 5.7). Pole hidden sectors se opraví."
    fi
    ED_UNDO+=("$(declare -p ED ED_PLAN)")
    ED_PLAN+=("move $n $newstart   # ${ED[$n.pname]}: sektor ${ED[$n.start]} → $newstart")
    ED[$n.start]=$newstart
    return 0
}

# Plán seřazený pro bezpečné provedení: smazání, zmenšení, přesuny doleva, přesuny doprava (odzadu), zvětšení, popisky
editor_plan_sorted() {
    local s op n arg key
    for s in "${ED_PLAN[@]}"; do
        read -r op n arg _ <<<"$s"
        [[ "$arg" =~ ^[0-9]+$ ]] || arg=0   # label: text, ne číslo
        case "$op" in
            delete) key=0 ;; shrink) key=1 ;;
            move)   if (( arg < ${ED_ORIG_START[$n]:-0} )); then key=2; else key=3; fi ;;
            grow)   key=4 ;; *) key=5 ;;
        esac
        # přesuny doprava odzadu (podle začátku sestupně), ostatní v pořadí zadání
        if (( key == 3 )); then printf '%s %012d %s\n' "$key" $(( 999999999999 - arg )) "$s"
        else printf '%s %012d %s\n' "$key" "$arg" "$s"; fi
    done | sort -s -k1,1n -k2,2n | cut -d' ' -f3-
}

# CLI: --resize sdf2 --size … / --move sdf3 --start …
cli_editor() {
    local p disk n why
    p=${OPT_RESIZE:-$OPT_MOVE}
    [[ "${BLK[$p.TYPE]:-}" == part ]] || die "$E_USER" "Oddíl $p neexistuje."
    disk=$(blk_parent "$p")
    if why=$(disk_protect_reason "$disk"); then die "$E_USER" "Disk $disk nelze upravovat: $why."; fi
    n=$(part_num "$p")
    ED_PLAN=() ED_UNDO=()
    editor_load_disk "$disk"
    local m
    for m in ${ED[parts]}; do ED_ORIG_START[$m]=${ED[$m.start]}; done
    if [[ "$ACTION" == resize ]]; then
        [[ -n "$OPT_SIZE" ]] || die "$E_USER" "Chybí --size."
        editor_do_resize "$n" "$OPT_SIZE" || die "$E_USER" "Změna velikosti odmítnuta."
    else
        [[ -n "$OPT_START" ]] || die "$E_USER" "Chybí --start."
        editor_do_move "$n" "$OPT_START" || die "$E_USER" "Přesun odmítnut."
    fi
    editor_apply
}

# Typ disku čitelně: NVMe SSD, SATA SSD/HDD, USB disk, USB flash/čtečka (CF/SD), SD/eMMC…
disk_kind() {
    local d=$1 t=${BLK[$1.TRAN]:-} r=${BLK[$1.ROTA]:-1} rm=${BLK[$1.RM]:-0}
    case "$t" in
        nvme)       echo "NVMe SSD" ;;
        sata|ata)   if [[ "$r" == 0 ]]; then echo "SATA SSD"; else echo "SATA HDD"; fi ;;
        usb)        if [[ "$rm" == 1 ]]; then echo "USB flash/čtečka"; elif [[ "$r" == 0 ]]; then echo "USB SSD"; else echo "USB disk"; fi ;;
        mmc)        echo "SD/eMMC" ;;
        sas|scsi)   if [[ "$r" == 0 ]]; then echo "SAS SSD"; else echo "SAS HDD"; fi ;;
        *)          if [[ "$d" == loop* ]]; then echo "loop soubor"
                    elif [[ "$d" == vd* ]]; then echo "virtuální"
                    elif [[ "$r" == 0 ]]; then echo "SSD"; else echo "disk"; fi ;;
    esac
}

# Výrobce + model (VENDOR "ATA" a duplicity se vynechají)
disk_vendor_model() {
    local v=${BLK[$1.VENDOR]:-} m=${BLK[$1.MODEL]:-}
    v=${v%% }; v=${v## }; v=${v%%+( )}
    [[ "$v" == ATA || "$m" == "$v"* ]] && v=""
    local s="${v:+$v }$m"
    echo "${s:--}"
}

# Jednořádkový popis disku pro nabídky: název, velikost, typ, výrobce/model, sériové číslo
# disk_desc <disk> [důvod_ochrany] – chráněný disk má stav hned za velikostí (aby se neuřízl) a kratší řádek
disk_desc() {
    local d=$1 why=${2:-}
    if [[ -n "$why" ]]; then
        printf '%-8s %10s  CHRÁNĚNO: %-24.24s %-16s %.24s' "$d" "$(human "${BLK[$d.SIZE]:-0}")" "$why" \
            "$(disk_kind "$d")" "$(disk_vendor_model "$d")"
    else
        printf '%-8s %10s  %-16s %-28.28s SN %.20s' "$d" "$(human "${BLK[$d.SIZE]:-0}")" "$(disk_kind "$d")" \
            "$(disk_vendor_model "$d")" "${BLK[$d.SERIAL]:--}"
    fi
}

# Geometrie CHS zdroje (*-chs.sf) vs. cíle – pro staré BIOSy a XP (kap. 5.7/5)
restore_chs_info() {
    local f=$1 tgt=$2 sh="" ss="" th="" ts="" g
    if [[ -r "$f" ]]; then
        sh=$(sed -n 's/^heads=//p' "$f"); ss=$(sed -n 's/^sectors=//p' "$f")
    fi
    if (( SIMULATE )); then
        th=255 ts=63
    else
        g=$(sfdisk -g "/dev/$tgt" 2>/dev/null || true)
        [[ "$g" =~ ([0-9]+)\ heads,\ ([0-9]+)\ sectors ]] && th=${BASH_REMATCH[1]} ts=${BASH_REMATCH[2]}
    fi
    info "Geometrie CHS: zdroj ${sh:-?} hlav / ${ss:-?} sektorů, cíl ${th:-?} hlav / ${ts:-?} sektorů."
    if [[ -n "$sh" && -n "$th" ]] && [[ "$sh/$ss" != "$th/$ts" ]]; then
        warn "Geometrie CHS se liší. Boot sektor oddílu má hodnoty ze zdroje (obnoveny z obrazu); velmi staré BIOSy s tím mohou mít potíže – ověř boot na panelu."
    fi
    return 0
}

# Disky uložené v obrazu (soubor "disk" může obsahovat víc disků, např. "sda sdb")
img_disks() {
    local -a d=()
    read -ra d <"$1/disk"
    printf '%s\n' "${d[@]}"
}

# Oddíly ze souboru "parts", které patří danému disku obrazu
img_disk_parts() {
    local dir=$1 disk=$2 p out=""
    local -a plist=()
    read -ra plist <"$dir/parts"
    for p in "${plist[@]}"; do
        [[ "$p" =~ ^${disk}p?[0-9]+$ ]] && out+="${out:+ }$p"
    done
    echo "$out"
}

# Výběr disku z vícediskového obrazu (jen jeden); výsledek v UI_REPLY
img_pick_disk() {
    local dir=$1 d items=()
    local -a disks=()
    mapfile -t disks < <(img_disks "$dir")
    if (( ${#disks[@]} == 1 )); then UI_REPLY=${disks[0]}; return 0; fi
    for d in "${disks[@]}"; do items+=("$d" "disk $d  (oddíly: $(img_disk_parts "$dir" "$d"))"); done
    ui_menu "Záloha obsahuje ${#disks[@]} disky" "Který disk ze zálohy?" "${items[@]}"
}

# Obnova na jeden cílový disk: restore_one_disk <cíl|""> <jednotka…>
# Jedna jednotka = jeden disk ze zálohy; víc jednotek (i z různých záloh) se sloučí na tento jediný disk.
restore_one_disk() {
    local tgt=$1 rc=0 mode why label u
    local -a units=() names=()
    shift
    units=("$@")
    if (( ${#units[@]} > 1 )); then
        mapfile -t units < <(merge_order "${units[@]}")
        for u in "${units[@]}"; do names+=("$(unit_name "$u")"); done
        if img_disk_bootable "${units[0]%%|*}" "${units[0]#*|}"; then
            info "Bootovací disk ze zálohy: ${names[0]} – jeho oddíl bude na cíli první (boot kód MBR, disk signature a aktivní příznak se převezmou z něj)."
        else
            warn "Žádný disk v záloze nemá bootovací oddíl – pořadí zůstává ${names[*]}."
        fi
        info "Pořadí oddílů na cílovém disku: ${names[*]}"
        img_load_merged SRC "${units[@]}"
        label="${names[*]}"
        label=${label// / + }
    else
        u=${units[0]}
        img_load "${u%%|*}" SRC "${u#*|}"
        label=$(unit_name "$u")
        img_verify SRC || die "$E_GEN" "Obraz disku $label je neúplný – obnova není možná."
    fi
    check_deps_image SRC
    img_info SRC

    ui_step "krok 3/6: cílový disk"
    ui_theme red
    if [[ -n "$tgt" ]]; then
        [[ "${BLK[$tgt.TYPE]:-}" == disk ]] || die "$E_USER" "Cílový disk $tgt neexistuje."
        if why=$(disk_protect_reason "$tgt"); then die "$E_USER" "Disk $tgt nelze použít jako cíl: $why."; fi
    else
        while true; do
            disk_select_target "Cílový disk pro $label" || return "$E_USER"
            tgt=$UI_REPLY
            [[ " ${RESTORE_USED_TARGETS[*]} " == *" $tgt "* ]] || break
            warn "Disk $tgt už je cílem jiné části obnovy – vyber jiný."
        done
    fi
    [[ "${BLK[$tgt.SIZE]:-0}" -lt 64000000000 ]] && [[ "${SRC[mode]}" == legacy ]] && SMALL_MEDIA=1

    ui_step "krok 4/6: velikost oddílů"
    restore_choose_mode SRC || return "$E_USER"
    mode=$UI_REPLY
    if [[ "$mode" == manual ]]; then
        # výchozí návrh jen jako předvyplněné hodnoty – kontroluje se až to, co uživatel zadá
        layout_compute SRC NEW "$tgt" last >/dev/null 2>&1 || true
        layout_ask_sizes SRC NEW "$tgt" || rc=$?
    else
        layout_compute SRC NEW "$tgt" "$mode" || rc=$?
    fi
    layout_table SRC NEW | ui_text "Rozložení $label → $tgt: původní → nové"
    if (( rc == E_SPACE )); then
        die "$E_SPACE" "Data ($label) se na disk $tgt nevejdou. Nic nebylo zapsáno."
    elif (( rc )); then
        return "$E_USER"
    fi
    restore_check_tmp SRC NEW

    local summary
    summary=$(
        disk_summary "$tgt"
        echo
        echo "Obraz: ${SRC[dirs]:-${SRC[dir]}}   (zdroje: $label)"
        echo "Režim: $mode, $([[ "${SRC[mode]}" == legacy ]] && echo 'legacy (Beckhoff)' || echo obecný)"
        echo
        layout_table SRC NEW
    )
    ui_step "krok 5/6: kontrola a potvrzení"
    ui_confirm_disk "$tgt" "$summary" || return "$E_USER"
    ui_step "krok 6/6: obnova na /dev/$tgt"
    restore_execute SRC NEW "$tgt"
    LAST_TARGET=$tgt
}

# Sloučení více zdrojů do JEDNOHO rozložení: oddíly prvního disku zůstanou na místě,
# oddíly dalších disků se přidají za ně (nová čísla, zarovnané pozice, příznak appended=1).
# Zdroje mohou být z různých záloh. img_load_merged <pole> <jednotka1> <jednotka2>…
img_load_merged() {
    local arr=$1; shift
    local -n _M=$arr
    local u dir d k n m=0 pos=0 first=1 label1="" ss1="" mode=generic uname dirs=""
    local -a names=()
    declare -gA IMGTMP=()
    _M=()
    for u in "$@"; do
        dir=${u%%|*} d=${u#*|} uname=$(unit_name "$u")
        names+=("$uname")
        [[ "|$dirs|" == *"|$dir|"* ]] || dirs+="${dirs:+|}$dir"
        img_load "$dir" IMGTMP "$d"
        img_verify IMGTMP || die "$E_GEN" "Obraz disku $uname je neúplný – obnova není možná."
        if (( first )); then
            for k in label disk_id sector first_lba last_lba src_disk dir; do _M["$k"]=${IMGTMP["$k"]:-}; done
            label1=${IMGTMP[label]} ss1=${IMGTMP[sector]}
            _M[parts]=""
        else
            [[ "${IMGTMP[label]}" == "$label1" ]] || die "$E_USER" "Zdroje mají různé tabulky oddílů (${label1} × ${IMGTMP[label]}, $uname) – sloučit na jeden disk nejde."
            [[ "${IMGTMP[sector]}" == "$ss1" ]] || die "$E_USER" "Zdroje mají různou velikost sektoru ($uname) – sloučit na jeden disk nejde."
        fi
        [[ "${IMGTMP[mode]}" == legacy ]] && mode=legacy
        for n in ${IMGTMP[parts]}; do
            if (( ! first )) && [[ "${IMGTMP[$n.role]}" == extended ]] || { (( ! first )) && (( n >= 5 )) && [[ "$label1" == dos ]]; }; then
                die "$E_USER" "Zdroj $uname má rozšířený/logický oddíl – sloučení na jeden disk není podporováno."
            fi
            m=$(( m + 1 ))
            for k in "${!IMGTMP[@]}"; do
                [[ "$k" == "$n".* ]] && _M[$m.${k#"$n".}]=${IMGTMP[$k]}
            done
            _M[$m.origstart]=${IMGTMP[$n.start]}
            _M[$m.fromdisk]=$uname
            if (( first )); then
                _M[$m.appended]=0
            else
                _M[$m.appended]=1
                _M[$m.boot]=0
                _M[$m.start]=$(align_up "$pos" "$ss1")
            fi
            pos=$(( _M[$m.start] + _M[$m.size] ))
            _M[parts]+="${_M[parts]:+ }$m"
        done
        first=0
    done
    if [[ "$label1" == dos ]] && (( m > 4 )); then
        die "$E_USER" "Sloučením by vzniklo $m primárních oddílů, MBR dovoluje nejvýš 4."
    fi
    if [[ "$label1" == gpt ]]; then _M[disk_sectors]=$(( pos + 34 )); else _M[disk_sectors]=$pos; fi
    _M[mode]=$mode
    _M[merged]="${names[*]}"
    _M[dirs]=$dirs
}

# Režim C: velikost každého (rostoucího) oddílu zadá uživatel; oddíly se poskládají za sebe.
# První oddíl si drží původní začátek (legacy: sektor 63). Pevné oddíly (EFI, MSR…) si drží velikost.
# Neinteraktivně: --sizes "20G,max" (hodnoty pro rostoucí oddíly v pořadí na disku).
layout_ask_sizes() {
    local -n _S=$1 _N=$2
    local tgt=$3 ss=${_N[sector]} n m i end cur start avail later minb origb newb expr dflt k
    local -a order presets=()
    mapfile -t order < <(layout_order "$2")
    [[ -n "$OPT_SIZES" ]] && IFS=, read -ra presets <<<"$OPT_SIZES"
    if [[ "${_N[label]}" == gpt ]]; then end=${_N[last_lba]}; else end=$(( _N[disk_sectors] - 1 )); fi
    cur=${_N[${order[0]}.start]}
    k=0
    for (( i = 0; i < ${#order[@]}; i++ )); do
        n=${order[i]}
        if (( i == 0 )); then start=$cur; else start=$(align_up "$cur" "$ss"); fi
        # místo, které musí zůstat pro další oddíly (pevné = jejich velikost, rostoucí = jejich minimum)
        later=0
        for (( m = i + 1; m < ${#order[@]}; m++ )); do
            if [[ "${_N[${order[m]}.class]}" == grow ]]; then
                later=$(( later + ( ${_N[${order[m]}.min]:-$MiB} + ss - 1 ) / ss + 2048 ))
            else
                later=$(( later + _S[${order[m]}.size] + 2048 ))
            fi
        done
        avail=$(( end + 1 - start - later ))
        origb=$(( _S[$n.size] * _S[sector] ))
        if [[ "${_N[$n.class]}" != grow ]]; then
            _N[$n.start]=$start; _N[$n.size]=${_S[$n.size]}
            info "Oddíl $n (${_S[$n.role]}, ${_S[$n.pname]}): pevná velikost $(human "$origb")."
            cur=$(( start + _N[$n.size] )); continue
        fi
        minb=${_N[$n.min]:-0}
        dflt="max"
        for (( m = i + 1; m < ${#order[@]}; m++ )); do
            [[ "${_N[${order[m]}.class]}" == grow ]] && { dflt="$(( _N[$n.size] * ss / MiB ))M"; break; }
        done
        while true; do
            if (( k < ${#presets[@]} )); then
                expr=${presets[k]}
            else
                [[ -n "$OPT_SIZES" ]] && die "$E_USER" "--sizes neobsahuje hodnotu pro oddíl $n (${_S[$n.pname]})."
                ui_input "Oddíl $n z ${_S[$n.fromdisk]:-${_S[src_disk]}} (${_S[$n.pname]}, ${_S[$n.fs]:-?}, ${_S[$n.label]:-bez labelu}): původně $(human "$origb"), obsazeno $([[ -n "${_S[$n.used]}" ]] && human "${_S[$n.used]}" || echo '?'), minimum $(human "$minb"), k dispozici až $(human $(( avail * ss ))). Velikost (20G, 15000M, 50%, max)" "$dflt" || return 1
                expr=$UI_REPLY
            fi
            if [[ "$expr" == max || "$expr" == zbytek ]]; then
                newb=$(( avail * ss ))
            elif ! newb=$(parse_size "$expr" "$origb" $(( _N[disk_sectors] * ss )) $(( avail * ss ))); then
                warn "Nerozumím zadání '$expr'."; newb=-1
            else
                newb=$(( newb / MiB * MiB ))
            fi
            if (( newb > avail * ss )); then warn "$(human "$newb") se nevejde – k dispozici je $(human $(( avail * ss )))."; newb=-1; fi
            if (( newb >= 0 && newb < minb )); then warn "Pod minimum: oddíl ${_S[$n.pname]} potřebuje aspoň $(human "$minb")."; newb=-1; fi
            if (( newb > 0 )); then break; fi
            [[ -n "$OPT_SIZES" ]] && die "$E_USER" "Neplatná velikost '$expr' pro oddíl $n – nic nebylo zapsáno."
        done
        k=$(( k + 1 ))
        _N[$n.start]=$start
        _N[$n.size]=$(( newb / ss ))
        cur=$(( start + _N[$n.size] ))
    done
    layout_check "$1" "$2"
}

# Klávesnice konzole: "cz" = jen prohodí Y a Z (jako česká QWERTZ), vše ostatní zůstává americké
# (čísla, lomítka…); "us" = vrátí Y/Z zpět; "keep" = nic nemění. Jen na skutečné konzoli, ne v simulaci.
kbd_init() {
    local km=${KEYMAP_WANT:-cz} map
    (( SIMULATE )) && return 0
    [[ "$km" == keep ]] && return 0
    sys_have loadkeys || { _log_file "loadkeys chybí – klávesnice beze změny"; return 0; }
    case "$(tty 2>/dev/null || true)" in /dev/tty[0-9]*|/dev/console) ;; *) return 0 ;; esac
    # keycode 21 = klávesa Y (US), 44 = klávesa Z (US); "+" = velké písmeno se Shiftem / CapsLockem
    if [[ "$km" == us ]]; then map=$'keycode 21 = +y\nkeycode 44 = +z\n'
    else map=$'keycode 21 = +z\nkeycode 44 = +y\n'; fi
    if printf '%s' "$map" | loadkeys -q - 2>/dev/null; then
        KEYMAP_CUR=$km
        [[ "$km" == cz ]] && info "Klávesnice: Y a Z jako na české klávesnici (ostatní klávesy beze změny)."
    else
        warn "Klávesnici se nepodařilo přepnout (loadkeys). Zůstává původní."
    fi
    return 0
}

# Je disk v záloze bootovací? (MBR: aktivní oddíl, GPT: EFI oddíl)
img_disk_bootable() {
    local f="$1/$2-pt.sf"
    [[ -r "$f" ]] || return 1
    grep -qiE 'bootable|type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B|type=ef([^0-9a-f]|$)' "$f"
}

# Pořadí zdrojů pro sloučení: bootovací disk vždy první (jeho oddíl bude č. 1, převezme boot kód a signaturu).
# merge_order <jednotka…> → jednotky, každá na vlastním řádku
merge_order() {
    local u
    local -a boot=() rest=()
    for u in "$@"; do
        if img_disk_bootable "${u%%|*}" "${u#*|}"; then boot+=("$u"); else rest+=("$u"); fi
    done
    (( ${#boot[@]} > 1 )) && warn "Bootovací oddíl mají zdroje: $(for u in "${boot[@]}"; do printf '%s ' "$(unit_name "$u")"; done)– první bude $(unit_name "${boot[0]}")."
    printf '%s\n' "${boot[@]}" "${rest[@]}"
}

# Záložní boot sektor NTFS (poslední sektor svazku) = kopie sektoru 0. partclone ho neobnovuje,
# proto ho po obnově zapíšeme (jinak chkdsk / ntfsfix hlásí "alternate boot sector BAD").
ntfs_sync_backup_boot() {
    local dev=$1 total devsec
    if (( SIMULATE || DRY_RUN )); then
        _show_cmd "dd if=$dev of=$dev bs=512 count=1 seek=<sektory svazku> conv=notrunc   # záložní boot sektor NTFS"
        return 0
    fi
    total=$(dd if="$dev" bs=1 skip=40 count=8 status=none | od -An -tu8 | tr -d ' ')
    [[ "$total" =~ ^[0-9]+$ ]] || return 0
    devsec=$(( $(blockdev --getsize64 "$dev") / 512 ))
    if (( total >= devsec )); then warn "NTFS na $dev je větší než oddíl – záložní boot sektor nelze zapsat."; return 0; fi
    # kopie patří za poslední sektor svazku; ntfsfix / ntfs-3g ji hledá na posledním sektoru oddílu –
    # po zmenšení (svazek zarovnaný na clustery) se obě místa liší, proto se zapíše na obě
    local s
    for s in "$total" $(( devsec - 1 )); do
        (( s > total )) && (( s >= devsec )) && continue
        if ! cmp -s <(dd if="$dev" bs=512 count=1 status=none) <(dd if="$dev" bs=512 skip="$s" count=1 status=none); then
            dd if="$dev" of="$dev" bs=512 count=1 seek="$s" conv=notrunc status=none
            _log_file "záložní boot sektor NTFS na $dev zapsán (sektor $s)"
        fi
    done
    return 0
}

# =============================================================================
# MAIN
# =============================================================================
STATE_DIR=""
ORIG_ARGS=""

main() {
    ORIG_ARGS="$*"
    color_on
    parse_args "$@"
    case "$ACTION" in
        help)    usage; exit "$E_OK" ;;
        version) echo "restore.sh $VERSION"; exit "$E_OK" ;;
    esac
    if (( SIMULATE )); then sim_init; fi
    STATE_DIR=$(mktemp -d)
    trap 'on_err $LINENO "$BASH_COMMAND" $?' ERR
    trap on_exit EXIT
    log_init
    check_root
    ui_init
    kbd_init
    check_deps
    blk_load
    live_detect
    disk_check_internal
    src_refresh

    case "$ACTION" in
        menu)        menu_main ;;
        restore)     restore_disk ;;
        list-disks)  disk_table ;;
        save)
            local it
            for it in "${OPT_SAVE_DISKS[@]}"; do
                [[ "${BLK[$it.TYPE]:-}" == disk ]] || die "$E_USER" "--save-disk: '$it' není disk (oddíly patří do --save-part)."
            done
            for it in "${OPT_SAVE_PARTS[@]}"; do
                [[ "${BLK[$it.TYPE]:-}" == part ]] || die "$E_USER" "--save-part: '$it' není oddíl (disky patří do --save-disk)."
            done
            src_select rw || exit "$E_USER"
            backup_run "$OPT_NAME" "$OPT_SEPARATE" "${OPT_SAVE_DISKS[@]}" "${OPT_SAVE_PARTS[@]}" ;;
        list-images)
            local base=${OPT_IMAGE:-}
            if [[ -z "$base" ]]; then src_select ro || exit "$E_USER"; base=$(partimag_dir); fi
            local d
            for d in $(img_find "$base"); do printf '%-40s %s\n' "${d#"$base"/}" "$(img_oneline "$d")"; done ;;
        info)
            [[ -d "$OPT_IMAGE" ]] || { src_select ro || exit "$E_USER"; }
            img_select
            for d in $(img_disks "$IMG_DIR"); do img_load "$IMG_DIR" SRC "$d"; UI_BACKEND=plain img_info SRC; done ;;
        edit)        editor_run "$OPT_EDIT" || true ;;
        resize|move)
            cli_editor ;;
    esac
}

main "$@"
