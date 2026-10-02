# ZADÁNÍ: `restore.sh` – univerzální offline nástroj pro obnovu a správu disků v Clonezille

> Tento soubor je kompletní zadání pro AI asistenta / vývojáře. Pracuješ přímo na USB flashce s Clonezilla Live.
> Výsledek musí fungovat **bez internetu**, jen s nástroji, které už v Clonezille jsou.
> Verze zadání: finální, 2. 10. 2026.

---

## 1. Role a cíl

Jsi zkušený Linux/Bash vývojář se znalostí Clonezilly, partclone, GPT/MBR a souborových systémů.
Napiš **jeden samostatný soubor `restore.sh`** (plus volitelně `README.md` a `test/test-loop.sh`), který:

1. Spuštěný v Clonezilla Live nahradí proklikávání menu Clonezilly.
2. Hlavní scénář: **obraz disku se 2 (nebo více) oddíly → obnova na jiný SSD, větší i menší**, s automatickým přepočtem tabulky oddílů a změnou velikosti souborových systémů.
3. Kromě toho nabízí menu dalších běžných offline operací s disky a oddíly (viz kap. 6).

**Hlavní cílový hardware:** starší průmyslové panely **Beckhoff** (řada CP, Windows XP Embedded, Windows Embedded Standard 7, Windows CE) s legacy BIOS a MBR, často na CompactFlash/CFast kartách nebo malých SSD. Pro ně platí zvláštní pravidla v kap. 5.7, která mají **přednost** před obecnými pravidly. UEFI/GPT musí skript umět také, ale je to vedlejší scénář.

Kód piš čistě, po funkcích, s komentáři v češtině. Před odevzdáním musí projít `shellcheck` bez chyb.

---

## 2. Prostředí, ve kterém skript poběží

- Clonezilla Live (Debian/Ubuntu základ), Bash 5, uživatel `user` se `sudo`, bez internetu, nic nelze doinstalovat.
- Flashka s Clonezillou je po startu připojena v `/run/live/medium` (ověř i `/lib/live/mount/medium`). Skript leží tam.
- Flashka je **FAT32** → soubor nemá executable bit. Spouštění: `sudo bash /run/live/medium/restore.sh`.
- **Obrazy NEJSOU na flashce.** Leží na samostatném disku (interní HDD, externí USB disk apod., v příkladu `/dev/sdh`). Flashka obsahuje jen Clonezillu a skript.
- Disk s obrazy po startu nemusí být připojený. Skript ho proto umí najít a připojit sám (kap. 5.0), a to stejně, jako to dělá Clonezilla: do `/home/partimag`. Pokud už je připojený, použije existující mount.
- Soubor bude editován ve VS Code (případně na Windows) → **konce řádků musí být LF**. Skript na startu zkontroluje, že sám neobsahuje `\r`, a pokud ano, srozumitelně to oznámí. Přidej `.editorconfig` / `.gitattributes` s `eol=lf`.
- Volitelně: doplň do README postup, jak skript spouštět automaticky po bootu (parametr jádra `ocs_live_run="bash /run/live/medium/restore.sh"` nebo vlastní položka v `grub.cfg` / `syslinux.cfg` flashky).

---

## 3. Formát obrazu Clonezilly (musí umět číst)

Adresář obrazu obsahuje typicky:

| Soubor | Význam |
|---|---|
| `disk` | jméno zdrojového disku (např. `sda`, `nvme0n1`) |
| `parts` | seznam oddílů (`sda1 sda2`) |
| `sda-pt.sf` | výpis `sfdisk --dump` (hlavní zdroj tabulky oddílů – GUID, typy, názvy, atributy, `last-lba`) |
| `sda-pt.parted`, `sda-pt.parted.compact` | výpis `parted` (záloha informací, velikost disku) |
| `sda-gpt-1st`, `sda-gpt-2nd`, `sda-gpt.gdisk`, `sda-mbr`, `sda-hidden-data-after-mbr` | surová data tabulky / boot sektoru |
| `sda1.vfat-ptcl-img.gz.aa`, `sda2.ext4-ptcl-img.zst.aa`, … | data oddílů |
| `sda3.ntfs-img.aa` / `sda3.dd-img.aa` | starší ntfsclone / dd obrazy |
| `swappt-sda5.info` | UUID/LABEL swapu (data swapu se neukládají) |
| `dev-fs.list`, `blkdev.list`, `blkid.list` | typy FS, UUID, LABEL |
| `lvm_vg_dev.list`, `lvm_*.conf` | LVM (pokud je) |
| `efi-nvram.dat` | záloha EFI boot záznamů |
| `Info-*.txt`, `clonezilla-img` | metadata |

