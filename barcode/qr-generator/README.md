# barcode/qr-generator — Generador y lector de códigos QR en Delphi

Generador **y lector** completos de códigos QR (ISO/IEC 18004, Model 2). El
generador no tiene dependencias externas (ni GDI+, ni Vcl.Graphics, ni DLLs
de terceros); el lector es "pure Pascal" salvo por `QRImageLoader.pas`
(único punto de contacto con la VCL, para abrir archivos BMP/PNG/JPEG).

**License: [CC0 1.0 Universal (Public Domain)](../../LICENSE.md)** — ver
también las notas de atribución (MIT/Apache 2.0) al final de este documento.

---

## Status: Active

### Generador

| Capacidad | Estado |
|---|:---:|
| Versiones 1–40 | ✅ |
| Niveles ECC L / M / Q / H | ✅ |
| Modo numérico | ✅ |
| Modo alfanumérico | ✅ |
| Modo byte (UTF-8) | ✅ |
| Modo Kanji (bytes Shift-JIS pre-codificados) | ✅ |
| Selección automática de modo (numeric > alphanumeric > byte) | ✅ |
| Selección automática de versión y "boost" de nivel ECC | ✅ |
| Selección automática de máscara (8 patrones + penalización) | ✅ |
| Exportar a matriz de módulos booleanos | ✅ |
| Exportar a BMP (24 bits, sin compresión) | ✅ |
| Exportar a SVG (rectángulos fusionados por fila) | ✅ |
| Exportar a PNG (escala de grises 1 bit, DEFLATE "stored") | ✅ |

### Lector

| Capacidad | Estado |
|---|:---:|
| Decodificar una matriz de módulos ya alineada (`QRMatrixDecoder`) | ✅ |
| Binarización adaptativa por bloques (fotos con luz despareja) | ✅ |
| Localización de los 3 patrones buscadores + patrón de alineación | ✅ |
| Corrección de perspectiva (rotación arbitraria, inclinación moderada) | ✅ |
| Corrección de errores Reed-Solomon (Euclides + Chien + Forney) | ✅ |
| Cargar BMP/PNG/JPEG desde archivo (`QRImageLoader`, requiere VCL) | ✅ |
| Multi-QR en una misma imagen / modo "try harder" multi-pasada | ❌ (no implementado) |

**Ver "Limitaciones del lector"** más abajo para el alcance probado de
tolerancia a ruido/rotación.

---

## Library path

Agregar en **Tools → Options → Language → Delphi → Library**:

```
...\delphi-libraries\barcode\qr-generator\src
```

---

## Uso

```pascal
uses
  QRTypes, QREncoder, QRImagePNG, QRImageSVG, QRImageBMP;

var
  QR: TQRCode;
begin
  // Alto nivel: elige automaticamente modo, version y nivel ECC (>= qeMedium)
  QR := TQRCode.EncodeText('https://github.com/gustavoeenriquez/delphi-libraries', qeMedium);
  try
    WriteLn('Version: ', QR.Version, '  Tamaño: ', QR.Size, 'x', QR.Size);
    QRSavePNG(QR, 'qr.png', 8, 4);  // escala 8px/modulo, quiet zone de 4 modulos
    QRSaveSVG(QR, 'qr.svg', 10, 4);
    QRSaveBMP(QR, 'qr.bmp', 8, 4);

    // Acceso directo a la matriz de modulos
    if QR.GetModule(0, 0) then
      // modulo oscuro en la esquina superior izquierda (patron buscador)
  finally
    QR.Free;
  end;
end;
```

### Control fino: segmentos, versión mínima/máxima, máscara forzada

```pascal
var
  Segs: TQRSegmentArray;
  QR: TQRCode;
begin
  SetLength(Segs, 1);
  Segs[0] := QRMakeAlphanumeric('HELLO WORLD');
  // O bien mezclar modos manualmente concatenando varios QRMake* en el array.

  QR := TQRCode.EncodeSegments(Segs, qeHigh,
    {AMinVersion=}1, {AMaxVersion=}40, {AMask=}-1, {ABoostEcl=}True);
  try
    // ...
  finally
    QR.Free;
  end;
end;
```

### Modo Kanji

El modo Kanji requiere los caracteres ya codificados en Shift-JIS (esta
librería no detecta ni convierte texto Unicode a Shift-JIS automáticamente):

```pascal
var
  Seg: TQRSegment;
begin
  Seg := QRMakeKanji(MisBytesShiftJIS); // pares de bytes 0x8140-0x9FFC o 0xE040-0xEBBF
end;
```

### Demo de línea de comandos (generador)

```
samples/QRDemo.exe "https://example.com" salida.png M 8 4
```

---

## Lector — uso

