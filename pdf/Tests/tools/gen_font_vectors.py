"""Generates the font programs of Tests/data/fonts for TestFonts: small fonts
drawn here (CC0) in the three formats read by uPDF.FontProgram, and the
expected outline points of every glyph.

  tt.ttf       TrueType: quadratic contours, a composite glyph with scale and
               offset, cmaps (3,1), (3,0) symbol and (1,0), 'post' names
  cff.cff      bare CFF (FontFile3 /Type1C): custom charset and encoding,
               hints and hintmask, local and global subroutines, flex,
               every curve operator, seac-style endchar
  t1.pfa       Type 1 (FontFile): custom encoding, eexec, Subrs with the
               flex and hint-replacement OtherSubrs, seac

The expected points come from FreeType (freetype-py) with FT_LOAD_NO_SCALE,
the engine MuPDF uses; for TrueType and CFF fontTools gives the same points.
manifest.txt has one line per glyph: file, glyph index, name, and the sorted
set of the outline points rounded to integers.

Usage: python gen_font_vectors.py <output dir>
"""
import os, sys, struct
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont, newTable
from fontTools.ttLib.tables._c_m_a_p import cmap_format_4, cmap_format_0
from fontTools.ttLib.tables._g_l_y_f import GlyphComponent
from fontTools.misc.psCharStrings import T2CharString, T1CharString
from fontTools.cffLib import PrivateDict, SubrsIndex, GlobalSubrsIndex
from fontTools.misc import eexec
from fontTools.pens.basePen import BasePen
import freetype

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
lines = []


def ft_points(path, names_by_gid):
    face = freetype.Face(path)
    res = {}
    for gid in range(face.num_glyphs):
        face.load_glyph(gid, freetype.FT_LOAD_NO_SCALE | freetype.FT_LOAD_NO_HINTING)
        name = face.get_glyph_name(gid).decode() if face.has_glyph_names else names_by_gid[gid]
        res[name] = sorted(set((round(x), round(y)) for x, y in face.glyph.outline.points))
    return res


class CubicPen(BasePen):
    """Outline points with quadratic segments turned into cubics (2/3 rule);
    contours without segments are dropped, as FreeType does."""
    def __init__(self, gs):
        super().__init__(gs)
        self.pts, self.cur = [], []
    def _moveTo(self, p): self._flush(); self.cur = [p]
    def _lineTo(self, p): self.cur.append(p)
    def _curveToOne(self, a, b, c): self.cur += [a, b, c]
    def _closePath(self): self._flush()
    def _endPath(self): self._flush()
    def _flush(self):
        if len(self.cur) > 1: self.pts += self.cur
        self.cur = []


def tt_points(path):
    font = TTFont(path)
    gs = font.getGlyphSet()
    res = {}
    for name in font.getGlyphOrder():
        pen = CubicPen(gs)
        gs[name].draw(pen)
        pen._flush()
        res[name] = sorted(set((round(x), round(y)) for x, y in pen.pts))
    return res


def record(fname, order, pts):
    for gid, name in enumerate(order):
        lines.append('%s %d %s %s' % (fname, gid, name,
                     ' '.join('%d,%d' % p for p in pts.get(name, []))))


# ---------------------------------------------------------------- TrueType
order = ['.notdef', 'A', 'B', 'C', 'D']
fb = FontBuilder(1000, isTTF=True)
fb.setupGlyphOrder(order)
fb.setupCharacterMap({0x41: 'A', 0x42: 'B', 0x43: 'C'})


def tt_glyph(draw):
    pen = TTGlyphPen(None)
    draw(pen)
    return pen.glyph()


def draw_a(p):
    # a triangle with a quadratic bulge (two consecutive off-curve points)
    p.moveTo((100, 0)); p.lineTo((500, 0))
    p.qCurveTo((600, 300), (400, 600), (300, 700))
    p.lineTo((100, 0)); p.closePath()


