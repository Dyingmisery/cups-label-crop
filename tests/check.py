#!/usr/bin/env python3
"""Assert a label-crop output PDF has the expected page size and orientation.

usage: check.py file.pdf WIDTH_PT HEIGHT_PT [--dark-corner tl|tr|bl|br]

--dark-corner renders the page and checks that the mock label's solid black
square (drawn in the label's top-right corner) ended up in that corner, which
proves the rotation is right, not just the page size.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

from pikepdf import Pdf


def corner_darkness(pdf_path: str) -> dict[str, float]:
    with tempfile.TemporaryDirectory() as td:
        prefix = Path(td) / "p"
        subprocess.run(["pdftoppm", "-r", "36", "-gray", "-singlefile", pdf_path, str(prefix)], check=True)
        data = (Path(td) / "p.pgm").read_bytes()
    # parse binary PGM
    parts = data.split(maxsplit=4)
    w, h, body = int(parts[1]), int(parts[2]), parts[4]
    def mean(x0, y0, x1, y1):
        tot = n = 0
        for y in range(y0, y1):
            row = body[y * w:(y + 1) * w]
            for x in range(x0, x1):
                tot += row[x]
                n += 1
        return 1 - tot / (255 * n)
    cw, ch = w // 4, h // 4
    return {
        "tl": mean(0, 0, cw, ch), "tr": mean(w - cw, 0, w, ch),
        "bl": mean(0, h - ch, cw, h), "br": mean(w - cw, h - ch, w, h),
    }


def main() -> int:
    path, want_w, want_h = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
    corner = sys.argv[5] if len(sys.argv) > 5 and sys.argv[4] == "--dark-corner" else None
    with Pdf.open(path) as pdf:
        if len(pdf.pages) < 1:
            print(f"FAIL {path}: no pages"); return 1
        mb = pdf.pages[0].mediabox
        w = float(mb[2]) - float(mb[0])
        h = float(mb[3]) - float(mb[1])
        rot = int(pdf.pages[0].get("/Rotate", 0) or 0) % 360
    if abs(w - want_w) > 0.5 or abs(h - want_h) > 0.5 or rot:
        print(f"FAIL {path}: got {w:.1f}x{h:.1f} pt /Rotate={rot}, want {want_w:.0f}x{want_h:.0f} /Rotate=0")
        return 1
    msg = f"{w:.0f}x{h:.0f} pt"
    if corner:
        d = corner_darkness(path)
        best = max(d, key=d.get)
        if best != corner:
            print(f"FAIL {path}: darkest corner is {best} ({d}), want {corner}")
            return 1
        msg += f", orientation ok (mock marker in {corner} corner)"
    print(f"ok   {Path(path).name}: {msg}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
