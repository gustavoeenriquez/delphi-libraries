# peaq — evaluación perceptual de mp3-encoder frente a LAME

Imagen Docker con ffmpeg, LAME 3.100, numpy y GstPEAQ 0.6.1 (PEAQ básico y avanzado,
ITU-R BS.1387), para medir en cualquier Linux con Docker, sin instalar nada en el host.
Montada el 2026-11-12 en mkai-c25 (sin compilador ni sudo).

```bash
# 1. imagen (una vez; ~1 GB)
docker build -t audio-eval audio/tools/peaq

# 2. CLI del encoder (Linux64)
dbuild.sh audio/tools/Mp3Enc/Mp3Enc.dproj Release      # -> ~/out/Mp3Enc/Release/Mp3Enc

# 3. evaluación: piezas (.flac/.wav, 44.1 kHz) en un directorio
docker run --rm --cpus 1 -v ~/audio-eval/sqam/flac:/work \
  -v ~/out/Mp3Enc/Release:/opt/mp3enc:ro -v $PWD/audio/tools/peaq:/opt/eval:ro \
  audio-eval nice -n 19 bash /opt/eval/eval.sh "96 128 192" "abr cbr lame-abr" > resultados.csv
```

`eval.sh` toma los primeros 30 s de cada pieza, codifica con cada modo (`abr`, `cbr`,
`vbrN` de mp3-encoder; `lame-abr`, `lame-cbr`, `lame-vN` de LAME), decodifica con
ffmpeg (gapless por la etiqueta LAME), remuestrea referencia y decodificado a 48 kHz
y saca el ODG de PEAQ básico (0 = transparente, −4 = muy molesto). CSV:
`pieza,modo,kbps_objetivo,kbps_real,odg`.

Material de prueba libre: EBU SQAM (Tech 3253), en FLAC desde
`https://qc.ebu.io/testmaterial/523/download` (175 MB, 70 pistas). No se versiona.

Notas de la imagen: GstPEAQ se instala en `/usr/lib/gstreamer-1.0`, fuera de la ruta
multiarch de Debian (de ahí `GST_PLUGIN_PATH`), y necesita `wavparse` de
gstreamer1.0-plugins-good.
