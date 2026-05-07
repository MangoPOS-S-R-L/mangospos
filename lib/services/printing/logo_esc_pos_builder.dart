// lib/services/printing/logo_esc_pos_builder.dart
//
// Genera bytes ESC/POS para imprimir el logo del negocio centrado en el
// header del ticket. Pipeline:
//   bytes (PNG/JPG) → img.decodeImage → resize a maxWidth conservando
//   aspect ratio → Generator.image() centrado.
//
// Usa esc_pos_utils_plus con CapabilityProfile generico (mismo patron que
// QrEscPosBuilder). Devuelve null ante cualquier fallo para no tumbar el
// ticket — el caller imprime sin logo.

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart' as esc;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class LogoEscPosBuilder {
  LogoEscPosBuilder._();

  /// Genera bytes ESC/POS del logo centrado.
  ///
  /// [bytes] son los bytes raw del archivo (PNG o JPG; img.decodeImage
  /// detecta el formato). [maxWidth] limita el ancho del bitmap final
  /// para que entre en el papel: 384 default deja ~96 dots de margen
  /// total en termica 80mm (ancho util 576 dots a 203 dpi). Para logos
  /// con aspect ratio extremo (ej. logo muy alto), tambien limitamos
  /// la altura — sin esto un logo cuadrado de 800x800 ocuparia 6cm de
  /// papel solo en el header.
  static Future<List<int>?> build({
    required Uint8List bytes,
    int maxWidth = 384,
    int maxHeight = 200,
    esc.PaperSize paperSize = esc.PaperSize.mm80,
  }) async {
    if (bytes.isEmpty) return null;

    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        debugPrint('LogoEscPosBuilder: decodeImage returned null');
        return null;
      }

      // Resize manteniendo aspect ratio. Si el width o el height
      // exceden el max, escalamos al limite mas restrictivo.
      img.Image resized = decoded;
      final widthRatio = decoded.width / maxWidth;
      final heightRatio = decoded.height / maxHeight;
      final scaleRatio = widthRatio > heightRatio ? widthRatio : heightRatio;
      if (scaleRatio > 1.0) {
        final newWidth = (decoded.width / scaleRatio).round();
        final newHeight = (decoded.height / scaleRatio).round();
        resized = img.copyResize(
          decoded,
          width: newWidth,
          height: newHeight,
          // average mejor que nearest para fotos/logos con gradientes
          interpolation: img.Interpolation.average,
        );
      }

      final profile = await esc.CapabilityProfile.load();
      final generator = esc.Generator(paperSize, profile);

      final out = <int>[];
      out.addAll(generator.image(resized, align: esc.PosAlign.center));
      // Reset alineacion para que el resto del ticket no quede centrado.
      out.addAll(generator.setStyles(esc.PosStyles(align: esc.PosAlign.left)));
      return out;
    } catch (e, st) {
      debugPrint('LogoEscPosBuilder.build failed: $e\n$st');
      return null;
    }
  }
}
