import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:mangopos/data/models/printing.dart' show PrinterConfig;
import 'package:mangopos/core/printing/printerless_mode.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/presentation/cashier/state/cash_close_formatters.dart';
import 'package:mangopos/services/printing/esc_pos_generator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Cómo mostrar el cierre en pantalla cuando el modo sin impresora está
/// activo. Lo provee la vista que dispara el cierre (necesita BuildContext);
/// si no se pasa, el cierre simplemente no saca papel ni modal.
typedef CashCloseScreenPresenter = Future<void> Function(String plainText);

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
    bool reprint = false,
    CashCloseScreenPresenter? presentOnScreen,
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

    final ticket = _buildEscPos(
      input: input,
      result: result,
      denominations: denominations,
      printedAt: printedAt,
      recountCount: recountCount,
      salesByArea: salesByArea,
      productsByArea: productsByArea,
      reprint: reprint,
    );

    await _printThermalOrThrow(
      ticket.bytes,
      cashRegisterId: cashRegisterId,
      plainText: ticket.plainText,
      presentOnScreen: presentOnScreen,
    );
  }

  /// Reimprime el ticket de cierre de una sesión YA cerrada, reconstruyendo
  /// exactamente los mismos datos que se imprimieron al cerrarla:
  ///  - esperados + estadísticas del turno vía la RPC `fn_get_cash_session_summary`
  ///    (misma fuente de verdad que el cierre real),
  ///  - reportado por método + denominaciones desde el conteo firmado
  ///    (`cash_count_blind`, cierre detallado); si no existe (cierre compacto),
  ///    el reportado se parsea de las notas de la sesión y el ticket va sin el
  ///    desglose de denominaciones (que ese modo nunca persiste),
  ///  - movimientos manuales del turno (depósitos/retiros/gastos) con su razón.
  ///
  /// Usa el MISMO layout que `printCloseTicket` — solo agrega la marca
  /// "REIMPRESION" bajo el encabezado. La fecha/hora del ticket son las del
  /// cierre original (no las de la reimpresión).
  ///
  /// [businessName]/[cashierName] son opcionales: si el caller ya los tiene
  /// (las vistas de cierres/reportes los muestran) se pasan para evitar
  /// lookups; si no, se resuelven aquí best-effort.
  Future<void> reprintForSession({
    required String sessionId,
    String? businessName,
    String? cashierName,
    CashCloseScreenPresenter? presentOnScreen,
  }) async {
    // 1. Fila de la sesión. Debe estar cerrada para tener un cierre que reimprimir.
    final session = await _client
        .from('cash_register_sessions')
        .select(
          'opened_at, closed_at, start_amount, notes, user_id, cash_register_id, status',
        )
        .eq('id', sessionId)
        .maybeSingle();
    if (session == null) {
      throw Exception('No se encontró la sesión de caja para reimprimir.');
    }
    final closedAtRaw = session['closed_at']?.toString();
    if (closedAtRaw == null || closedAtRaw.isEmpty) {
      throw Exception('Esta sesión de caja aún no está cerrada.');
    }
    final closedAt = DateTime.tryParse(closedAtRaw) ?? DateTime.now();
    final startAmount = (session['start_amount'] as num?)?.round() ?? 0;
    final notes = session['notes']?.toString() ?? '';
    final cashRegisterId = session['cash_register_id']?.toString();
    final userId = session['user_id']?.toString() ?? '';

    // 2. Esperados + estadísticas del turno (misma RPC que el cierre real).
    final summaryResp = Map<String, dynamic>.from(
      await _client.rpc(
        'fn_get_cash_session_summary',
        params: {'p_session_id': sessionId},
      ),
    );
    final summary = (summaryResp['success'] as bool? ?? true)
        ? summaryResp
        : const <String, dynamic>{};

    int toInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.round();
      return int.tryParse(v.toString()) ?? 0;
    }

    double toDouble(dynamic v) => (v as num?)?.toDouble() ?? 0;

    final expectedCash = toInt(summary['expected_cash']);
    final expectedCard = toInt(summary['expected_card']);
    final expectedTransfer = toInt(summary['expected_transfer']);

    final repo = CashierRepository(_client);
    final businessId = await resolveBusinessIdOrNull(_client, 'auto');

    // 3. Movimientos manuales del turno (depósitos/retiros/gastos) con razón
    //    resuelta desde el catálogo. No crítico: si falla, va sin movimientos.
    List<CashMovementEntry> movements = const <CashMovementEntry>[];
    try {
      final allTx = await repo.getSessionTransactions(sessionId);
      final reasons = (businessId == null || businessId.isEmpty)
          ? const <Map<String, dynamic>>[]
          : await repo.getCashTransactionReasons(businessId: businessId);
      final reasonByCode = <String, String>{
        for (final r in reasons)
          if (r['code'] != null && r['label'] != null)
            r['code'].toString(): r['label'].toString(),
      };
      movements = allTx
          .where((tx) =>
              tx.type == 'deposit' ||
              tx.type == 'withdrawal' ||
              tx.type == 'expense')
          .map((tx) {
            final code = tx.reasonCode;
            final label = (code != null && reasonByCode[code] != null)
                ? reasonByCode[code]
                : tx.description;
            return CashMovementEntry(
              type: tx.type,
              amount: tx.amount,
              reasonLabel: label,
              description: tx.description,
              createdAt: tx.createdAt,
            );
          })
          .toList(growable: false);
    } catch (e) {
      debugPrint('[CashClosePrint] movimientos no disponibles (reimpresión): $e');
    }

    // 4. Lado reportado + denominaciones. Preferimos el conteo firmado
    //    (cash_count_blind, cierre detallado); si no existe (cierre compacto),
    //    parseamos las notas y el ticket va sin desglose de denominaciones.
    final blind = await repo.getBlindCountForSession(sessionId);
    int reportedCash;
    double reportedCard;
    double reportedTransfer;
    List<DenominationCount> denominations;
    if (blind != null) {
      reportedCash = toInt(blind['cash_amount']);
      reportedCard = toDouble(blind['card_amount']);
      reportedTransfer = toDouble(blind['transfer_amount']);
      denominations = _denominationsFromJson(blind['denominations']);
    } else {
      final parsed = _reportedFromNotes(notes);
      reportedCash = parsed.cash.round();
      reportedCard = parsed.card;
      reportedTransfer = parsed.transfer;
      denominations = const <DenominationCount>[];
    }
    final totalReported = reportedCash + reportedCard + reportedTransfer;

    // 5. Nombre del negocio / cajero (fallback a lookups si no vienen del caller).
    final resolvedBusinessName =
        (businessName != null && businessName.trim().isNotEmpty)
            ? businessName.trim()
            : await _resolveBusinessName(businessId);
    final resolvedCashier =
        (cashierName != null && cashierName.trim().isNotEmpty)
            ? cashierName.trim()
            : await _resolveCashierName(userId);

    final input = CashCloseInput(
      expectedCash: expectedCash,
      expectedCard: expectedCard,
      expectedTransfer: expectedTransfer,
      totalSales: toInt(summary['total_sales_all_methods']),
      transactionCount: toInt(summary['transaction_count']),
      cashierName: resolvedCashier,
      businessName: resolvedBusinessName,
      startAmount: startAmount,
      cashSalesNet: toInt(summary['cash_sales_net']),
      totalDeposits: toInt(summary['total_deposits']),
      totalWithdrawals: toInt(summary['total_withdrawals']),
      totalExpenses: toInt(summary['total_expenses']),
      movements: movements,
    );

    // Diferencias reconstruidas igual que CashCloseCalculator.calculate.
    final result = CashCloseResult(
      totalCounted: reportedCash,
      numericCard: reportedCard,
      numericTransfer: reportedTransfer,
      totalReported: totalReported.toDouble(),
      expectedTotal: input.expectedTotal,
      cashDifference: reportedCash - expectedCash,
      cardDifference: reportedCard - expectedCard,
      transferDifference: reportedTransfer - expectedTransfer,
      totalDifference: totalReported - input.expectedTotal,
    );

    int recountCount = 0;
    try {
      recountCount =
          await PosSettingsRepository(_client).getCashRecountCount(sessionId);
    } catch (_) {}

    await printCloseTicket(
      input: input,
      result: result,
      denominations: denominations,
      printedAt: closedAt,
      cashRegisterId: cashRegisterId,
      recountCount: recountCount,
      sessionId: sessionId,
      reprint: true,
      presentOnScreen: presentOnScreen,
    );
  }

  /// Reconstruye la lista de denominaciones desde el JSONB de `cash_count_blind`
  /// (`{"1000": 3, "500": 2}` → valor:conteo). El label no se usa en el ticket
  /// (solo value/count), así que va vacío. Se ordena descendente por valor para
  /// imprimir de mayor a menor, igual que el conteo en vivo.
  List<DenominationCount> _denominationsFromJson(dynamic raw) {
    if (raw is! Map) return const <DenominationCount>[];
    final list = <DenominationCount>[];
    raw.forEach((k, v) {
      final value = int.tryParse(k.toString());
      final count = v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0;
      if (value != null && count > 0) {
        list.add(DenominationCount(value: value, label: '', count: count));
      }
    });
    list.sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  /// Parsea el reportado por método desde las notas del cierre. Acepta singular
  /// o plural porque el modo compacto escribe "Tarjetas"/"Transferencias" y el
  /// detallado "Tarjeta"/"Transferencia". Usado solo cuando NO hay conteo
  /// firmado (cierres compactos).
  ({double cash, double card, double transfer, double total}) _reportedFromNotes(
    String notes,
  ) {
    double extract(String label) {
      final match =
          RegExp('$label:\\s*([0-9]+(?:\\.[0-9]+)?)').firstMatch(notes);
      return match == null ? 0 : (double.tryParse(match.group(1) ?? '') ?? 0);
    }

    final cash = extract('Efectivo');
    final card = extract('Tarjetas?');
    final transfer = extract('Transferencias?');
    final total = extract('Total reportado');
    return (
      cash: cash,
      card: card,
      transfer: transfer,
      total: total > 0 ? total : cash + card + transfer,
    );
  }

  Future<String> _resolveBusinessName(String? businessId) async {
    if (businessId == null || businessId.isEmpty) return 'MangoPOS Restaurant';
    try {
      final row = await _client
          .from('businesses')
          .select('business_name')
          .eq('id', businessId)
          .maybeSingle();
      final name = row?['business_name']?.toString().trim();
      return (name != null && name.isNotEmpty) ? name : 'MangoPOS Restaurant';
    } catch (_) {
      return 'MangoPOS Restaurant';
    }
  }

  Future<String> _resolveCashierName(String userId) async {
    if (userId.isEmpty) return 'Cajero';
    try {
      final row = await _client
          .from('profiles')
          .select('full_name')
          .eq('id', userId)
          .maybeSingle();
      final name = row?['full_name']?.toString().trim();
      return (name != null && name.isNotEmpty) ? name : 'Cajero';
    } catch (_) {
      return 'Cajero';
    }
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

  ({List<int> bytes, String plainText}) _buildEscPos({
    required CashCloseInput input,
    required CashCloseResult result,
    required List<DenominationCount> denominations,
    required DateTime printedAt,
    int recountCount = 0,
    List<Map<String, dynamic>> salesByArea = const [],
    List<Map<String, dynamic>> productsByArea = const [],
    bool reprint = false,
  }) {
    final gen = EscPosGenerator(paperWidth: 80);
    gen.initialize();
    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered(input.businessName);
    gen.setTextSize();
    gen.setBold(false);
    gen.textCentered('CIERRE DE CAJA');
    // Marca de auditoría: este ticket es una reimpresión de un cierre ya
    // firmado, no el cierre original. Solo aparece en reimpresiones — los
    // cierres en vivo salen byte-idénticos a como estaban.
    if (reprint) {
      gen.setBold(true);
      gen.textCentered('** REIMPRESION **');
      gen.setBold(false);
    }
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
    return (bytes: gen.getCommands(), plainText: gen.getPlainText());
  }

  Future<void> _printThermalOrThrow(
    List<int> bytes, {
    String? cashRegisterId,
    String? plainText,
    CashCloseScreenPresenter? presentOnScreen,
  }) async {
    final businessId = await resolveBusinessIdOrNull(_client, 'auto');
    if (businessId == null) {
      throw Exception(
        'No se pudo resolver el negocio activo para imprimir el cierre.',
      );
    }

    // Modo sin impresora: el cierre se muestra en pantalla (con compartir
    // PDF) en vez de exigir una térmica. El cierre en sí ya quedó guardado
    // — esto es solo el comprobante.
    if (await PrinterlessMode.isEnabled(businessId)) {
      if (presentOnScreen != null && plainText != null) {
        await presentOnScreen(plainText);
      }
      return;
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
