# TODO – co ještě nebylo vyzkoušeno a možné upgrady

Stav k verzi 1.2.13 (4. 10. 2026). Navíc `test/test-matrix.sh`: 61 kombinací do 3 TB, 583 kontrol; ve VM s USB disky ověřen klon, záloha (1 i 2 disky) a sloučená obnova. Ověřeno: `test/test-loop.sh` (185 kontrol na skutečných datech),
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

## 2. Funkce menu

Ověřeno 4. 10. 2026 klávesnicí na loop discích (`test/test-menus.sh`, 44 kontrol) a ve skutečné Clonezille v QEMU:
- [x] 5/1 informace o záloze + `partclone.chkimg` + SHA1SUMS, 5/2 prohlížení obsahu (připojení a úklid)
- [x] 6 informace o discích, 7 editor (zmenšení ext4 i FAT, přesun, LABEL, smazání oddílu)
- [x] 8/1 kontrola a oprava FS s výsledkem, 8/2 boot kód MBR ze zálohy, záložní GPT na konec (`sfdisk --relocate`)
- [x] 8/3 převod MBR → GPT → MBR (data beze změny), 9/1 smazání (wipefs), 9/3 nastavení (komprese gzip)
- [x] 9/2 předání Clonezille (`ocs-sr restoredisk -k1`) ve skutečné Clonezille – obnova WIN na větší disk
- [ ] 8/2 UEFI záznam (`efibootmgr`) – jen hláška v režimu BIOS; na UEFI počítači neověřeno
- [ ] 8/2 reinstalace GRUB přes chroot – neověřeno (potřebuje skutečný Linux s GRUB)
- [ ] 9/1 `blkdiscard`, NVMe format, ATA Secure Erase – neověřeno (jen wipefs)
- [ ] 3/3 disky i oddíly dohromady a 1 „Vlastní rozdělení“ / „Více záloh“ – jen simulace a loop testy, ne v dialog UI

## 3. Formáty a souborové systémy

- [x] **Obraz vytvořený skriptem obnovit standardní Clonezillou** – ověřeno 4. 10. 2026 (QEMU, Clonezilla 3.3.3,
      `ocs-sr restoredisk`): MBR FAT32 + NTFS, dva disky v jedné záloze, GPT; obraz jen vybraných oddílů (`restoreparts`) zatím ne
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
