# g722-codec — Códec ITU-T G.722 (SB-ADPCM) en Delphi puro

Encoder y decoder G.722 (audio de 7 kHz, SB-ADPCM de 2 sub-bandas con QMF) en Object Pascal,
sin DLLs. Entrada y salida: PCM lineal int16 a 16 kHz. Licencia: CC0 1.0 para el código; los
vectores de prueba de `samples/` son de la ITU-T STL y van bajo su licencia (ver `samples/NOTICE.md`).

Implementado desde el texto de la Recomendación ITU-T G.722 (09/2012), con los bloques y las
tablas de la norma. El software de STL (G.191) solo se usó como referencia cruzada y como
fuente de los vectores de prueba; su código no se tradujo.

## Estado (validado 2026-10-20)

| Parte | Estado | Verificación |
|---|---|---|
| Encoder (QMF de transmisión + ADPCM de banda baja de 6 bits y banda alta de 2 bits) | ✅ | **bit-exacto**: `inpsp.bin` → `codspw.cod` (STL) y secuencias `bt1c1/bt1c2` → `bt2r1/bt2r2` (Apéndice II) |
| Decoder modo 1 (64 kbit/s) | ✅ | **bit-exacto**: `outsp1.bin` y `bt3l*.rc1` + `bt3h*.rc0` |
| Decoder modo 2 (56 kbit/s, descarta 1 LSB de I_L) | ✅ | **bit-exacto**: `outsp2.bin` y `bt3l*.rc2` |
| Decoder modo 3 (48 kbit/s, descarta 2 LSB de I_L) | ✅ | **bit-exacto**: `outsp3.bin` y `bt3l*.rc3` |
| Reset (secuencias del Apéndice II con bit de reset) | ✅ | bit-exacto |
| Estado por instancia, API por bloques de cualquier tamaño | ✅ | tests G06/G07 |
| Ocultación de pérdidas de paquetes | ✅ | diseño propio (ver abajo); PESQ-WB mejor que repetir el último paquete en todos los casos medidos |
| Win64 y Linux64 | ✅ | 34/34 tests en ambas plataformas |

## API

```pascal
uses G722Codec;

Enc := TG722Encoder.Create;            // g722m64 por defecto
N := Enc.Encode(@PCM[0], 320, @Buf[0]); // 320 muestras (20 ms a 16 kHz) -> 160 octetos
Bytes := Enc.Encode(PCMArray);          // sobrecarga con arreglos

Dec := TG722Decoder.Create;             // modo 1 (64 kbit/s); g722m56 / g722m48 para los otros
M := Dec.Decode(@Buf[0], 160, @PCM[0]); // 160 octetos -> 320 muestras
Samples := Dec.Decode(BytesArray);

M := Dec.Decode(nil, 160, @PCM[0]);     // paquete perdido de 160 octetos -> 320 muestras ocultadas
M := Dec.Conceal(@PCM[0], 320);         // equivalente, en muestras

Enc.Reset; Dec.Reset;                   // vuelve al estado inicial
```

- `Encode` acepta bloques de cualquier tamaño. Si N es impar, la muestra sobrante se guarda
  para la llamada siguiente, así que devuelve `(N + pendiente) div 2` octetos. Si el bloque es
  par (lo normal en RTP), siempre da N/2 octetos.
- Cada octeto: bits 7..6 = I_H (banda alta), bits 5..0 = I_L (banda baja), igual que en la
  norma y en RTP.
- En los modos de 56/48 kbit/s el encoder pone a cero los 1 o 2 LSB de I_L (en la norma llevan
  datos auxiliares). El decoder en esos modos los ignora.
- `EncodeSubbands`, `DecodeSubbands` y `ResetSubbands` operan sin el QMF (configuración de prueba
  del Apéndice II). Sirven para conformidad, no para audio.
- El retardo algorítmico es de 22 muestras (QMF de 24 coeficientes en encoder y decoder).

### Ocultación de pérdidas

Los Apéndices III y IV de G.722 (PLC) son informativos, y su texto no se usó (la
ITU solo publica su software). La ocultación es de diseño propio, con técnicas
conocidas:

- Sustitución de forma de onda sincronizada con el pitch sobre la salida de 16 kHz:
  se repite 1, luego 2 y luego 3 periodos (a los 10 y 20 ms, con solapamiento al
  cambiar), con 20 % de atenuación cada 10 ms después de los primeros 10 ms y
  silencio a los 60 ms.
- Los primeros 10 ms de la señal ocultada se recodifican con un encoder que parte del
  estado del decoder, 22 muestras adelantado a la salida (el retardo de los QMF), para
  que los predictores y factores de escala del ADPCM la sigan. Recodificar también el
  desvanecimiento empeoraba las ráfagas: el factor de escala quedaba bajo al volver.
