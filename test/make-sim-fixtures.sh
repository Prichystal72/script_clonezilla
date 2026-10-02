#!/usr/bin/env bash
# Vygeneruje simulační fixtures do ../sim/<scénář>/ (kap. 10.1).
# Výsledek jsou obyčejné textové soubory – lze je dál ručně upravovat.
# Spuštění: bash test/make-sim-fixtures.sh

set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="$ROOT/sim"

GPT_EFI=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
GPT_MSR=E3C9E316-0B5C-4DB8-817D-F92DF00215AE
GPT_LINUX=0FC63DAF-8483-4772-8E79-3D69D8477DE4
GPT_MSDATA=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
GPT_RECOVERY=DE94BBA4-06D1-4D40-A16A-BFD50179D6AC

S=""   # adresář aktuálního scénáře

# --- lsblk -P řádek -----------------------------------------------------------
# blk NAME PKNAME TYPE SIZE_B FSTYPE LABEL UUID MODEL SERIAL TRAN ROTA RM MOUNTPOINT
blk() {
    printf 'NAME="%s" KNAME="%s" PKNAME="%s" TYPE="%s" SIZE="%s" FSTYPE="%s" LABEL="%s" UUID="%s" MODEL="%s" SERIAL="%s" TRAN="%s" ROTA="%s" RM="%s" LOG-SEC="512" MOUNTPOINT="%s"\n' \
        "$1" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}" >>"$S/lsblk.P"
}

# Nový scénář: scenario <název> <popis> [chybějící nástroje]
scenario() {
    S="$SIM/$1"
    rm -rf "$S"
    mkdir -p "$S/sfdisk" "$S/disks"
    printf '# Simulační scénář – načítá restore.sh --simulate=%s\nSIM_DESC="%s"\nSIM_MISSING="%s"\n' "$1" "$2" "${3:-}" >"$S/scenario.conf"
    : >"$S/lsblk.P"
    # flashka s Clonezillou je ve všech scénářích sda
    blk sda "" disk 16008609792 "" "" "" "SanDisk Ultra" 4C5300011 usb 1 1 ""
    blk sda1 sda part 16007561216 vfat CLONEZILLA 1A2B-3C4D "" "" usb 1 1 /run/live/medium
}

# Disk s obrazy: images_disk <disk> <fs> <label> <mountpoint>
images_disk() {
    blk "$1" "" disk 1000204886016 "" "" "" "WD Elements 25A2" WX12A3456789 usb 1 0 ""
    blk "${1}1" "$1" part 1000203837440 "$2" "$3" 5e1f0c9a-77aa-4b0e-9d3c-3e0b8c1d2e01 "" "" usb 1 0 "$4"
    mkdir -p "$S/disks/${1}1"
}

# Prázdný cílový disk: target <disk> <sektory> <model> <tran> <rota> <rm>
target() {
    blk "$1" "" disk $(( $2 * 512 )) "" "" "" "$3" "SN-$1-0001" "$4" "$5" "${6:-0}" ""
}

# --- obraz Clonezilly ---------------------------------------------------------
# image_begin <adresář> <disk> <sektory_disku> <sfdisk-hlavička…>
IMG=""
IMG_DISK=""
image_begin() {
    IMG="$1"; IMG_DISK="$2"
    mkdir -p "$IMG"
    echo "$2" >"$IMG/disk"
    : >"$IMG/parts"
    : >"$IMG/blkid.list"
    : >"$IMG/sim-partclone-info.txt"
    printf '# <Device name>   <File system>   <Size>\n' >"$IMG/dev-fs.list"
    printf 'Model: ATA SSD (scsi)\nDisk /dev/%s: %ss\nSector size (logical/physical): 512B/512B\n' "$2" "$3" >"$IMG/$2-pt.parted"
    printf 'Image was saved by Clonezilla at 2026-09-15 14:32:10 UTC\nSaved by clonezilla-live-3.2.0-5\n' >"$IMG/Info-saved-by-cmd.txt"
    echo "This image was saved by Clonezilla at 2026-09-15 14:32:10 UTC" >"$IMG/clonezilla-img"
    shift 3
    printf '%s\n' "$@" >"$IMG/$IMG_DISK-pt.sf"
    echo >>"$IMG/$IMG_DISK-pt.sf"
}

