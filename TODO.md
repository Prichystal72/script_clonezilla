# TODO – co ještě nebylo vyzkoušeno a možné upgrady

Stav k verzi 1.2.10 (4. 10. 2026). Navíc `test/test-matrix.sh`: 61 kombinací do 3 TB, 583 kontrol; ve VM s USB disky ověřen klon, záloha (1 i 2 disky) a sloučená obnova. Ověřeno: `test/test-loop.sh` (185 kontrol na skutečných datech),
`test/test-sim.sh` (39 kontrol) a ručně ve VMware + Clonezilla 3.3.3-37 obnova záloh Beckhoff CF
(1 karta i 2 karty → jeden SSD).

## 1. Ověřit na skutečném hardwaru

- [ ] **Boot panelu Beckhoff** po obnově – XP Embedded (start 63) z 4GB CF na 120GB SSD
- [ ] Boot panelu po **sloučení 2 karet** na jeden disk – písmeno datového oddílu (D:/E:), cesty v TwinCAT
- [ ] Boot **WES7** (System Reserved + systém) po zmenšení na menší disk
- [ ] Boot **Windows CE** po obnově FAT16 bez `fatresize` (FAT vytvořená znovu, boot kód z originálu, NK.BIN)
- [ ] Panel s **EWF/FBWF** write filtrem – chování po změně velikosti
- [ ] Obnova na **CF/CFast kartu** v USB čtečce (malá média, MiB)
- [ ] Obnova přímo na **interní disk** panelu nebo PC (Clonezilla nabootovaná na tom stroji)
- [ ] Clonezilla na **reálném počítači** (ne VM): konzole 80×25, framebuffer, česká klávesnice (Y/Z)
- [ ] Kopie logu do `restore-logs/` na flashce, když Clonezilla bootuje z flashky (`/run/live/medium`)

- [ ] **Barvy oken** (zdroj zelená, cíl červená) ve VM s `dialog` – v testech jsou ověřené jen soubory motivu a plain režim
- [ ] **Flashka** upravená `vm/make-flash.sh` (BIOS i UEFI menu): ověřit boot na skutečném počítači – BIOS / legacy i UEFI
      (UEFI úprava `boot/grub/grub.cfg` je zkoušená jen na kopii souboru)
- [ ] Čeština s diakritikou na konzoli Clonezilly (teď se zobrazuje bez háčků a čárek)

## 2. Funkce ověřené jen v simulaci (ostře nespuštěné)

- [ ] Menu 2 – obnova vybraných oddílů na existující oddíly
- [ ] Menu 3 (3/1, 3/2, 3/3) – interaktivní výběr disků a oddílů ve VM s Clonezillou (příkazový řádek `--save-disk`
      / `--save-part` / `--separate` je ověřený na loop discích, menu jen v simulaci)
- [ ] Menu 1 – *Více záloh najednou* a *Vlastní rozdělení* ve VM (parametry `--image A,B`, `--groups` jsou ověřené na loop discích)
- [ ] Menu 2 – opakování obnovy vybraných oddílů z dalšího disku / další zálohy
- [ ] Menu 4 – klon disk → disk
- [ ] Menu 5/2 – prohlížení obsahu zálohy (obnova do dočasného souboru + mount)
- [ ] Menu 8 – kontrola FS, opravy bootu (EFI záznamy `efibootmgr`, GRUB přes chroot, MBR kód, `sgdisk -e`)
- [ ] Menu 8/3 – převod MBR ↔ GPT (`sgdisk -m` / `-g`)
- [ ] Menu 9/1 – bezpečné smazání (`blkdiscard`, `nvme format`, ATA secure erase)
- [ ] Menu 9/2 – předání Clonezille (`ocs-sr`), přepínače z `ocs-sr --help`
- [ ] Editor: smazání oddílu a změna LABEL ostře (zmenšení, zvětšení a přesun ověřeny)

## 3. Formáty a souborové systémy

- [ ] **Obraz vytvořený skriptem obnovit standardní Clonezillou** (kritérium přijetí ze zadání) – jednodiskový i
      vícediskový (`--save-disk sda,sdb`, soubory `disk` a `parts` se všemi disky) a obraz jen vybraných oddílů (`restoreparts`)
- [ ] FAT / exFAT se při zvětšení / zmenšení vytváří znovu (kopie souborů): mění se pořadí souborů a FAT ztrácí atributy H/S
      – ověřit boot Windows CE / DOS z takto zvětšené FAT
- [ ] Odhad minima ext4 z obrazu je přísný (metadata se počítají jako data) – velký prázdný ext4 na malý disk se odmítne
- [ ] Starší obrazy `ntfsclone` (`*.ntfs-img.*`) a `dd` (`*.dd-img.*`)
- [ ] Komprese `gz`, `xz`, `bz2`, `lz4`, `lzo` ostře (ostře ověřeno jen `zstd`)
- [ ] Data rozdělená do více souborů (`.aa`, `.ab`, …) ostře – obrazy nad 4 GiB
- [ ] UEFI/GPT Windows (EFI + MSR + NTFS + Recovery) ostře – přesun Recovery na konec disku
- [ ] XFS (zmenšení jen kopií souborů), btrfs, f2fs, exFAT
- [ ] Swap oddíl (nové `mkswap` se stejným UUID)
- [ ] MBR s rozšířeným a logickými oddíly
- [ ] Disky s 4K sektory (4Kn) – přepočet pozic
- [ ] LVM, RAID, LUKS, BitLocker – jen ověřit, že skript odmítne / upozorní

## 4. Možné upgrady

- [ ] Editor oddílů: vytvoření nového oddílu (`mkfs` + LABEL), změna typu oddílu
- [ ] Nastavení geometrie CHS při zápisu tabulky (teď se jen porovná a upozorní)
- [ ] Menu 8 → „Přesunout záložní GPT na konec (sgdisk -e)“: sgdisk hlásí u tabulek s first-lba 2048 falešný překryv
      (obnova ho už nepoužívá) – nahradit zápisem přes sfdisk
- [ ] Obnova ve více krocích: nejdřív zvolit všechny cíle a potvrdit je, teprve potom zapisovat (teď se zapisuje na
      první cíl před dotazem na druhý; parametry `--target` / `--yes-i-know` se kontrolují předem všechny)
- [ ] Obnova oddílů z obrazu jen vybraných oddílů jako celého disku (teď se odmítne, jde jen menu 2)
- [ ] `--sizes` i pro obnovu „každý disk zvlášť“
- [ ] Průběh partclone v okně dialogu (gauge) místo textového výpisu
- [ ] Tabulky a souhrny vyzkoušet a případně zúžit pro konzoli 80 sloupců
- [ ] Automatický start skriptu po bootu flashky (`ocs_live_run` v `syslinux.cfg` / `grub.cfg`) – připravit hotovou flashku
- [ ] Odhad doby obnovy podle velikosti dat
- [ ] Ověření obrazu (`partclone.chkimg`) volitelně před každou obnovou
- [ ] Anglická verze textů (jazyk podle nastavení)

## 5. Mimo skript

- [ ] Windows na vývojovém notebooku: v proměnné PATH se nerozbaluje `%SystemRoot%\system32`
      (příkazy `wsl`, `cmd` nejdou spustit jménem) – opravit uložení PATH jako REG_EXPAND_SZ (vyžaduje správce)
