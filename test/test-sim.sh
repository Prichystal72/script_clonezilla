#!/usr/bin/env bash
# Automatický průchod simulačními scénáři (kap. 10.1 / kritéria přijetí).
# Nepotřebuje root ani Linux – stačí bash 4+ (i Git Bash na Windows).
# Spuštění: bash test/test-sim.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/restore.sh"
PASS=0 FAIL=0

# check <název> <scénář> <vstup> <čekaný_kód> <musí_obsahovat…> [-- <nesmí_obsahovat…>]
check() {
    local name=$1 scen=$2 input=$3 want=$4; shift 4
    local out rc p bad=0 neg=0
    out=$(printf '%b' "$input" | bash "$R" --simulate="$scen" 2>&1); rc=$?
    for p in "$@"; do
        if [[ "$p" == -- ]]; then neg=1; continue; fi
        if (( neg )); then
            grep -qE -- "$p" <<<"$out" && { echo "    nesmí obsahovat: $p"; bad=1; }
        else
            grep -qE -- "$p" <<<"$out" || { echo "    chybí: $p"; bad=1; }
        fi
    done
    grep -qE 'Chyba na řádku|command not found|unbound variable|bad array subscript' <<<"$out" && {
        echo "    běhová chyba:"; grep -E 'Chyba na řádku|command not found|unbound|bad array' <<<"$out" | head -3 | sed 's/^/      /'; bad=1; }
    (( rc == want )) || { echo "    návratový kód $rc, čekáno $want"; bad=1; }
    if (( bad )); then FAIL=$((FAIL + 1)); echo "✘ $name"; else PASS=$((PASS + 1)); echo "✔ $name"; fi
}

# Vstupy jsou ČÍSLA voleb z nabídek (pořadí disků je dané fixtures lsblk.P).
# bigger/smaller/…: disky sda (flashka), sdh (obrazy), sdf (cíl) → sdf = 3
# windows: sda, sdb (obrazy), nvme0n1, nvme1n1 → nvme0n1 = 3, nvme1n1 = 4
# režim: 1 = A (zbytek), 2 = B (proporcionálně), 3 = C (ručně), 4 = D (1:1)
echo "== Hlavní scénáře =="
check "bigger: sken, připojení, růst ext4" bigger \
    '1\n2\n1\n1\n3\n1\nsdf\n0\n' 0 \
    'sdh1: /clonezilla/UBUNTU-2026-09' 'mount -o ro /dev/sdh1 /home/partimag' 'sdf2 : start=1050624, size=975722511' \
    'resize2fs /dev/sdf2' 'sgdisk -v /dev/sdf' 'Hotovo' 'umount /home/partimag'
check "bigger: chráněné disky nejdou vybrat" bigger \
    '1\n1\n1\n1\n2\n\n0\n' 0 \
    'nelze použít jako cíl: flashka s Clonezillou' 'nelze použít jako cíl: disk s obrazy' -- 'wipefs'
check "bigger: špatné potvrzení = nic se nezapíše" bigger \
    '1\n1\n1\n3\n1\nsdg\n0\n' 0 \
    'Potvrzení nesouhlasí' -- 'wipefs' 'sfdisk --wipe'
check "bigger: neplatná volba se odmítne" bigger \
    '1\n1\n1\n9\nabc\n3\n1\nsdf\n0\n' 0 'Neplatná volba' 'Hotovo'
check "smaller: zmenšení přes dočasný soubor" smaller \
    '1\n1\n3\n1\nsdf\n0\n' 0 \
    'ZMENŠIT' 'remount,rw /home/partimag' 'truncate -s' 'resize2fs /dev/loopX' 'partclone.ext4 -b -I -s /dev/loopX -o /dev/sdf2' 'Hotovo'
check "toosmall: konec PŘED zápisem" toosmall \
    '1\n1\n3\n1\n0\n' 0 \
    'chybí' 'Nic nebylo zapsáno' 'nedostatek místa \(kód 4\)' -- 'wipefs' 'sfdisk --wipe' 'partclone'
check "windows: NVMe názvy, Recovery na konec" windows \
    '1\n1\n4\n1\nnvme1n1\n0\n' 0 \
    'nvme1n1p3 : start=239616, size=1998880768' 'nvme1n1p4 : start=1999120384' 'attrs="RequiredPartition GUID:63"' \
    'nemá data \(msr\)' 'ntfsresize --force --no-progress-bar /dev/nvme1n1p3' 'Hotovo'
