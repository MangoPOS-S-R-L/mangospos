// Destinos de impresión para el selector visible al usuario.
//
// Un "destino" puede ser:
//   - Una impresora física (LAN, USB, BT) configurada en el negocio.
//   - Un destino especial (solo pantalla, WhatsApp en el futuro).
//
// Esta capa abstrae al UI de la implementación concreta — el bottom sheet
// muestra una lista de PrintDestination sin saber si son impresoras o no.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/models/printing_v2.dart';

/// Tipo de destino. Determina cómo el orchestrator procesa la elección.
enum PrintDestinationKind {
  /// Impresora física configurada en `printers` table.
  printer,

  /// Solo mostrar la pre-cuenta en pantalla (modal). No imprime nada.
  screenOnly,

  // Reservados para futuras fases:
  // whatsapp, email, pdfDownload, etc.
}

/// Un destino disponible para imprimir. Lo expone el resolver al UI.
class PrintDestination {
  final PrintDestinationKind kind;

  /// Si kind == printer, la config de la impresora. NULL para destinos
  /// especiales (screen-only, etc.).
  final PrinterConfig? printer;

  /// Estado de salud actual de la impresora. NULL si nunca se reportó o
  /// si el destino no es una impresora física.
  final PrinterHealthRecord? health;

  /// Label visible en el selector (sobreescribe el name de la impresora
  /// si es destino especial).
  final String displayName;

  /// Subtítulo opcional para mostrar info de transport / IP / etc.
  final String? subtitle;

  const PrintDestination({
    required this.kind,
    this.printer,
    this.health,
    required this.displayName,
    this.subtitle,
  });

  /// Crea un destino a partir de una impresora física. El subtítulo se
  /// genera automáticamente desde transport + IP/MAC/path.
  factory PrintDestination.fromPrinter(
    PrinterConfig printer, {
    PrinterHealthRecord? health,
  }) {
    return PrintDestination(
      kind: PrintDestinationKind.printer,
      printer: printer,
      health: health,
      displayName: printer.name,
      subtitle: _buildPrinterSubtitle(printer),
    );
  }

  /// Destino "Solo pantalla" — no requiere impresora, muestra el modal
  /// de pre-cuenta directamente al cliente.
  factory PrintDestination.screenOnly() {
    return const PrintDestination(
      kind: PrintDestinationKind.screenOnly,
      displayName: 'Mostrar en pantalla',
      subtitle: 'Sin imprimir — el cliente lee directo',
    );
  }

  /// Identifier estable para persistir la última elección. Para
  /// impresoras es el printer.id; para destinos especiales es un código
  /// fijo prefijado por `__`.
  String get persistKey {
    if (kind == PrintDestinationKind.printer && printer != null) {
      return printer!.id;
    }
    return '__${kind.name}';
  }

  static String _buildPrinterSubtitle(PrinterConfig p) {
    final transport = p.transport.wireName.toUpperCase();
    final ip = p.effectiveIp;
    if (ip != null && ip.isNotEmpty) {
      return '$transport · $ip';
    }
    final mac = p.effectiveMac;
    if (mac != null && mac.isNotEmpty) {
      return '$transport · $mac';
    }
    if (p.devicePath != null && p.devicePath!.isNotEmpty) {
      return '$transport · ${p.devicePath}';
    }
    return transport;
  }
}

/// Resuelve los destinos disponibles para un purpose en un business.
///
/// Combina:
///   - Impresoras del business con `prints_prebills = true` (legacy) o
///     `purpose = 'precheck'` (v2).
///   - Estado de salud de cada una (left join, NULL si nunca probó).
///   - Destinos especiales (solo pantalla) según parámetros.
///
/// NO toma decisiones de UX (qué pre-seleccionar, ordering visual, etc.)
/// — eso lo hace el picker. Aquí solo es lookup de datos.
class PrintDestinationResolver {
  final SupabaseClient _client;

  PrintDestinationResolver(this._client);

  /// Destinos para pre-cuenta (precheck). Default incluye el destino
  /// especial "Solo pantalla".
  Future<List<PrintDestination>> resolveForPrecheck({
    required String businessId,
    bool includeScreenOnly = true,
  }) async {
    final printers = await _fetchPrechecPrinters(businessId);
    final healthByPrinterId = await _fetchHealthMap(
      printers.map((p) => p.id).toList(growable: false),
    );

    final destinations = printers
        .map((p) => PrintDestination.fromPrinter(
              p,
              health: healthByPrinterId[p.id],
            ))
        .toList(growable: false);

    if (includeScreenOnly) {
      return [...destinations, PrintDestination.screenOnly()];
    }
    return destinations;
  }

  /// Trae todas las impresoras activas del business que estén asignadas
  /// a algún área con `prints_prebills = true`. Usa la tabla legacy
  /// `print_area_printers` — es la fuente de verdad hasta que la UI
  /// migre por completo a `purpose`.
  Future<List<PrinterConfig>> _fetchPrechecPrinters(String businessId) async {
    // Consulta: print_area_printers JOIN printers donde:
    //   - business_id = X
    //   - enabled = true
    //   - prints_prebills = true
    //   - printers.is_active = true
    // distinct por printer_id (la misma impresora puede estar asignada
    // a varias áreas con prints_prebills=true; solo nos interesa una
    // entrada).
    final rows = await _client
        .from('print_area_printers')
        .select('printer_id, printers!inner(*)')
        .eq('business_id', businessId)
        .eq('enabled', true)
        .eq('prints_prebills', true);

    final seen = <String>{};
    final result = <PrinterConfig>[];
    for (final row in (rows as List<dynamic>)) {
      final printerMap = (row as Map)['printers'] as Map?;
      if (printerMap == null) continue;
      final config = PrinterConfig.fromMap(
          Map<String, dynamic>.from(printerMap));
      if (!config.isActive) continue;
      if (!seen.add(config.id)) continue;
      result.add(config);
    }
    return result;
  }

  Future<Map<String, PrinterHealthRecord>> _fetchHealthMap(
    List<String> printerIds,
  ) async {
    if (printerIds.isEmpty) return const {};

    // Supabase Dart no soporta `in` con lista vacía sin trabar — ya
    // chequeamos arriba.
    final rows = await _client
        .from('printer_health')
        .select()
        .inFilter('printer_id', printerIds);

    final map = <String, PrinterHealthRecord>{};
    for (final row in (rows as List<dynamic>)) {
      final record = PrinterHealthRecord.fromMap(
          Map<String, dynamic>.from(row as Map));
      map[record.printerId] = record;
    }
    return map;
  }
}

/// Provider riverpod del resolver (single-instance, stateless).
final printDestinationResolverProvider =
    Provider<PrintDestinationResolver>((ref) {
  return PrintDestinationResolver(Supabase.instance.client);
});
