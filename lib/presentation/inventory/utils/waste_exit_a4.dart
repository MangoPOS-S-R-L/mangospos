// Conduce de salida en A4 a partir de movimientos `waste` ya registrados.
//
// Lo usan el detalle de un insumo en Salidas / Mermas (todas sus salidas o
// una sola) y la lista de "Últimos movimientos". El motivo se lee del prefijo
// de la nota ("Vencido — …"), que la salida guarda siempre, esté o no
// desplegada la columna `reason_code`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/currency/business_currency_provider.dart';
import '../../../core/utils/app_snackbar.dart';
import '../../../services/printing/waste_exit_pdf.dart';
import '../../../services/session/session_controller.dart';
import '../state/adjust_reasons.dart';
import '../state/inventory_state.dart';

class WasteExitA4 {
  const WasteExitA4._();

  /// Separa "Motivo — nota". Si la nota no empieza por un motivo del
  /// catálogo (salidas viejas, texto libre), el motivo es "Merma" y la nota
  /// queda entera.
  static ({String reason, String notes}) splitNotes(String raw) {
    final notes = raw.trim();
    final exitLabels = {
      for (final r in kAdjustReasons.where((r) => r.isExit)) r.label,
    };
    final dash = notes.indexOf(' — ');
    final head = dash >= 0 ? notes.substring(0, dash) : notes;
    if (!exitLabels.contains(head)) return (reason: 'Merma', notes: notes);
    return (
      reason: head,
      notes: dash >= 0 ? notes.substring(dash + 3).trim() : '',
    );
  }

  /// Abre el diálogo de impresión del sistema (en A4) con [movements].
  /// Nunca lanza: si algo falla, lo dice con un snackbar.
  static Future<void> print(
    BuildContext context,
    WidgetRef ref, {
    required List<InventoryMovementEntry> movements,
    required Map<String, InventoryItemSummary> itemsById,
    required String warehouseName,
  }) async {
    final lines = [
      for (final m in movements)
        () {
          final item = itemsById[m.itemId];
          final parts = splitNotes(m.notes);
          return WasteExitPdfLine(
            date: m.createdAt,
            itemName: m.itemName,
            quantity: m.quantity.abs(),
            unit: item?.unit ?? '',
            reason: parts.reason,
            notes: parts.notes,
            costPerUnit: item?.cost ?? 0,
          );
        }(),
    ];

    final negocio = (ref.read(sessionProvider).activeBusinessName ?? '').trim();
    try {
      await WasteExitPdf.printDocument(
        lines: lines,
        businessName: negocio.isEmpty ? 'MangoPOS' : negocio,
        warehouseName: warehouseName,
        // Sin nombre a propósito: quien imprime no es necesariamente quien
        // sacó la mercancía. Las dos firmas se llenan a mano.
        currency: currentBusinessCurrencyOrFallback(ref),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showAppSnackBar(
        SnackBar(content: Text('No se pudo imprimir: $e')),
      );
    }
  }
}
