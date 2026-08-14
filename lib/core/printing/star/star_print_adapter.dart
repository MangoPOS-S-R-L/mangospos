// Punto único de conversión ESC/POS → raster Star.
//
// Lo llama el repositorio de impresión justo antes de mandar bytes al
// dispositivo: si la impresora destino es de la familia TSP100 (ver
// `printer_emulation.dart`), el ticket que ya armamos en ESC/POS se
// reinterpreta y sale como bitmap. Para cualquier otra impresora devuelve
// los mismos bytes sin tocar nada.
//
// Fail-soft a propósito: si algo falla al rasterizar (fuente ausente,
// bytes raros), devolvemos el ESC/POS original. Peor caso, la Star no
// imprime — que es exactamente lo que pasaba antes de esto; nunca dejamos
// caer un ticket de una impresora que sí funcionaba.

import 'package:flutter/foundation.dart';

import '../../../data/models/printing.dart';
import 'esc_pos_raster_encoder.dart';
import 'escpos_parser.dart';
import 'printer_emulation.dart';
import 'star_raster_encoder.dart';
import 'ticket_rasterizer.dart';

class StarPrintAdapter {
  /// Devuelve los bytes que hay que escribir en [printer] para imprimir
  /// [escPosData].
  static Future<List<int>> adapt({
    required PrinterConfig printer,
    required List<int> escPosData,
  }) async {
    if (escPosData.isEmpty) return escPosData;

    final isStar = resolvePrinterEmulation(printer).isStarRaster;
    // "Modo calidad" opt-in para ESC/POS: mismo pipeline, otro encoder y
    // dibujado con tipografía real (ver `printerWantsEscPosRaster`).
    final wantsEscPosRaster = !isStar && printerWantsEscPosRaster(printer);
    if (!isStar && !wantsEscPosRaster) return escPosData;

    // Ya viene rasterizado (p.ej. un job que rebota por la cola).
    if (StarRasterEncoder.looksLikeStarRaster(escPosData)) return escPosData;
    if (EscPosRasterEncoder.looksLikeEscPosRaster(escPosData)) {
      return escPosData;
    }

    final label = isStar ? 'Star' : 'Raster';
    try {
      final parsed = EscPosParser.parse(escPosData);
      if (parsed.ops.isEmpty) return escPosData;
      final dots = isStar
          ? StarRasterEncoder.dotsForPaperWidth(printer.paperWidth)
          : EscPosRasterEncoder.dotsForPaperWidth(printer.paperWidth);
      final bitmap = await TicketRasterizer.render(
        parsed,
        dots,
        // Solo el modo calidad usa tipografía proporcional. Las Star llevan
        // tiempo saliendo con celdas fijas y no se les cambia el acabado
        // sin que alguien lo pida.
        proportional: wantsEscPosRaster,
      );
      if (bitmap.height == 0) return escPosData;
      final bytes = isStar
          ? StarRasterEncoder.encode(bitmap, cut: parsed.cut)
          : EscPosRasterEncoder.encode(
              bitmap,
              cut: parsed.cut,
              openCashDrawer: parsed.openCashDrawer,
            );
      debugPrint(
        '[$label] ${printer.name}: ESC/POS ${escPosData.length}B → raster '
        '${bytes.length}B (${dots}x${bitmap.height} puntos)',
      );
      return bytes;
    } catch (e, st) {
      debugPrint(
        '[$label] no se pudo rasterizar para ${printer.name}: $e\n$st',
      );
      return escPosData;
    }
  }
}
