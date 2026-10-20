# g729-codec — Códec ITU-T G.729 Anexo A (CS-ACELP, 8 kbit/s) en Delphi puro

Encoder y decoder G.729A en Object Pascal, sin DLLs. Tramas de 10 ms: 80 muestras int16 a 8 kHz
⇄ 10 octetos. El bitstream es el estándar de G.729, así que el decoder también acepta tramas de
G.729 completo y cualquier decoder G.729 o G.729A decodifica lo que produce el encoder.

## Origen y licencia

- **Código (CC0 1.0):** se escribió desde el **texto** de la Recomendación ITU-T G.729 (06/2012):
  cuerpo principal (cláusulas 3 y 4) y Anexo A. No se tradujo ni se consultó el código C de
  referencia de la ITU.
- **Tablas (`G729Tables.pas`):** el texto de la norma no incluye los valores de los codebooks
  (LSP L1/L2/L3, predictor MA, filtro de interpolación b30, codebooks de ganancia GA/GB y sus
  mapas). Esos números se tomaron de `TAB_LD8A.C`, el archivo de tablas del paquete de software
  de la ITU (G.729 Release 3; © ITU-T y los autores originales: AT&T, France Telecom, NTT y la
  Universidad de Sherbrooke), porque la interoperabilidad exige esos valores exactos. Solo se
  copiaron los datos numéricos, con `tools/gentables.py`. Las ventanas de análisis, la ventana de
  lag y los demás coeficientes se calculan con las fórmulas del texto.
- **Patentes:** las de G.729/G.729A vencieron y el programa de licencias se cerró (~2017).

## Estado (2026-10-20)

| Parte | Estado | Verificación |
|---|---|---|
| Decoder G.729A (parámetros, excitación, síntesis LP, postfiltro del Anexo A, pasa-altos) | ✅ | SNR segmental 25–40 dB frente a la salida del decoder de referencia (`.PST`) en los 9 vectores del Anexo A |
| Ocultación de tramas perdidas (4.4 / A.4.4) y error de paridad del pitch | ✅ | `ERASURE` 31,8 dB, `PARITY` 34,6 dB frente a la referencia |
| Decodificar G.729 completo | ✅ | 22–29 dB frente a la salida del decoder G.729 completo (otro postfiltro) |
| Encoder G.729A | ✅ | misma calidad que el encoder de referencia (±0,2 dB de SNR segmental, con el mismo decoder) |
| Interoperabilidad | ✅ | el decoder de referencia de la ITU decodifica nuestro bitstream: 26–41 dB frente a nuestro decoder, el mismo nivel que con bitstreams oficiales |
| Bit-exactitud con la referencia de punto fijo | ❌ | no aplica: es una implementación en punto flotante (ver abajo) |
| Anexo B (VAD/DTX/CNG, tramas SID de 2 octetos) | 🚧 | pendiente; por ahora una trama SID se trata como trama perdida |
| Win64 y Linux64 | ✅ | 42/42 tests en ambas plataformas |

### Por qué no es bit-exacto

La Recomendación define la bit-exactitud solo mediante su código C de punto fijo (cláusulas 2.4,
5 y A.5); el texto describe el algoritmo con ecuaciones reales y no fija formatos Q, redondeos ni
saturaciones. Esta implementación usa punto flotante (`Double`), como el Anexo C, que admite
implementaciones en flotante. El bitstream es idéntico en formato; las salidas difieren de la
referencia unos 25–40 dB por debajo de la señal, lo normal entre implementaciones flotantes y de
punto fijo de G.729. Para un troncal VoIP lo que importa es la interoperabilidad del bitstream,
y está verificada en los dos sentidos.

Única divergencia notable: el vector `OVERFLOW` ejercita el manejo de desbordes del punto fijo
(la referencia reduce la excitación cuando la síntesis satura). Aquí se aplica una protección
equivalente (si la síntesis sale del rango de 16 bits, la historia de excitación se divide entre 4
y se repite la subtrama), pero la salida no sigue a la referencia en ese vector extremo.

## API

```pascal
uses G729Common, G729Encoder, G729Decoder;

Enc := TG729Encoder.Create;
Enc.EncodeFrame10ms(@PCM[0], @Frame[0]);   // 80 muestras -> 10 octetos
N := Enc.Encode(@PCM[0], Count, @Buf[0]);  // cualquier cantidad: 10 octetos por trama completa,
                                           // el resto queda pendiente para la llamada siguiente
Bytes := Enc.Encode(PCMArray);

Dec := TG729Decoder.Create;
T := Dec.Decode(@Frame[0], 10, @PCM[0]);   // trama de voz -> 80 muestras (T = g729Speech)
T := Dec.Decode(nil, 0, @PCM[0]);          // trama perdida -> ocultación (T = g729Lost)
M := Dec.DecodePayload(@Pkt[0], Len, @PCM[0]);  // payload RTP con varias tramas (80 muestras c/u)

Enc.Reset; Dec.Reset;
```