Pravidla parsování datových souborů oddílů:
- Vzor názvu: `<part>.<fs>-<typ>-img.<komprese>.<suffix>`; typ: `ptcl` (partclone), `ntfs` (ntfsclone), `dd`.
- **Rozdělené soubory** (`.aa`, `.ab`, …) se spojují `cat` v abecedním pořadí.
- Komprese: `gz` (pigz → gzip), `zst` (zstd / pzstd), `xz` (pixz → xz), `bz2` (pbzip2 → bzip2), `lz4`, `lzo` (lzop), `lzip`, nebo nekomprimované. Vyber paralelní variantu, pokud existuje.
- Obnova partclone: `cat <soubory> | <dekompresor> -dc | partclone.<fs> -r -s - -o /dev/<cil> -N` (nebo bez `-N` pro textový progress; řeš podle toho, zda je terminál).
- ntfsclone: `... | ntfsclone --restore-image --overwrite /dev/<cil> -`.
- dd: `... | dd of=/dev/<cil> bs=4M status=progress conv=fsync`.
- Pro zjištění původní velikosti FS a obsazeného místa použij `partclone.info` (z hlavičky obrazu přes stdin). U ntfsclone/dd obrazů tato informace chybí → odhad z `Info-*.txt`, jinak ji řeš až po obnově.
- Názvy disků mohou být `sdX`, `nvmeXnY` (oddíly `nvmeXnYpZ`), `mmcblkX` (`pZ`), `vdX`. Napiš funkci `part_name <disk> <číslo>`, která vrátí správný název oddílu.

---

## 4. Bezpečnost (nepodkročitelné)

1. Kontrola `root` (`EUID == 0`), jinak srozumitelná hláška a konec.
2. `set -Eeuo pipefail`, `trap` na `ERR` a `EXIT` (výpis řádku chyby, úklid loop zařízení, odpojení dočasných mountů).
3. **Ochrana disků:** v nabídce cílů nikdy nenabízej (nebo výrazně zablokuj s varováním):
   - disk, ze kterého běží Clonezilla Live (flashka, `/run/live/medium`),
   - **disk s obrazy** (zdrojový disk, např. `sdh`), a to zjištěný přes `findmnt`/`lsblk` z cesty k obrazu, ne odhadem,
   - disky s připojenými oddíly (nejdřív nabídni odpojení).
4. Před každou destruktivní operací: souhrn (model, sériové číslo, velikost, co se smaže, nový layout) a potvrzení **opsáním názvu disku** (např. `sdf`), ne jen „a/n“.
5. Režim `--dry-run`: vypíše všechny příkazy, nic nezapisuje.
6. Kontrola, že obraz je čitelný a kompletní (všechny oddíly z `parts` mají data, nebo jsou to swap / bez FS), volitelně `partclone.chkimg`.
7. Kontroly kompatibility: velikost logického sektoru zdroj vs. cíl (512 vs. 4Kn → varování, GPT se musí přepočítat), BitLocker (signatura `-FVE-FS-`) → upozornit, že resize není možný.
8. Log všeho do souboru (`/tmp/restore-<datum>.log` a kopie na flashku, pokud je zapisovatelná).

---

## 5. Hlavní scénář: obnova obrazu na jiný disk s přepočtem velikosti

### 5.0 Připojení disku s obrazy (zdroj)
1. Pokud je `/home/partimag` už připojený a obsahuje obrazy, nabídni ho rovnou.
2. Jinak vypiš oddíly všech disků **kromě flashky s Clonezillou**: `lsblk -no NAME,SIZE,FSTYPE,LABEL,MODEL,MOUNTPOINT`. Podporované FS: ext2/3/4, NTFS (`ntfs-3g`), exFAT, FAT32, XFS, btrfs.
3. Volitelně „automatické hledání“: každý oddíl dočasně připoj **read-only** do `/tmp/scan/<oddil>`, hledej adresáře obsahující `parts` + `disk` (max. hloubka 3) a výsledky vypiš ve tvaru `sdh1: /zalohy/WIN11-2026-09`. Po skenu vše odpoj.
4. Vybraný oddíl připoj do `/home/partimag`, při obnově read-only (`-o ro`). Pro vytváření záloh (menu 3, 4) připoj read-write. Pokud je NTFS „dirty“ nebo Windows hibernované (Fast Startup), oznam to a nabídni `ntfsfix` nebo připojení jen pro čtení.
5. Zapamatuj si fyzický disk s obrazy (rodič oddílu přes `lsblk -no PKNAME`) a vyřaď ho ze seznamu cílů.
6. Na konci (i při chybě, přes `trap`) disk s obrazy korektně odpoj.
7. CLI varianta: `--source-dev /dev/sdh1` (připojí sám) nebo `--image /cesta` (už připojeno).