check "windows: proporcionální režim" windows \
    '1\n1\n4\n2\nnvme1n1\n0\n' 0 'Hotovo'
check "windows: režim 1:1" windows \
    '1\n1\n4\n4\nnvme1n1\n0\n' 0 'nvme1n1p3 : start=239616, size=998686720' 'Hotovo'
check "windows: ruční velikost oddílu (300G)" windows \
    '1\n1\n4\n3\n300G\nnvme1n1\n0\n' 0 'nvme1n1p3 : start=239616, size=629145600' 'Hotovo'
check "windows: ruční velikost pod minimum → znovu" windows \
    '1\n1\n4\n3\n1G\n300G\nnvme1n1\n0\n' 0 'Pod minimum' 'Hotovo'

echo "== Záloha se 2 disky (Beckhoff CF + CF) =="
# disky: sda flashka, sdh obrazy (nepřipojený → výběr 1 = sdh1), sdf cíl 120 GB, sdg druhý cíl 32 GB → sdf = 3, sdg = 4
# volba: 1 = sloučit na jeden disk, 2 = každý zvlášť, 3 = jen sda, 4 = jen sdb
check "2 disky: sloučit na jeden (režim A)" beckhoff-2disk \
    '1\n1\n1\n1\n3\n1\nsdf\n0\n' 0 \
    'obsahuje 2 disky' 'Bootovací disk ze zálohy: sda' 'sdf1 : start=63, size=[0-9]+, type=7, bootable' 'sdf2 : start=' \
    'cat .*sdb1.ntfs-ptcl-img.gz.aa' 'hidden sectors' 'záložní boot sektor NTFS' 'jiné písmeno' 'Hotovo'
check "2 disky: sloučit, velikosti ručně 20G + max" beckhoff-2disk \
    '1\n1\n1\n1\n3\n3\n20G\nmax\nsdf\n0\n' 0 'sdf1 : start=63, size=41943040' 'sdf2 : start=41945088' 'Hotovo'
check "2 disky: každý na jiný cíl" beckhoff-2disk \
    '1\n1\n1\n2\n3\n1\nsdf\n4\n1\nsdg\n0\n' 0 'sdf1 : start=63' 'sdg1 : start=63' 'sda → sdf' -- 'sdf2 :'
check "2 disky: jen druhý disk" beckhoff-2disk \
    '1\n1\n1\n4\n3\n1\nsdf\n0\n' 0 'sdb1.ntfs-ptcl-img' 'Hotovo' -- 'sda1.ntfs-ptcl-img'
check "2 disky: vlastní rozdělení sda → cíl 1, sdb → cíl 2" beckhoff-2disk \
    '1\n1\n1\n5\n1\n2\n3\n1\nsdf\n4\n1\nsdg\n0\n' 0 'sdf1 : start=63' 'sdg1 : start=63' 'sda → sdf' 'sdb → sdg' -- 'sdf2 :'
check "2 disky: vlastní rozdělení obou na stejný cíl = sloučení" beckhoff-2disk \
    '1\n1\n1\n5\n1\n1\n3\n1\nsdf\n0\n' 0 'sdf1 : start=63' 'sdf2 : start=' 'Hotovo'
check "2 disky: vlastní rozdělení, sda vynechat (0)" beckhoff-2disk \
    '1\n1\n1\n5\n0\n1\n3\n1\nsdf\n0\n' 0 'sdb1.ntfs-ptcl-img' 'Hotovo' -- 'sda1.ntfs-ptcl-img'
check "noimage: žádný obraz" noimage \
    '1\n1\nq\n0\n' 0 'nebyl nalezen žádný obraz' -- 'wipefs'
check "mounted: připojený cíl je blokovaný" mounted \
    '1\n1\n3\n0\n\n0\n' 0 'CHRÁNĚNO: připojeno: sdf1' 'má připojené oddíly' -- 'wipefs'
check "mounted: po odpojení pokračuje" mounted \
    '1\n1\n3\n1\n1\nsdf\n0\n' 0 'umount /dev/sdf1' 'Hotovo'