- Estado por instancia: usa un encoder y un decoder por llamada y dirección.
- Retardo algorítmico: 15 ms (10 ms de trama + 5 ms de lookahead del encoder).
- Constantes en `G729Common`: `G729_FRAME = 80`, `G729_FRAME_BYTES = 10`,
  `G729_SID_BYTES = 2`, `G729_SAMPLE_RATE = 8000`.

### Notas para RTP (RFC 3551)

Payload type estático 18, `G729/8000`. Cada paquete lleva una o varias tramas de 10 octetos
seguidas (20 ms = 20 octetos es lo habitual), con el bit más significativo de cada parámetro
primero, en el orden de la Tabla 8 de la norma. Con `annexb=yes` puede llegar al final una trama
SID de 2 octetos: `DecodePayload` ya la separa, pero hasta implementar el Anexo B se decodifica
como trama perdida. Si el troncal anuncia `annexb=yes` y no queremos DTX, en SDP se responde
`a=fmtp:18 annexb=no`.

## Implementación

| Unidad | Contenido (cláusula de la norma) |
|---|---|
| `G729Tables` | Codebooks y mapas numéricos (ver Origen) |
| `G729Common` | Bitstream (Tabla 8), paridad (3.7.2), LSF: codebook de 2 etapas, reordenamiento, predicción MA conmutada y estabilidad (3.2.4); LSP⇄LP (3.2.3, 3.2.6); vector adaptativo con b30 (ec. 40); codebook fijo (3.8.2); predicción de ganancia MA (3.9.1) |
| `G729Decoder` | Decodificación (4.1), postfiltro del Anexo A (A.4.2), pasa-altos (4.2.5), ocultación (4.4) |
| `G729Encoder` | Preprocesamiento (3.1), análisis LP (3.2.1–3.2.2), cuantización LSF (3.2.4), ponderación del Anexo A (A.3.3), pitch en lazo abierto (3.4) y cerrado (A.3.7), codebook fijo (3.8), ganancias (3.9), actualización de memorias (A.3.10) |

Puntos que el texto deja abiertos y se resolvieron contra los vectores de prueba:
- La energía de c(n) para predecir la ganancia fija (ec. 66) se mide **después** del prefiltro
  de pitch (ec. 48): medirla antes empeora 10–20 dB frente a la referencia.
- El bit de paridad P0 es `1 xor` los bits 7..2 de P1 (paridad impar): coincide en el 100 % de
  las tramas válidas de los vectores.

Donde la norma deja libre la estrategia de búsqueda, el encoder usa búsquedas exactas en lugar
de las de baja complejidad: raíces LSP por bisección completa, pitch en lazo abierto con
correlaciones a tasa completa, búsqueda **exhaustiva** del codebook fijo (8192 combinaciones) y
de las ganancias (8 × 16). Aun así consume ~0,1 ms por trama de 10 ms en un PC actual.

## Tests

`tests/src/G729Tests.dpr` (42 tests):

| Test | Contenido |
|---|---|
| T01–T04 | Empaquetado de bits, codificación del pitch y paridad, codebook fijo, LSF⇄LP y estabilidad |
| T05 | Encoder→decoder con una señal sonora sintética: nivel, distancia log-espectral y envolvente (la cadena de referencia ITU da los mismos valores con esa señal) |
| T06 | Tramas perdidas (sueltas y en ráfaga), `Reset`, instancias independientes |
| T07 | API por bloques de tamaños impares y `DecodePayload` |
| T08 | Decoder frente a las salidas de referencia del Anexo A (umbrales de SNR segmental por vector) |
| T09 | Decoder del Anexo A con bitstreams de G.729 completo |
| T10 | Encoder frente al encoder de referencia, con el mismo decoder |

Los vectores de la ITU **no se redistribuyen**. Para correr T08–T10, descarga el software de la
Recomendación (https://www.itu.int/rec/T-REC-G.729-201206-I/en, "Software", zip de 18 MB) y copia:

- `Software/G729_Release3/g729AnnexA/test_vectors/*` → `samples/itu-g729a/`
- `Software/G729_Release3/g729/test_vectors/*` → `samples/itu-g729/`
- `Software/G729_Release3/g729AnnexB/test_vectors/*` → `samples/itu-g729b/` (para el Anexo B)

Esas carpetas están en `.gitignore`. Si faltan, T08–T10 se saltan y el resto corre igual.

## Compilación

```
cd tests\src
dcc64 -B -NSSystem -U..\..\src -NUWin64\Release -EWin64\Release G729Tests.dpr
```

O con `G729Tests.dproj` en MSBuild. Para Linux64, igual que en `g722-codec` (hace falta un sysroot de Linux).