# image_part <číslo> <sfdisk-řádek-bez-zařízení> <fs> <typ ptcl|ntfs|dd|-> <komprese> <velikost_B> <obsazeno_B> <label> <uuid> [počet_dílů]
image_part() {
    local n=$1 line=$2 fs=$3 t=$4 comp=$5 size=$6 used=$7 label=$8 uuid=$9 nsplit=${10:-1}
    local p="$IMG_DISK$n"
    [[ "$IMG_DISK" =~ [0-9]$ ]] && p="${IMG_DISK}p$n"
    echo "/dev/$p : $line" >>"$IMG/$IMG_DISK-pt.sf"
    if [[ "$t" != - ]]; then
        local base suf i cur
        cur=$(cat "$IMG/parts")
        echo "${cur:+$cur }$p" >"$IMG/parts"
        case "$t" in
            ptcl) base="$p.$fs-ptcl-img.$comp" ;;
            ntfs) base="$p.ntfs-img.$comp" ;;
            dd)   base="$p.dd-img.$comp" ;;
        esac
        for (( i = 0; i < nsplit; i++ )); do
            suf=$(printf '%b' "\x$(printf %x $(( 97 + i / 26 )))\x$(printf %x $(( 97 + i % 26 )))")
            : >"$IMG/$base.$suf"
        done
        echo "$p $size $used" >>"$IMG/sim-partclone-info.txt"
    fi
    if [[ -n "$fs" ]]; then
        printf '/dev/%s: %sUUID="%s" TYPE="%s"\n' "$p" "${label:+LABEL=\"$label\" }" "$uuid" "$fs" >>"$IMG/blkid.list"
        printf '/dev/%s %s %s\n' "$p" "$fs" "$size" >>"$IMG/dev-fs.list"
    fi
}

# MBR boot kód + data za MBR (legacy)
image_mbr() {
    head -c 512 /dev/zero | tr '\0' 'M' >"$IMG/$IMG_DISK-mbr"
    head -c $(( ${1:-62} * 512 )) /dev/zero >"$IMG/$IMG_DISK-hidden-data-after-mbr"
}

# Existující tabulka na cílovém disku
target_dump() { printf '%s\n' "${@:2}" >"$S/sfdisk/$1.dump"; }

GB=1000000000

# =============================================================================
# bigger – EFI + ext4 (128 GB) → 500 GB SSD, disk s obrazy nepřipojený (sken)
# =============================================================================
scenario bigger "obraz 2 oddíly (EFI + ext4, 128 GB) → cíl 500 GB SSD; disk s obrazy je třeba najít a připojit"
images_disk sdh ext4 ZALOHY ""
target sdf 976773168 "Samsung SSD 870 EVO 500GB" sata 0
image_begin "$S/disks/sdh1/clonezilla/UBUNTU-2026-09" sda 250069680 \
    "label: gpt" "label-id: 6A1F3E2B-9C4D-4E5F-8A7B-1C2D3E4F5A6B" "device: /dev/sda" "unit: sectors" \
    "first-lba: 2048" "last-lba: 250069646" "sector-size: 512"
image_part 1 "start=2048, size=1048576, type=$GPT_EFI, uuid=1D2E3F40-5A6B-4C7D-8E9F-0A1B2C3D4E5F, name=\"EFI System Partition\"" \
    vfat ptcl zst $(( 1048576 * 512 )) $(( 31 * 1048576 )) "" 7A3C-1F2E
image_part 2 "start=1050624, size=249019023, type=$GPT_LINUX, uuid=2E3F4051-6B7C-4D8E-9FA0-1B2C3D4E5F60" \
    ext4 ptcl zst $(( 249019023 * 512 )) $(( 45 * GB )) "" 9f1c2d3e-4b5a-4c6d-8e7f-0a1b2c3d4e5f 3
mkdir -p "$S/disks/sdh1/fotky" "$S/disks/sdh1/clonezilla/stare-nefunkcni"

# =============================================================================
# smaller – 500 GB (data 60 GB) → 256 GB
# =============================================================================
scenario smaller "obraz 500 GB (data 60 GB) → cíl 256 GB; vyžaduje zmenšení přes dočasný soubor"
images_disk sdh ext4 ZALOHY /home/partimag
target sdf 500118192 "Crucial MX500 250GB" sata 0
image_begin "$S/disks/sdh1/DEBIAN-500G" sda 976773168 \
    "label: gpt" "label-id: 3B2A1C0D-4E5F-4061-8273-94A5B6C7D8E9" "device: /dev/sda" "unit: sectors" \
    "first-lba: 2048" "last-lba: 976773134" "sector-size: 512"
