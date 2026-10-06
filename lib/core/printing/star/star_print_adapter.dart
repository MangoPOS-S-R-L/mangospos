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
import 'cut_feed.dart';
import 'esc_pos_raster_encoder.dart';
import 'escpos_parser.dart';
import 'print_speed.dart';
import 'print_width.dart';
import 'printer_emulation.dart';
import 'raster_ink.dart';
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
    final adapted = await _adaptFormat(
      printer: printer,
      escPosData: escPosData,
      preferRaster: preferRaster,
    );
    // Velocidad elegida para ESTA impresora (ver `print_speed.dart`). Va al
    // final porque el comando depende del formato que realmente sale: ESC/POS
    // tras el `ESC @`, o `ESC * r Q` dentro del raster Star.
    final timed = applyPrintSpeed(adapted, resolvePrintSpeed(printer));
    // Avance extra antes del corte para la impresora cuya cuchilla queda más
    // lejos del cabezal (ver `cut_feed.dart`). Va aquí, en el punto por el
    // que pasa TODO lo que se imprime, para que cubra factura, precuenta,
    // comanda y cierre por igual, salgan en texto o en raster.
    return applyCutFeed(timed, resolveCutFeedLines(printer));
  }

  static Future<List<int>> _adaptFormat({
    required PrinterConfig printer,
    required List<int> escPosData,
    required bool preferRaster,
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
        // Cuánto trazo pone el binarizado. Va por impresora porque el
        // resultado depende del CABEZAL: la misma imagen sale negra en una
        // térmica y gris en otra (ver `raster_ink.dart`).
        ink: resolveRasterInk(printer),
        // Columnas elegidas para ESTA impresora: una Epson TM-T88 (180 dpi)
        // imprime 512 puntos en 80mm y tira lo que pase de ahí — se cortaban
        // los montos de la derecha (ver `print_width.dart`).
        printDots: resolvePrintDots(printer),
      );
      if (bitmap.height == 0) return escPosData;
      // Un ticket más angosto que el papel sale centrado. La Star no tiene
      // alineación en raster: se rellena a los lados hasta su cabezal.
      final narrower = bitmap.width < dots;
      final bytes = isStar
          ? StarRasterEncoder.encode(
              narrower ? bitmap.centeredOn(dots) : bitmap,
              cut: parsed.cut,
            )
          : EscPosRasterEncoder.encode(
              bitmap,
              cut: parsed.cut,
              openCashDrawer: parsed.openCashDrawer,
              center: narrower,
            );
      debugPrint(
        '[$label] ${printer.name}: ESC/POS ${escPosData.length}B → raster '
        '${bytes.length}B (${bitmap.width}x${bitmap.height} puntos)',
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