### 5.1 Postup
1. Kontrola root, závislostí (kap. 8), LF konců řádků.
2. Připojení disku s obrazy (5.0) a výběr obrazu: prohledej `/home/partimag` (případně ručně zadanou cestu, max. hloubka 3) na adresáře obsahující `parts` + `disk`. Flashku s Clonezillou neprohledávej. Vypiš: název, datum, zdrojový disk, oddíly s FS a velikostmi, celkovou velikost obrazu.
3. Výběr cíle: tabulka disků (`lsblk -dno NAME,SIZE,MODEL,SERIAL,TRAN,ROTA,TYPE`), bez loop/rom/zram, s vyznačením chráněných disků.
4. Výpočet nového rozložení (5.2), zobrazení tabulky **původní → nová** velikost u každého oddílu.
5. Volba režimu změny velikosti:
   - **A) Poslední/největší datový oddíl zabere zbytek** (výchozí, nejbezpečnější),
   - **B) Proporcionálně** (rostoucí oddíly se škálují poměrem velikosti disků),
   - **C) Ruční** – otevře se editor oddílů (kap. 5.6), ve kterém nastavíš velikost každého oddílu,
   - **D) Beze změny** (1:1, jen pokud se vejde).
6. Závěrečné potvrzení (kap. 4).
7. Wipe staré tabulky (`wipefs -a`, `sgdisk --zap-all`), zápis nové tabulky (`sfdisk` ze sestaveného dumpu), `partprobe` + `udevadm settle`, ověření, že nové oddíly existují.
8. Postupná obnova oddílů s progressem a výpisem „oddíl 1/2 …“.
9. Změna velikosti FS (5.3), kontrola FS.
10. Opravy po obnově (kap. 5.5), souhrn, čas trvání, cesta k logu.

### 5.2 Výpočet tabulky oddílů
- Načti `sda-pt.sf` (label gpt/dos, start, size, type, uuid, name, attrs) a původní velikost disku.
- Klasifikuj oddíly:
  - **pevné** (velikost se nemění): EFI System, BIOS boot, MSR, Windows Recovery, `/boot` ≤ 2 GiB, oddíly bez FS, swap (volitelně škálovat);
  - **rostoucí**: ostatní datové oddíly (ext*, ntfs, xfs, btrfs, f2fs…).
- Zachovej pořadí, typy, PARTUUID, názvy a atributy GPT. Nové `disk GUID` jen na přání (aby nevznikl konflikt, pokud starý disk zůstane v PC).
- **Začátek oddílů se standardně NEMĚNÍ** (kap. 5.7). Mění se jen konec, případně začátek oddílů za rostoucím oddílem (např. Recovery přesunutá na konec disku). Zarovnání nových a přesunutých oddílů na 1 MiB (2048 sektorů při 512 B), přepočet při jiné velikosti sektoru.
- Po zápisu GPT na jiný disk: záložní GPT hlavička na konec (`sgdisk -e`).
- Pozor na Windows Recovery oddíl za systémovým oddílem: při růstu ho posuň na konec disku a systémový oddíl roztáhni před něj.
- MBR: respektuj primární/rozšířené/logické oddíly (rozšířený oddíl se roztahuje s logickými).
- **Kontrola minima:** každý cílový oddíl ≥ obsazené místo FS + rezerva (např. 10 % / min. 1 GiB). Pokud to nejde, jasně vypiš, kolik chybí, a skonči před zápisem.

### 5.3 Zvětšení (cíl ≥ původní oddíl)
Obnov přímo, pak roztáhni FS:
- ext2/3/4: `e2fsck -fy` → `resize2fs`
- NTFS: `ntfsresize --info`, pak `ntfsresize --force --no-action`, pak skutečně; po něm upozornit, že Windows při prvním startu spustí chkdsk
- FAT16/32 (EFI se obvykle nemění): `fatresize`, pokud existuje; jinak nabídni: záloha souborů do tmp → `mkfs.vfat -i <původní volume ID> -n <label>` → kopie zpět
- XFS: dočasně připojit → `xfs_growfs`
- btrfs: připojit → `btrfs filesystem resize max`
- f2fs: `resize.f2fs`, pokud existuje
- swap: `mkswap` s původním UUID a LABEL ze `swappt-*.info`
- neznámý FS / dd: obnovit, nezvětšovat, upozornit

