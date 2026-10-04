# restore.sh – obnova záloh Clonezilly na jiný disk

`restore.sh` (verze 1.2.13) obnoví zálohu Clonezilly na jiný disk, větší i menší, a sám přepočítá oddíly.
U panelů Beckhoff (XP Embedded, WES7, Windows CE) zachová start oddílu na sektoru 63, boot kód,
disk signature a aktivní oddíl, takže systém nabootuje. Zálohu se dvěma kartami (systém + data)
obnoví na jeden disk. Umí také vytvořit zálohu (jeden disk, více disků, vybrané oddíly) a obnovit libovolnou
kombinaci disků z jedné i více záloh na jeden nebo více disků.

- [Co je potřeba](#co-je-potřeba)
- [Příprava: skript na flashku](#příprava-skript-na-flashku)
- [Spuštění v Clonezille](#spuštění-v-clonezille)
- [Ovládání](#ovládání)
- [Obnova zálohy krok za krokem](#obnova-zálohy-krok-za-krokem)
- [Záloha se dvěma disky na jeden disk](#záloha-se-dvěma-disky-na-jeden-disk)
- [Záloha: více disků, oddíly a jejich kombinace](#záloha-více-disků-oddíly-a-jejich-kombinace)
- [Obnova z více disků a více záloh](#obnova-z-více-disků-a-více-záloh)
- [Testování ve VMware a stejná flashka](#testování-ve-vmware-a-stejná-flashka)
- [Kontrola výsledku a první start panelu](#kontrola-výsledku-a-první-start-panelu)
- [Řešení problémů](#řešení-problémů)
- [Přehled příkazů](#přehled-příkazů)
- [Pro vývojáře](#pro-vývojáře)

## Co je potřeba

| Co | K čemu | Poznámka |
| --- | --- | --- |
| Flashka s Clonezillou | z ní se bootuje, leží na ní `restore.sh` | skript ji nikdy nenabídne jako cíl |
| Disk se zálohami | obsahuje složky záloh Clonezilly (`…-img`) | připojí se jen pro čtení, nikdy jako cíl |
| Cílový disk | sem se záloha obnoví | **všechna data na něm se smažou** |
| Klávesnice | ovládání skriptu | myš nefunguje |

Při zkoušce ve VMware nabootuje Clonezilla z ISO a flashka i disky se do virtuálu připojí přes
*VM → Removable Devices → Connect*. Disky počítače virtuál nevidí.

## Příprava: skript na flashku

1. Zasuň flashku s Clonezillou do počítače s Windows.
2. Zkopíruj `restore.sh` do kořene flashky – vedle složek `live`, `EFI` a `boot` (přepíšeš starou verzi).
3. Flashku bezpečně odeber.

Soubor otevírej jen ve VS Code nebo Notepad++: má linuxové konce řádků (LF). Kdyby se při uložení
změnily na Windows (CRLF), skript to při startu sám ohlásí a nespustí se.

## Spuštění v Clonezille

Skript se spouští z příkazového řádku Clonezilly. Cesta k němu začíná lomítkem: `/mnt/restore.sh`.

1. Připoj flashku, disk se zálohami a cílový disk (ve VMware: *VM → Removable Devices → Connect*).
2. Nabootuj Clonezillu: první položka menu (Enter), jazyk, klávesnice *Keep*, potom **Enter_shell** a **cmd**.
3. Najdi flashku – řádek s `usb` a její oddíl typu `vfat`:
   ```
   lsblk -o NAME,SIZE,TRAN,FSTYPE,LABEL
   ```
4. Připoj ji a zkontroluj, že na ní je `restore.sh` (místo `sda1` dej oddíl z předchozího výpisu):
   ```
   sudo mount /dev/sda1 /mnt
   ls /mnt
   ```
   ![Clonezilla: lsblk ukazuje flashku sda (usb, vfat), po připojení je v /mnt vidět restore.sh](docs/img/00-clonezilla-mount.png)

   Na screenshotu je poslední příkaz špatně (`mnt/restore.sh` bez lomítka) – proto hláška *No such file or directory*.
5. Spusť skript. Poprvé doporučuji režim nanečisto, který nic nezapíše:
   ```
   sudo bash /mnt/restore.sh --dry-run
   sudo bash /mnt/restore.sh
   ```

## Ovládání

Vše se ovládá klávesnicí, myš v okně nefunguje. Ve VMware nejdřív jednou klikni do okna virtuálu,
aby dostalo klávesnici (zpět do Windows: Ctrl+Alt).

| Klávesa / tlačítko | Co dělá |
| --- | --- |
| **číslo** nebo **šipky ↑ ↓** | výběr položky; hlavní menu má volby 0–9 |
| **Enter** | potvrdí zvýrazněné tlačítko |
| **Tab** | přepne mezi tlačítky (např. *Vybrat* / *< Zpět*) |
| **Esc** | zpět o krok |
| *Vybrat* / *< Zpět* | tlačítka v nabídkách |
| *Další >* | zavře informační okno (tabulku, souhrn) a pokračuje |
| *Ano* / *Ne* | odpověď na otázku |
| *Potvrdit* | potvrdí zadanou hodnotu (velikost, název disku) |

**Barvy oken:** okna se **zdrojem** (disk se zálohami, výběr zálohy, zdrojový disk, informace o záloze) jsou
**zelená** a v horním řádku mají `[ZDROJ]`. Okna s **cílem** (cílový disk, rozložení, souhrn před zápisem,
potvrzení) jsou **červená** a mají `[CÍL – ZÁPIS]`. Co je červené, se bude přepisovat. Ostatní okna jsou modrá.

Horní řádek obrazovky ukazuje, kde právě jsi, např. *krok 3/6: cílový disk*. Skript při startu prohodí
klávesy **Y a Z** jako na české klávesnici; ostatní klávesy (čísla, lomítka) zůstávají americké.

## Obnova zálohy krok za krokem

Obnova má 6 kroků a až do kroku 5 se na disk nic nezapisuje. Obrázky jsou z verze 1.1.0
(příklad: záloha dvou CF karet panelu na jeden SSD).

**Hlavní menu** – zvol **1 Obnovit obraz na disk**.

![Hlavní menu restore.sh s volbami 0–9](docs/img/01-hlavni-menu.png)

**Krok 1 – disk se zálohami.** Vyber oddíl, na kterém jsou zálohy. Nevíš-li který, zvol
*Automaticky prohledat* – skript projde všechny oddíly jen pro čtení a vypíše nalezené zálohy.

![Krok 1: výběr oddílu se zálohami](docs/img/02-disk-se-zalohami.png)

**Krok 2 – výběr zálohy.** U každé zálohy je datum, disky a oddíly. Koš Windows se neprohledává.

![Krok 2: výběr zálohy](docs/img/03-vyber-zalohy.png)

Následuje přehled zálohy (oddíly, souborové systémy, obsazené místo) – pokračuj *Další >*.
Obsahuje-li záloha dva disky, skript se zeptá, jak je obnovit
(viz [Záloha se dvěma disky](#záloha-se-dvěma-disky-na-jeden-disk)).

![Přehled zálohy se dvěma disky](docs/img/05-informace-o-zaloze.png)

**Krok 3 – cílový disk.** U každého disku je typ, výrobce, model a sériové číslo. Flashka s Clonezillou
a disk se zálohami jsou označené *CHRÁNĚNO* a vybrat nejdou. Disk s připojeným oddílem skript nabídne odpojit.

![Krok 3: výběr cílového disku](docs/img/07-cilovy-disk.png)

**Krok 4 – velikost oddílů.**

| Volba | Kdy ji použít |
| --- | --- |
| 1 – zbytek disku | běžný případ: největší datový oddíl zabere volné místo |
| 2 – poměrem | více oddílů, každý se zvětší ve stejném poměru |
| 3 – zadat ručně | velikost každého oddílu zadáš sám (`20G`, `15000M`, `50%`, `max`) |
| 4 – beze změny | stejné velikosti jako v záloze, jen když se vejdou |

![Krok 4: volba režimu velikosti](docs/img/08-velikost-oddilu-rezim.png)

**Krok 5 – kontrola a potvrzení.** Souhrn ukazuje cílový disk a tabulku původní → nová velikost.
Zkontroluj model a sériové číslo. Pro potvrzení opiš název disku (např. `sdf`) – až teď se začne zapisovat.

![Krok 5: souhrn před zápisem](docs/img/12-souhrn-pred-zapisem.png)

![Krok 5: potvrzení opsáním názvu disku](docs/img/13b-potvrzeni-zadano.png)

**Krok 6 – obnova.** Skript zapíše tabulku oddílů, obnoví data, rozšíří souborové systémy a opraví
bootování. Na konci je souhrn s varováními a cestou k logu.

![Krok 6: souhrn po obnově](docs/img/14-hotovo.png)

## Záloha se dvěma disky na jeden disk

Záloha panelu se dvěma kartami (systém + data) se obnoví na jeden cílový disk jako dva oddíly za sebou.
Bootovací kartu skript pozná sám a dá ji na první místo: zachová start na sektoru 63, boot kód,
disk signature a aktivní příznak. Druhému oddílu opraví *hidden sectors*, protože se mu změní pozice.

![Volba, jak obnovit zálohu se dvěma disky](docs/img/04-zaloha-se-2-disky.png)

| Volba | Výsledek |
| --- | --- |
| 1 – Sloučit na JEDEN disk | oba oddíly na jeden cílový disk (systém + data) |
| 2 – Každý disk zvlášť | každá karta na vlastní cílový disk |
| 3 / 4 – Jen jeden disk | obnoví jen vybranou kartu |

**Velikost obou oddílů** nastavíš v kroku 4 volbou **3 – zadat ručně**. Skript se zeptá postupně na každý
oddíl a ukáže obsazené místo, minimum a kolik zbývá. Předvyplněnou hodnotu smaž (Backspace) a napiš novou:

- `20G` = 20 GiB, `15000M` = 15 000 MiB, `50%` = polovina disku,
- `max` = vše, co zbývá (u posledního oddílu je předvyplněno).

Méně než minimum skript nepřijme a zeptá se znovu.

![Velikost prvního oddílu: zadáno 20G](docs/img/09b-velikost-oddilu-1-zadano.png)

![Velikost druhého oddílu: max (zbytek disku)](docs/img/10-velikost-oddilu-2.png)

Potom ukáže rozložení původní → nové a pruh disku. Když nesedí, dej *< Zpět* (Esc) – nic se zatím nezapsalo.

![Rozložení po zadání velikostí](docs/img/11-rozlozeni.png)

Windows mohou datovému oddílu po sloučení přidělit jiné písmeno (např. E: místo D:).
Po prvním startu ho zkontroluj ve Správě disků.

## Záloha: více disků, oddíly a jejich kombinace

Menu **3 – Vytvořit obraz** má tři volby:

| Volba | Co zálohuje |
| --- | --- |
| 3/1 Obraz disku (jednoho nebo více) | celé disky se všemi oddíly |
| 3/2 Obraz oddílů (jednoho nebo více) | vybrané oddíly, i z různých disků |
| 3/3 Disky i oddíly dohromady | např. celý disk `sda` a k tomu jen oddíl `sdb2` |

Postup: **co zálohovat** (zelené okno, zaškrtávací seznam – položku označ **mezerníkem**, objeví se `[*]`, pak
*Potvrdit výběr*; v textovém režimu čísla oddělená mezerou) → **kam uložit** (červené okno, nabízí jen oddíly,
které se nezálohují) → název. Na konci se ukáže souhrn: kde záloha leží, velikost a výsledek kontrolních součtů.
Při výběru více položek se skript zeptá, jestli je uložit **do jednoho obrazu** (stejný formát jako Clonezilla
`savedisk sda sdb`, soubory `disk` a `parts` obsahují všechny disky a oddíly), nebo **každou položku do samostatného obrazu**.

| Chci zálohovat | Příkaz |
| --- | --- |
| dva disky do jedné zálohy | `--save-disk sda,sdb --name PANEL` |
| každý disk do vlastní zálohy | `--save-disk sda,sdb --separate --name PANEL` (vzniknou `PANEL-sda`, `PANEL-sdb`) |
| vybrané oddíly, i z různých disků | `--save-part sda1,sdb2 --name VYBER` |
| celý disk a oddíl jiného disku | `--save-disk sda --save-part sdb2 --name MIX` |

Skript před prvním zápisem zkontroluje všechny položky i názvy. Odmítne: neexistující položku, disk bez
oddílu, připojený oddíl, rozšířený kontejner (zálohuj jeho logické oddíly), už existující název obrazu.
Oddíl, který leží na už zálohovaném disku, se nezdvojí.

Obraz jen **vybraných oddílů** nejde obnovit jako celý disk (skript to oznámí a nic nezapíše). Obnovíš ho volbou
**2 – Obnovit jen vybrané oddíly**; ta se po každém průchodu zeptá, jestli chceš obnovit ještě oddíly z jiného
disku nebo jiné zálohy.

## Obnova z více disků a více záloh

Zdrojem obnovy je jeden **disk ze zálohy**. Záloha jich může mít víc a v kroku 2 můžeš zvolit
*Více záloh najednou* – pak jsou zdroje všechny disky ze všech vybraných záloh. Každý zdroj můžeš:

- **sloučit** s dalšími na jeden cílový disk (oddíly za sebou, bootovací disk je první),
- obnovit na **vlastní cílový disk**,
- libovolně **seskupit**: některé zdroje na jeden cíl, jiné na další (volba *Vlastní rozdělení* – ke každému
  zdroji napíšeš číslo cílového disku, stejné číslo = sloučí se, `0` = neobnovovat).

| Chci | Příkaz |
| --- | --- |
| dvoudiskovou zálohu na jeden disk | `--image PANEL --target sdf` |
| dvoudiskovou zálohu na dva disky | `--image PANEL --target sdf,sdg` |
| dvě samostatné zálohy sloučit na jeden disk | `--image PANEL-sda,PANEL-sdb --target sdf` |
| dvě samostatné zálohy na dva disky | `--image PANEL-sda,PANEL-sdb --target sdf,sdg` |
| jen vybrané disky ze zálohy | `--image PANEL --source-disk sdb --target sdf` |
| libovolné seskupení | `--image A,B --groups "A:sda+B:sdc,A:sdb" --target sdf,sdg` |

U více záloh se zdroj zapisuje `OBRAZ:disk` (např. `A:sda`); holé `sda` stačí, když je v zálohách jen jednou,
jinak skript odmítne a požádá o `OBRAZ:disk`. V `--groups` odděluje čárka cílové disky, `+` zdroje na jednom cíli.
`--yes-i-know` při více cílech uvádí všechny: `--yes-i-know sdf,sdg`.

Před prvním zápisem skript zkontroluje všechny zadané cíle (existují, nejsou chráněné, jsou potvrzené, žádný není
dvakrát) a že počet cílů odpovídá počtu skupin. V menu se cíle ptají postupně: zápis na první cíl proběhne dřív,
než se zeptá na druhý.

Slučování má omezení: stejný typ tabulky (MBR / GPT) a velikost sektoru, v MBR nejvýš 4 primární oddíly a žádný
rozšířený / logický oddíl na dalších discích než prvním.

## Testování ve VMware a stejná flashka

Ve VMware (např. Player) se skript zkouší s ISO Clonezilly a malým virtuálním diskem, na flashce je totéž.
Obojí se po startu chová stejně: větší písmo, žádné dotazy na jazyk a klávesnici a rovnou menu `restore.sh`.

| Co | Jak |
| --- | --- |
| ISO s automatickým startem | `bash vm/make-vm-iso.sh clonezilla-live-….iso clonezilla-live-….-vm.iso` (Linux / WSL, xorriso) |
| Virtuální disk se skriptem | `sudo bash vm/make-script-disk.sh restore.sh "…/scripts.vmdk"` (VM vypnutá) |
| Flashka se stejným menu | `bash vm/make-flash.sh /mnt/e` (viz níže) |

**Bootovací menu** má na horní úrovni dvě vlastní položky:

1. **AUTOMATICKY restore.sh (1024x768, velké písmo)** – výchozí; po 30 s nebo po Enter se spustí `vm/start.sh`.
   Ten nastaví písmo, projde oddíly, najde `restore.sh` (flashka nebo disk) a spustí ho. Po skončení skriptu
   zůstane příkazový řádek (restart: `sudo reboot`).
2. **Clonezilla live RUČNĚ (1024x768)** – obyčejná Clonezilla v rozlišení 1024×768, bez automatiky.

Dál jsou původní položky Clonezilly. Originální ISO se nemění, vzniká jeho kopie.

**Nastavení VM (`.vmx`)**, které je potřeba:

| Nastavení | Hodnota | Proč |
| --- | --- | --- |
| `svga.maxWidth` / `svga.maxHeight` | `1920` / `1080` | jinak VMware omezí rozlišení konzole na 640×480 |
| `svga.vramSize` | `16777216` | video paměť pro vyšší rozlišení |
| `bios.bootOrder` | `cdrom,hdd` | nejdřív ISO, disk se skriptem není bootovací |
| `scsi0:0.fileName` | `scripts.vmdk` | disk se skriptem (jen `restore.sh`) |

Skript se do VM dostává z disku `scripts.vmdk` nebo z flashky; po změně `restore.sh` ho na disk znovu nahraj
(`make-script-disk.sh`, VM vypnutá) a na flashku zkopíruj.

### Stejná flashka jako ve VM

Cíl: po bootu z flashky se bez psaní příkazů otevře `restore.sh` stejně jako ve VM.

1. Zasuň flashku s Clonezillou (rozložení `syslinux/`, `boot/grub/` a `live/`).
2. Ve WSL ji připoj a spusť přípravu (E: je písmeno flashky ve Windows):
   ```
   sudo mkdir -p /mnt/e && sudo mount -t drvfs E: /mnt/e
   bash vm/make-flash.sh /mnt/e
   ```
   Skript zkopíruje `restore.sh` a `start.sh` do kořene flashky a přidá stejné dvě položky jako ve VM do menu pro
   **BIOS** (`syslinux/syslinux.cfg`, `syslinux/isolinux.cfg`) i **UEFI** (`boot/grub/grub.cfg`). Původní soubory uloží
   vedle jako `*.bak`. Dvakrát spuštěný nic nezdvojí.
3. Bez WSL jde totéž ručně: zkopíruj `restore.sh` a `vm/start.sh` do kořene flashky a do menu vlož položku podle
   `vm/patch-syslinux.py` (BIOS) a `vm/patch-grub.py` (UEFI). Je to kopie položky *KMS* s
   `ocs_live_run="sudo bash /run/live/medium/start.sh"`, `ocs_live_batch="yes"`, `ocs_lang="en_US.UTF-8"`
   a `ocs_live_keymap="NONE"`.

Při zlomu bootu stačí vrátit původní `syslinux.cfg.bak`, `isolinux.cfg.bak` a `grub.cfg.bak` na jejich místo.
Boot z flashky na skutečném počítači (BIOS i UEFI) zatím není ověřený.

## Kontrola výsledku a první start panelu

Před vložením disku do panelu zkontroluj tabulku oddílů. V Clonezille (po ukončení skriptu volbou 0):

```
sudo sfdisk -d /dev/sdf
sudo ntfsresize --info --force /dev/sdf1
```

![Kontrola v Clonezille: start=63, bootable, NTFS vyplňuje oddíl](docs/img/15-kontrola-sfdisk.png)

| Co zkontrolovat | Správně | Kde to vidíš |
| --- | --- | --- |
| Začátek 1. oddílu | `start=63` (jako na CF kartě) | `sfdisk -d` |
| Aktivní oddíl | `bootable` u 1. oddílu | `sfdisk -d` |
| Disk signature | stejná jako v záloze (`label-id`) | `sfdisk -d`, ve Windows `Get-Disk` |
| Velikost NTFS | *Current volume size* ≈ *device size* | `ntfsresize --info` |
| Hidden sectors | rovná se začátku oddílu (63, resp. start 2. oddílu) | skript kontroluje a opravuje sám |

Při kontrole ve Windows ukazují oba svazky stav *Warning*. To je správně: po změně velikosti je NTFS
označen ke kontrole. Na počítači, kde disk kontroluješ, nic neopravuj.

**První start panelu:** vlož disk místo CF karty a zapni panel. Windows spustí chkdsk, nech ho doběhnout
(může restartovat). Pak zkontroluj písmena disků a licenci TwinCAT – je vázaná na hardware panelu.

## Řešení problémů

| Problém | Příčina | Řešení |
| --- | --- | --- |
| *No such file or directory* při spuštění | chybí lomítko: `mnt/restore.sh` | `sudo bash /mnt/restore.sh` |
| *wrong fs type* při `mount` | připojuješ celý disk (`/dev/sda`) | připoj oddíl: `/dev/sda1` |
| Klik myší nic nedělá | rozhraní je jen na klávesnici | šipky / číslo + Enter; ve VMware nejdřív klik do okna (Ctrl+G) |
| Ve výběru není očekávaná záloha | záloha je hlouběji než 3 složky nebo na jiném oddílu | volba *Automaticky prohledat*; kontrola: `sudo find /zal -maxdepth 8 -name parts` |
| Záloha v `$RECYCLE.BIN` | smazaná záloha v koši Windows | verze 1.1.0 koš přeskakuje |
| Cílový disk je *CHRÁNĚNO* | flashka, disk se zálohami nebo připojený oddíl | připojený oddíl skript nabídne odpojit |
| *Data se nevejdou … Nic nebylo zapsáno* | cílový disk je menší než data | větší disk nebo menší velikosti v režimu 3 |
| Chybí místo pro dočasný soubor | zmenšení potřebuje místo ≈ obsazená data + 10 % | parametr `--tmpdir /cesta` na disk s místem |
| Ve Windows *Warning* u NTFS | NTFS označen ke kontrole po změně velikosti | v pořádku, chkdsk doběhne při 1. startu panelu |
| Y a Z prohozené | klávesnice Clonezilly je americká | skript je prohodí sám; vypnout: `--keymap us` |
| Na disku nad 2 TB zůstane volné místo | tabulka MBR adresuje nejvýš 2 TiB | pro celý disk GPT (menu 8 → 3; ne pro XP / Beckhoff) |
| FAT16 se nezvětšila přes 2 GB | FAT16 víc neunese | zbytek disku zůstane volný (skript upozorní) |
| Prázdný velký ext4 se nevejde na malý disk | metadata ext4 (tabulky inodů) se počítají jako obsazená | větší cílový disk |

Log každého běhu je v `/tmp/restore-<datum>.log` a kopie ve složce `restore-logs/` na flashce.
Při chybě ho přilož k hlášení.

## Přehled příkazů

| Příkaz | Co dělá |
| --- | --- |
| `sudo bash /mnt/restore.sh` | interaktivní menu |
| `sudo bash /mnt/restore.sh --dry-run` | jen vypíše, co by se provedlo, nic nezapíše |
| `--source-dev /dev/sdh1 --image ZÁLOHA --target sdf --mode last --yes-i-know sdf` | obnova bez menu |
| `--mode manual --sizes 20G,max` | záloha se 2 disky na jeden disk s danými velikostmi |
| `--target sdf,sdg` | každý disk ze zálohy na vlastní cíl |
| `--source-disk sdb` | jen jeden disk ze zálohy |
| `--image A,B` / `--groups "A:sda+B:sdc,A:sdb"` | více záloh najednou / seskupení zdrojů na cíle |
| `--yes-i-know sdf,sdg` | potvrzení všech cílů najednou |
| `--save-disk sda[,sdb] --name NÁZEV` / `--save-part sda2[,sdb1] --name NÁZEV` | záloha disků / oddílů ve formátu Clonezilly (vše do jednoho obrazu) |
| `--separate` | každý disk / oddíl do vlastního obrazu (`NÁZEV-sda`, `NÁZEV-sdb`) |
| `--resize sdf2 --size -20G\|+50G\|200G\|max\|60% --yes-i-know sdf` | změna velikosti oddílu |
| `--move sdf3 --start end\|start\|<MiB> --yes-i-know sdf` | přesun oddílu |
| `--edit sdf` | editor oddílů |
| `--list-disks` / `--list-images` / `--info ZÁLOHA` | výpis disků / záloh / detail zálohy |
| `--keymap us` | nepřehazovat Y a Z |
| `--tmpdir /cesta` | místo pro dočasný soubor při zmenšování |

Automatické spuštění po bootu (volitelné): do parametrů jádra v `syslinux/syslinux.cfg` a
`boot/grub/grub.cfg` na flashce přidej `ocs_live_run="sudo bash /run/live/medium/restore.sh"`.

## Pro vývojáře

### Struktura

| Soubor | Obsah |
| --- | --- |
| `restore.sh` | celý nástroj (jeden soubor, bash 4+) |
| `test/test-sim.sh` | 50 kontrol v simulaci – funguje i v Git Bash na Windows |
| `test/test-loop.sh` | 258 kontrol na skutečných datech (loop disky, Linux/WSL2, root) |
| `test/test-menus.sh` | průchod menu 5–9 klávesnicí (info, prohlížení, disky, editor, kontrola FS, boot, MBR ↔ GPT, smazání, nastavení), 44 kontrol |
| `test/qvm.sh` | ovládání testovací VM v QEMU: skutečná Clonezilla z ISO, disky jako soubory, snímky obrazovky |
| `test/test-matrix.sh` | matice 61 kombinací (FS × tabulka × velikost do 3 TB × obnova / klon × režim, české popisky, zálohy na FAT32), 583 kontrol |
| `test/make-sim-fixtures.sh` | vygeneruje simulační scénáře do `sim/` |
| `test/screenshots.py` | nasnímá obrazovky do `docs/img/` (pyte + Pillow) |
| `sim/<scénář>/` | fixtures: `lsblk.P`, `sfdisk/*.dump`, obsah disku se zálohami |
| `simulace.cmd` | spuštění simulace ve WSL dvojklikem |
| `vm/start.sh` | automatický start po bootu Clonezilly (písmo, najde a spustí `restore.sh`) |
| `vm/make-vm-iso.sh`, `vm/patch-syslinux.py`, `vm/patch-grub.py` | upravená kopie ISO / úprava menu bootu (BIOS, UEFI) |
| `vm/make-script-disk.sh` | virtuální disk VMware se `restore.sh` |
| `vm/make-flash.sh` | stejné menu a skripty na flashku |
| `ZADANI_restore(1).md` | zadání |

### Simulace (bez rootu, nic nezapisuje)

```
bash restore.sh --simulate=beckhoff-2disk
```

Scénáře: `bigger`, `smaller`, `toosmall`, `windows`, `noimage`, `mounted`, `beckhoff-xp`,
`beckhoff-ce`, `beckhoff-w7`, `beckhoff-2disk`, `twodisks` (záloha více disků). Na Windows: `simulace.cmd beckhoff-xp`.

### Testy

```
bash test/test-sim.sh                     # simulace
sudo bash test/test-loop.sh               # skutečná data na loop discích
sudo bash test/test-matrix.sh             # matice kombinací, i velké disky (řídké soubory)
sudo bash test/test-matrix.sh 'exfat'     # jen vybrané případy (regex)
shellcheck restore.sh test/*.sh
python3 test/screenshots.py docs/img      # obrázky do návodu
```

`test-loop.sh` a `test-matrix.sh` pracují jen se soubory v `/var/tmp/restore-test` a `/var/tmp/restore-matrix`
a spouštějí skript s `--allow-loop`. Disky jsou řídké soubory: 3TB „disk“ zabere jen zapsaná data.
Ve WSL je pro exFAT potřeba `exfat-fuse` a odkaz `mount.exfat` (Clonezilla exFAT umí sama).

Matice u každého případu kontroluje: oddíl i souborový systém vyplňují cíl, soubory jsou shodné (sha256),
`fsck` je čistý, UUID FS zůstalo, u MBR začátek 63, aktivní oddíl a disk signature.

| Oblast | Ověřené kombinace |
| --- | --- |
| Souborové systémy | FAT16, FAT32, exFAT, NTFS, ext4, swap, EFI, MSR, Recovery |
| Tabulky | MBR od sektoru 63 (Beckhoff), MBR 1 MiB (Windows), GPT |
| Velikosti | 512 MB – 3 TB, zvětšení, zmenšení, stejná velikost |
| Operace | obnova z obrazu, klon disk → disk |
| Režimy | A celý disk, B poměrem, C ručně, D 1:1 |

### Ověřeno

- Ve VMware Workstation s Clonezillou 3.3.3-37: obnova 4GB CF karty Beckhoff (XP, start 63) na 120GB SSD
  a záloha se dvěma kartami na jeden SSD (kontrola tabulky, signatury a hidden sectors ve Windows).
- Záloha více disků / oddílů do jednoho nebo více obrazů a obnova z více disků i více záloh (sloučení, rozdělení,
  seskupení, chybové stavy) je ověřená na loop discích v `test/test-loop.sh`. Ve VMware s Clonezillou a standardní
  Clonezillou (obnova obrazu vytvořeného skriptem) zatím ne – viz `TODO.md`.
- Ve VMware Playeru: ISO s automatickým startem (`vm/make-vm-iso.sh`) otevře `restore.sh` bez dotazů, ve větším okně
  1024×768 a s větším písmem.
- **Kompatibilita se standardní Clonezillou:** zálohy vytvořené skriptem (MBR FAT32 + NTFS, dva disky v jedné
  záloze, GPT EFI + ext4) obnovila Clonezilla 3.3.3 sama (`ocs-sr restoredisk`, bez skriptu) – tabulky, UUID,
  popisky i soubory shodné. Clonezilla u bootovacího oddílu FAT po obnově mění typ `c` → `b` a maže popisek
  v boot sektoru – stejně i u vlastních záloh, nejde o rozdíl ve formátu.
- Neověřeno na skutečném hardwaru: oprava EFI záznamů, reinstalace GRUB, převod MBR ↔ GPT,
  NVMe format / ATA secure erase – používej nejdřív s `--dry-run`.

### Test ve skutečné Clonezille (QEMU)

Kromě testů na loop discích jde celý průchod menu vyzkoušet ve skutečné Clonezille – bez VMware a bez
skutečných disků. `test/qvm.sh` spustí ve WSL QEMU (KVM) s upraveným ISO a disky jako řídkými soubory
(USB flashky i SATA), posílá klávesy a ukládá snímky obrazovky:

```
sudo bash vm/make-vm-iso.sh clonezilla-live-….iso /var/tmp/qvm/cz.iso
sudo bash test/qvm.sh start /var/tmp/qvm/cz.iso sata:/var/tmp/qvm/scripts.raw:1G usb:/var/tmp/qvm/src.raw:8G usb:/var/tmp/qvm/dst.raw:60G
sudo bash test/qvm.sh shot obrazovka.png     # snímek
sudo bash test/qvm.sh keys 4 ret             # klávesy
sudo bash test/qvm.sh type sdc               # text
sudo bash test/qvm.sh stop
```

Takto je ověřený klon FAT32 8 GB → 58 GB (USB flashky) včetně vzhledu oken, barev a češtiny.

### Konce řádků

`restore.sh` musí mít LF. Hlídají to `.editorconfig` a `.gitattributes`; při CRLF skript na startu
ohlásí chybu (kód 1).