```pascal
uses
  QRGrayImage, QRReader, QRImageLoader; // QRImageLoader es opcional (VCL)

var
  Img: TQRGrayImage;
  R: TQRReadResult;
begin
  Img := QRLoadGrayImage('foto_qr.jpg');  // BMP/PNG/JPEG via VCL
  R := QRReadImage(Img);
  if R.Success then
    WriteLn('Texto: ', R.Text, '  (v', R.Version, ', errores corregidos: ', R.NumErrorsCorrected, ')')
  else
    WriteLn('No se pudo decodificar: ', R.ErrorMessage);
end;
```

Si ya tenés los píxeles en escala de grises desde otra fuente (una cámara,
Skia4Delphi, etc.), construí el `TQRGrayImage` directamente con
`QRGrayImageCreate` y omití `QRImageLoader` (así el resto del lector sigue
sin depender de la VCL).

Para decodificar una matriz de módulos ya alineada (por ejemplo, generada
por otra herramienta), salteando binarización/detección/perspectiva:

```pascal
uses QRMatrixDecoder;
var R: TQRMatrixDecodeResult;
begin
  R := QRDecodeMatrix(MiGrilla, TamanoDeLaGrilla);
end;
```

### Demo de línea de comandos (lector)

```
samples/QRScanDemo.exe foto_qr.jpg
```

### Limitaciones del lector

- Detecta **un solo** código QR por imagen (el primero cuyos 3 patrones
  buscadores encuentre); no hay modo "multi-QR en una foto".
- No implementa el modo "try harder" de reintentos múltiples (varias
  binarizaciones, várias rotaciones forzadas) que sí tiene ZXing — una
  sola pasada de detección. En la práctica, la rotación arbitraria ya
  funciona sin reintentos porque la geometría de los 3 buscadores no
  depende de que la imagen esté "derecha" (ver tests: 90°/180°/270° y 12°
  arbitrarios, todos ✅).
- Tolerancia a ruido probada: hasta ~0.5–0.6% de píxeles alterados
  aleatoriamente (ruido sal-y-pimienta sintético, un modelo más agresivo
  que el ruido de sensor real); JPEG con compresión agresiva (calidad 60)
  decodifica sin problema — es un modelo de degradación más representativo
  de una foto real.
- Modo Structured Append / FNC1 / Hanzi: no soportados (igual que el
  encoder), se reporta error explícito en vez de decodificar mal.

---

## API — unidades

### Generador

| Unidad | Responsabilidad |
|---|---|
| `QRTypes.pas` | `TQRErrorLevel`, `TQRMode`, `TQRBitBuffer`, `TQRModuleGrid`, tablas ECC, `QRGetNumRawDataModules`, `QRGetAlignmentPatternPositions`, `QRMaskFunction` |
| `QRBCH.pas` | Codificación/decodificación BCH de format info (15 bits) y version info (18 bits) |
| `QRReedSolomon.pas` | Aritmética GF(256) y generación/cálculo de codewords Reed-Solomon (codificación) |
| `QRSegment.pas` | `TQRSegment` + builders numeric/alphanumeric/byte/kanji/eci + selección automática de modo |
| `QREncoder.pas` | `TQRCode` — construcción completa del símbolo (patrones de función, ECC, máscaras, penalización) |
| `QRImageBMP.pas` | `QRRenderBMP` / `QRSaveBMP` |
| `QRImageSVG.pas` | `QRRenderSVG` / `QRSaveSVG` |
| `QRImagePNG.pas` | `QRRenderPNG` / `QRSavePNG` (con CRC-32, Adler-32 y DEFLATE "stored" propios) |

### Lector

| Unidad | Responsabilidad |
|---|---|
| `QRReedSolomonDecoder.pas` | GF(256) por tablas exp/log, corrección de errores (Euclides + Chien + Forney) |
| `QRBitStreamDecoder.pas` | Inverso de `QRSegment`: bytes corregidos → texto (numeric/alphanumeric/byte/kanji/eci) |
| `QRMatrixDecoder.pas` | Decodifica una `TQRModuleGrid` ya alineada: format/version info, desenmascarado, desentrelazado, RS, bitstream |
| `QRGrayImage.pas` | `TQRGrayImage` — imagen en escala de grises, desacoplada de cualquier formato de archivo |
| `QRBinarizer.pas` | Binarización adaptativa por bloques (`QRHybridBinarize`) + fallback por histograma global |
| `QRFinderPatternFinder.pas` | Localiza los 3 patrones buscadores (proporción 1:1:3:1:1 + verificación cruzada) |
| `QRAlignmentPatternFinder.pas` | Localiza el patrón de alineación (proporción 1:1:1) |
| `QRPerspectiveTransform.pas` | Homografía cuadrilátero↔cuadrilátero + muestreo de grilla |
| `QRReader.pas` | `QRReadImage` — orquesta todo el pipeline de vision → `QRMatrixDecoder` |
| `QRImageLoader.pas` | Carga BMP/PNG/JPEG a `TQRGrayImage` (única unidad que usa Vcl.Graphics) |

---

## Test coverage

