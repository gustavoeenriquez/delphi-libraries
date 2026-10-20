#!/bin/bash
# build_oracle.sh - Compila libopus 1.5.2 (solo como oráculo de pruebas) y opus_oracle.
#
# Uso (Linux / WSL):  ./build_oracle.sh [directorio de trabajo]   (por defecto ~/opus-oracle)
#
# libopus se compila con --disable-intrinsics para que el camino float sea el
# escalar SSE2, igual que el código Delphi Win64/Linux64. Configuración por
# defecto de libopus (incluye FLOAT_APPROX). Nada de esto entra en la librería.
set -e
WORK="${1:-$HOME/opus-oracle}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VER=1.5.2
SHA=65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1
mkdir -p "$WORK"
cd "$WORK"
if [ ! -f opus-$VER.tar.gz ]; then
  curl -sSL -o opus-$VER.tar.gz https://downloads.xiph.org/releases/opus/opus-$VER.tar.gz
fi
echo "$SHA  opus-$VER.tar.gz" | sha256sum -c -
if [ ! -f opus-$VER/.libs/libopus.a ]; then
  rm -rf opus-$VER
  tar xzf opus-$VER.tar.gz
  (cd opus-$VER && ./configure --disable-intrinsics --disable-shared --enable-static \
     --disable-doc --disable-extra-programs CFLAGS='-O2 -g' >/dev/null && make -j"$(nproc)" >/dev/null)
fi
gcc -O2 -I opus-$VER/include -I opus-$VER/src -I opus-$VER/celt -o opus_oracle \
  "$HERE/opus_oracle.c" opus-$VER/.libs/libopus.a -lm
echo "oráculo listo: $WORK/opus_oracle"

# Variante sin análisis tonal: copia de libopus parcheada para que el
# resultado de run_analysis()/tonality_get_info() se descarte
# (analysis_info.valid = 0). Sirve para comparar byte a byte las
# complejidades 7-10 mientras el port no tenga analysis.c (etapa E3).
if [ ! -f noan/opus-$VER/.libs/libopus.a ]; then
  rm -rf noan && mkdir noan
  (cd noan && tar xzf ../opus-$VER.tar.gz && cd opus-$VER && \
   sed -i 's/lsb_depth, downmix, &analysis_info);/lsb_depth, downmix, \&analysis_info); analysis_info.valid = 0;/' src/opus_encoder.c && \
   sed -i 's/tonality_get_info(&st->analysis, &analysis_info, enc_frame_size);/tonality_get_info(\&st->analysis, \&analysis_info, enc_frame_size); analysis_info.valid = 0;/' src/opus_encoder.c && \
   test "$(grep -c 'analysis_info.valid = 0;' src/opus_encoder.c)" -ge 3 && \
   ./configure --disable-intrinsics --disable-shared --enable-static --disable-doc \
     --disable-extra-programs CFLAGS='-O2 -g' >/dev/null && make -j"$(nproc)" >/dev/null)
fi
gcc -O2 -I noan/opus-$VER/include -I noan/opus-$VER/src -I noan/opus-$VER/celt \
  -o opus_oracle_noan "$HERE/opus_oracle.c" noan/opus-$VER/.libs/libopus.a -lm
echo "oráculo sin análisis listo: $WORK/opus_oracle_noan"
