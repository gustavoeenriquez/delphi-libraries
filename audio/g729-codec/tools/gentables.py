"""Extract the numeric codebook tables of G.729 (TAB_LD8A.C, ITU-T) into a
Pascal unit. Only numbers are taken; no code."""
import re, sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding='latin-1').read().replace('\r', '')
s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)

WANT = [
    # name, pascal name, dims, comment
    ('lspcb1', 'LSPCB1', (128, 10), 'First-stage LSF codebook L1, Q13 (radians * 8192)'),
    ('lspcb2', 'LSPCB2', (32, 10), 'Second-stage LSF codebook: columns 0..4 = L2, 5..9 = L3, Q13'),
    ('fg', 'MA_PRED', (2, 4, 10), 'Switched MA predictor coefficients p(i,k), Q15'),
    ('fg_sum', 'MA_PRED_SUM', (2, 10), '1 - sum_k p(i,k), Q15'),
    ('inter_3l', 'INTERP_B30', (31,), 'Interpolation filter b30(0..30), Q15'),
    ('gbk1', 'GAIN_GA', (8, 2), 'Gain codebook GA: [gp Q14, gamma Q13]'),
    ('gbk2', 'GAIN_GB', (16, 2), 'Gain codebook GB: [gp Q14, gamma Q13]'),
    ('map1', 'GA_MAP', (8,), 'GA index -> transmitted codeword'),
    ('map2', 'GB_MAP', (16,), 'GB index -> transmitted codeword'),
    ('imap1', 'GA_IMAP', (8,), 'Transmitted GA codeword -> index'),
    ('imap2', 'GB_IMAP', (16,), 'Transmitted GB codeword -> index'),
]

def numbers(name):
    m = re.search(r'\b' + name + r'\s*(\[[^=]*\])\s*=\s*\{(.*?)\};', s, flags=re.S)
    if not m:
        sys.exit('table not found: ' + name)
    return [int(x) for x in re.findall(r'-?\d+', m.group(2))]

def fmt(vals, dims, indent):
    if len(dims) == 1:
        return '(' + ', '.join(str(v) for v in vals) + ')'
    step = len(vals) // dims[0]
    parts = [fmt(vals[i*step:(i+1)*step], dims[1:], indent + '  ') for i in range(dims[0])]
    return '(\n' + indent + '  ' + (',\n' + indent + '  ').join(parts) + ')'

out = []
for cname, pname, dims, comment in WANT:
    vals = numbers(cname)
    n = 1
    for d in dims: n *= d
    if len(vals) != n:
        sys.exit('%s: expected %d values, got %d' % (cname, n, len(vals)))
    rng = ', '.join('0..%d' % (d - 1) for d in dims)
    out.append('  // %s\n  %s: array[%s] of SmallInt = %s;\n' % (comment, pname, rng, fmt(vals, dims, '  ')))

unit = '''unit G729Tables;

{
  G729Tables.pas - Numeric tables of ITU-T G.729 / G.729 Annex A

  The Recommendation text does not list the codebook values; they are part
  of the ITU-T reference material (file TAB_LD8A.C of the G.729 software
  package, Release 3, (c) ITU-T and the original authors: AT&T, France
  Telecom, NTT, Universite de Sherbrooke). Only the numbers are reproduced
  here, because bit-stream interoperability requires these exact values.
  Generated automatically; do not edit by hand.

  Everything else in g729-codec is written from the text of the
  Recommendation and is released under CC0 1.0.
}

interface

const
''' + '\n'.join(out) + '''
implementation

end.
'''
open(dst, 'w', encoding='ascii', newline='\r\n').write(unit)
print('ok', len(WANT), 'tables')
