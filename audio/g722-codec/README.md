# g722-codec — Códec ITU-T G.722 (SB-ADPCM) en Delphi puro

Encoder y decoder G.722 (audio de 7 kHz, SB-ADPCM de 2 sub-bandas con QMF) en Object Pascal,
sin DLLs. Entrada y salida: PCM lineal int16 a 16 kHz. Licencia: CC0 1.0.

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
| Win64 y Linux64 | ✅ | 27/27 tests en ambas plataformas |
| Ocultación de pérdidas (G.722 Apéndices III/IV) | ❌ | no implementada |

## API

```pascal
uses G722Codec;

Enc := TG722Encoder.Create;            // g722m64 por defecto
N := Enc.Encode(@PCM[0], 320, @Buf[0]); // 320 muestras (20 ms a 16 kHz) -> 160 octetos
Bytes := Enc.Encode(PCMArray);          // sobrecarga con arreglos

Dec := TG722Decoder.Create;             // modo 1 (64 kbit/s); g722m56 / g722m48 para los otros
M := Dec.Decode(@Buf[0], 160, @PCM[0]); // 160 octetos -> 320 muestras
Samples := Dec.Decode(BytesArray);

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

### Nota para RTP (RFC 3551)

En RTP, G.722 se anuncia como `G722/8000` (payload type estático 9) aunque el audio es de 16 kHz:
el reloj RTP corre a 8000 Hz por un error histórico de la especificación original. Una trama de
20 ms tiene 320 muestras, 160 octetos, y el timestamp avanza 160. La constante
`G722_RTP_CLOCK_RATE = 8000` lo documenta; el SDP y el RTP los maneja la pila VoIP.

## Tests y vectores

`tests/src/G722Tests.dpr` (27 tests):

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
dcc64 -B -NSSystem -U..\..\src -NUWin64\Release -EWin64\Release G722Tests.dpr
dcclinux64 -B -NSSystem -U..\..\src -NULinux64\Release -ELinux64\Release --syslibroot:<sysroot> --libpath:<...> G722Tests.dpr
```

También se puede compilar con `G722Tests.dproj` en MSBuild. La unidad solo depende de `SysUtils`.

## Notas de implementación

- `shr` de Delphi es lógico: los desplazamientos de la norma son aritméticos y usan `Sar`.
- Las sumas de FILTEZ se saturan a 16 bits en cada paso, como el sumador de la norma.
- El orden temporal dentro de cada par es: la primera muestra del par es la más antigua, tanto
  en la entrada del encoder como en la salida del decoder.
