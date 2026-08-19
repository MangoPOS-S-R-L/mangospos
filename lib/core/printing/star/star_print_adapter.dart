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
  /// [preferRaster] lo pide el TICKET (ver `PrintTicket.preferRaster`), no la
  /// impresora: hay formatos que solo existen como imagen. Se suma al ajuste
  /// por impresora, no lo reemplaza.
  static Future<List<int>> adapt({
    required PrinterConfig printer,
    required List<int> escPosData,
    bool preferRaster = false,
  }) async {
    if (escPosData.isEmpty) return escPosData;

    final isStar = resolvePrinterEmulation(printer).isStarRaster;
    // "Modo calidad" opt-in para ESC/POS: mismo pipeline, otro encoder y
    // dibujado con tipografía real (ver `printerWantsEscPosRaster`).
    final wantsEscPosRaster =
        !isStar && (preferRaster || printerWantsEscPosRaster(printer));
    if (!isStar && !wantsEscPosRaster) return escPosData;
    // Qué ACABADO se dibuja, que es una decisión aparte de qué encoder se usa
    // (ver `wantsProportionalRaster`): una Star también sale con tipografía
    // real cuando el ticket la pide.
    final proportional = wantsProportionalRaster(
      printer,
      ticketPrefersRaster: preferRaster,
    );

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
        // Las comandas y los cierres se quedan en la rejilla de celdas fijas
        // aunque salgan por una Star: sus tablas cuadran por ancho de columna
        // y una proporcional las descuadra. El acabado tipográfico es para el
        // documento que ve el cliente.
        proportional: proportional,
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
