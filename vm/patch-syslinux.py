#!/usr/bin/env python3
"""Přidá do bootovacího menu Clonezilly (syslinux.cfg / isolinux.cfg) dvě položky na horní úroveň:

  AUTOMATICKY restore.sh (výchozí): bez dotazů na jazyk a klávesnici spustí /run/live/medium/start.sh
  Clonezilla live RUCNE (1024x768): jen KMS 1024x768, příkazový řádek

Použití: patch-syslinux.py soubor.cfg [soubor2.cfg …]   (soubory se upraví na místě)
Vychází z položky "Clonezilla live (KMS)" originálního menu. Při neznámé podobě menu skončí chybou
a nic nezmění.
"""
import sys


def fix_vga(s: str) -> str:
    """vga=791 (VESA 0x317, 1024x768) v našich položkách → vga=normal. Starší panely (Beckhoff) režim 0x317
    neznají: jádro hlásí "undefined mode number 317" a čeká. Výsledné rozlišení stejně nastaví KMS."""
    out = []
    for part in s.split('\nlabel '):
        if part.startswith(('Clonezilla live AUTO', 'Clonezilla live RUCNE')):
            part = part.replace('vga=791', 'vga=normal')
        out.append(part)
    return '\nlabel '.join(out)


def short_timeout(s: str) -> str:
    """Menu čeká na výběr 3 s místo 30 s; v našich položkách je vidět výpis startu (bez quiet / loglevel=0),
    ať je na panelu poznat, kde se start zdrží nebo zasekne."""
    s = s.replace('\ntimeout 300\n', '\ntimeout 30\n', 1).replace('\ntimeout 100\n', '\ntimeout 30\n', 1)
    out = []
    for part in s.split('\nlabel '):
        if part.startswith(('Clonezilla live AUTO', 'Clonezilla live RUCNE')):
            part = part.replace(' quiet loglevel=0', '').replace(' quiet', '').replace(' loglevel=0', '')
        out.append(part)
    return '\nlabel '.join(out)


def patch(path: str) -> None:
    s = open(path, encoding='utf-8').read()
    if 'label Clonezilla live AUTO restore' in s:
        f = short_timeout(fix_vga(s))
        if f != s:
            open(path, 'w', encoding='utf-8', newline='\n').write(f)
            print(f'{path}: už upraveno, doplněno vga=normal / výpis startu / timeout 3 s')
        else:
            print(f'{path}: už upraveno, přeskakuji')
        return
    k = s.index('label Clonezilla live KMS\n')
    k_end = s.index('\nlabel ', k + 5)
    kms = s[k:k_end]
    if 'vga=791' not in kms or 'ocs_live_run="ocs-live-general"' not in kms:
        raise SystemExit(f'{path}: neočekávaná podoba položky KMS – nic neměním')
    base = kms.replace('  # MENU DEFAULT\n', '', 1).replace('vga=791', 'vga=normal')

    auto = base.replace('label Clonezilla live KMS\n', 'label Clonezilla live AUTO restore\n  MENU DEFAULT\n', 1)
    auto = auto.replace('MENU LABEL Clonezilla live (^KMS)', 'MENU LABEL ^AUTOMATICKY restore.sh (1024x768, velke pismo)', 1)
    auto = auto.replace('ocs_live_run="ocs-live-general"', 'ocs_live_run="sudo bash /run/live/medium/start.sh"', 1)
    auto = auto.replace('ocs_live_batch="no"', 'ocs_live_batch="yes" ocs_lang="en_US.UTF-8" ocs_live_keymap="NONE"', 1)
    auto = auto.replace('locales= keyboard-layouts=', 'locales=en_US.UTF-8 keyboard-layouts=NONE', 1)

    hand = base.replace('label Clonezilla live KMS\n', 'label Clonezilla live RUCNE 1024\n', 1)
    hand = hand.replace('MENU LABEL Clonezilla live (^KMS)', 'MENU LABEL Clonezilla live ^RUCNE (1024x768)', 1)

    a = s.index('label Clonezilla live\n')
    first_end = s.index('\nlabel ', a + 5)
    first = s[a:first_end].replace('  MENU DEFAULT\n', '  # MENU DEFAULT\n', 1)
    s = s[:a] + auto + '\n' + hand + '\n' + first + s[first_end:]
    s = short_timeout(s)
    open(path, 'w', encoding='utf-8', newline='\n').write(s)
    print(f'{path}: upraveno')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    for f in sys.argv[1:]:
        patch(f)
