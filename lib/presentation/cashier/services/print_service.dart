import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:mangopos/data/models/printing.dart' show PrinterConfig;
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/presentation/cashier/state/cash_close_formatters.dart';
import 'package:mangopos/services/printing/esc_pos_generator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CashClosePrintService {
  final SupabaseClient _client;
  final PrintingRepository _printingRepository;

  CashClosePrintService(SupabaseClient client)
    : _client = client,
      _printingRepository = PrintingRepository(client);

  Future<void> printCloseTicket({
    required CashCloseInput input,
    required CashCloseResult result,
    required List<DenominationCount> denominations,
    required DateTime printedAt,
    String? cashRegisterId,
    int recountCount = 0,
    String? sessionId,
  }) async {
    // Desglose por área de producción: solo si el negocio activó el toggle
    // y tenemos la sesión para acotar el periodo. Best-effort — si falla,
    // el cierre se imprime igual sin esta sección.
    final salesByArea = sessionId != null && sessionId.isNotEmpty
        ? await _loadSalesByAreaIfEnabled(sessionId)
        : const <Map<String, dynamic>>[];

    // Desglose por producto dentro de cada área (toggle aparte). Mismo
    // best-effort: si falla o está off, no aparece la sección.
    final productsByArea = sessionId != null && sessionId.isNotEmpty
        ? await _loadProductsByAreaIfEnabled(sessionId)
        : const <Map<String, dynamic>>[];

    final bytes = _buildEscPos(
      input: input,
      result: result,
      denominations: denominations,
      printedAt: printedAt,
      recountCount: recountCount,
      salesByArea: salesByArea,
      productsByArea: productsByArea,
    );

    await _printThermalOrThrow(bytes, cashRegisterId: cashRegisterId);
  }

  /// Lee el toggle `cash_close_print_sales_by_area`; si está activo, trae el
  /// desglose de ventas por área de producción para la ventana de la sesión
  /// [sessionId] (opened_at → closed_at/ahora) vía la RPC get_sales_summary_v2
  /// (mismo campo `sales_by_production_area` del reporte de Ventas). Devuelve
  /// `[]` si el toggle está off o ante cualquier error (no rompe el cierre).
  Future<List<Map<String, dynamic>>> _loadSalesByAreaIfEnabled(
    String sessionId,
  ) async {
    try {
      final businessId = await resolveBusinessIdOrNull(_client, 'auto');
      if (businessId == null) return const [];
      final enabled = await PosSettingsRepository(_client)
          .getCashClosePrintSalesByArea(businessId);
      if (!enabled) return const [];

      final session = await _client
          .from('cash_register_sessions')
          .select('opened_at, closed_at')
          .eq('id', sessionId)
          .maybeSingle();
      final openedAt = session?['opened_at']?.toString();
      if (openedAt == null || openedAt.isEmpty) return const [];
      final closedAt = (session?['closed_at']?.toString().isNotEmpty == true)
          ? session!['closed_at'].toString()
          : DateTime.now().toUtc().toIso8601String();

      // Llamamos la RPC directo con los timestamps UTC de la sesión (no via
      // ReportsRepository, que asume DateTimes en hora local AST).
      final resp = await _client.rpc('get_sales_summary_v2', params: {
        '_business_id': businessId,
        '_from': openedAt,
        '_to': closedAt,
      });
      if (resp is! Map) return const [];
      final rows = resp['sales_by_production_area'];
      if (rows is! List) return const [];
      return rows
          .whereType<Object?>()
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
    } catch (e) {
      debugPrint('[CashClosePrint] desglose por área falló: $e');
      return const [];
    }
  }

  /// Lee el toggle `cash_close_print_products_by_area`; si está activo, trae el
  /// desglose por área → productos (cantidad en unidades) de la ventana de la
  /// sesión vía la RPC `get_products_by_production_area`. Devuelve `[]` si el
  /// toggle está off o ante cualquier error (no rompe el cierre).
  Future<List<Map<String, dynamic>>> _loadProductsByAreaIfEnabled(
    String sessionId,
  ) async {
    try {
      final businessId = await resolveBusinessIdOrNull(_client, 'auto');
      if (businessId == null) return const [];
      final enabled = await PosSettingsRepository(_client)
          .getCashClosePrintProductsByArea(businessId);
      if (!enabled) return const [];

      final session = await _client
          .from('cash_register_sessions')
          .select('opened_at, closed_at')
          .eq('id', sessionId)
          .maybeSingle();
      final openedAt = session?['opened_at']?.toString();
      if (openedAt == null || openedAt.isEmpty) return const [];
      final closedAt = (session?['closed_at']?.toString().isNotEmpty == true)
          ? session!['closed_at'].toString()
          : DateTime.now().toUtc().toIso8601String();

      final resp = await _client.rpc('get_products_by_production_area', params: {
        '_business_id': businessId,
        '_from': openedAt,
        '_to': closedAt,
      });
      if (resp is! List) return const [];
      return resp
          .whereType<Object?>()
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
    } catch (e) {
      debugPrint('[CashClosePrint] desglose productos por área falló: $e');
      return const [];
    }
  }

  List<int> _buildEscPos({
    required CashCloseInput input,
    required CashCloseResult result,
    required List<DenominationCount> denominations,
    required DateTime printedAt,
    int recountCount = 0,
    List<Map<String, dynamic>> salesByArea = const [],
    List<Map<String, dynamic>> productsByArea = const [],
  }) {
    final gen = EscPosGenerator(paperWidth: 80);
    gen.initialize();
    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered(input.businessName);
    gen.setTextSize();
    gen.setBold(false);
    gen.textCentered('CIERRE DE CAJA');
    gen.textCentered('Fecha: ${formatDateEsDo(printedAt)}');
    gen.textCentered('Hora: ${formatTimeEsDo(printedAt)}');
    gen.doubleSeparator();

    gen.setBold(true);
    gen.text('CONTEO DE EFECTIVO');
    gen.setBold(false);
    for (final d in denominations.where((e) => e.count > 0)) {
      gen.textRow('${formatRD(d.value)} x ${d.count}', formatRD(d.subtotal));
    }
    gen.separator();
    gen.textRow('Total efectivo', formatRD(result.totalCounted));
    gen.doubleSeparator();

    gen.setBold(true);
    gen.text('COMPARACION');
    gen.setBold(false);
    gen.text('Concepto   Esperado   Reportado   Dif.');
    gen.separator();

    void row(String concept, num expected, num reported) {
      final diff = reported - expected;
      final diffLabel =
          '${diff >= 0 ? '+' : '-'}${formatRD(diff.abs()).replaceFirst('RD\$ ', '')}';
      final line =
          '${concept.padRight(10)} ${_shortMoney(expected).padLeft(8)} ${_shortMoney(reported).padLeft(9)} ${diffLabel.padLeft(8)}';
      gen.text(line);
    }

    row('Efectivo', input.expectedCash, result.totalCounted);
    row('Tarjetas', input.expectedCard, result.numericCard);
    row('Transf.', input.expectedTransfer, result.numericTransfer);
    row('CIERRE', input.expectedClosureAmount, result.totalCounted);
    row('TOTAL', input.expectedTotal, result.totalReported);
    gen.doubleSeparator();

    gen.textRow('CIERRE ESPERADO', formatRD(input.expectedClosureAmount));
    gen.textRow('CIERRE REPORTADO', formatRD(result.totalCounted));
    gen.textRow('TOTAL ESPERADO', formatRD(input.expectedTotal));
    gen.textRow('TOTAL REPORTADO', formatRD(result.totalReported));
    gen.separator();
    gen.textRow('MONTO INICIAL', formatRD(input.startAmount));
    final toDeposit = result.totalCounted - input.startAmount;
    gen.setBold(true);
    gen.textRow('MONTO A DEPOSITAR', formatRD(toDeposit));
    gen.setBold(false);
    gen.separator();

    if (result.isBalanced) {
      gen.textCentered('CAJA CUADRADA');
    } else if (result.hasSurplus) {
      gen.textCentered('SOBRANTE: ${formatRD(result.totalDifference.abs())}');
    } else {
      gen.textCentered('FALTANTE: ${formatRD(result.totalDifference.abs())}');
    }

    gen.doubleSeparator();
    gen.setBold(true);
    gen.text('ESTADISTICAS DEL TURNO');
    gen.setBold(false);
    gen.textRow('Total Ventas', formatRD(input.totalSales));
    gen.textRow('Transacciones', input.transactionCount.toString());
    // Auditoría: cuántas veces el cajero presionó "Volver a contar"
    // antes de firmar este cierre. Solo se imprime si hubo al menos
    // uno — un cierre limpio no necesita ensuciar el ticket.
    if (recountCount > 0) {
      gen.textRow('Reconteos', recountCount.toString());
    }
    gen.doubleSeparator();

    // Sprint Caja Pro — Listado detallado de depósitos / retiros /
    // gastos del turno. Cada uno con razón y monto para auditoría
    // (entrega de dinero a contador, banco, etc.).
    if (input.movements.isNotEmpty) {
      _renderMovementsSection(
        gen,
        title: 'DEPOSITOS DEL TURNO',
        entries: input.movements.where((m) => m.type == 'deposit').toList(),
        sign: '+',
      );
      _renderMovementsSection(
        gen,
        title: 'RETIROS DEL TURNO',
        entries:
            input.movements.where((m) => m.type == 'withdrawal').toList(),
        sign: '-',
      );
      _renderMovementsSection(
        gen,
        title: 'GASTOS DEL TURNO',
        entries: input.movements.where((m) => m.type == 'expense').toList(),
        sign: '-',
      );
    }

    // Desglose de ventas por área de producción (toggle por negocio). Va
    // tras los movimientos y antes de los datos del cajero/firma.
    _renderSalesByAreaSection(gen, salesByArea);

    // Desglose por área → cada producto con su cantidad (toggle aparte).
    _renderProductsByAreaSection(gen, productsByArea);

    gen.text('Cajero: ${input.cashierName}');
    gen.text(
      'Impreso: ${formatDateEsDo(printedAt)} ${formatTimeEsDo(printedAt)}',
    );
    gen.lineFeed(3);
    gen.textCentered('__________________________');
    gen.textCentered('Firma Cajero');
    gen.lineFeed(3);
    gen.textCentered('__________________________');
    gen.textCentered('Recibe Conforme');
    gen.lineFeed(2);
    gen.textCentered('www.mangopos.do');
    gen.lineFeed(2);
    gen.cut();
    return gen.getCommands();
  }

  Future<void> _printThermalOrThrow(
    List<int> bytes, {
    String? cashRegisterId,
  }) async {
    final businessId = await resolveBusinessIdOrNull(_client, 'auto');
    if (businessId == null) {
      throw Exception(
        'No se pudo resolver el negocio activo para imprimir el cierre.',
      );
    }

    // 1. Try register-specific printer first
    PrinterConfig? registerPrinter;
    if (cashRegisterId != null) {
      final data = await _client
          .from('cash_registers')
          .select('receipt_printer_id')
          .eq('id', cashRegisterId)
          .maybeSingle();
      final printerId = data?['receipt_printer_id'] as String?;
      if (printerId != null) {
        registerPrinter = await _printingRepository.getPrinterById(printerId);
      }
    }

    // 2. Fall back to area-based lookup
    final preferredPrinter =
        registerPrinter ??
        await _printingRepository.getAssignedPrinterForType(
          businessId: businessId,
          preferredAreaCodes: const [
            'cash_close',
            'cashier',
            'receipt',
            'receipts',
            'fiscal',
          ],
          printsReceipts: true,
        );

    final printers = await _printingRepository.getPrinters(businessId);
    final activePrinters = printers
        .where((p) => p.isActive)
        .toList(growable: false);

    // Para cierre de caja debe tener prioridad la impresora explícitamente
    // asignada al área de cierre, aunque el flag `online` no esté actualizado.
    final printer =
        preferredPrinter ??
        (activePrinters.isNotEmpty ? activePrinters.first : null);

    if (printer == null) {
      throw Exception(
        'No hay una impresora configurada para imprimir el cierre de caja.',
      );
    }

    if (kIsWeb && printer.isUSB && !await _printingRepository.isAgentUp()) {
      throw Exception(
        'El cierre está asignado a una impresora USB, pero este flujo necesita el Agente Local activo en la PC donde está conectada.',
      );
    }

    await _printingRepository.printEscPos(printer: printer, data: bytes);
  }

  String _shortMoney(num amount) {
    return formatRD(amount).replaceFirst('RD\$ ', '');
  }

  /// Sprint Caja Pro — Renderiza una sección de movimientos manuales
  /// del turno (depósitos, retiros o gastos) con razón + monto + total.
  /// Si no hay entradas la sección se omite por completo.
  void _renderMovementsSection(
    EscPosGenerator gen, {
    required String title,
    required List<CashMovementEntry> entries,
    required String sign,
  }) {
    if (entries.isEmpty) return;
    gen.setBold(true);
    gen.text(title);
    gen.setBold(false);
    var total = 0.0;
    for (final m in entries) {
      total += m.amount;
      final label =
          (m.reasonLabel?.trim().isNotEmpty == true ? m.reasonLabel!.trim() : '—');
      // Línea con razón a la izquierda + monto con signo a la derecha.
      // 28 chars máximo en el label para no romper papel de 80mm.
      final shortLabel = label.length > 28 ? '${label.substring(0, 25)}...' : label;
      gen.textRow(shortLabel, '$sign ${_shortMoney(m.amount)}');
    }
    gen.separator();
    gen.setBold(true);
    gen.textRow('Subtotal $title', '$sign ${formatRD(total)}');
    gen.setBold(false);
    gen.doubleSeparator();
  }

  /// Desglose de ventas por área de producción (cocina, bar, caja…) para el
  /// periodo de la sesión. Cada área muestra su monto y, debajo, unidades y
  /// órdenes. Se omite por completo si la lista está vacía (toggle off o sin
  /// ventas con área en el periodo).
  void _renderSalesByAreaSection(
    EscPosGenerator gen,
    List<Map<String, dynamic>> salesByArea,
  ) {
    if (salesByArea.isEmpty) return;
    gen.setBold(true);
    gen.text('VENTAS POR AREA DE PRODUCCION');
    gen.setBold(false);
    var total = 0.0;
    for (final area in salesByArea) {
      final label = (area['label']?.toString().trim().isNotEmpty == true)
          ? area['label'].toString().trim()
          : 'Sin area';
      final amount = (area['amount'] as num?)?.toDouble() ?? 0;
      final quantity = (area['quantity'] as num?)?.toDouble() ?? 0;
      final count = (area['count'] as num?)?.toInt() ?? 0;
      total += amount;

      final shortLabel =
          label.length > 28 ? '${label.substring(0, 25)}...' : label;
      gen.textRow(shortLabel, formatRD(amount));
      // Línea secundaria con unidades y órdenes (formato compacto).
      final qtyLabel = quantity == quantity.roundToDouble()
          ? quantity.toStringAsFixed(0)
          : quantity.toStringAsFixed(2);
      gen.text('  $qtyLabel und  ·  $count ord');
    }
    gen.separator();
    gen.setBold(true);
    gen.textRow('Total areas', formatRD(total));
    gen.setBold(false);
    gen.doubleSeparator();
  }

  /// Desglose por área de producción → cada producto con su cantidad
  /// (unidades) en el periodo de la sesión. Cada área es un subtítulo y debajo
  /// van sus productos. Se omite por completo si la lista está vacía (toggle
  /// off o sin ventas con área en el periodo).
  void _renderProductsByAreaSection(
    EscPosGenerator gen,
    List<Map<String, dynamic>> productsByArea,
  ) {
    if (productsByArea.isEmpty) return;
    gen.setBold(true);
    gen.text('DESGLOSE POR AREA DE PRODUCCION');
    gen.setBold(false);

    for (final area in productsByArea) {
      final products = area['products'];
      if (products is! List || products.isEmpty) continue;

      final label = (area['label']?.toString().trim().isNotEmpty == true)
          ? area['label'].toString().trim()
          : 'Sin area';

      gen.separator();
      gen.setBold(true);
      gen.text(label);
      gen.setBold(false);

      for (final raw in products) {
        if (raw is! Map) continue;
        final p = Map<String, dynamic>.from(raw);
        final name = (p['product']?.toString().trim().isNotEmpty == true)
            ? p['product'].toString().trim()
            : '—';
        final qty = (p['quantity'] as num?)?.toDouble() ?? 0;
        final qtyLabel = qty == qty.roundToDouble()
            ? qty.toStringAsFixed(0)
            : qty.toStringAsFixed(2);
        // Nombre acotado a 28 chars para no romper el papel de 80mm.
        final shortName = name.length > 28 ? '${name.substring(0, 25)}...' : name;
        gen.textRow(shortName, '$qtyLabel unidades');
      }
    }
    gen.doubleSeparator();
  }
}
