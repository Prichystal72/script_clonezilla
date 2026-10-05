#!/usr/bin/env python3
"""Přidá do UEFI menu Clonezilly (boot/grub/grub.cfg) na horní úroveň dvě položky:

  AUTOMATICKY restore.sh (první = výchozí): bez dotazů spustí /run/live/medium/start.sh
  Clonezilla live RUCNE (KMS): obyčejná Clonezilla, příkazový řádek

Použití: patch-grub.py grub.cfg   (soubor se upraví na místě). Vychází z položky "Clonezilla live (KMS)".
Při neznámé podobě menu skončí chybou a nic nezmění. Totéž pro BIOS dělá patch-syslinux.py.
"""
import re
import sys


def tweak(s: str) -> str:
    """Menu čeká 3 s místo 30 s; v našich položkách (--id live-auto*, live-rucne*) je vidět výpis startu."""
    s = re.sub(r'^set timeout="?30"?$', 'set timeout="3"', s, count=1, flags=re.M)
    return re.sub(r'(menuentry "[^"]*" --id live-(?:auto|rucne)[^\n]*\n(?:[^\n]*\n)*?\})',
                  lambda m: m.group(1).replace(' quiet loglevel=0', '').replace(' quiet', '').replace(' loglevel=0', ''),
                  s)


def patch(path: str) -> None:
    s = open(path, encoding='utf-8').read()
    if '--id live-auto' in s:
        f = tweak(s)
        if f != s:
            open(path, 'w', encoding='utf-8', newline='\n').write(f)
            print(f'{path}: už upraveno, doplněno výpis startu / timeout 3 s')
        else:
            print(f'{path}: už upraveno, přeskakuji')
        return
    m = re.search(r'menuentry [^\n]*"Clonezilla live \(KMS\)"\s*\{\n(?:[^\n]*\n)*?\s*(\$linux_cmd [^\n]*)\n', s)
    first = re.search(r'^menuentry [^\n]*"Clonezilla live \(VGA 800x600\)"', s, re.M)
    if not m or not first:
        raise SystemExit(f'{path}: neočekávaná podoba menu (chybí položka KMS) – nic neměním')
    line = m.group(1)
    if 'ocs_live_run="ocs-live-general"' not in line:
        raise SystemExit(f'{path}: neočekávaná podoba položky KMS – nic neměním')

    auto = line.replace('ocs_live_run="ocs-live-general"', 'ocs_live_run="sudo bash /run/live/medium/start.sh"', 1)
    auto = auto.replace('ocs_live_batch="no"', 'ocs_live_batch="yes" ocs_lang="en_US.UTF-8" ocs_live_keymap="NONE"', 1)
    auto = auto.replace('locales= keyboard-layouts=', 'locales=en_US.UTF-8 keyboard-layouts=NONE', 1)

    def entry(title: str, ident: str, linux_line: str) -> str:
        return (f'menuentry "{title}" --id {ident} {{\n'
                '  search --set -f /live/vmlinuz\n'
                f'  {linux_line}\n'
                '  $initrd_cmd /live/initrd.img\n'
                '}\n\n')

    new = (entry('AUTOMATICKY restore.sh (velke pismo)', 'live-auto', auto)
           + entry('Clonezilla live RUCNE (KMS)', 'live-rucne', line))
    s = tweak(s[:first.start()] + new + s[first.start():])
    open(path, 'w', encoding='utf-8', newline='\n').write(s)
    print(f'{path}: upraveno')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    for f in sys.argv[1:]:
        patch(f)
