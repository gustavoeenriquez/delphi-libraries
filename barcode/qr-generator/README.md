# barcode/qr-generator — Generador de códigos QR en Delphi puro

Generador completo de códigos QR (ISO/IEC 18004, Model 2) sin dependencias
externas: ni GDI+, ni Vcl.Graphics, ni DLLs de terceros. Cubre las 40
versiones, los 4 niveles de corrección de errores y los 4 modos de
codificación, con selección automática de versión, nivel ECC y máscara.

**License: [CC0 1.0 Universal (Public Domain)](../../LICENSE.md)** — ver
también la nota de atribución MIT al final de este documento.

---

## Status: Active

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
| Decodificación | ❌ (fuera de alcance — solo generador) |

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

### Demo de línea de comandos

```
samples/QRDemo.exe "https://example.com" salida.png M 8 4
```

---

## API — unidades

| Unidad | Responsabilidad |
|---|---|
| `QRTypes.pas` | `TQRErrorLevel`, `TQRMode`, `TQRBitBuffer`, tablas ECC, `QRGetNumRawDataModules`, `QRGetAlignmentPatternPositions` |
| `QRReedSolomon.pas` | Aritmética GF(256) y generación/cálculo de codewords Reed-Solomon |
| `QRSegment.pas` | `TQRSegment` + builders numeric/alphanumeric/byte/kanji/eci + selección automática de modo |
| `QREncoder.pas` | `TQRCode` — construcción completa del símbolo (patrones de función, ECC, máscaras, penalización) |
| `QRImageBMP.pas` | `QRRenderBMP` / `QRSaveBMP` |
| `QRImageSVG.pas` | `QRRenderSVG` / `QRSaveSVG` |
| `QRImagePNG.pas` | `QRRenderPNG` / `QRSavePNG` (con CRC-32, Adler-32 y DEFLATE "stored" propios) |

---

## Test coverage

| Suite | Tests |
|---|:---:|
| QRGeneratorTests (bit buffer, Reed-Solomon, tablas de capacidad, posiciones de alineación, segmentos, estructura del símbolo, renderizado) | 237 ✅ |

```bash
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat"
msbuild barcode\qr-generator\tests\src\QRGeneratorTests.dproj /p:Config=Debug /p:Platform=Win64
Win64\Debug\QRGeneratorTests.exe
```

La mayoría de los vectores de bajo nivel (bit buffer, Reed-Solomon, tablas
`ECC_CODEWORDS_PER_BLOCK`/`NUM_ERROR_CORRECTION_BLOCKS`, posiciones de
alineación, segmentos numeric/alphanumeric/eci) están tomados literalmente
de `qrcodegen-test.c`, el test suite oficial de la librería de referencia
(ver atribución abajo), en vez de confiar en la memoria del algoritmo.
Además, la imagen PNG generada para varios casos (URLs, texto con acentos,
distintos niveles ECC y versiones) fue verificada de extremo a extremo con
un decodificador QR independiente (`pyzbar`/ZBar), confirmando que el texto
decodificado coincide exactamente con el original.

---

## Referencias

- [ISO/IEC 18004:2015](https://www.iso.org/standard/62021.html) — QR Code bar code symbology specification
- [QR Code generator library](https://github.com/nayuki/QR-Code-generator) (Project Nayuki) — implementación de referencia
- [thonky.com/qr-code-tutorial](https://www.thonky.com/qr-code-tutorial/) — tutorial detallado del formato

---

## Atribución

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