echo "== Beckhoff / legacy =="
check "beckhoff-xp: start 63, MBR, signature" beckhoff-xp \
    '1\n1\n3\n1\nsdf\n0\n' 0 \
    'legacy \(Beckhoff\)' 'Oddíl zabere celý disk' 'label-id: 0x8c3f12a7' 'sdf1 : start=63, size=62533233, type=7, bootable' \
    'bs=446 count=1' 'seek=1' 'hidden sectors.*63' 'EWF/FBWF' 'TwinCAT' 'Hotovo'
check "beckhoff-ce: FAT16, MiB, bez fatresize" beckhoff-ce \
    '1\n1\n3\n1\nsdf\n0\n' 0 \
    'sdf1 : start=63, size=2001825, type=6, bootable' '488 MiB' 'Zvětšení FAT' 'mkfs.fat -F 16' 'Hotovo'
check "beckhoff-w7: SR pevný, systém zmenšen" beckhoff-w7 \
    '1\n1\n3\n1\nsdf\n0\n' 0 \
    'sdf1 : start=2048, size=204800, type=7, bootable' 'sdf2 : start=206848, size=31070384' \
    'ntfsresize --force --no-progress-bar -s' 'label-id: 0x5d2c8e41' 'Hotovo' -- 'EWF'

echo "== Záloha více disků a oddílů (scénář twodisks: sdb 2 oddíly, sdc 1 oddíl, prázdný sdf) =="
# pořadí: co zálohovat → kam uložit (sdh1 = 1) → jeden obraz (1) / každá položka zvlášť (2) → název (prázdný = výchozí)
# položky: disky sdh=1 sdb=2 sdc=3 sdf=4; oddíly sdh1=1 sdb1=2 sdb2=3 sdc1=4; disky i oddíly: sdh=1 sdh1=2 sdb=3 sdb1=4 sdb2=5 sdc=6 sdc1=7
check "záloha 2 disků do JEDNOHO obrazu" twodisks \
    '3\n1\n2 3\n1\n1\n\n0\n' 0 "echo 'sdb sdc' > " "echo 'sdb1 sdb2 sdc1' > " 'sfdisk --dump /dev/sdc' 'sdc-mbr' 'partclone.ext4 -c -s /dev/sdc1' 'partclone.ntfs -c -s /dev/sdb2'
check "záloha 2 disků do SAMOSTATNÝCH obrazů" twodisks \
    '3\n1\n2 3\n1\n2\nPANEL\n0\n' 0 "echo 'sdb' > '/home/partimag/PANEL-sdb/disk'" "echo 'sdc' > '/home/partimag/PANEL-sdc/disk'" 'Hotovo: 2 obrazů'
check "záloha oddílů z různých disků do jednoho obrazu" twodisks \
    '3\n2\n3 4\n1\n1\n\n0\n' 0 "echo 'sdb sdc' > " "echo 'sdb2 sdc1' > " -- 'sdb1.ext4-ptcl'
check "záloha disk + oddíl jiného disku" twodisks \
    '3\n3\n6 4\n1\n1\n\n0\n' 0 "echo 'sdc sdb' > " "echo 'sdc1 sdb1' > " -- 'sdb2.ntfs-ptcl'
check "záloha disku bez oddílů se odmítne" twodisks \
    '3\n1\n4\n1\n\n0\n' 0 'nemá žádný oddíl' -- 'sfdisk --dump'

echo "== Ostatní položky menu =="
# Hlavní menu: 1 obnova, 2 vybrané oddíly, 3 záloha (1 disk / 2 oddíl), 4 klon, 5 obraz (1 info / 2 obsah),
# 6 disky, 7 editor, 8 opravy (1 FS / 2 boot / 3 MBR↔GPT), 9 další (1 smazání / 2 ocs-sr / 3 nastavení)
# Editor: 1 velikost, 2 přesun, 3 smazat, 4 LABEL, 5 zarovnání, 6 zpět, 7 provést/použít, 8 odejít
check "menu 3/1: záloha disku" windows '3\n1\n1\n\n0\n' 0 'sfdisk --dump /dev/nvme0n1' 'sha1sum' 'Záloha hotová'
check "menu 3/1: nic neoznačeno → nápověda, ne tichý návrat" windows '3\n1\n\n\n0\n\n0\n' 0 'Nic není označené'
check "menu 5/1: info + chkimg" bigger '5\n1\n1\n1\n1\n0\n' 0 'partclone.chkimg' 'všechny oddíly'
check "menu 6: info o discích" bigger '6\n3\n0\n' 0 'TRIM: ano'
check "menu 7: editor zmenšení + undo" windows '7\n3\n1\n1\n-100G\n6\n1\n1\n-100G\n7\nnvme0n1\n8\n0\n' 0 \
    'shrink 1' 'ntfsresize --force --no-progress-bar -s' 'sfdisk --no-reread -q --wipe-partitions never -N 1'