### 5.4 Zmenšení (cíl < původní oddíl) – „nemožný“ scénář
partclone odmítne obnovit na menší oddíl. Implementuj tyto strategie (uživatel volí, skript doporučí):
1. **Mezikrok přes dočasný soubor:** na zvoleném úložišti s dostatkem místa (typicky disk s obrazy, pokud má volné místo; připoj ho pak read-write) vytvoř řídký soubor (`truncate`) o původní velikosti oddílu, připoj přes `losetup`, obnov do něj, zmenši FS offline (`resize2fs -M` / na cílovou velikost, `ntfsresize -s`), pak přenes na cíl (`partclone.<fs> -b` nebo `dd` jen potřebné délky) a nakonec roztáhni na plnou velikost cílového oddílu.
2. **Kopie na úrovni souborů** (pro FS, které nejde zmenšit, např. XFS): obnov do loop souboru, na cíli vytvoř nový FS se **stejným UUID a LABEL**, zkopíruj `rsync -aHAXx --numeric-ids` (nebo `tar` s xattr), pro NTFS jen s varováním (ztráta některých metadat → doporučit variantu 1).
3. Pokud není kam dočasně obnovit, jasně to vysvětli a skonči před zápisem.
Odhadni předem potřebné dočasné místo a čas.

### 5.5 Opravy po obnově (bootovatelnost)
- Kontrola, že UUID souborových systémů odpovídají `blkid.list` (partclone je zachovává). Pokud se změnily (mkfs, swap), nabídni opravu `/etc/fstab` a `/etc/crypttab` v obnoveném Linuxu.
- UEFI: obnovit boot záznam (`efibootmgr -c -d /dev/sdf -p <EFI číslo> -L <název> -l <cesta>`) podle `efi-nvram.dat` nebo nalezených `.efi` souborů (`\EFI\Microsoft\Boot\bootmgfw.efi`, `\EFI\debian\shimx64.efi`, `\EFI\BOOT\BOOTX64.EFI`). Upozornit, že NVRAM je v PC, ne na disku – záznam platí jen pro tento počítač.
- Linux: volitelně reinstalace GRUB přes chroot (bind `/dev /proc /sys /run`, `grub-install`, `update-grub`), pokud je to v obnoveném systému dostupné.
- Legacy BIOS: obnovit `*-mbr` (446 B boot kód) a `*-hidden-data-after-mbr`.
- Windows: informovat o `bcdboot` (není dostupné z Linuxu) a že by měl boot fungovat, pokud se nezměnila struktura EFI.

### 5.6 Editor oddílů (změna velikosti podle přání uživatele)
Jedna společná funkce, kterou používá **obnova (režim C a úprava navrženého layoutu v režimech A/B)** i **samostatná položka menu 9** na už existujícím disku.

**Zobrazení:** tabulka s čísly oddílů, začátkem, koncem, velikostí, FS, LABEL, obsazeným a minimálním možným místem a volným místem mezi oddíly. Pod ní grafický pruh disku v textu, např.
`[EFI|█████ systém █████|░░░ volné ░░░|Rec]`.

**Operace (vše se nejdřív jen plánuje, na disk se zapisuje až po potvrzení celého plánu):**
- **Změnit velikost oddílu.** Zadání v `MiB`, `GiB`, `%` disku, relativně (`+20G`, `-5G`) nebo `max` (do konce volného místa). Pro zvětšení i zmenšení.
- **Přesunout oddíl** (posun začátku doleva/doprava). Data se přesunou bezpečně: `sfdisk --move-data`, nebo kopie přes partclone/dd s ohledem na překryv (při posunu doprava kopírovat odzadu).
- **Vytvořit oddíl** ve volném místě (typ, FS přes `mkfs.*`, LABEL).
- **Smazat oddíl** (s potvrzením opsáním názvu oddílu).
- **Změnit typ, název (GPT name) a LABEL FS** (`e2label`, `ntfslabel`, `fatlabel`, `xfs_admin -L`, `btrfs filesystem label`).
- **Zkontrolovat zarovnání** oddílů. Přesun začátku systémového oddílu kvůli zarovnání jen na výslovnou žádost a s varováním z kap. 5.7.
- **Vrátit změnu / zahodit plán / zobrazit plán** jako seznam kroků a příkazů.