image_part 1 "start=2048, size=1048576, type=$GPT_EFI, uuid=AA11BB22-CC33-4D44-8E55-FF6677889900, name=\"EFI System Partition\"" \
    vfat ptcl zst $(( 1048576 * 512 )) $(( 6 * 1048576 )) "" 1B2C-3D4E
image_part 2 "start=1050624, size=975722511, type=$GPT_LINUX, uuid=BB22CC33-DD44-4E55-8F66-007788990011" \
    ext4 ptcl zst $(( 975722511 * 512 )) $(( 60 * GB )) "" 0d1e2f30-4a5b-4c6d-9e8f-102132435465 2

# =============================================================================
# toosmall – data se nevejdou → konec před zápisem
# =============================================================================
scenario toosmall "obraz 500 GB (data 300 GB) → cíl 256 GB; musí skončit před zápisem"
images_disk sdh ext4 ZALOHY /home/partimag
target sdf 500118192 "Crucial MX500 250GB" sata 0
image_begin "$S/disks/sdh1/DEBIAN-PLNY" sda 976773168 \
    "label: gpt" "label-id: 3B2A1C0D-4E5F-4061-8273-94A5B6C7D8EA" "device: /dev/sda" "unit: sectors" \
    "first-lba: 2048" "last-lba: 976773134" "sector-size: 512"
image_part 1 "start=2048, size=1048576, type=$GPT_EFI, uuid=AA11BB22-CC33-4D44-8E55-FF6677889901, name=\"EFI System Partition\"" \
    vfat ptcl zst $(( 1048576 * 512 )) $(( 6 * 1048576 )) "" 1B2C-3D4F
image_part 2 "start=1050624, size=975722511, type=$GPT_LINUX, uuid=BB22CC33-DD44-4E55-8F66-007788990012" \
    ext4 ptcl zst $(( 975722511 * 512 )) $(( 300 * GB )) "" 0d1e2f30-4a5b-4c6d-9e8f-102132435466 5

# =============================================================================
# windows – EFI + MSR + NTFS + Recovery, NVMe
# =============================================================================
scenario windows "Windows 11: EFI + MSR + NTFS + Recovery, NVMe 512 GB → NVMe 1 TB"
blk sdb "" disk 2000398934016 "" "" "" "Seagate Expansion" NAA1BCD2 usb 1 0 ""
blk sdb1 sdb part 2000397885440 ntfs BACKUP 01D9A1B2C3D4E5F6 "" "" usb 1 0 /home/partimag
mkdir -p "$S/disks/sdb1"
blk nvme0n1 "" disk 512110190592 "" "" "" "Samsung SSD 980 PRO 512GB" S5GXNF0R123456 nvme 0 0 ""
blk nvme1n1 "" disk 1024209543168 "" "" "" "WD Blue SN580 1TB" 23456789ABCD nvme 0 0 ""
target_dump nvme0n1 "label: gpt" "label-id: 11111111-2222-4333-8444-555555555555" "device: /dev/nvme0n1" "unit: sectors" \
    "first-lba: 34" "last-lba: 1000215182" "sector-size: 512" "" \
    "/dev/nvme0n1p1 : start=2048, size=1000213135, type=$GPT_MSDATA, uuid=12345678-1234-4234-8234-123456789ABC, name=\"data\""
blk nvme0n1p1 nvme0n1 part 512109142016 ntfs DATA 4E5A6B7C8D9E0F10 "" "" nvme 0 0 ""
image_begin "$S/disks/sdb1/WIN11-2026-09" nvme0n1 1000215216 \
    "label: gpt" "label-id: 7C1E5A2B-3D4F-4A6B-9C8D-0E1F2A3B4C5D" "device: /dev/nvme0n1" "unit: sectors" \
    "first-lba: 34" "last-lba: 1000215182" "sector-size: 512"
image_part 1 "start=2048, size=204800, type=$GPT_EFI, uuid=0A1B2C3D-4E5F-4061-8273-A4B5C6D7E8F9, name=\"EFI system partition\", attrs=\"GUID:63\"" \
    vfat ptcl zst $(( 204800 * 512 )) $(( 28 * 1048576 )) "" 4C3D-2E1F
