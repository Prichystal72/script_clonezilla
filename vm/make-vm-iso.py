#!/usr/bin/env python3
"""Upravená kopie ISO Clonezilly pro VM – i na Windows bez WSL (potřebuje jen Python a pycdlib).

Do ISO přidá menu "AUTOMATICKY restore.sh" (patch-syslinux.py), vm/start.sh a aktuální restore.sh.
start.sh hledá restore.sh nejdřív na discích (flashka, disk VM) a pak na samotném ISO – virtuálka tedy
nepotřebuje disk scripts.vmdk. Originál ISO se nemění.

Použití:  py -3 -m pip install --user pycdlib
          py -3 vm/make-vm-iso.py clonezilla-live-3.3.3-37-amd64.iso clonezilla-live-3.3.3-37-amd64-vm.iso
Totéž s xorriso (Linux / WSL): make-vm-iso.sh.
"""
import io
import os
import sys

import pycdlib

HERE = os.path.dirname(os.path.abspath(__file__))
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location('patch_syslinux', os.path.join(HERE, 'patch-syslinux.py'))
patch_syslinux = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(patch_syslinux)


def lf_bytes(path: str) -> bytes:
    return open(path, 'rb').read().replace(b'\r\n', b'\n')


def iso_path_of(iso: pycdlib.PyCdlib, rr_path: str) -> str:
    rec = iso.get_record(rr_path=rr_path)
    return iso.full_path_from_dirrecord(rec, rockridge=False)


def replace(iso: pycdlib.PyCdlib, rr_path: str, data: bytes, joliet: bool) -> None:
    """Nahradí soubor (nebo přidá nový) v kořeni / podadresáři ISO podle jména Rock Ridge."""
    d, name = rr_path.rsplit('/', 1)
    try:
        ip = iso_path_of(iso, rr_path)
        iso.rm_file(iso_path=ip, rr_name=name)
    except pycdlib.pycdlibexception.PyCdlibInvalidInput:
        ip = (d + '/' if d else '/') + name.upper().replace('-', '_') + ';1'
    kw = {'iso_path': ip, 'rr_name': name}
    if joliet:
        kw['joliet_path'] = rr_path
    iso.add_fp(io.BytesIO(data), len(data), **kw)


def main(src: str, out: str) -> None:
    if os.path.abspath(src) == os.path.abspath(out):
        raise SystemExit('Výstup musí být jiný soubor než původní ISO.')
    root = os.path.dirname(HERE)
    iso = pycdlib.PyCdlib()
    iso.open(src)
    # hybridní MBR (zápis ISO na USB přes dd) pycdlib s EFI oddílem neumí přepočítat; VM a CD bootují přes El Torito
    if iso.isohybrid_mbr is not None:
        iso.rm_isohybrid()
    if not iso.has_rock_ridge():
        raise SystemExit(f'{src}: ISO bez Rock Ridge – neočekávaná podoba, nic neměním')
    joliet = iso.has_joliet()
    for cfg in ('/syslinux/isolinux.cfg', '/syslinux/syslinux.cfg'):
        buf = io.BytesIO()
        iso.get_file_from_iso_fp(buf, rr_path=cfg)
        tmp = os.path.join(os.path.dirname(os.path.abspath(out)), os.path.basename(cfg) + '.tmp')
        open(tmp, 'wb').write(buf.getvalue())
        patch_syslinux.patch(tmp)
        replace(iso, cfg, open(tmp, 'rb').read(), joliet)
        os.remove(tmp)
    replace(iso, '/start.sh', lf_bytes(os.path.join(HERE, 'start.sh')), joliet)
    replace(iso, '/restore.sh', lf_bytes(os.path.join(root, 'restore.sh')), joliet)
    iso.write(out)
    iso.close()
    print(f'Hotovo: {out}')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