**Pravidla pro bezpečné provedení:**
- Zmenšení: **nejdřív FS, potom oddíl** (`e2fsck -f` → `resize2fs <velikost>` / `ntfsresize -s` → změna oddílu). Zvětšení: **nejdřív oddíl, potom FS**.
- Minimální velikost se počítá z FS: `resize2fs -P`, `ntfsresize --info` (s rezervou). Menší hodnotu editor nedovolí.
- FS, které nejde zmenšit (XFS), zablokovat. Případně nabídnout cestu přes zálohu souborů → nový FS se stejným UUID → kopii zpět.
- btrfs/XFS se zvětšují po dočasném připojení. FAT přes `fatresize`, jinak přes zálohu souborů a `mkfs.vfat -i <volume ID>`.
- Oddíly musí být odpojené, swap vypnutý (`swapoff`). LVM, RAID a šifrované oddíly (LUKS, BitLocker) se jen zobrazí jako nepodporované pro resize.
- Kroky se provádějí ve správném pořadí: nejdřív zmenšení a přesuny uvolňující místo, pak zvětšení. Plán editor sám seřadí.
- Před prvním zápisem nabídni zálohu tabulky oddílů (`sfdisk --dump` + `sgdisk --backup`) do souboru na disk s obrazy a příkaz pro její obnovu.
- Po každém kroku `partprobe`, `udevadm settle` a kontrola FS. Při chybě zastavit a vypsat přesný stav (co se už provedlo).
- Funguje i v `--dry-run`.

**CLI varianta:**
```
restore.sh --resize sdf2 --size 200G|+50G|-20G|max|60%
restore.sh --move sdf3 --start end|<MiB>
restore.sh --edit sdf          # interaktivní editor
```

### 5.7 Beckhoff / legacy systémy (mají přednost před obecnými pravidly)
**Detekce:** label tabulky `dos` (MBR), první oddíl začíná na sektoru 63 nebo jiném nezarovnaném sektoru, NTFS s boot sektorem NTLDR (XP) nebo BOOTMGR (Win7), FAT12/16/32 s Windows CE (`NK.BIN`, `\BOOT`), velikost disku do ~32 GB. Pokud skript legacy systém pozná, zobrazí v souhrnu `Režim: legacy (Beckhoff)` a použije tato pravidla:

1. **Zachovat začátek každého oddílu** přesně v původním sektoru, včetně startu na sektoru 63. Žádné zarovnání na 1 MiB. Mění se jen konec oddílu.
   Důvod: NTFS/FAT boot sektor obsahuje pole *hidden sectors* (pozice oddílu na disku) a Windows 7 BCD se na MBR disku odkazuje na pozici oddílu. Posun začátku = nebootující systém.
2. **Zachovat čísla a pořadí oddílů** (XP `boot.ini` se odkazuje na `partition(N)`) a aktivní (boot) příznak oddílu.
3. **Zachovat MBR beze změny** kromě položek tabulky: boot kód (446 B), **disk signature** (offset 0x1B8, Win7 BCD i XP na ni spoléhají) a data mezi MBR a prvním oddílem (`*-hidden-data-after-mbr`).
4. **Kontrola pole *hidden sectors*** po obnově: NTFS i FAT32 na offsetu 0x1C, FAT12/16 také 0x1C (4 B, little-endian) musí odpovídat skutečnému začátku oddílu. Pokud ne (např. obraz z jiného disku nebo ruční přesun), skript to oznámí a nabídne opravu zápisem správné hodnoty (u NTFS i do záložního boot sektoru na konci oddílu). V režimu `--dry-run` jen vypsat.
5. **Geometrie CHS:** u velmi starých BIOSů a XP vypiš původní a novou geometrii (heads/sectors z `sfdisk`/`parted`); při zápisu tabulky ji nastav podle zdroje, pokud to `sfdisk` dovolí, a upozorni na rozdíl.
6. **Jeden oddíl je běžný stav.** Celá logika musí fungovat pro 1 až N oddílů. Při jednom oddílu je výchozí režim „oddíl zabere celý disk“.
7. **Malá média (CF/CFast, 1–8 GB):** zobrazuj velikosti v MiB, ne jen GiB. Zmenšení i zvětšení je běžné (CF 2 GB → SSD 32 GB, ale i 4 GB → 2 GB).
8. **FAT12/16/32 (Windows CE):** obnova přes `partclone.fat`/`partclone.vfat`, příp. `partclone.dd`. Změna velikosti přes `fatresize`; pokud chybí nebo FAT16 nejde roztáhnout (limit 2 GiB/4 GiB), nabídni cestu: záloha souborů → `mkfs.fat` se **stejným volume ID, labelem a typem FAT** → kopie zpět → obnova boot sektoru zavaděče CE ze zálohy (prvních N sektorů oddílu). Upozorni, že u CE záleží na pořadí souborů jen výjimečně a ověř boot ve virtuálu nebo na panelu.
9. **NTFS z XP:** `ntfsresize` funguje i pro XP. Po změně velikosti upozornit na chkdsk při prvním startu a na to, že XP Embedded může mít zapnutý **EWF/FBWF write filter**, který se o změně nedozví – obraz by měl být vytvořený s vypnutým filtrem.
10. **Licence TwinCAT** jsou vázané na hardware panelu. Při obnově na jiný panel skript jen zobrazí informativní upozornění.
11. **GPT a UEFI** se u těchto panelů nepředpokládají. Opravy EFI (kap. 5.5) se v legacy režimu přeskakují.

