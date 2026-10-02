#!/usr/bin/env python3
"""Nasnímá obrazovky restore.sh v SIMULACI (nic se nezapisuje) a uloží je jako PNG.

Spouští skript v pseudo-terminálu s rozhraním dialog, posílá klávesy a obsah obrazovky
vykreslí barvami konzole Clonezilly. Použití (Linux/WSL, potřebuje pyte a Pillow):

    python3 test/screenshots.py [výstupní_adresář]
"""
import os
import pty
import select
import sys
import time

import pyte
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "docs", "img")
COLS, ROWS = 100, 30
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
FONT_B = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
SIZE = 16

# Barvy textové konzole (VGA), stejně jako v Clonezille
PAL = {
    "black": "#000000", "red": "#aa0000", "green": "#00aa00", "brown": "#aa5500",
    "blue": "#0000aa", "magenta": "#aa00aa", "cyan": "#00aaaa", "white": "#aaaaaa",
    "brightblack": "#555555", "brightred": "#ff5555", "brightgreen": "#55ff55",
    "brightbrown": "#ffff55", "brightyellow": "#ffff55", "brightblue": "#5555ff",
    "brightmagenta": "#ff55ff", "brightcyan": "#55ffff", "brightwhite": "#ffffff",
}

BKSP = "\x7f" * 12
ENTER = "\r"
# (klávesy, čekání v s, název snímku nebo None) – scénář beckhoff-2disk: 2 CF karty → jeden SSD
STEPS = [
    ("", 2.5, "01-hlavni-menu"),
    ("1" + ENTER, 1.5, "02-disk-se-zalohami"),
    ("1" + ENTER, 1.5, "03-vyber-zalohy"),
    ("1" + ENTER, 1.5, "04-zaloha-se-2-disky"),
    ("1" + ENTER, 2.0, "05-informace-o-zaloze"),
    (ENTER, 1.5, None),  # tabulka disků
    (ENTER, 1.5, "07-cilovy-disk"),
    ("3" + ENTER, 1.5, "08-velikost-oddilu-rezim"),
    ("3" + ENTER, 1.5, None),  # zadání velikosti (předvyplněné)
    (BKSP + "20G", 1.0, "09b-velikost-oddilu-1-zadano"),
    (ENTER, 1.5, "10-velikost-oddilu-2"),
    (ENTER, 1.5, "11-rozlozeni"),
    (ENTER, 1.5, "12-souhrn-pred-zapisem"),
    (ENTER, 1.5, None),  # potvrzení (prázdné)
    ("sdf", 1.0, "13b-potvrzeni-zadano"),
    (ENTER, 9.0, "14-hotovo"),
    (ENTER, 1.5, None),
    ("0" + ENTER, 1.5, None),
]


class BceScreen(pyte.Screen):
    """Smazání obrazovky vyplní aktuální barvou pozadí (jako skutečný terminál – „bce“)."""

    def erase_in_display(self, how=0, *args, **kwargs):
        if how in (2, 3):
            for y in range(self.lines):
                line = self.buffer[y]
                for x in range(self.columns):
                    line[x] = self.cursor.attrs
            self.dirty.update(range(self.lines))
        else:
            super().erase_in_display(how, *args, **kwargs)


def color(name, default):
    if name in (None, "default"):
        return default
    if name in PAL:
        return PAL[name]
    if len(name) == 6:  # 256 barev / truecolor jako hex
        return "#" + name
    return default


def render(screen, path):
    font = ImageFont.truetype(FONT, SIZE)
    bold = ImageFont.truetype(FONT_B, SIZE)
    cw = int(font.getlength("M"))
    ch = SIZE + 4
    img = Image.new("RGB", (COLS * cw, ROWS * ch), PAL["black"])
    d = ImageDraw.Draw(img)
    for y in range(ROWS):
        line = screen.buffer[y]
        for x in range(COLS):
            c = line[x]
            fg = c.fg
            if c.bold and fg in PAL and not fg.startswith("bright"):
                fg = "bright" + fg
            fgc = color(fg, PAL["white"])
            bgc = color(c.bg, PAL["black"])
            if c.reverse:
                fgc, bgc = bgc, fgc
            d.rectangle([x * cw, y * ch, (x + 1) * cw - 1, (y + 1) * ch - 1], fill=bgc)
            if c.data.strip():
                d.text((x * cw, y * ch + 1), c.data, font=bold if c.bold else font, fill=fgc)
    img.save(path)


def main():
    os.makedirs(OUT, exist_ok=True)
    env = dict(os.environ, TERM="xterm", LANG="C.UTF-8", LC_ALL="C.UTF-8",
               NCURSES_NO_UTF8_ACS="1", COLUMNS=str(COLS), LINES=str(ROWS))
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        import fcntl, struct, termios
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        os.execvpe("bash", ["bash", "restore.sh", "--simulate=beckhoff-2disk", "--ui", "dialog"], env)
    screen = BceScreen(COLS, ROWS)
    stream = pyte.ByteStream(screen)

    def pump(seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return
                if not data:
                    return
                stream.feed(data)

    for keys, wait, name in STEPS:
        if keys:
            for k in keys:
                os.write(fd, k.encode())
                time.sleep(0.03)
        pump(wait)
        if name:
            path = os.path.join(OUT, name + ".png")
            render(screen, path)
            print("uloženo", path)
    pump(1.0)
    try:
        os.kill(pid, 9)
    except ProcessLookupError:
        pass


if __name__ == "__main__":
    main()