- Fundido de 4 a 10 ms (según la duración de la pérdida) entre la ocultación y el
  primer paquete bueno.
- Tras la pérdida el decoder vuelve a ser bit-exacto con el que no tuvo pérdidas
  (~300 ms después de una ráfaga de 100 ms; a los 120 ms ya está a ~29 dB).

PESQ-WB (ITU-T P.862.2) con dos grabaciones de voz de 40 s, paquetes de 20 ms:

| Pérdidas | Silencio | Repetir el último paquete | Ocultación |
|---|---|---|---|
| sin pérdidas | 4.20 / 4.40 | — | — |
| 5 % aleatorias | 1.72 / 1.80 | 1.89 / 2.13 | **2.16 / 2.82** |
| 10 % aleatorias | 1.25 / 1.45 | 1.38 / 1.70 | **1.55 / 2.24** |
| 20 % aleatorias | 1.13 / 1.19 | 1.23 / 1.35 | **1.33 / 1.67** |
| 10 % en ráfagas (media 3 paquetes) | 1.48 / 1.51 | 1.68 / 1.95 | **1.77 / 2.15** |

### Nota para RTP (RFC 3551)

En RTP, G.722 se anuncia como `G722/8000` (payload type estático 9) aunque el audio es de 16 kHz:
el reloj RTP corre a 8000 Hz por un error histórico de la especificación original. Una trama de
20 ms tiene 320 muestras, 160 octetos, y el timestamp avanza 160. La constante
`G722_RTP_CLOCK_RATE = 8000` lo documenta; el SDP y el RTP los maneja la pila VoIP.

## Tests y vectores

`tests/src/G722Tests.dpr` (34 tests):

| Test | Contenido |
|---|---|
| G01 | Encoder `inpsp.bin` → `codspw.cod` bit-exacto |
| G02–G04 | Decoder `codspw.cod` → `outsp1/2/3.bin` (modos 1/2/3) bit-exacto |
| G05 | Cadena encoder → decoder = `outsp1.bin` |
| G06 | Bloques de tamaños impares dan los mismos octetos que una sola llamada |
| G07 | Varias instancias intercaladas (encoders y decoders en distintos modos) |
| G08 | Tono de 1 kHz ida y vuelta: retardo de 22 muestras, SNR > 30 dB (da 47 dB) |
| G09 | Reset, arreglos vacíos, bits auxiliares en modo de 48 kbit/s |
| G10 | Apéndice II, encoder: `bt1c1.xmt` → `bt2r1.cod`, `bt1c2.xmt` → `bt2r2.cod` |
| G11 | Apéndice II, decoder: `bt2r1/bt2r2/bt1d3.cod` → `bt3l*.rc1..3` + `bt3h*.rc0` (9 casos) |
| G12 | Ocultación: arranque en frío, `Decode(nil)`, nivel y continuidad, desvanecimiento, reconvergencia bit-exacta |

Origen y licencia de los vectores:

- `samples/inpsp.bin`, `codspw.cod`, `outsp1.bin`, `outsp2.bin` y `outsp3.bin` vienen de la
  ITU-T Software Tool Library (G.191, https://github.com/openitu/STL, `src/g722/test_data`), que se
  distribuye bajo la "ITU-T Software Tools General Public License". Se incluyen sin modificar: PCM
  de 16 bits little-endian, y en `codspw.cod` cada octeto va en una palabra de 16 bits.
- Las secuencias digitales del Apéndice II (`bt*.xmt`, `bt*.cod`, `bt*.rc*`) no se redistribuyen.
  Para correr G10/G11, descarga el software de la Recomendación (T-REC-G.722-201209, "Software",
  https://www.itu.int/rec/T-REC-G.722-201209-I/en) y copia el contenido de
  `Software/G.722_MB-testvectors/g722-ts-le/bin/` en `samples/itu-appII/`. Esa carpeta está en
  `.gitignore`. Si falta, G10/G11 se saltan.

## Compilación

```
cd tests\src
msbuild G722Tests.dproj /p:Config=Release /p:Platform=Win64
msbuild G722Tests.dproj /p:Config=Release /p:Platform=Linux64
```

Linux64 se compila con el SDK de Linux registrado en RAD Studio 13 (Studio 37:
`ubuntu24.04.sdk`, plataforma Linux64 por defecto); el binario corre en WSL o en Linux.
La unidad solo depende de `SysUtils`.

## Notas de implementación

- `shr` de Delphi es lógico: los desplazamientos de la norma son aritméticos y usan `Sar`.
- Las sumas de FILTEZ se saturan a 16 bits en cada paso, como el sumador de la norma.
- El orden temporal dentro de cada par es: la primera muestra del par es la más antigua, tanto
  en la entrada del encoder como en la salida del decoder.