---

## 6. Hlavní menu (všechny offline operace)

```
=== restore.sh – Clonezilla offline nástroj ===
 1) Obnovit obraz na disk (automatický přepočet velikosti)      [hlavní scénář]
 2) Obnovit jen vybrané oddíly z obrazu na existující oddíly
 3) Vytvořit obraz disku (záloha ve formátu kompatibilním s Clonezillou)
 4) Vytvořit obraz jednoho oddílu
 5) Klonovat disk → disk přímo (s přepočtem velikosti)
 6) Informace o obrazu + ověření integrity (partclone.chkimg)
 7) Připojit/prohlížet obsah obrazu (obnova do loop souboru, mount read-only)
 8) Informace o discích (lsblk, tabulka oddílů, SMART, TRIM podpora)
 9) Editor oddílů: změna velikosti, přesun, vytvoření, smazání, LABEL (kap. 5.6)
10) Kontrola / oprava souborových systémů (e2fsck, ntfsfix, fsck.vfat, xfs_repair)
11) Opravy bootu (EFI záznamy, GRUB, MBR, záložní GPT)
12) Převod MBR ↔ GPT (sgdisk -g, s varováním)
13) Bezpečné smazání disku (wipefs, blkdiscard pro SSD, NVMe format / ATA secure erase – s vícenásobným potvrzením)
14) Přepnutí do režimu Clonezilly (delegace na ocs-sr, viz kap. 7)
15) Nastavení (cesta k obrazům, komprese, dry-run, jazyk logu)
 0) Konec
```

Každá položka musí mít vlastní funkci a stejné bezpečnostní kontroly. Operace, které jsou v daném prostředí nemožné (chybí nástroj), se v menu zobrazí jako `(nedostupné: chybí <nástroj>)` a nespadnou.

Vytváření obrazu (3, 4) musí zapisovat **přesně formát Clonezilly** (kap. 3), aby šel obraz obnovit i standardní Clonezillou: `disk`, `parts`, `*-pt.sf`, `*-pt.parted`, `*-mbr`, `*-gpt-*`, `blkid.list`, `dev-fs.list`, `Info-*.txt`, data `partclone.<fs> -c -s /dev/X -o - | zstd -T0 | split -b 4096m - <název>.` (rozdělení kvůli FAT32), na konci kontrolní součty (sha1sum/b2sum do souboru).

---

## 7. Režimy ovládání

- **Interaktivní menu:** použij `dialog` (je v Clonezille), fallback `whiptail`, fallback čisté `select`/`read`. Abstrahuj do funkcí `ui_menu`, `ui_yesno`, `ui_input`, `ui_msg`, `ui_gauge`.
- **Neinteraktivní CLI** (pro skripty a opakované použití):
  ```
  restore.sh [--source-dev /dev/sdh1] --image /home/partimag/WIN11 --target sdf --mode last|proportional|fixed \
             [--tmpdir /mnt/usb] [--dry-run] [--yes-i-know sdf] [--no-efi-fix] [--log FILE]
  restore.sh --list-images [DIR] | --list-disks | --info IMAGE | --help | --version
  ```
- **Delegace na Clonezillu** (záložní cesta, když vlastní logika něco nepodporuje, např. LVM nebo RAID): sestav a ukaž příkaz typu
  `ocs-sr -e1 auto -e2 -r -j2 -k1 -icds -scr -p true restoredisk <OBRAZ> <DISK>`
  (`-k1` proporcionální tabulka, `-r` resize FS, `-icds` bez kontroly velikosti disku). Přesné přepínače ověř na místě přes `ocs-sr --help` a skript je má číst odtud, ne natvrdo spoléhat.

---

## 8. Závislosti (kontrola na startu)

Povinné: `bash ≥ 4`, `lsblk`, `blkid`, `sfdisk`, `sgdisk`, `parted`, `partprobe`, `wipefs`, `udevadm`, `dd`, `cat`, `awk`, `sed`.
Podle obsahu obrazu: `partclone.<fs>` (ext4, ntfs, vfat/fat, xfs, btrfs, f2fs, exfat, dd), `ntfsclone`, `ntfsresize`, `resize2fs`, `e2fsck`, `xfs_growfs`, `btrfs`, `fatresize`, `mkfs.vfat`, `mkswap`.
Dekompresory: `pigz`/`gzip`, `zstd`/`pzstd`, `pixz`/`xz`, `pbzip2`/`bzip2`, `lz4`, `lzop`, `lzip`.
Volitelné: `dialog`/`whiptail`, `pv`, `smartctl`, `efibootmgr`, `blkdiscard`, `nvme`, `hdparm`, `rsync`, `partclone.info`, `partclone.chkimg`.

