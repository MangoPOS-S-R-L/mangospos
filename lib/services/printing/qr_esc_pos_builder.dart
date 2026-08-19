import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:qr_flutter/qr_flutter.dart';

import 'raster_image_esc_pos.dart';

/// 🔲 QrEscPosBuilder
///
/// Genera bytes ESC/POS para imprimir un QR centrado en una térmica 80mm.
///
/// Implementación: render del QR a `ui.Image` → PNG → `img.Image` →
/// bytes `GS v 0` propios (ver `raster_image_esc_pos.dart`). Se eligió
/// raster (no QR nativo `GS ( k`) porque garantiza píxel-perfect en
/// cualquier impresora ESC/POS, sin depender de comandos del firmware.
///
/// Centrado: `RasterImageEscPos` emite `ESC a 1` antes del bitmap y un
/// `ESC a 0` al final para no dejar la alineación cambiada al resto del
/// ticket.
class QrEscPosBuilder {
  QrEscPosBuilder._();

  /// Genera bytes ESC/POS para imprimir el QR centrado.
  ///
  /// [data] se codifica en el QR (típicamente `fiscal_documents.public_url`).
  ///
  /// [maxSizePx] es un TECHO, no el tamaño final. El tamaño real se redondea
  /// hacia abajo hasta el múltiplo entero de módulos que quepa (ver
  /// [_renderQrToImage]).
  ///
  /// Devuelve `null` si [data] está vacío o si el render falla. El caller
  /// debe tratar `null` como "no imprimir QR" sin fallar el ticket completo.
  static Future<List<int>?> build({
    required String data,
    int maxSizePx = 264,
  }) async {
    if (data.isEmpty) return null;

    try {
      final imgImage = await _renderQrToImage(data: data, maxSizePx: maxSizePx);
      if (imgImage == null) return null;

      // Emision directa de `ESC a 1` + `GS v 0` + `ESC a 0`, sin
      // esc_pos_utils_plus en el medio: su `Generator.image()` anteponia
      // comandos que nuestro parser no conocia y que acababan IMPRESOS
      // como basura junto al QR (ver raster_image_esc_pos.dart).
      return RasterImageEscPos.encode(imgImage, align: 1);
    } catch (e, st) {
      // Cualquier fallo (canvas, codec, profile, generator) NO debe tumbar
      // el ticket. Logueamos vía debugPrint y devolvemos null.
      debugPrint('QrEscPosBuilder.build failed: $e\n$st');
      return null;
    }
  }

  /// Renderiza el QR a un `img.Image` listo para `Generator.image()`.
  ///
  /// POR QUÉ NO UN TAMAÑO FIJO
  ///
  /// Antes esto rendereaba a 264 px pasara lo que pasara. El problema es que
  /// el QR no tiene un tamaño propio: tiene MÓDULOS, y cuántos hay depende de
  /// cuánto texto lleve. La URL de consulta de la DGII produce 49x49 módulos,
  /// y 264 / 49 = 5.39 puntos por módulo. Como un punto de la térmica no se
  /// puede partir, el redimensionado dejaba unos módulos de 5 puntos y otros
  /// de 6: los cuadros salían desiguales, los bordes bailaban y el lector
  /// tardaba o fallaba. No era la impresora — era la aritmética.
  ///
  /// Ahora el módulo mide un número ENTERO de puntos y el tamaño final sale
  /// de ahí. Para 49 módulos y techo 264: escala 4, quiet zone de 4 módulos
  /// a cada lado, total (49 + 8) x 4 = 228 px. Más pequeño que antes Y
  /// nítido.
  ///
  /// LA QUIET ZONE no es decoración: el estándar QR exige 4 módulos de blanco
  /// alrededor para que el lector encuentre el código. `QrPainter` no la
  /// dibuja, así que el QR salía pegado al texto de al lado.
  static Future<img.Image?> _renderQrToImage({
    required String data,
    required int maxSizePx,
  }) async {
    final qrCode = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );

    final modules = qrCode.moduleCount;
    const quietZone = 4; // módulos, por estándar
    final total = modules + quietZone * 2;

    // Escala entera más grande que quepa bajo el techo. Nunca menos de 2: por
    // debajo de eso el módulo es tan chico que ningún teléfono lo lee, y es
    // preferible un QR que sobresalga del techo a uno ilegible.
    var scale = maxSizePx ~/ total;
    if (scale < 2) scale = 2;

    final painter = QrPainter.withQr(
      qr: qrCode,
      gapless: true,
      eyeStyle: const QrEyeStyle(
        eyeShape: QrEyeShape.square,
        color: Color(0xFF000000),
      ),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: Color(0xFF000000),
      ),
    );

    // Se pinta a 1 punto por módulo y se amplía con vecino más cercano. Así
    // el escalado es exacto por construcción: no hay interpolación que pueda
    // dejar un módulo a medio tono.
    final ui.Image rendered = await painter.toImage(modules.toDouble());
    final byteData = await rendered.toByteData(format: ui.ImageByteFormat.png);
    rendered.dispose();
    if (byteData == null) return null;

    final Uint8List pngBytes = byteData.buffer.asUint8List();
    final core = img.decodePng(pngBytes);
    if (core == null) return null;

    final scaled = img.copyResize(
      core,
      width: modules * scale,
      height: modules * scale,
      interpolation: img.Interpolation.nearest,
    );

    // Lienzo blanco del tamaño total y el QR pegado dentro, dejando la quiet
    // zone alrededor.
    final canvas = img.Image(width: total * scale, height: total * scale);
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(
      canvas,
      scaled,
      dstX: quietZone * scale,
      dstY: quietZone * scale,
    );
    return canvas;
  }
}
