#!/bin/bash
# Evalúa mp3-encoder contra LAME con PEAQ básico (GstPEAQ), dentro de la imagen audio-eval.
#
#   docker build -t audio-eval audio/tools/peaq
#   docker run --rm -v <dir piezas>:/work -v <dir de Mp3Enc>:/opt/mp3enc:ro -v audio/tools/peaq:/opt/eval:ro \
#     audio-eval bash /opt/eval/eval.sh "96 128 192" "abr cbr lame-abr" > resultados.csv
#
# /work debe tener las piezas (*.flac o *.wav, 44.1 kHz). Se usan los primeros 30 s.
# Modos: abr, cbr, vbrN (N = 0..9) para mp3-encoder; lame-abr, lame-cbr, lame-vN para LAME.
# Salida CSV: pieza,modo,kbps_objetivo,kbps_real,odg
set -u
RATES=${1:-"96 128 192"}
MODES=${2:-"abr cbr lame-abr"}
ENC=/opt/mp3enc/Mp3Enc
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "pieza,modo,kbps_objetivo,kbps_real,odg"
for src in /work/*.flac /work/*.wav; do
  [ -e "$src" ] || continue
  p=$(basename "${src%.*}")
  ffmpeg -nostdin -v error -y -i "$src" -t 30 -c:a pcm_s16le "$TMP/ref.wav" || continue
  ffmpeg -nostdin -v error -y -i "$TMP/ref.wav" -ar 48000 -c:a pcm_s16le "$TMP/ref48.wav"
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/ref.wav")
  for kb in $RATES; do
    for m in $MODES; do
      out="$TMP/x.mp3"; rm -f "$out"
      case $m in
        abr)      "$ENC" "$TMP/ref.wav" "$out" --abr "$kb" >/dev/null ;;
        cbr)      "$ENC" "$TMP/ref.wav" "$out" --cbr "$kb" >/dev/null ;;
        vbr[0-9]) "$ENC" "$TMP/ref.wav" "$out" --vbr "${m#vbr}" >/dev/null ;;
        lame-abr) lame --quiet --abr "$kb" "$TMP/ref.wav" "$out" ;;
        lame-cbr) lame --quiet --cbr -b "$kb" "$TMP/ref.wav" "$out" ;;
        lame-v[0-9]) lame --quiet -V "${m#lame-v}" "$TMP/ref.wav" "$out" ;;
      esac
      if [ ! -s "$out" ]; then echo "$p,$m,$kb,,ERROR"; continue; fi
      real=$(awk -v s="$(stat -c %s "$out")" -v d="$dur" 'BEGIN{printf "%.1f", s*8/d/1000}')
      ffmpeg -nostdin -v error -y -i "$out" -ar 48000 -c:a pcm_s16le "$TMP/dec48.wav"
      odg=$(peaq --basic "$TMP/ref48.wav" "$TMP/dec48.wav" 2>/dev/null \
            | awk -F: '/Objective Difference Grade/{gsub(/ /,"",$2); print $2}')
      echo "$p,$m,$kb,$real,${odg:-ERROR}"
    done
  done
done