Výstup: tabulka ✔/✘, chybějící povinné → konec; chybějící podle obrazu → konec až po výběru obrazu; volitelné → jen omezí menu.

---

## 9. Průběh a výstupy

- Progress: partclone vlastní (`-N` v dialogu nebo textový), u dd `status=progress`, u ostatních `pv`, pokud existuje.
- Hlavičky kroků: `[2/5] Obnova sdf2 (ext4, 118 GiB → 476 GiB)…`
- Barevný výstup jen v terminálu (`[[ -t 1 ]]`), v logu bez barev.
- Na konci souhrn: co se udělalo, výsledné `lsblk -f` cíle, varování, doba běhu, cesta k logu.
- Návratové kódy: 0 OK, 1 obecná chyba, 2 chyba uživatele/zrušeno, 3 chybí závislost, 4 nedostatek místa.

---

## 10. Vývojové prostředí a simulace (WSL2)

Vývoj probíhá ve VS Code na Windows, skript se ladí ve **WSL2 (Debian/Ubuntu)** bez restartů do Clonezilly.

### 10.0 Příprava WSL2 (do README)
```
wsl --install -d Debian
sudo apt update && sudo apt install -y dialog shellcheck partclone ntfs-3g gdisk parted \
     dosfstools e2fsprogs xfsprogs btrfs-progs pigz zstd xz-utils lz4 lzop pv rsync efibootmgr
```
VS Code: rozšíření *WSL* a *ShellCheck*. Flashka je ve WSL dostupná jako `/mnt/<písmeno>/`.

### 10.1 Simulační režim `--simulate` (implementovat JAKO PRVNÍ)
Cíl: proklikat celé menu, editor oddílů a všechny dialogy bez jakéhokoli zápisu a bez skutečných disků.
- Všechny „systémové“ dotazy jdou přes obalovací funkce (`sys_lsblk`, `sys_blkid`, `sys_sfdisk_dump`, `sys_findmnt`, `sys_partclone_info`…). V simulaci čtou data z adresáře `sim/` (fixtures), jinak volají skutečné nástroje.
- Všechny měnící příkazy jdou přes `run` (např. `run sfdisk /dev/sdf < layout`). V simulaci a v `--dry-run` se jen vypíší barevně jako `[SIM] sfdisk /dev/sdf`, v ostrém režimu se provedou.
- Progress (partclone, dd) se v simulaci napodobí krátkým odpočtem (`ui_gauge` 0–100 %).
- Kontrola root a závislostí se v simulaci přeskočí (jen se vypíše, co by chybělo).
- `--simulate=<scénář>` vybere sadu fixtures. Dodej alespoň tyto scénáře:
  - `bigger` – obraz 2 oddíly (EFI + ext4, 128 GB) → cíl 500 GB SSD,
  - `smaller` – obraz 500 GB (data 60 GB) → cíl 256 GB,
  - `toosmall` – data se nevejdou → musí skončit před zápisem,
  - `windows` – EFI + MSR + NTFS + Recovery, NVMe názvy (`nvme0n1p1`),
  - `noimage` – disk s obrazy neobsahuje žádný obraz,
  - `mounted` – cílový disk má připojený oddíl,
  - `beckhoff-xp` – MBR, 1 oddíl NTFS začínající na sektoru 63, CF 2 GB → SSD 32 GB,
  - `beckhoff-ce` – MBR, 1 oddíl FAT16 (Windows CE), CF 512 MB → CF 1 GB,
  - `beckhoff-w7` – MBR, oddíl „System Reserved“ + systém NTFS, SSD 32 GB → 16 GB (data se vejdou).
- Fixtures jsou obyčejné textové soubory (výstupy `lsblk -P`, `sfdisk --dump`, struktura adresáře obrazu s prázdnými datovými soubory), aby šly snadno přidávat a upravovat.
- Simulace se v žádném případě nesmí dostat k reálnému zápisu: `run` v simulaci nikdy nevolá příkaz a ostrý režim se s `--simulate` nesmí kombinovat.

### 10.2 Testy na loop discích (skutečná práce s daty)