def draw_c(p):
    # outer square and inner counter; the second contour starts off-curve
    p.moveTo((0, 0)); p.lineTo((600, 0)); p.lineTo((600, 600)); p.lineTo((0, 600)); p.closePath()
    p.qCurveTo((150, 150), (450, 150), (450, 450), (150, 450), None); p.closePath()


glyphs = {'.notdef': tt_glyph(lambda p: None), 'A': tt_glyph(draw_a), 'C': tt_glyph(draw_c),
          'D': tt_glyph(lambda p: None)}
# B: A at half size moved by (300, 200), plus C unscaled
b = tt_glyph(lambda p: None)
c1 = GlyphComponent(); c1.glyphName = 'A'; c1.x, c1.y = 300, 200; c1.flags = 0
c1.transform = [[0.5, 0], [0, 0.5]]
c2 = GlyphComponent(); c2.glyphName = 'C'; c2.x, c2.y = -50, 0; c2.flags = 0
b.components = [c1, c2]
b.numberOfContours = -1
glyphs['B'] = b
fb.setupGlyf(glyphs)
glyf = fb.font['glyf']
# left side bearings equal to xMin (FreeType moves the outline otherwise)
fb.setupHorizontalMetrics({n: (700, getattr(glyf[n], 'xMin', 0)) for n in order})
fb.setupHorizontalHeader(ascent=800, descent=-200)
fb.setupNameTable({'familyName': 'PDFTestTT', 'styleName': 'Regular'})
fb.setupOS2()
fb.setupPost(keepGlyphNames=True)
font = fb.font
# extra cmaps: (3,0) symbol at 0xF020 + code, (1,0) Mac by code
sym = cmap_format_4(4); sym.platformID, sym.platEncID, sym.language = 3, 0, 0
sym.cmap = {0xF061: 'A', 0xF062: 'B', 0xF063: 'C'}
mac = cmap_format_0(0); mac.platformID, mac.platEncID, mac.language = 1, 0, 0
mac.cmap = {0x61: 'A', 0x62: 'B', 0x63: 'C', 0x64: 'D'}
font['cmap'].tables += [sym, mac]
path = os.path.join(out, 'tt.ttf')
font.save(path)
# TrueType outlines are compared as cubics (uPDF.FontProgram converts them)
pts = tt_points(path)
record('tt.ttf', order, pts)

# ---------------------------------------------------------------- CFF
# Local subr 0 draws a box; global subr 0 a diamond. Bias is 107 for both.
lsubr = T2CharString(program=[0, 0, 'rmoveto', 200, 0, 'rlineto', 0, 200, 'rlineto',
                              -200, 0, 'rlineto', 'return'])
gsubr = T2CharString(program=[100, 0, 'rmoveto', 100, 100, 'rlineto', -100, 100, 'rlineto',
                              -100, -100, 'rlineto', 'return'])
