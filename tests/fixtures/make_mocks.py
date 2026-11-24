#!/usr/bin/env python3
"""Build mock shipping-label PDFs (Vinted/InPost/Evri-style A4, US Letter, ...) for testing label-crop.

All names and addresses are made up.
"""
from __future__ import annotations

from pathlib import Path

from pikepdf import Dictionary, Name, Pdf, Stream

HERE = Path(__file__).resolve().parent
A4 = (595.28, 841.89)
LETTER = (612.0, 792.0)
# ~6x4 inches, matching a typical carrier label XObject
LABEL_W, LABEL_H = 432.0, 288.0


def _font(pdf: Pdf) -> Dictionary:
    return pdf.make_indirect(
        Dictionary(Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.Helvetica)
    )


def _bold(pdf: Pdf) -> Dictionary:
    return pdf.make_indirect(
        Dictionary(Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.Helvetica)
    )


def _label_form(pdf: Pdf, width: float, height: float, caption: str) -> Stream:
    # A filled "shipping label" with a border, title, address, and barcode bars.
    bars = []
    x = 16
    # Deterministic dummy barcode
    pattern = [1, 0, 1, 1, 0, 1, 0, 0, 1, 1, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 1, 1, 1, 0, 1]
    pattern = pattern * 6
    i = 0
    while x < width - 16 and i < len(pattern):
        w = 1.4 if pattern[i] else 0.8
        if pattern[i]:
            bars.append(f"{x:.2f} 28 {w:.2f} 54 re f")
        x += w + 0.6
        i += 1
    content = f"""
q
0.98 0.98 1 rg 0 0 {width} {height} re f
0 0 0 RG 2.2 w 3 3 {width-6} {height-6} re S
0 0 0 rg
{chr(10).join(bars)}
Q
BT
/FB 18 Tf 16 {height-32} Td ({caption}) Tj
/F1 11 Tf 0 -18 Td (Tracking  VINTEST123456789GB) Tj
0 -20 Td (From: Example Seller) Tj
0 -13 Td (1 Sample Road, Testtown) Tj
0 -20 Td (To: Alex Buyer) Tj
0 -13 Td (10 Example Street, London) Tj
0 -20 Td (MOCK LABEL - NOT A REAL SHIPMENT) Tj
ET
q 0 0 0 rg {width-70} {height-70} 48 48 re f Q
""".encode()
    return Stream(
        pdf,
        content,
        Dictionary(
            Type=Name.XObject,
            Subtype=Name.Form,
            BBox=[0, 0, width, height],
            Resources=Dictionary(Font=Dictionary(F1=_font(pdf), FB=_bold(pdf))),
        ),
    )


def write_landscape_xobject(path: Path) -> None:
    """A4 with a 4x6 portrait label placed sideways — the common InPost case.

    The Form XObject itself is 4x6 portrait (text upright in form space). It is
    drawn with a 90-degree clockwise CTM so it sits as a 6x4 landscape box on
    the A4 sheet (text appears sideways). Crop + 270 then stands it back up.
    """
    pdf = Pdf.new()
    page = pdf.add_blank_page(page_size=A4)
    # Portrait form: 288 x 432 (4x6)
    form = _label_form(pdf, LABEL_H, LABEL_W, "VINTED  INPOST")
    decoy = Stream(
        pdf,
        b"q 0.95 0.95 0.95 rg 0 0 595.28 841.89 re f Q\n",
        Dictionary(Type=Name.XObject, Subtype=Name.Form, BBox=[0, 0, 595.28, 841.89], Resources=Dictionary()),
    )
    f1 = _font(pdf)
    page.Resources = Dictionary(
        XObject=Dictionary(Lb1=form, Bg=decoy),
        Font=Dictionary(F1=f1),
    )
    # 90 CW matrix [0 -1 1 0 80 688] places the 4x6 form as a 6x4 box at (80,400)
    page.Contents = Stream(
        pdf,
        b"q /Bg Do Q\n"
        b"q 0 -1 1 0 80 688 cm /Lb1 Do Q\n"
        b"BT /F1 12 Tf 50 800 Td (Vinted shipping document - A4 sheet) Tj\n"
        b"0 -16 Td (Instructions: take this parcel to an InPost locker.) Tj ET\n",
    )
    pdf.save(path)
    print(f"wrote {path}")


def write_portrait_xobject(path: Path) -> None:
    """A4 with a portrait 4x6 Form XObject, already upright."""
    pdf = Pdf.new()
    page = pdf.add_blank_page(page_size=A4)
    form = _label_form(pdf, LABEL_H, LABEL_W, "VINTED  EVRI")
    f1 = _font(pdf)
    page.Resources = Dictionary(
        XObject=Dictionary(Lb1=form),
        Font=Dictionary(F1=f1),
    )
    page.Contents = Stream(
        pdf,
        b"q 1 0 0 1 72 200 cm /Lb1 Do Q\n"
        b"BT /F1 12 Tf 50 800 Td (Vinted shipping document - portrait label) Tj ET\n",
    )
    pdf.save(path)
    print(f"wrote {path}")


