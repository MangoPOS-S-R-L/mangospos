import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart' as esc;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:qr_flutter/qr_flutter.dart';

/// 🔲 QrEscPosBuilder
///
/// Genera bytes ESC/POS para imprimir un QR centrado en una térmica 80mm.
///
/// Implementación: render del QR a `ui.Image` → PNG → `img.Image` →
/// rasterizado ESC/POS via `esc_pos_utils_plus`. Se eligió raster (no QR
/// nativo `GS ( k`) porque garantiza píxel-perfect en cualquier impresora
/// ESC/POS, sin depender de comandos QR específicos del firmware.
///
/// Centrado: usa `esc.PosAlign.center` que emite `ESC a 1` antes del bitmap.
/// La utility devuelve también un `ESC a 0` (left) al final para no dejar
/// la alineación cambiada para el resto del ticket.
class QrEscPosBuilder {
  QrEscPosBuilder._();

  /// Genera bytes ESC/POS para imprimir el QR centrado.
  ///
  /// [data] se codifica en el QR (típicamente `fiscal_documents.public_url`).
  /// [sizePx] tamaño del QR en píxeles del bitmap final. Default 264 (~4×4cm
  /// en térmica 203dpi 80mm). El ancho útil de papel 80mm es 576 dots, así
  /// que 264 deja ~156 dots de margen a cada lado — visualmente centrado
  /// con margen amplio.
  ///
  /// Devuelve `null` si [data] está vacío o si el render falla. El caller
  /// debe tratar `null` como "no imprimir QR" sin fallar el ticket completo.
  static Future<List<int>?> build({
    required String data,
    int sizePx = 264,
    esc.PaperSize paperSize = esc.PaperSize.mm80,
  }) async {
    if (data.isEmpty) return null;

    try {
      final imgImage = await _renderQrToImage(data: data, sizePx: sizePx);
      if (imgImage == null) return null;

      // Profile genérico funciona en la mayoría de impresoras ESC/POS estándar.
      final profile = await esc.CapabilityProfile.load();
      final generator = esc.Generator(paperSize, profile);

      final bytes = <int>[];
      // align: center => ESC a 1. Reset a left después para no contaminar
      // el resto del ticket.
      bytes.addAll(generator.image(imgImage, align: esc.PosAlign.center));
      bytes.addAll(generator.setStyles(esc.PosStyles(align: esc.PosAlign.left)));
      return bytes;
    } catch (e, st) {
      // Cualquier fallo (canvas, codec, profile, generator) NO debe tumbar
      // el ticket. Logueamos vía debugPrint y devolvemos null.
      debugPrint('QrEscPosBuilder.build failed: $e\n$st');
      return null;
    }
  }

  /// Renderiza el QR a un `img.Image` (formato del package `image`) listo
  /// para `Generator.image()` de esc_pos_utils_plus.
  ///
  /// Pipeline: QrPainter → ui.Image → PNG bytes → img.decodePng → resize
  /// si necesario para que sea exactamente [sizePx] de ancho.
  static Future<img.Image?> _renderQrToImage({
    required String data,
    required int sizePx,
  }) async {
    final qrCode = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
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

    final ui.Image rendered = await painter.toImage(sizePx.toDouble());
    final byteData =
        await rendered.toByteData(format: ui.ImageByteFormat.png);
    rendered.dispose();
    if (byteData == null) return null;

    final Uint8List pngBytes = byteData.buffer.asUint8List();
    final decoded = img.decodePng(pngBytes);
    if (decoded == null) return null;

    // Asegurar exactamente [sizePx] de ancho. Si el bitmap salió con un
    // tamaño ligeramente distinto (por antialiasing del canvas), normalizamos.
    if (decoded.width == sizePx) return decoded;
    return img.copyResize(
      decoded,
      width: sizePx,
      height: sizePx,
      interpolation: img.Interpolation.nearest, // QR debe ser cuadrado nítido
    );
  }
}