cs = {
    '.notdef': [500, 'endchar'],
    # width, stems, hintmask, every line/curve operator
    'A': [600, 0, 50, 650, 50, 'hstemhm', 100, 40, 'hintmask', b'\xc0',
          100, 100, 'rmoveto', 300, 'hlineto', 200, 'vlineto', 50, 50, 50, 50, 50, 50, 'rrcurveto',
          -100, 50, -50, 50, 'hvcurveto', -50, -50, -50, -50, 'vhcurveto',
          10, 20, 30, 40, 'hhcurveto', 5, 10, 20, 30, 40, 'vvcurveto',
          10, 10, 20, 20, 30, 30, -40, -10, 'rcurveline',
          -20, 0, -20, -20, 10, -10, 20, -30, 30, -40, 'rlinecurve', 'endchar'],
    # subroutines (local index -107 -> 0, global -107 -> 0)
    'B': [-107, 'callsubr', 300, 0, 'rmoveto', -107, 'callgsubr', 'endchar'],
    # flex, hflex, hflex1 and flex1
    'C': [0, 300, 'rmoveto',
          50, 20, 50, 20, 50, 0, 50, -20, 50, -20, 50, 0, 50, 'flex',
          40, 30, 40, 30, 40, 30, 40, 'hflex',
          20, 10, 30, 20, 30, 30, -20, -10, 30, 'hflex1',
          10, 20, 10, 20, 10, 20, -10, 20, -10, 20, -30, 'flex1',
          'endchar'],
    # endchar with seac arguments: A (code 65) with acute (code 194) moved by (100, 500)
    'Aacute': [100, 500, 65, 194, 'endchar'],
    'acute': [0, 0, 'rmoveto', 100, 0, 'rlineto', -50, 80, 'rlineto', 'endchar'],
}
order_cff = ['.notdef', 'A', 'B', 'C', 'Aacute', 'acute']
fb = FontBuilder(1000, isTTF=False)
fb.setupGlyphOrder(order_cff)
fb.setupCharacterMap({0x41: 'A', 0x42: 'B', 0x43: 'C'})
fb.setupCFF('PDFTestCFF', {}, {n: T2CharString(program=p) for n, p in cs.items()}, {})
cff = fb.font['CFF '].cff
top = cff.topDictIndex[0]
priv = top.Private
priv.Subrs = SubrsIndex(); priv.Subrs.append(lsubr)
cff.GlobalSubrs.append(gsubr)
for n in order_cff:
    top.CharStrings[n].private = priv
    top.CharStrings[n].globalSubrs = cff.GlobalSubrs
lsubr.private = priv; lsubr.globalSubrs = cff.GlobalSubrs
gsubr.private = priv; gsubr.globalSubrs = cff.GlobalSubrs
# custom encoding: codes 0x61.. for A, B, C, Aacute
top.Encoding = ['.notdef'] * 256
for code, n in ((0x61, 'A'), (0x62, 'B'), (0x63, 'C'), (0x64, 'Aacute')):
    top.Encoding[code] = n
fb.setupHorizontalMetrics({n: (600, 0) for n in order_cff})
fb.setupHorizontalHeader(ascent=800, descent=-200)
fb.setupNameTable({'familyName': 'PDFTestCFF', 'styleName': 'Regular'})
fb.setupOS2()
fb.setupPost()
otf = os.path.join(out, 'cff.otf')
fb.font.save(otf)
f2 = TTFont(otf)
raw = f2.getTableData('CFF ')
open(os.path.join(out, 'cff.cff'), 'wb').write(raw)
pts = ft_points(otf, order_cff)
assert pts == tt_points(otf), 'FreeType and fontTools disagree on the CFF font'
record('cff.cff', order_cff, pts)
os.remove(otf)

# ---------------------------------------------------------------- Type 1
# Subrs 0-3 are the standard flex / hint replacement helpers
t1subrs = [
    [3, 0, 'callothersubr', 'pop', 'pop', 'setcurrentpoint', 'return'],
    [0, 1, 'callothersubr', 'return'],
    [0, 2, 'callothersubr', 'return'],
    ['return'],
    # 4: hint replacement target
    [0, 600, 'hstem', 'return'],
]
t1cs = {
    '.notdef': [0, 500, 'hsbw', 'endchar'],
    # hsbw side bearing 20; hint replacement through OtherSubr 3; all moves/lines/curves
    'A': [20, 600, 'hsbw', 0, 650, 'hstem', 4, 1, 3, 'callothersubr', 'pop', 'callsubr',
          80, 0, 'rmoveto', 300, 'hlineto', 200, 'vlineto', -100, 0, 'rlineto',
          50, 50, 50, 50, 50, 50, 'rrcurveto', 50, 50, 50, 50, 'vhcurveto',
          -50, -50, -50, -50, 'hvcurveto', 'closepath',
          200, 'vmoveto', 30, 'hmoveto', 40, 'hlineto', 40, 'vlineto', 'closepath', 'endchar'],
    # flex: the standard sequence with Subrs 0-2
    'B': [0, 600, 'hsbw', 100, 300, 'rmoveto', 1, 'callsubr',
          50, 0, 'rmoveto', 2, 'callsubr', 0, 20, 'rmoveto', 2, 'callsubr',
          50, 0, 'rmoveto', 2, 'callsubr', 50, 0, 'rmoveto', 2, 'callsubr',
          50, 0, 'rmoveto', 2, 'callsubr', 50, -20, 'rmoveto', 2, 'callsubr',
          50, 0, 'rmoveto', 2, 'callsubr', 50, 400, 300, 0, 'callsubr',
          0, -100, 'rlineto', 'closepath', 'endchar'],
    # div and sbw
    'C': [10, 0, 600, 0, 'sbw', 300, 2, 'div', 0, 'rmoveto', 100, 'hlineto', 100, 'vlineto',
          'closepath', 'endchar'],
    # seac: A (StandardEncoding 65) with acute (194); accent sidebearing 30
    'Aacute': [20, 600, 'hsbw', 30, 120, 500, 65, 194, 'seac'],
    'acute': [30, 300, 'hsbw', 0, 0, 'rmoveto', 100, 0, 'rlineto', -50, 80, 'rlineto',
              'closepath', 'endchar'],
}
order_t1 = ['.notdef', 'A', 'B', 'C', 'Aacute', 'acute']