Dodej `test/test-loop.sh`, který ve WSL2 (nebo jiném Linuxu) bez reálných SSD:
0. Vytvoří samostatný loop „disk s obrazy“ (ext4), na který se ukládají a ze kterého se čtou obrazy, aby se otestovalo i připojování zdroje (5.0).
1. Vytvoří loop „zdrojový disk“ 2 GiB s GPT: EFI (FAT32, 100 MiB) + ext4 (zbytek), nahraje testovací soubory.
2. Vytvoří z něj obraz skriptem (menu 3) **a zároveň** ověří, že struktura odpovídá kap. 3.
3. Obnoví obraz na loop disky 4 GiB (zvětšení) a 1,5 GiB (zmenšení) ve všech režimech A–D.
4. Ověří: tabulka oddílů, UUID shodné, `e2fsck -n` čisté, kontrolní součty souborů shodné, FS zabírá celý oddíl.
5. Test `--dry-run` nic nezapíše (porovnání hashe loop disku před/po).
5b. Test editoru oddílů: zmenšení ext4 a NTFS, přesun oddílu doprava i doleva, zvětšení do `max`. Kontrolní součty souborů musí zůstat shodné. Pokus o zmenšení pod minimum musí být odmítnut.
5c. Legacy test: MBR disk s jedním NTFS oddílem začínajícím na sektoru 63 a s FAT16 oddílem. Po obnově na větší i menší loop disk se ověří: začátek oddílů beze změny, shodná disk signature, shodný boot kód MBR, správné pole *hidden sectors*, aktivní příznak.
6. Úklid všech loop zařízení i při chybě.

### 10.3 Generálka ve virtuálu
README popíše test ve VirtualBoxu/Hyper-V: boot z Clonezilla ISO, virtuální disk s obrazy, prázdný cílový disk jiné velikosti a skript na malém FAT32 disku. Tím se ověří skutečné prostředí Clonezilly (verze nástrojů, `/run/live/medium`, LF).

---

## 11. Kritéria přijetí

- [ ] `restore.sh --simulate=<scénář>` projde všechny scénáře z 10.1 ve WSL2 bez root práv a bez jediného zápisu.
- [ ] Jediný soubor `restore.sh`, LF, `shellcheck` bez chyb, spustitelný `bash restore.sh` z FAT32 flashky.
- [ ] Bez root práv → srozumitelná hláška a konec.
- [ ] Sám najde a připojí disk s obrazy (jiný než flashka) a zobrazí obrazy Clonezilly včetně rozdělených a různě komprimovaných souborů.
- [ ] Nikdy nenabídne jako cíl flashku s Clonezillou ani disk s obrazy.
- [ ] Obraz se 2 oddíly (EFI + systém) obnoví na větší disk a systémový FS zabere zbytek.
- [ ] Totéž na menší disk, pokud se data vejdou (strategie 5.4), jinak skončí **před** zápisem s vysvětlením.
- [ ] Zachová UUID FS, PARTUUID a typy oddílů; obnovený systém nabootuje (ext4 i NTFS/Windows).
- [ ] Při obnově lze navržený layout ručně upravit. Na existujícím disku lze libovolný oddíl zvětšit, zmenšit (ne pod minimum FS) a přesunout bez ztráty dat.
- [ ] Destruktivní kroky vyžadují opsání názvu disku; `--dry-run` nic nezapíše.
- [ ] Obrazy vytvořené skriptem jdou obnovit standardní Clonezillou a naopak.
- [ ] Legacy/Beckhoff obraz (MBR, 1 oddíl od sektoru 63, NTFS i FAT16) se obnoví na větší i menší disk se zachovaným začátkem oddílu, disk signature, boot kódem a aktivním příznakem.
- [ ] Testy v `test/test-loop.sh` projdou.

---

## 12. Postup práce pro asistenta

1. Nejdřív navrhni strukturu funkcí a datový model oddílu (asociativní pole / řádky `start size type uuid name fs grow|fixed`) a ukaž mi ho.
2. Pak implementuj kostru: knihovna (log, ui, `run`, `sys_*` obaly) + **simulační režim s fixtures** + kompletní menu, které v simulaci jen vypisuje kroky. Tuto fázi ladím ve WSL2, dokud nebudu s menu spokojený.
3. Teprve potom doplňuj skutečnou logiku po částech: parser obrazu → výpočet layoutu → obnova → resize → editor oddílů → vytváření obrazu → ostatní položky menu → testy na loop discích.
4. Po každé části spusť `shellcheck` a relevantní test na loop zařízeních.
5. Samotný `restore.sh` nesmí potřebovat internet ani instalaci balíčků (to platí jen pro vývojové prostředí WSL2, kap. 10.0).