check "menu 7: přes max odmítnuto" windows '7\n3\n1\n1\n+5G\n8\n0\n' 0 'se nevejde'
check "menu 4: klon disku" windows '4\n1\n4\n1\nnvme1n1\n0\n' 0 'partclone.ntfs -c -q -s /dev/nvme0n1p1 -o -' 'partclone.ntfs -r -s - -o /dev/nvme1n1p1' 'Hotovo'
check "menu 9/1: smazání 2× potvrzení" bigger '9\n1\n3\n1\nsdf\n1\nsdf\n0\n' 0 'wipefs -a /dev/sdf'
check "menu 9/2: ocs-sr" windows '9\n2\n1\n4\nnvme1n1\n0\n' 0 'ocs-sr -e1 auto'
check "menu 2: vybrané oddíly" windows '2\n1\n2\n1\nnvme0n1p1\nn\n0\n' 0 'partclone.ntfs -r -s - -o /dev/nvme0n1p1'
check "menu 5/2: prohlížení obrazu" windows '5\n2\n1\n3\n/tmp\n0\n' 0 'mount -o ro /dev/loopX'
check "menu 9/3: nastavení" bigger '9\n3\n2\n2\n\n0\n' 0 'Komprese'
check "menu 8/1: kontrola FS" windows '8\n1\n1\n0\n0\n' 0 'ntfsfix -n /dev/nvme0n1p1'
check "menu: jednociferné volby (1 ≠ 10)" bigger '1\n\n0\n' 0 -- 'Kontrola souborového systému'

echo "== CLI =="
# result <název> <příkaz-podmínka…> – započte výsledek podmínky
result() {
    local name=$1; shift
    if "$@"; then PASS=$((PASS + 1)); echo "✔ $name"; else FAIL=$((FAIL + 1)); echo "✘ $name"; fi
}
has() { grep -q -- "$1" <<<"$out"; }

out=$(bash "$R" --simulate=bigger --list-disks 2>&1)
result "--list-disks" has 'flashka s Clonezillou'
out=$(bash "$R" --simulate=twodisks --source-dev /dev/sdh1 --save-disk sdb --save-part sdc1 --separate --name P 2>&1)
result "--save-disk + --save-part + --separate" has 'Hotovo: 2 obrazů (P-sdb P-sdc1)'
out=$(bash "$R" --simulate=twodisks --source-dev /dev/sdh1 --save-disk sdb,sdc --save-part sdc1 --name X 2>&1)
result "--save-part oddílu z už zálohovaného disku se nezdvojí" has "echo 'sdb1 sdb2 sdc1' >"
bash "$R" --simulate=twodisks --source-dev /dev/sdh1 --save-disk sdb1 >/dev/null 2>&1; rc=$?
result "--save-disk s oddílem → kód 2" test "$rc" = 2
out=$(bash "$R" --simulate=windows --list-images 2>&1)
result "--list-images" has 'WIN11-2026-09'
bash "$R" --simulate=nesmysl >/dev/null 2>&1; rc=$?
result "neznámý scénář → kód 2" test "$rc" = 2
if [[ "${EUID:-$(id -u)}" != 0 ]]; then
    out=$(bash "$R" --list-disks 2>&1); rc=$?
    # shellcheck disable=SC2016  # podmínka se vyhodnotí až v eval
    result "bez rootu → kód 2 + srozumitelná hláška" eval '[[ $rc == 2 ]] && has "musí běžet jako root"'
fi
tmp=$(mktemp -d); sed 's/$/\r/' "$R" >"$tmp/restore.sh"
out=$(bash "$tmp/restore.sh" --help 2>&1); rc=$?
# shellcheck disable=SC2016  # podmínka se vyhodnotí až v eval
result "CRLF detekce" eval '[[ $rc == 1 ]] && has CRLF'
rm -rf "$tmp"

echo
echo "Výsledek: $PASS OK, $FAIL chyb"
(( FAIL == 0 ))
