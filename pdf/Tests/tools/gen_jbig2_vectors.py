"""Generates the JBIG2Decode test vectors in Tests/data/jbig2.

The JBIG2 data is encoded by jbig2enc (Ubuntu package "jbig2"); the
expected output is the JBIG2Decode result of MuPDF (PyMuPDF) on a PDF that
wraps the data (with /JBIG2Globals when there are globals), and it is also
checked against the source image in the lossless modes.  Files per vector:

  <name>.jb2    page stream (embedded organisation, as stored in a PDF)
  <name>.glb    JBIG2Globals stream (only in symbol mode)
  <name>.file   whole JBIG2 file (sequential organisation, file header)

manifest.txt lists, per line:  name width height sha1  where sha1 is the
SHA-1 of the decoded page, rows of (width+7)//8 bytes, 1 = black (JBIG2
convention), padding bits cleared.

Requirements: jbig2 (jbig2enc), pip install pillow pymupdf numpy
Usage: python gen_jbig2_vectors.py <output dir>
"""
import hashlib, os, random, shutil, subprocess, sys, tempfile
import numpy as np
import pymupdf
from PIL import Image, ImageDraw, ImageFont

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
random.seed(88)


def text_image(w, h, lines, size, seed):
    rnd = random.Random(seed)
    im = Image.new('L', (w, h), 255)
    d = ImageDraw.Draw(im)
    font = ImageFont.load_default(size=size)
    y = 8
    for t in lines:
        d.text((10 + rnd.randrange(4), y), t, fill=0, font=font)
        y += int(size * 1.4)
    return im


def images():
    lorem = ['La U.A.E. Dirección de Impuestos y Aduanas Nacionales,',
             'conforme a la facultad discrecional establecida en el',
             'artículo 684-2 del Estatuto Tributario y en virtud de lo',
             'estipulado en la Resolución 000165 del 01/11/2023, por la',
             'cual se dictan otras disposiciones en materia de sistemas',
             'de facturación; previo estudio y evaluación de la',
             'solicitud realizada por el contribuyente, representante',
             'legal o apoderado debidamente acreditado: 0123456789.']
    yield 'text', text_image(900, 330, lorem, 22, 1)
    yield 'small', text_image(300, 60, ['JBIG2 T.88', 'abc ABC 123'], 18, 2)
    im = Image.new('L', (513, 257), 255)
    d = ImageDraw.Draw(im)
    for i in range(25):
        x, y = random.randrange(480), random.randrange(230)
        r = random.randrange(4, 60)
        d.ellipse((x, y, x + r, y + r), outline=0, width=random.randrange(1, 5))
    for i in range(0, 513, 16):
        d.line((i, 0, 512 - i, 256), fill=0)
    yield 'shapes', im


# (suffix, jbig2enc flags, lossless); symbol mode merges similar symbols,
# so only MuPDF is the reference there.  (jbig2enc 0.28 has refinement,
# -r, disabled.)
MODES = [('gen', [], True), ('tpgd', ['-d'], True), ('sym', ['-s'], False)]


def encode(im, flags):
    tmp = tempfile.mkdtemp()
    try:
        im.convert('1').save(os.path.join(tmp, 'in.png'))
        # PDF-ready data: output.sym (globals, symbol mode) + output.0000
        out = subprocess.run(['jbig2'] + flags + ['-p', '-b', 'output', 'in.png'], cwd=tmp,
                             check=True, capture_output=True).stdout
        # symbol mode writes files; generic mode writes the page to stdout
        pg = os.path.join(tmp, 'output.0000')
        page = open(pg, 'rb').read() if os.path.exists(pg) else out
        sym = os.path.join(tmp, 'output.sym')
        glb = open(sym, 'rb').read() if os.path.exists(sym) else b''
        # whole file on stdout
        whole = subprocess.run(['jbig2'] + flags + ['in.png'], cwd=tmp, check=True,
                               capture_output=True).stdout
        return page, glb, whole
    finally:
        shutil.rmtree(tmp)


def mupdf_decode(page, glb, w, h):
    objs = {}
    objs[1] = b'<< /Type /Catalog /Pages 2 0 R >>'
    objs[2] = b'<< /Type /Pages /Kids [] /Count 0 >>'
    dp = b''
    if glb:
        objs[4] = b'<< /Length %d >>\nstream\n' % len(glb) + glb + b'\nendstream'
        dp = b'/DecodeParms << /JBIG2Globals 4 0 R >> '
    objs[3] = (b'<< /Type /XObject /Subtype /Image /Width %d /Height %d /BitsPerComponent 1 '
               b'/ColorSpace /DeviceGray /Filter /JBIG2Decode %s/Length %d >>\nstream\n'
               % (w, h, dp, len(page))) + page + b'\nendstream'
    pdf = b'%PDF-1.4\n' + b''.join(b'%d 0 obj\n' % k + v + b'\nendobj\n' for k, v in sorted(objs.items()))
    pdf += b'trailer\n<< /Root 1 0 R >>\n%%EOF\n'
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
    src = clean(np.packbits(np.asarray(im.convert('1')) == 0, axis=1).tobytes(), w, h)  # 1 = black
    for mode, flags, lossless in MODES:
        page, glb, whole = encode(im, flags)
        exp = clean(bytes(255 - b for b in mupdf_decode(page, glb, w, h)), w, h)   # PDF: 1 = white
        if lossless:
            assert exp == src, '%s_%s: MuPDF differs from the source image' % (name, mode)
        vname = '%s_%s' % (name, mode)
        open(os.path.join(OUT, vname + '.jb2'), 'wb').write(page)
        if glb:
            open(os.path.join(OUT, vname + '.glb'), 'wb').write(glb)
        open(os.path.join(OUT, vname + '.file'), 'wb').write(whole)
        lines.append('%s %d %d %s' % (vname, w, h, hashlib.sha1(exp).hexdigest()))
open(os.path.join(OUT, 'manifest.txt'), 'w', newline='\n').write('\n'.join(lines) + '\n')
print(len(lines), 'vectors')