image_part 2 "start=206848, size=32768, type=$GPT_MSR, uuid=1B2C3D4E-5F60-4172-8394-B5C6D7E8F90A, name=\"Microsoft reserved partition\"" \
    "" - none 0 0 "" ""
image_part 3 "start=239616, size=998686720, type=$GPT_MSDATA, uuid=2C3D4E5F-6071-4283-94A5-C6D7E8F90A1B, name=\"Basic data partition\"" \
    ntfs ptcl zst $(( 998686720 * 512 )) $(( 80 * GB )) Windows 5A4B3C2D1E0F9A8B 4
image_part 4 "start=998926336, size=1288847, type=$GPT_RECOVERY, uuid=3D4E5F60-7182-4394-A5B6-D7E8F90A1B2C, attrs=\"RequiredPartition GUID:63\"" \
    ntfs ptcl zst $(( 1288847 * 512 )) $(( 520 * 1048576 )) "" 6B5C4D3E2F1A0B9C

# =============================================================================
# noimage – disk s obrazy neobsahuje žádný obraz
# =============================================================================
scenario noimage "disk s obrazy (sdh1) neobsahuje žádný obraz Clonezilly"
images_disk sdh ext4 ZALOHY ""
target sdf 976773168 "Samsung SSD 870 EVO 500GB" sata 0
mkdir -p "$S/disks/sdh1/dokumenty/2025" "$S/disks/sdh1/fotky"
echo "jen dokument" >"$S/disks/sdh1/dokumenty/readme.txt"

# =============================================================================
# mounted – cílový disk má připojený oddíl
# =============================================================================
scenario mounted "cílový disk sdf má připojený oddíl sdf1 (/mnt/data) – nesmí se použít bez odpojení"
images_disk sdh ext4 ZALOHY /home/partimag
blk sdf "" disk 500107862016 "" "" "" "Samsung SSD 870 EVO 500GB" S5Y1NX0T654321 sata 0 0 ""
blk sdf1 sdf part 500106813440 ext4 DATA 77aa88bb-99cc-4dde-8eff-001122334455 "" "" sata 0 0 /mnt/data
target_dump sdf "label: gpt" "label-id: 99999999-8888-4777-8666-555555555555" "device: /dev/sdf" "unit: sectors" \
    "first-lba: 2048" "last-lba: 976773134" "sector-size: 512" "" \
    "/dev/sdf1 : start=2048, size=976771087, type=$GPT_LINUX, uuid=ABCDEF01-2345-4678-89AB-CDEF01234567"
image_begin "$S/disks/sdh1/UBUNTU-2026-09" sda 250069680 \
    "label: gpt" "label-id: 6A1F3E2B-9C4D-4E5F-8A7B-1C2D3E4F5A6C" "device: /dev/sda" "unit: sectors" \
    "first-lba: 2048" "last-lba: 250069646" "sector-size: 512"
image_part 1 "start=2048, size=1048576, type=$GPT_EFI, uuid=1D2E3F40-5A6B-4C7D-8E9F-0A1B2C3D4E60, name=\"EFI System Partition\"" \
    vfat ptcl zst $(( 1048576 * 512 )) $(( 31 * 1048576 )) "" 7A3C-1F2F
image_part 2 "start=1050624, size=249019023, type=$GPT_LINUX, uuid=2E3F4051-6B7C-4D8E-9FA0-1B2C3D4E5F61" \
    ext4 ptcl zst $(( 249019023 * 512 )) $(( 45 * GB )) "" 9f1c2d3e-4b5a-4c6d-8e7f-0a1b2c3d4e60 3

# =============================================================================
# beckhoff-xp – MBR, 1 oddíl NTFS od sektoru 63, CF 2 GB → SSD 32 GB
# =============================================================================
scenario beckhoff-xp "Beckhoff CP (XP Embedded): MBR, 1× NTFS od sektoru 63, CF 2 GB → SSD 32 GB"
images_disk sdh ntfs BECKHOFF /home/partimag
target sdf 62533296 "Transcend SSD 32GB" sata 0
image_begin "$S/disks/sdh1/CP6201-XPE-2026" sda 4001760 \
    "label: dos" "label-id: 0x8c3f12a7" "device: /dev/sda" "unit: sectors" "sector-size: 512"
