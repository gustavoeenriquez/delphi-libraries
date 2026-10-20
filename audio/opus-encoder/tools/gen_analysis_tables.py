#!/usr/bin/env python3
"""Genera src/OpusAnalysisTables.pas desde src/analysis.c y src/mlp_data.c de libopus.

Uso:  python gen_analysis_tables.py <directorio src/ de libopus 1.5.2> <salida .pas>

Copia literal de dct_table, analysis_window, tbands, std_feature_bias y de los
pesos/bias del MLP (layer0, layer1, layer2). Los float se escriben con 9 cifras
significativas del valor float32 que produce el compilador C, para que la
conversión de Delphi dé exactamente el mismo Single.
"""
import re
import struct
import sys


def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
    return re.sub(r'//[^\n]*', ' ', s)


def arrays(src):
    out = {}
    for m in re.finditer(r'static\s+const\s+(float|int|opus_int8)\s+(\w+)\s*\[[^\]]*\]\s*=\s*\{(.*?)\}\s*;', src, re.S):
        typ, name, body = m.groups()
        vals = [v.strip() for v in body.split(',') if v.strip()]
        out[name] = (typ, vals)
    return out


def f32(v):
    v = v.rstrip('fF')
    x = struct.unpack('<f', struct.pack('<f', float(v)))[0]
    return '%.9g' % x


def emit(lines, pname, typ, vals):
    if typ == 'float':
        ptype, vs = 'Single', [f32(v) for v in vals]
    elif typ == 'opus_int8':
        ptype, vs = 'ShortInt', [str(int(v)) for v in vals]
    else:
        ptype, vs = 'Integer', [str(int(v)) for v in vals]
    rows = [', '.join(vs[i:i + 12]) for i in range(0, len(vs), 12)]
    lines.append('  %s: array[0..%d] of %s = (' % (pname, len(vs) - 1, ptype))
    lines.append('    ' + ',\n    '.join(rows) + ');')
    lines.append('')


def main():
    d, out = sys.argv[1], sys.argv[2]
    an = arrays(strip_comments(open(d + '/analysis.c', encoding='latin-1').read()))
    ml = arrays(strip_comments(open(d + '/mlp_data.c', encoding='latin-1').read()))
    lines = ['unit OpusAnalysisTables;', '', '{',
             '  OpusAnalysisTables.pas - tablas del análisis tonal y del MLP del encoder',
             '',
             '  GENERADO por tools/gen_analysis_tables.py desde src/analysis.c y',
             '  src/mlp_data.c de libopus 1.5.2. No editar. Datos Copyright (c) 2011-2018',
             '  Xiph.Org Foundation, Jean-Marc Valin; licencia BSD de libopus.', '}', '',
             'interface', '', 'const']
    for name in ('dct_table', 'analysis_window', 'tbands', 'std_feature_bias'):
        typ, vals = an[name]
        emit(lines, 'AN_' + name.upper(), typ, vals)
    for name in ('layer0_weights', 'layer0_bias', 'layer1_weights', 'layer1_recur_weights',
                 'layer1_bias', 'layer2_weights', 'layer2_bias'):
        typ, vals = ml[name]
        emit(lines, 'MLP_' + name.upper(), typ, vals)
    lines += ['implementation', '', 'end.']
    with open(out, 'w', encoding='utf-8-sig', newline='\r\n') as f:
        f.write('\n'.join(lines) + '\n')
    print('ok')


if __name__ == '__main__':
    main()