def t1_encrypt_cs(prog):
    data = T1CharString(program=prog)
    data.compile()
    return eexec.encrypt(b'\0\0\0\0' + data.bytecode, 4330)[0]


priv = [b'dup /Private 8 dict dup begin', b'/RD{string currentfile exch readstring pop}executeonly def',
        b'/ND{noaccess def}executeonly def', b'/NP{noaccess put}executeonly def',
        b'/lenIV 4 def', b'/BlueValues [] def', b'/password 5839 def', b'/MinFeature {16 16} def',
        b'/Subrs %d array' % len(t1subrs)]
body = b'\n'.join(priv) + b'\n'
for i, s in enumerate(t1subrs):
    e = t1_encrypt_cs(s)
    body += b'dup %d %d RD ' % (i, len(e)) + e + b' NP\n'
body += b'ND\n2 index /CharStrings %d dict dup begin\n' % len(t1cs)
for n in order_t1:
    e = t1_encrypt_cs(t1cs[n])
    body += b'/%s %d RD ' % (n.encode(), len(e)) + e + b' ND\n'
body += b'end\nend\nreadonly put\nnoaccess put\ndup/FontName get exch definefont pop\nmark currentfile closefile\n'
clear = (b'%!PS-AdobeFont-1.0: PDFTestT1 001.000\n11 dict begin\n/FontName /PDFTestT1 def\n'
         b'/FontType 1 def\n/PaintType 0 def\n/FontMatrix [0.001 0 0 0.001 0 0] readonly def\n'
         b'/FontBBox {0 0 1000 1000} readonly def\n'
         b'/Encoding 256 array\n0 1 255 {1 index exch /.notdef put} for\n'
         b'dup 97 /A put\ndup 98 /B put\ndup 99 /C put\ndup 100 /Aacute put\nreadonly def\n'
         b'currentdict end\ncurrentfile eexec\n')
enc = eexec.encrypt(b'\0\0\0\0' + body, 55665)[0]
hexed = b'\n'.join(enc[i:i + 32].hex().encode() for i in range(0, len(enc), 32))
trailer = b'\n' + (b'0' * 64 + b'\n') * 8 + b'cleartomark\n'
# The PDF FontFile keeps the trailer out (Length3 = 0); FreeType needs it
open(os.path.join(out, 't1.pfa'), 'wb').write(clear + hexed + b'\n')
tmp = os.path.join(out, 't1_full.pfa')
open(tmp, 'wb').write(clear + hexed + trailer)
record('t1.pfa', order_t1, ft_points(tmp, order_t1))
os.remove(tmp)

open(os.path.join(out, 'manifest.txt'), 'w').write(
    '# file gid name points (sorted, unique, rounded): generated by tools/gen_font_vectors.py\n' +
    '\n'.join(lines) + '\n')
print('\n'.join(lines))
