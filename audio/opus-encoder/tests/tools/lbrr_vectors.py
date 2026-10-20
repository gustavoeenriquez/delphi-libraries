#!/usr/bin/env python3
"""lbrr_vectors.py - Genera los vectores de prueba de FEC in-band (LBRR) del encoder.

Herramienta de pruebas del repositorio (no forma parte de la librería).

Uso:  python lbrr_vectors.py <OpusEncTool.exe> <directorio de salida> [directorio del oráculo en WSL]
      (por defecto ~/opus-oracle, ver build_oracle.sh)

Por cada caso escribe:
  <caso>.bin  paquetes del encoder Delphi; cada uno precedido de uint16 LE con su
              longitud; longitud 0 = paquete perdido (patrón fijo, ver abajo).
  <caso>.pcm  s16le mono a la frecuencia del caso: libopus 1.5.2 decodificando la
              misma secuencia; trama perdida -> si llega la siguiente se decodifica
              su LBRR (decode_fec=1), si no, PLC normal.
  <caso>.txt  parámetros, patrón de pérdidas y estadísticas (tramas con LBRR, etc.).

La señal de entrada es sintética (OpusEncTool gensig kind=speech), así que los
vectores se pueden distribuir. Los paquetes del encoder Delphi se comprueban
idénticos byte a byte a los de libopus 1.5.2 con los mismos parámetros.
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile

TOOL = sys.argv[1]
OUT = sys.argv[2]
ODIR = sys.argv[3] if len(sys.argv) > 3 else '~/opus-oracle'
ORACLE = 'wsl -e bash -lc "' + ODIR + '/opus_oracle {args}"'
SECONDS = 6

# (nombre, fs, bitrate, modo, dtx)
CASES = [
    ('silk_16k_16kbps', 16000, 16000, 'auto', 0),
    ('silk_16k_24kbps', 16000, 24000, 'auto', 0),
    ('silk_8k_16kbps', 8000, 16000, 'auto', 0),
    ('silk_8k_24kbps', 8000, 24000, 'auto', 0),
    ('hybrid_48k_16kbps', 48000, 16000, 'hybrid', 0),
    ('hybrid_48k_24kbps', 48000, 24000, 'auto', 0),
    ('silk_16k_24kbps_dtx', 16000, 24000, 'auto', 1),
]
COMMON = 'ch=1 app=voip ms=20 cx=10 vbr=1 fec=1 loss=10'
BURST = (154, 155)


def lost(k):
    return k % 10 == 9 or k in BURST


def wsl_path(p):
    p = os.path.abspath(p).replace('\\', '/')
    return '/mnt/' + p[0].lower() + p[2:]


def run(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, encoding='utf-8', errors='replace')
    if r.returncode != 0:
        sys.exit('falló: %s\n%s%s' % (cmd, r.stdout, r.stderr))
    return (r.stdout + r.stderr).strip()


def read_opk(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'OPK1'
    p, pk = 4, []
    while p < len(d):
        n, _rng = struct.unpack('<iI', d[p:p + 8])
        p += 8
        pk.append(d[p:p + n])
        p += n
    return pk


def lbrr_flag(pkt):
    # SILK/híbrido mono 20 ms: primeros bits del rango = VAD, LBRR
    toc = pkt[0]
    if (toc >> 3) >= 16 or len(pkt) < 2:
        return None
    return (pkt[1] >> 6) & 1


def main():
    os.makedirs(OUT, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix='lbrr_')
    for name, fs, br, mode, dtx in CASES:
        raw = os.path.join(tmp, '%s.raw' % name)
        run('"%s" gensig "%s" kind=speech fs=%d ch=1 n=%d' % (TOOL, raw, fs, fs * SECONDS))
        if dtx:
            # pausas de silencio digital para que actúe la DTX
            b = bytearray(open(raw, 'rb').read())
            for a, z in ((2.0, 3.6), (4.6, 5.4)):
                b[int(a * fs) * 2:int(z * fs) * 2] = bytes(int(z * fs) * 2 - int(a * fs) * 2)
            open(raw, 'wb').write(b)
        args = '%s fs=%d br=%d mode=%s dtx=%d' % (COMMON, fs, br, mode, dtx)
        ours = os.path.join(tmp, name + '.our.opk')
        ref = os.path.join(tmp, name + '.ref.opk')
        run('"%s" encode "%s" "%s" %s' % (TOOL, raw, ours, args))
        run(ORACLE.format(args='encode %s %s %s' % (wsl_path(raw), wsl_path(ref), args)))
        pk = read_opk(ours)
        if pk != read_opk(ref):
            sys.exit('%s: los paquetes Delphi difieren de libopus' % name)
        binp = os.path.join(OUT, name + '.bin')
        with open(binp, 'wb') as f:
            for k, p in enumerate(pk):
                if lost(k):
                    f.write(struct.pack('<H', 0))
                else:
                    f.write(struct.pack('<H', len(p)) + p)
        pcm = os.path.join(OUT, name + '.pcm')
        msg = run(ORACLE.format(args='fecdec %s %s fs=%d ch=1 ms=20' % (wsl_path(binp), wsl_path(pcm), fs)))
        nl = sum(1 for k in range(len(pk)) if lost(k))
        fl = [lbrr_flag(p) for p in pk]
        lb = sum(1 for k in range(len(pk) - 1) if lost(k) and not lost(k + 1) and fl[k + 1] == 1)
        modes = sorted({('SILK' if (p[0] >> 3) < 12 else 'HYBRID' if (p[0] >> 3) < 16 else 'CELT') for p in pk})
        short = sum(1 for p in pk if len(p) <= 2)
        with open(os.path.join(OUT, name + '.txt'), 'w', encoding='utf-8', newline='\n') as f:
            f.write('caso: %s\n' % name)
            f.write('señal: OpusEncTool gensig kind=speech, %d s, mono, %d Hz%s\n' % (
                SECONDS, fs, ', silencio en 2.0-3.6 s y 4.6-5.4 s' if dtx else ''))
            f.write('encoder: TOpusEncoder (idéntico byte a byte a libopus 1.5.2)\n')
            f.write('parámetros: %s\n' % args)
            f.write('modos en el flujo: %s\n' % ', '.join(modes))
            f.write('paquetes: %d (20 ms); perdidos: %d (k %% 10 == 9 y ráfaga k = %d,%d)\n' % (
                len(pk), nl, BURST[0], BURST[1]))
            f.write('paquetes con bandera LBRR: %d\n' % sum(1 for x in fl if x == 1))
            f.write('pérdidas con LBRR disponible en el siguiente paquete: %d\n' % lb)
            f.write('paquetes DTX (<= 2 bytes): %d\n' % short)
            f.write('referencia .pcm (libopus fecdec): %s\n' % msg.splitlines()[-1])
        print('%-22s %s | LBRR %d/%d, DTX %d' % (name, msg.splitlines()[-1], lb, nl, short))
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()