image_part 1 "start=63, size=4001697, type=7, bootable" \
    ntfs ptcl gz $(( 4001697 * 512 )) $(( 1200 * 1048576 )) "" 6E4A2C0B9D8F7E61
image_mbr 62

# =============================================================================
# beckhoff-ce – MBR, 1 oddíl FAT16 (Windows CE), CF 512 MB → CF 1 GB
# =============================================================================
scenario beckhoff-ce "Beckhoff CP (Windows CE): MBR, 1× FAT16 od sektoru 63, CF 512 MB → CF 1 GB, bez fatresize" "fatresize"
images_disk sdh ext4 ZALOHY /home/partimag
target sdf 2001888 "CF Card Reader 1GB" usb 0 1
image_begin "$S/disks/sdh1/CX9001-CE6" sda 1000944 \
    "label: dos" "label-id: 0x00000000" "device: /dev/sda" "unit: sectors" "sector-size: 512"
image_part 1 "start=63, size=1000881, type=6, bootable" \
    vfat ptcl gz $(( 1000881 * 512 )) $(( 40 * 1048576 )) "" 3A21-0F1E
image_mbr 62

# =============================================================================
# beckhoff-w7 – MBR, System Reserved + systém NTFS, SSD 32 GB → 16 GB
# =============================================================================
scenario beckhoff-w7 "Beckhoff CP (Win Embedded 7): MBR, System Reserved + NTFS, SSD 32 GB → 16 GB (data 9 GB)"
images_disk sdh ext4 ZALOHY /home/partimag
target sdf 31277232 "Transcend SSD 16GB" sata 0
image_begin "$S/disks/sdh1/CP2215-WES7" sda 62533296 \
    "label: dos" "label-id: 0x5d2c8e41" "device: /dev/sda" "unit: sectors" "sector-size: 512"
image_part 1 "start=2048, size=204800, type=7, bootable" \
    ntfs ptcl gz $(( 204800 * 512 )) $(( 30 * 1048576 )) "System Reserved" 1C2D3E4F5A6B7C8D
image_part 2 "start=206848, size=62326448, type=7" \
    ntfs ptcl gz $(( 62326448 * 512 )) $(( 9 * GB )) "" 2D3E4F5A6B7C8D9E 2
image_mbr 2047


# Další disk do téhož obrazu (vícediskový obraz): image_add_disk <disk> <sektory> <sfdisk-hlavička…>
image_add_disk() {
    IMG_DISK=$1
    echo "$(cat "$IMG/disk") $1" >"$IMG/disk"
    printf 'Model: CF (scsi)\nDisk /dev/%s: %ss\nSector size (logical/physical): 512B/512B\n' "$1" "$2" >"$IMG/$1-pt.parted"
    shift 2
    printf '%s\n' "$@" >"$IMG/$IMG_DISK-pt.sf"
    echo >>"$IMG/$IMG_DISK-pt.sf"
}

# =============================================================================
# beckhoff-2disk – záloha 2 CF karet (sda: systém NTFS, sdb: data NTFS), obě od sektoru 63
# =============================================================================
scenario beckhoff-2disk "Beckhoff: záloha 2 CF karet (sda systém 4 GB + sdb data 2 GB) → jeden SSD 120 GB nebo dva disky"
images_disk sdh ntfs ZALOHY ""
target sdf 234441648 "KINGSTON SA400S37120G" sata 0
target sdg 62533296 "Transcend SSD 32GB" sata 0
image_begin "$S/disks/sdh1/cell17-git-2025-10-19-12-img" sda 7846272 \
    "label: dos" "label-id: 0x6df0d34f" "device: /dev/sda" "unit: sectors" "sector-size: 512"
image_part 1 "start=63, size=7846209, type=7, bootable" \
    ntfs ptcl zst $(( 7846209 * 512 )) $(( 2032 * 1048576 )) "" 4E91C1F52C1F821B 2
image_mbr 62
image_add_disk sdb 3909744 \
    "label: dos" "label-id: 0x1a2b3c4d" "device: /dev/sdb" "unit: sectors" "sector-size: 512"
image_part 1 "start=63, size=3909681, type=7" \
    ntfs ptcl gz $(( 3909681 * 512 )) $(( 600 * 1048576 )) DATA 7C6B5A4938271605
echo "Fixtures vytvořeny v $SIM:"
ls "$SIM"