def write_ink_only(path: Path) -> None:
    """A4 with a 4x6 label drawn directly (no Form XObject) for the ink fallback."""
    pdf = Pdf.new()
    page = pdf.add_blank_page(page_size=A4)
    f1 = _font(pdf)
    fb = _bold(pdf)
    page.Resources = Dictionary(Font=Dictionary(F1=f1, FB=fb))
    # Draw a portrait 4x6 inch box at (100, 220)
    x, y, w, h = 100, 220, 288, 432
    page.Contents = Stream(
        pdf,
        f"""
q
0.96 0.96 0.98 rg {x} {y} {w} {h} re f
0 0 0 RG 3 w {x+3} {y+3} {w-6} {h-6} re S
0 0 0 rg
{x+20} {y+40} 248 60 re f
Q
BT
/FB 18 Tf {x+16} {y+h-36} Td (VINTED  ROYAL MAIL) Tj
/F1 12 Tf 0 -22 Td (Tracking  MOCKRM000111222GB) Tj
0 -20 Td (Drawn directly, no Form XObject) Tj
ET
BT /F1 12 Tf 50 800 Td (Vinted A4 sheet with a drawn 4x6 label) Tj ET
""".encode(),
    )
    pdf.save(path)
    print(f"wrote {path}")


def write_already_4x6(path: Path) -> None:
    """An already-cropped 4x6 portrait PDF (reprint / pass-through)."""
    pdf = Pdf.new()
    page = pdf.add_blank_page(page_size=(288, 432))
    f1 = _font(pdf)
    page.Resources = Dictionary(Font=Dictionary(F1=f1))
    page.Contents = Stream(
        pdf,
        b"q 0 0 0 RG 2 w 4 4 280 424 re S Q\n"
        b"BT /F1 16 Tf 20 400 Td (Already 4x6 portrait) Tj ET\n",
    )
    pdf.save(path)
    print(f"wrote {path}")


def write_no_label(path: Path) -> None:
    """A4 with only sparse text — must fail detection."""
    pdf = Pdf.new()
    page = pdf.add_blank_page(page_size=A4)
    f1 = _font(pdf)
    page.Resources = Dictionary(Font=Dictionary(F1=f1))
    page.Contents = Stream(
        pdf,
        b"BT /F1 14 Tf 72 720 Td (This A4 page has no shipping label.) Tj ET\n",
    )
    pdf.save(path)
    print(f"wrote {path}")


def _placed_form_page(path: Path, page_size, form_w, form_h, cm: bytes, caption: str, header: bytes) -> None:
    pdf = Pdf.new()
    page = pdf.add_blank_page(page_size=page_size)
    form = _label_form(pdf, form_w, form_h, caption)
    page.Resources = Dictionary(XObject=Dictionary(Lb1=form), Font=Dictionary(F1=_font(pdf)))
    page.Contents = Stream(pdf, b"q " + cm + b" cm /Lb1 Do Q\n" + header)
    pdf.save(path)
    print(f"wrote {path}")


def write_letter_xobject(path: Path) -> None:
    """US Letter sheet with an upright 4x6 label XObject (eBay/Etsy US style)."""
    _placed_form_page(
        path, LETTER, LABEL_H, LABEL_W, b"1 0 0 1 162 300", "GENERIC  US LETTER",
        b"BT /F1 12 Tf 50 750 Td (Letter sheet: print the label below) Tj ET\n",
    )


def write_a4_100x150(path: Path) -> None:
    """A4 with a 100x150 mm label (283.5 x 425.2 pt), common in Europe."""
    w, h = 100 / 25.4 * 72, 150 / 25.4 * 72
    _placed_form_page(
        path, A4, w, h, b"1 0 0 1 60 360", "GENERIC  100x150MM",
        b"BT /F1 12 Tf 50 800 Td (A4 sheet with a 100x150 mm label) Tj ET\n",
    )


def write_a4_4x4(path: Path) -> None:
    """A4 with a 4x4 inch label, for LABEL_WIDTH_IN=4 LABEL_HEIGHT_IN=4 tests."""
    _placed_form_page(
        path, A4, 288, 288, b"1 0 0 1 150 400", "GENERIC  4X4",
        b"BT /F1 12 Tf 50 800 Td (A4 sheet with a 4x4 inch label) Tj ET\n",
    )


def main() -> None:
    write_landscape_xobject(HERE / "mock-vinted-a4-landscape.pdf")
    write_portrait_xobject(HERE / "mock-vinted-a4-portrait.pdf")
    write_ink_only(HERE / "mock-vinted-a4-ink.pdf")
    write_already_4x6(HERE / "mock-already-4x6.pdf")
    write_no_label(HERE / "mock-a4-no-label.pdf")
    write_letter_xobject(HERE / "mock-generic-letter.pdf")
    write_a4_100x150(HERE / "mock-generic-a4-100x150mm.pdf")
    write_a4_4x4(HERE / "mock-generic-a4-4x4.pdf")


if __name__ == "__main__":
    main()