| Suite | Tests |
|---|:---:|
| QRGeneratorTests (encoder: bit buffer, Reed-Solomon, tablas de capacidad, posiciones de alineación, segmentos, estructura del símbolo, renderizado) | 237 ✅ |
| QRReaderTests (lector: GF(256)/RS decode, bitstream, matrix decode, imágenes externas, round-trip por archivo, rotación/ruido/JPEG) | 87 ✅ |

```bash
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat"
msbuild barcode\qr-generator\tests\src\QRGeneratorTests.dproj /p:Config=Debug /p:Platform=Win64
msbuild barcode\qr-generator\tests\src\QRReaderTests.dproj /p:Config=Debug /p:Platform=Win64
Win64\Debug\QRGeneratorTests.exe
Win64\Debug\QRReaderTests.exe
```

La mayoría de los vectores de bajo nivel del **encoder** (bit buffer,
Reed-Solomon, tablas `ECC_CODEWORDS_PER_BLOCK`/`NUM_ERROR_CORRECTION_BLOCKS`,
posiciones de alineación, segmentos numeric/alphanumeric/eci) están tomados
literalmente de `qrcodegen-test.c`, el test suite oficial de la librería de
referencia (ver atribución abajo), en vez de confiar en la memoria del
algoritmo. Además, el encoder fue verificado de punta a punta con un
decodificador QR independiente (`pyzbar`/ZBar).

El **lector** se verificó, en orden creciente de independencia:
1. Round-trip con el propio encoder de esta librería (matriz → grilla → texto).
2. Round-trip por archivo (encoder → PNG/BMP en disco → `QRImageLoader` → lector).
3. Imágenes generadas por una librería **completamente independiente**
   (`qrcode`, Python) — descarta bugs simétricos entre nuestro encoder y
   nuestro lector.
4. Las mismas imágenes con rotación de 90°/180°/270°, rotación arbitraria
   (12°), ruido sal-y-pimienta y compresión JPEG real (calidad 60, vía PIL).

---

## Referencias

- [ISO/IEC 18004:2015](https://www.iso.org/standard/62021.html) — QR Code bar code symbology specification
- [QR Code generator library](https://github.com/nayuki/QR-Code-generator) (Project Nayuki) — implementación de referencia del encoder
- [ZXing ("Zebra Crossing")](https://github.com/zxing/zxing) — implementación de referencia del lector (binarización, detección, RS decode)
- [thonky.com/qr-code-tutorial](https://www.thonky.com/qr-code-tutorial/) — tutorial detallado del formato

---

## Atribución

### Encoder — Project Nayuki (MIT)

El algoritmo de `QRTypes.pas`, `QRReedSolomon.pas`, `QRSegment.pas` y
`QREncoder.pas` está traducido de **"QR Code generator library"** de
Project Nayuki (https://www.nayuki.io/page/qr-code-generator-library),
publicada bajo licencia MIT. Los vectores de prueba de
`QRGeneratorTests.dpr` provienen del mismo proyecto (`qrcodegen-test.c`).
Los módulos de renderizado (`QRImageBMP.pas`, `QRImageSVG.pas`,
`QRImagePNG.pas`) son implementación propia, sin relación con dicho proyecto.

Aviso de licencia MIT original (se incluye por requerirlo los términos de
la licencia):

```
Copyright (c) Project Nayuki.
https://www.nayuki.io/page/qr-code-generator-library

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:
- The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.
- The Software is provided "as is", without warranty of any kind, express or
  implied, including but not limited to the warranties of merchantability,
  fitness for a particular purpose and noninfringement. In no event shall the
  authors or copyright holders be liable for any claim, damages or other
  liability, whether in an action of contract, tort or otherwise, arising from,
  out of or in connection with the Software or the use or other dealings in the
  Software.
```

### Lector — ZXing "Zebra Crossing" (Apache License 2.0)

El algoritmo de `QRReedSolomonDecoder.pas`, `QRBitStreamDecoder.pas`,
`QRMatrixDecoder.pas`, `QRBinarizer.pas`, `QRFinderPatternFinder.pas`,
`QRAlignmentPatternFinder.pas`, `QRPerspectiveTransform.pas` y la
orquestación de `QRReader.pas` está traducido de **ZXing ("Zebra
Crossing")** (https://github.com/zxing/zxing), publicada bajo Apache
License 2.0. `QRGrayImage.pas` e `QRImageLoader.pas` son implementación
propia, sin relación con dicho proyecto.

Aviso de licencia Apache 2.0 (resumen; el texto completo está en
https://www.apache.org/licenses/LICENSE-2.0):

```
Copyright 2007-2024 ZXing authors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

Cambios respecto al código original: traducción de Java a Object Pascal;
adaptación de las estructuras de datos (`BitMatrix`/`ResultPoint` de ZXing
se unificaron en `TQRModuleGrid`/`TQRPointF` de esta librería); simplificación
de algunas rutas de manejo de excepciones de Java a `Boolean`/valores de
retorno idiomáticos de Pascal. La lógica algorítmica (proporciones,
umbrales, fórmulas geométricas) se preservó sin cambios.
