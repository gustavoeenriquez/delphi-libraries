# Vectores de FEC in-band (LBRR)

Vectores para probar la decodificación con FEC (`decode_fec`) de flujos SILK e
híbridos producidos por `TOpusEncoder`. Se regeneran con
`tests/tools/lbrr_vectors.py` (ver su cabecera).

Por caso:

- `<caso>.bin`: paquetes de 20 ms; cada uno precedido de `uint16` LE con su
  longitud. Longitud 0 = paquete perdido.
- `<caso>.pcm`: s16le mono a la frecuencia del caso. Es la salida de libopus
  1.5.2 para la misma secuencia: en una trama perdida, si llega la siguiente se
  llama a `opus_decode(siguiente, decode_fec=1)`; si la siguiente también se
  perdió, PLC normal (`opus_decode(NULL)`). El resto, decodificación normal.
- `<caso>.txt`: parámetros del encoder, modos presentes, cuántas pérdidas tienen
  LBRR disponible en el paquete siguiente y cuántos paquetes son DTX.

Patrón de pérdidas fijo: se pierde el paquete `k` si `k % 10 == 9` y además la
ráfaga `k = 154, 155` (32 pérdidas en 300 paquetes; la 154 y la última, 299,
van por PLC).

| caso | fs | bitrate | modo | LBRR útil |
|---|---|---|---|---|
| silk_16k_16kbps | 16 kHz | 16 kb/s | SILK WB | no (ver nota) |
| silk_16k_24kbps | 16 kHz | 24 kb/s | SILK WB | sí |
| silk_8k_16kbps | 8 kHz | 16 kb/s | SILK NB | no (ver nota) |
| silk_8k_24kbps | 8 kHz | 24 kb/s | SILK NB | sí |
| hybrid_48k_16kbps | 48 kHz | 16 kb/s | híbrido (forzado) | no (ver nota) |
| hybrid_48k_24kbps | 48 kHz | 24 kb/s | híbrido | sí |
| silk_16k_24kbps_dtx | 16 kHz | 24 kb/s | SILK WB + DTX | sí |

Nota: con 10 % de pérdidas y 16 kb/s, libopus (y por tanto este encoder)
decide no codificar LBRR (`decide_fec`: el umbral de FEC no se alcanza en
ningún ancho de banda). Esos casos ejercitan `decode_fec=1` sobre paquetes sin
LBRR, que debe caer en PLC.

Señal: sintética (`OpusEncTool gensig kind=speech`, 6 s); en el caso DTX con
silencio digital en 2,0–3,6 s y 4,6–5,4 s. Los paquetes son idénticos byte a
byte a los de libopus 1.5.2 con los mismos parámetros (incluido el análisis
tonal).

Datos de prueba bajo la misma licencia que las pruebas del repositorio (CC0).
