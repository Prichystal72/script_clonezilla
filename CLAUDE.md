# script_clonezilla – restore.sh (obnova záloh Clonezilly)

Komunikace česky, stručně. Bash skript `restore.sh` (verze v README) pro Clonezillu: obnova záloh na jiný disk (větší/menší),
speciálně Beckhoff panely (XP Embedded, WES7, CE – zachovat start oddílu na sektoru 63, boot kód, disk signature, aktivní oddíl),
záloha více disků/oddílů, obnova z více obrazů. Zadání: `ZADANI_restore(1).md`, úkoly `TODO.md`.

## Zásady (uživatel je na to citlivý)
- **Nikdy nesahat na disky tohoto PC** (hlavně interní NVMe, disk 0). Testy jen na loop souborech v `/var/tmp/restore-test` s `--allow-loop`.
  Interní disky musí zůstat ve výběru skriptu (žádný „jen USB“ režim).
- Rozhraní skriptu: **česky, číselné menu** (hlavní 0–9), české popisky tlačítek (žádné anglické EXIT), klávesy Y/Z prohozené.
- Rozhodnutí držet, neměnit přístup uprostřed práce; opravy dávkovat; dlouhé tiché běhy nedělat.
- Každou eventualitu otestovat (i velké disky) dřív, než uživatel zkusí reálnou flashku: `test/test-matrix.sh`, `test-loop`, `sim/`.

## Prostředí
- `wsl`/`cmd` nejsou v PATH → `C:\Windows\System32\wsl.exe -d Ubuntu-24.04 -u root` (Git Bash: `MSYS_NO_PATHCONV=1`). Složité příkazy do wsl předávat souborem.
- Test ve VMware (VM v `Documents\Virtual Machines\Clonezilla-test`, Clonezilla 3.3.3), skript se do VM dostává přes USB flashku.
