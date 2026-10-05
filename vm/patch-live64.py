#!/usr/bin/env python3
"""Přidá do už upraveného menu flashky (patch-syslinux.py / patch-grub.py) položky pro druhou,
64bitovou Clonezillu ve složce /live64 a variantu s omezením SATA na 1,5 Gb/s:

  AUTOMATICKY restore.sh 32bit                       (původní, zůstává výchozí)
  AUTOMATICKY 32bit, SATA 1,5 Gb/s                    libata.force=1.5Gbps (starý řadič + nové SSD)
  AUTOMATICKY 64bit (/live64)                         live-media-path=/live64
  AUTOMATICKY 64bit, SATA 1,5 Gb/s
  Clonezilla RUCNE 32bit / RUCNE 64bit

Použití: patch-live64.py syslinux.cfg [isolinux.cfg] [grub.cfg]   (soubory se upraví na místě)
Typ souboru se pozná podle obsahu. Položky se odvodí od "AUTOMATICKY" a "RUCNE" z patch-*.py.
Při neznámé podobě menu skončí chybou a nic nezmění. Soubory 64bitové verze nakopíruje add-live64.sh.
"""
import re
import sys

SATA = ' libata.force=1.5Gbps'
L64 = ' live-media-path=/live64'


def block(s: str, head: str) -> tuple[int, int]:
    a = s.index(head)
    return a, s.index('\nlabel ', a + 5)


def patch_syslinux(path: str, s: str) -> str:
    a, a_end = block(s, 'label Clonezilla live AUTO restore\n')
    auto = s[a:a_end]
    r, r_end = block(s, 'label Clonezilla live RUCNE 1024\n')
    hand = s[r:r_end]
    if 'kernel /live/vmlinuz' not in auto or 'initrd=/live/initrd.img' not in auto:
        raise SystemExit(f'{path}: neočekávaná podoba položky AUTOMATICKY – nic neměním')

    def variant(src: str, label: str, title: str, extra: str, live64: bool) -> str:
        v = re.sub(r'^label [^\n]*', f'label {label}', src, count=1)
        v = v.replace('  MENU DEFAULT\n', '', 1)
        v = re.sub(r'MENU LABEL [^\n]*', f'MENU LABEL {title}', v, count=1)
        if live64:
            v = v.replace('kernel /live/vmlinuz', 'kernel /live64/vmlinuz', 1)
            v = v.replace('initrd=/live/initrd.img', 'initrd=/live64/initrd.img', 1)
        v = re.sub(r'(\n  append [^\n]*)', lambda m: m.group(1).rstrip() + extra, v, count=1)
        return v.rstrip('\n') + '\n\n'

    auto_new = re.sub(r'MENU LABEL [^\n]*', 'MENU LABEL ^AUTOMATICKY restore.sh 32bit (velke pismo)', auto, count=1)
    adds = (variant(auto, 'Clonezilla live AUTO SATA15', 'AUTOMATICKY 32bit, ^SATA 1,5 Gb/s (stary radic + SSD)', SATA, False)
            + variant(auto, 'Clonezilla live AUTO 64', 'AUTOMATICKY ^64bit (Clonezilla 3.3.3, jen 64bit CPU)', L64, True)
            + variant(auto, 'Clonezilla live AUTO 64 SATA15', 'AUTOMATICKY 64bit, SATA 1,5 Gb/s', L64 + SATA, True))
    hand_new = re.sub(r'MENU LABEL [^\n]*', 'MENU LABEL Clonezilla live ^RUCNE 32bit (1024x768)', hand, count=1)
    hand64 = variant(hand, 'Clonezilla live RUCNE 64', 'Clonezilla live RUCNE 64bit (1024x768)', L64, True)
    return (s[:a] + auto_new.rstrip('\n') + '\n\n' + adds + hand_new.rstrip('\n') + '\n\n' + hand64.rstrip('\n')
            + s[r_end:])


def patch_grub(path: str, s: str) -> str:
    def find(ident: str) -> re.Match:
        m = re.search(r'menuentry "[^"]*" --id ' + ident + r' \{\n(?:[^\n]*\n)*?\}\n\n', s)
        if not m:
            raise SystemExit(f'{path}: chybí položka --id {ident} (nejdřív patch-grub.py) – nic neměním')
        return m

    ma, mr = find('live-auto'), find('live-rucne')

    def variant(src: str, ident: str, title: str, extra: str, live64: bool) -> str:
        v = re.sub(r'^menuentry "[^"]*" --id \S+', f'menuentry "{title}" --id {ident}', src, count=1)
        if live64:
            v = v.replace('/live/vmlinuz', '/live64/vmlinuz').replace('/live/initrd.img', '/live64/initrd.img')
        return re.sub(r'(\n  \$linux_cmd [^\n]*)', lambda m: m.group(1).rstrip() + extra, v, count=1)

    auto = ma.group(0)
    auto_new = auto.replace('"AUTOMATICKY restore.sh (velke pismo)"', '"AUTOMATICKY restore.sh 32bit (velke pismo)"', 1)
    adds = (variant(auto, 'live-auto-sata15', 'AUTOMATICKY 32bit, SATA 1,5 Gb/s (stary radic + SSD)', SATA, False)
            + variant(auto, 'live-auto64', 'AUTOMATICKY 64bit (Clonezilla 3.3.3, jen 64bit CPU)', L64, True)
            + variant(auto, 'live-auto64-sata15', 'AUTOMATICKY 64bit, SATA 1,5 Gb/s', L64 + SATA, True))
    hand = mr.group(0)
    hand_new = hand.replace('"Clonezilla live RUCNE (KMS)"', '"Clonezilla live RUCNE 32bit (KMS)"', 1)
    hand64 = variant(hand, 'live-rucne64', 'Clonezilla live RUCNE 64bit (KMS)', L64, True)
    if ma.end() != mr.start():
        raise SystemExit(f'{path}: položky AUTOMATICKY a RUCNE nejsou za sebou – nic neměním')
    return s[:ma.start()] + auto_new + adds + hand_new + hand64 + s[mr.end():]


def patch(path: str) -> None:
    s = open(path, encoding='utf-8').read()
    if 'live-media-path=/live64' in s:
        print(f'{path}: už upraveno, přeskakuji')
        return
    if 'label Clonezilla live AUTO restore' in s:
        s = patch_syslinux(path, s)
    elif '--id live-auto' in s:
        s = patch_grub(path, s)
    else:
        raise SystemExit(f'{path}: chybí položka AUTOMATICKY (nejdřív make-flash.sh) – nic neměním')
    open(path, 'w', encoding='utf-8', newline='\n').write(s)
    print(f'{path}: upraveno')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    for f in sys.argv[1:]:
        patch(f)
