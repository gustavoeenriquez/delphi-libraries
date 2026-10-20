"""Generates the CCITTFaxDecode test vectors in Tests/data/ccitt.

The fax data is encoded by libtiff (through Pillow); the expected output is
the CCITTFaxDecode result of MuPDF (PyMuPDF) on a PDF that wraps the data
with the same /DecodeParms, and it is also checked against the source image.
Each vector is <name>.fax; manifest.txt lists, per line:

  name K Columns Rows EndOfLine EncodedByteAlign EndOfBlock BlackIs1 sha1

where sha1 is the SHA-1 of the expected output (rows of (Columns+7)//8 bytes,
the padding bits of each row's last byte cleared).

Requirements: pip install pillow pymupdf numpy
Usage: python gen_ccitt_vectors.py <output dir>
"""
import hashlib, io, os, random, sys
import numpy as np
import pymupdf
from PIL import Image, ImageDraw, ImageFont

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
random.seed(722)


def images():
    im = Image.new("1", (800, 200), 255)
    d = ImageDraw.Draw(im)
    font = ImageFont.load_default(size=28)
    for i, t in enumerate(['CCITTFaxDecode T.4 / T.6', 'Grupo 3 y Grupo 4, 0123456789',
                           'áéíóú ñ ¿? ¡! @#$%&*()[]{}']):
        d.text((10, 10 + 60 * i), t, fill=0, font=font)
    yield 'text', im

    im = Image.new("1", (1001, 333), 255)
    d = ImageDraw.Draw(im)
    for i in range(12):
        x, y = random.randrange(0, 900), random.randrange(0, 250)
        r = random.randrange(5, 90)
        d.ellipse((x, y, x + r, y + r), outline=0, width=random.randrange(1, 6))
    for i in range(20):
        d.line((random.randrange(1001), random.randrange(333),
                random.randrange(1001), random.randrange(333)), fill=0, width=random.randrange(1, 4))
    d.rectangle((0, 0, 1000, 332), outline=0)
    yield 'shapes', im

    a = np.indices((16, 64)).sum(axis=0) % 2
    a[8:, :] = (np.arange(64) // 3) % 2          # vertical stripes of 3
    yield 'checker', Image.fromarray((a * 255).astype(np.uint8)).convert('1')

    a = np.ones((20, 5000), np.uint8) * 255
    a[2:6, 100:4900] = 0                          # black run of 4800 (> 2560)
    a[8:12, 0:2600] = 0
    a[14:18, 2559:5000] = 0
    a[:, 4999] = 0
    yield 'wide', Image.fromarray(a).convert('1')

    yield 'black', Image.new('1', (40, 10), 0)
    yield 'white', Image.new("1", (40, 10), 255)

    a = (np.random.default_rng(29).random((100, 300)) > 0.3).astype(np.uint8) * 255
    yield 'noise', Image.fromarray(a).convert('1')

    yield 'tiny', Image.new('1', (1, 1), 0)


# (suffix, Pillow compression, T4Options, K, EndOfLine, EncodedByteAlign, EndOfBlock)
CODINGS = [
    ('g4',      'group4',     None, -1, False, False, True),
    ('g31d',    'group3',     0,     0, True,  False, True),
    ('g31df',   'group3',     4,     0, True,  True,  True),
    ('g32d',    'group3',     1,     4, True,  False, True),
    ('g32df',   'group3',     5,     4, True,  True,  True),
    ('mh',      'tiff_ccitt', None,  0, False, True,  False),
]


def strip(im, comp, t4):
    b = io.BytesIO()
    info = {} if t4 is None else {292: t4}
    # libtiff codes 0 bits as white runs; Pillow writes "1" images MinIsBlack
    # (1 = white), so the image is inverted to keep white runs white
    im = Image.fromarray(~np.array(im, dtype=bool))
    im.save(b, "TIFF", compression=comp, tiffinfo=info, strip_size=1 << 30)
    t = Image.open(io.BytesIO(b.getvalue()))
    offs, cnts = t.tag_v2[273], t.tag_v2[279]
    assert len(offs) == 1, 'one strip expected'
    return b.getvalue()[offs[0]:offs[0] + cnts[0]]


def pdf_decode(data, w, h, parms):
    dp = ' '.join('/%s %s' % kv for kv in parms.items())
    obj = (b'<< /Type /XObject /Subtype /Image /Width %d /Height %d /BitsPerComponent 1 '
           b'/ColorSpace /DeviceGray /Filter /CCITTFaxDecode /DecodeParms << %s >> /Length %d >>\nstream\n'
           % (w, h, dp.encode(), len(data))) + data + b'\nendstream'
    pdf = (b'%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'
           b'2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n3 0 obj\n' + obj +
           b'\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n')
    doc = pymupdf.open(stream=pdf, filetype='pdf')
    return doc.xref_stream(3)


def clean(raw, w, h):
    rb = (w + 7) // 8
    a = np.frombuffer(raw, np.uint8)[:h * rb].reshape(h, rb).copy()
    if w % 8:
        a[:, -1] &= (0xFF << (8 - w % 8)) & 0xFF
    return a.tobytes()


lines = []
for name, im in images():
    w, h = im.size
    src = clean(im.tobytes(), w, h)               # Pillow '1': 1 = white, as PDF BlackIs1 false
    for suffix, comp, t4, k, eol, align, eob in CODINGS:
        data = strip(im, comp, t4)
        variants = [('', False, h)]
        if suffix == 'g4' and name in ('text', 'shapes'):
            variants += [('_b1', True, h), ('_norows', False, 0)]
        for vs, black1, rows in variants:
            parms = {'K': k, 'Columns': w, 'EndOfLine': str(eol).lower(),
                     'EncodedByteAlign': str(align).lower(), 'EndOfBlock': str(eob).lower(),
                     'BlackIs1': str(black1).lower()}
            if rows:
                parms['Rows'] = rows
            exp = clean(pdf_decode(data, w, h, parms), w, h)
            mine = src if not black1 else clean(bytes(255 - x for x in src), w, h)
            assert exp == mine, '%s_%s%s: MuPDF differs from the source image' % (name, suffix, vs)
            vname = '%s_%s%s' % (name, suffix, vs)
            open(os.path.join(OUT, vname + '.fax'), 'wb').write(data)
            lines.append('%s %d %d %d %d %d %d %d %s' % (vname, k, w, rows, eol, align, eob, black1,
                                                         hashlib.sha1(exp).hexdigest()))
open(os.path.join(OUT, 'manifest.txt'), 'w', newline='\n').write('\n'.join(lines) + '\n')
print(len(lines), 'vectors')
