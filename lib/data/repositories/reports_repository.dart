import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/fiscal/ncf_types.dart';
import '../../core/offline/reports_offline_cache.dart';
import '../../core/utils/app_time.dart';
import '../datasources/queries/reports_queries.dart';
import '../utils/payment_amount_utils.dart';
import '../utils/order_pricing_utils.dart';
import '../models/sales_models.dart';
import '../../core/tax/tax_engine.dart';

class ReportsRepository {
  final SupabaseClient _client;
  static const int _inFilterBatchSize = 150;

  ReportsRepository(this._client);

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  double _extractReportedAmount(String? notes, String label) {
    final source = notes ?? '';
    if (source.isEmpty) return 0;
    final escapedLabel = RegExp.escape(label);
    final match = RegExp(
      '$escapedLabel\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)',
      caseSensitive: false,
    ).firstMatch(source);
    if (match == null) return 0;
    return double.tryParse(match.group(1) ?? '') ?? 0;
  }

  Future<List<Map<String, dynamic>>> _selectInBatches({
    required String table,
    required String select,
    required String column,
    required List<String> values,
    dynamic Function(dynamic query)? transform,
  }) async {
    if (values.isEmpty) return <Map<String, dynamic>>[];

    final rows = <Map<String, dynamic>>[];
    for (var start = 0; start < values.length; start += _inFilterBatchSize) {
      final end = (start + _inFilterBatchSize > values.length)
          ? values.length
          : start + _inFilterBatchSize;
      final chunk = values.sublist(start, end);
      var query = _client.from(table).select(select).inFilter(column, chunk);
      if (transform != null) {
        query = transform(query);
      }
      final chunkRows = await query;
      rows.addAll(List<Map<String, dynamic>>.from(chunkRows));
    }
    return rows;
  }

  Future<List<Map<String, dynamic>>> _loadScopedPaymentsForRange({
    required String businessId,
    required DateTime from,
    required DateTime to,
    required String select,
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    // payments.business_id existe como columna directa → filtramos ahí
    // en vez de hacer INNER JOIN payments → orders → table_sessions.
    // El JOIN evaluaba RLS sobre las 3 tablas y disparaba seq scans con
    // statement_timeout 57014 en reportes. El índice
    // (business_id, created_at DESC) sostiene este filter + sort.
    //
    // Pre-requisito DB: para evitar perder payments legacy, correr el
    // backfill que popula payments.business_id desde orders→sessions.
    // Está documentado al lado del CREATE INDEX correspondiente.
    final paymentRows = List<Map<String, dynamic>>.from(
      await _client
          .from(ReportsQueries.tablePayments)
          .select(select)
          .eq('business_id', businessId)
          .gte('created_at', fromIso)
          .lt('created_at', toIso)
          .order('created_at', ascending: false)
          .limit(50000),
    );

    return paymentRows;
  }

  /// Resumen de ventas — usa RPC `get_sales_summary_v2` que agrega todo
  /// server-side en un solo round-trip. Antes hacía 8 queries
  /// secuenciales con LRM/voluntary-tip calculados en Dart; ahora
  /// Postgres lo hace en una sola pasada con CTEs (~95ms vs 4s).
  ///
  /// Campos faltantes vs versión legacy:
  /// - modifier_sales_total, sales_by_modifier → necesitan join a
  ///   order_item_modifiers, no incluidos en v2
  /// - sales_by_receipt → necesita clasificación por NCF type
  /// - sales_by_adjustment → necesita lógica de cortesía/promo
  ///
  /// Default a [] vacío para esos; el UI los renderiza como secciones
  /// vacías. Si se necesitan, agregar a `get_sales_summary_v2` en SQL.
  Future<Map<String, dynamic>> getSalesSummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    try {
      final response = await _client.rpc(
        'get_sales_summary_v2',
        params: {
          '_business_id': businessId,
          '_from': fromIso,
          '_to': toIso,
        },
      );

      final result = response == null
          ? _emptySalesSummary(fromIso, toIso)
          : Map<String, dynamic>.from(response as Map);

      // Defaults para campos no cubiertos por el RPC v2
      result['modifier_sales_total'] ??= 0;
      result['sales_by_modifier'] ??= const <Map<String, dynamic>>[];
      result['sales_by_receipt'] ??= const <Map<String, dynamic>>[];
      result['sales_by_adjustment'] ??= const <Map<String, dynamic>>[];
      result['sales_by_production_area'] ??= const <Map<String, dynamic>>[];

      // F5: cacheamos el resumen para poder verlo sin conexión (solo
      // lectura). Best-effort — no bloquea ni rompe la carga online.
      await ReportsOfflineCache().saveSalesSummary(
        businessId: businessId,
        fromIso: fromIso,
        toIso: toIso,
        summary: result,
      );

      return result;
    } catch (e) {
      // F5: sin conexión, servimos el snapshot cacheado del MISMO rango,
      // marcado con `_offline_cached_at` para que la UI muestre el aviso de
      // "datos sin conexión". Si no hay cache para ese rango, propagamos el
      // error (comportamiento de siempre).
      final cached = await ReportsOfflineCache().loadSalesSummary(
        businessId: businessId,
        fromIso: fromIso,
        toIso: toIso,
      );
      if (cached != null) {
        return {
          ...cached.summary,
          '_offline_cached_at': cached.savedAt.toIso8601String(),
        };
      }
      rethrow;
    }
  }

  Map<String, dynamic> _emptySalesSummary(String fromIso, String toIso) => {
        'from': fromIso,
        'to': toIso,
        'total_sales': 0,
        'voided_sales': 0,
        'net_sales': 0,
        'payments_count': 0,
        'voided_payments_count': 0,
        'items_sold': 0,
        'avg_ticket': 0,
        'modifier_sales_total': 0,
        'discounts_total': 0,
        'courtesy_total': 0,
        'discounted_lines_count': 0,
        'courtesy_lines_count': 0,
        'sales_by_method': const <Map<String, dynamic>>[],
        'sales_by_receipt': const <Map<String, dynamic>>[],
        'sales_by_hour': const <Map<String, dynamic>>[],
        'sales_by_modifier': const <Map<String, dynamic>>[],
        'sales_by_adjustment': const <Map<String, dynamic>>[],
        'top_products': const <Map<String, dynamic>>[],
        'product_sales': const <Map<String, dynamic>>[],
        'sales_by_category': const <Map<String, dynamic>>[],
        'sales_by_employee': const <Map<String, dynamic>>[],
        'sales_by_zone': const <Map<String, dynamic>>[],
        'sales_by_production_area': const <Map<String, dynamic>>[],
      };


  /// Envuelve un loader de resumen con cache offline (F5): cachea al cargar
  /// online y, ante error de red, sirve el snapshot cacheado del MISMO rango
  /// (marcado `_offline_cached_at`). Si no hay cache para ese rango, propaga
  /// el error. [kind] separa los snapshots por categoría de reporte.
  Future<Map<String, dynamic>> _withOfflineCache({
    required String kind,
    required String businessId,
    required DateTime from,
    required DateTime to,
    required Future<Map<String, dynamic>> Function() loader,
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);
    try {
      final result = await loader();
      await ReportsOfflineCache().saveSummary(
        kind: kind,
        businessId: businessId,
        fromIso: fromIso,
        toIso: toIso,
        summary: result,
      );
      return result;
    } catch (e) {
      final cached = await ReportsOfflineCache().loadSummary(
        kind: kind,
        businessId: businessId,
        fromIso: fromIso,
        toIso: toIso,
      );
      if (cached != null) {
        return {
          ...cached.summary,
          '_offline_cached_at': cached.savedAt.toIso8601String(),
        };
      }
      rethrow;
    }
  }

  /// Resumen de caja/finanzas. F5-2: cachea al cargar online y, sin red,
  /// sirve el snapshot cacheado del MISMO rango (marcado `_offline_cached_at`)
  /// para poder ver el cierre del día offline. Si no hay cache para ese rango,
  /// propaga el error.
  Future<Map<String, dynamic>> getCashSummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);
    try {
      final result = await _getCashSummaryOnline(
          businessId: businessId, from: from, to: to);
      await ReportsOfflineCache().saveCashSummary(
        businessId: businessId,
        fromIso: fromIso,
        toIso: toIso,
        summary: result,
      );
      return result;
    } catch (e) {
      final cached = await ReportsOfflineCache().loadCashSummary(
        businessId: businessId,
        fromIso: fromIso,
        toIso: toIso,
      );
      if (cached != null) {
        return {
          ...cached.summary,
          '_offline_cached_at': cached.savedAt.toIso8601String(),
        };
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _getCashSummaryOnline({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    final sessions = await _client
        .from(ReportsQueries.tableCashSessions)
        .select(
          'id, cash_register_id, user_id, start_amount, end_amount, difference, status, opened_at, closed_at, notes, cash_registers!inner(business_id, name)',
        )
        .eq('cash_registers.business_id', businessId)
        .gte('opened_at', fromIso)
        .lt('opened_at', toIso)
        .order('opened_at', ascending: false);

    final sessionRows = List<Map<String, dynamic>>.from(sessions);

    double openingsTotal = 0;
    double closingsTotal = 0;
    double differencesTotal = 0;
    int openSessions = 0;
    int closedSessions = 0;

    for (final session in sessionRows) {
      final startAmount = session['start_amount'];
      final endAmount = session['end_amount'];
      final status = session['status']?.toString();

      if (startAmount is num) openingsTotal += startAmount.toDouble();
      if (endAmount is num) closingsTotal += endAmount.toDouble();
      // differencesTotal se calcula abajo como suma de las diferencias NETAS
      // (todos los métodos), no de session.difference (solo efectivo).
      if (status == 'open') {
        openSessions += 1;
      } else {
        closedSessions += 1;
      }
    }

    final sessionIds = sessionRows
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final transactions = await _selectInBatches(
      table: ReportsQueries.tableCashTransactions,
      // related_order_id es necesario para excluir las ventas asociadas
      // a órdenes anuladas (su payment.status = 'cancelled' / 'void').
      select: 'session_id, amount, type, created_at, related_order_id',
      column: 'session_id',
      values: sessionIds,
      transform: (query) =>
          query.gte('created_at', fromIso).lt('created_at', toIso),
    );

    // Bug fix: cuando se anula una orden, payments.status pasa a
    // 'cancelled' pero la fila en cash_transactions (type='sale')
    // queda intacta y el cierre la seguía contando como venta. Aquí
    // resolvemos los order_ids cuyos pagos están anulados y los
    // excluimos del cálculo (tanto del total como del byType['sale']).
    final saleOrderIds = transactions
        .where(
          (tx) =>
              (tx['type']?.toString() ?? '') == 'sale' &&
              (tx['related_order_id']?.toString().trim().isNotEmpty ?? false),
        )
        .map((tx) => tx['related_order_id'].toString())
        .toSet()
        .toList(growable: false);

    final cancelledOrderIds = <String>{};
    if (saleOrderIds.isNotEmpty) {
      try {
        final cancelledRows = await _client
            .from('payments')
            .select('order_id')
            .inFilter('order_id', saleOrderIds)
            .inFilter('status', ['cancelled', 'void']);
        for (final row in cancelledRows as List) {
          final id = (row as Map)['order_id']?.toString();
          if (id != null && id.isNotEmpty) cancelledOrderIds.add(id);
        }
      } catch (_) {
        // Si falla la query, conservamos el behavior previo (sumar
        // todas las ventas) — preferimos un total ligeramente
        // inflado a un cierre vacío.
      }
    }

    double manualIn = 0;
    double manualOut = 0;
    double salesTotal = 0;
    double expensesTotal = 0;
    double withdrawalsTotal = 0;
    double voidedSalesTotal = 0; // visibilidad: ventas excluidas por anulación
    final byType = <String, Map<String, dynamic>>{};

    for (final tx in transactions) {
      final amount = tx['amount'];
      final type = tx['type']?.toString() ?? 'other';
      final normalized = _toDouble(amount);
      final relatedOrderId = tx['related_order_id']?.toString();
      final isVoidedSale =
          type == 'sale' &&
          relatedOrderId != null &&
          cancelledOrderIds.contains(relatedOrderId);

      // Las ventas anuladas no se suman al cierre — se reportan aparte
      // en `voided_sales` para que el comerciante sepa cuánto se anuló.
      if (isVoidedSale) {
        voidedSalesTotal += normalized;
        continue;
      }

      final bucket = byType.putIfAbsent(
        type,
        () => {'label': _cashTypeLabel(type), 'amount': 0.0, 'count': 0},
      );
      bucket['amount'] = _toDouble(bucket['amount']) + normalized;
      bucket['count'] = (bucket['count'] as int) + 1;

      if (type == 'deposit' || type == 'income') {
        manualIn += normalized;
      }
      if (type == 'withdrawal') {
        withdrawalsTotal += normalized;
        manualOut += normalized;
      }
      if (type == 'expense') {
        expensesTotal += normalized;
        manualOut += normalized;
      }
      if (type == 'sale') {
        salesTotal += normalized;
      }
    }

    final profileIds = sessionRows
        .map((row) => row['user_id']?.toString().trim())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final profileRows = profileIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from('profiles')
                .select('id, full_name')
                .inFilter('id', profileIds),
          );
    final profileNamesById = <String, String>{
      for (final profile in profileRows)
        if ((profile['id']?.toString() ?? '').isNotEmpty)
          profile['id'].toString():
              profile['full_name']?.toString().trim().isNotEmpty == true
              ? profile['full_name'].toString().trim()
              : 'Cajero',
    };

    final closureDetails = await Future.wait(
      sessionRows.map((session) async {
        final sessionId = session['id']?.toString() ?? '';
        Map<String, dynamic> summary = const <String, dynamic>{};
        if (sessionId.isNotEmpty) {
          try {
            final rpcResult = Map<String, dynamic>.from(
              await _client.rpc(
                'fn_get_cash_session_summary',
                params: {'p_session_id': sessionId},
              ),
            );
            final success = rpcResult['success'] as bool? ?? true;
            if (success) {
              summary = rpcResult;
            }
          } catch (_) {
            summary = const <String, dynamic>{};
          }
        }

        final notes = session['notes']?.toString();
        final status = session['status']?.toString() ?? 'open';
        final startAmount = _toDouble(session['start_amount']);
        final endAmount = _toDouble(session['end_amount']);
        final difference = _toDouble(session['difference']);
        final expectedCash = _toDouble(summary['expected_cash']);
        final expectedCard = _toDouble(summary['expected_card']);
        final expectedTransfer = _toDouble(summary['expected_transfer']);
        final expectedTotal = _toDouble(summary['expected_total']) > 0
            ? _toDouble(summary['expected_total'])
            : expectedCash + expectedCard + expectedTransfer;
        final reportedCash = _extractReportedAmount(notes, 'Efectivo');
        final reportedCard = _extractReportedAmount(notes, 'Tarjetas');
        final reportedTransfer = _extractReportedAmount(
          notes,
          'Transferencias',
        );
        final extractedReportedTotal = _extractReportedAmount(
          notes,
          'Total reportado',
        );
        final reportedTotal = extractedReportedTotal > 0
            ? extractedReportedTotal
            : (endAmount > 0
                  ? endAmount
                  : reportedCash + reportedCard + reportedTransfer);
        // Diferencia NETA (todos los métodos) = reportado − esperado, coherente
        // con la app. session['difference'] es solo de EFECTIVO. Si no hay
        // resumen (RPC falló) o no se pudo parsear el reportado, caemos a la de
        // efectivo para no mostrar un neto falso.
        final netDifference = (summary.isNotEmpty && reportedTotal > 0)
            ? reportedTotal - expectedTotal
            : difference;
        final totalSalesAllMethods = _toDouble(
          summary['total_sales_all_methods'],
        );
        final register = session['cash_registers'];
        final registerMap = register is Map<String, dynamic>
            ? register
            : (register is Map
                  ? Map<String, dynamic>.from(register)
                  : const <String, dynamic>{});
        final userId = session['user_id']?.toString() ?? '';
        final cashierName =
            profileNamesById[userId] ??
            (userId.isEmpty
                ? 'No identificado'
                : 'Usuario ${userId.substring(0, userId.length >= 8 ? 8 : userId.length).toUpperCase()}');

        return <String, dynamic>{
          'id': sessionId,
          'status': status,
          'cashier_name': cashierName,
          'cash_register_name': registerMap['name']?.toString() ?? 'Caja',
          'opened_at': session['opened_at'],
          'closed_at': session['closed_at'],
          'start_amount': startAmount,
          'end_amount': endAmount,
          'difference': netDifference,
          'difference_cash': difference,
          'expected_cash': expectedCash,
          'expected_card': expectedCard,
          'expected_transfer': expectedTransfer,
          'expected_total': expectedTotal,
          'reported_cash': reportedCash,
          'reported_card': reportedCard,
          'reported_transfer': reportedTransfer,
          'reported_total': reportedTotal,
          'sales_total_all_methods': totalSalesAllMethods,
          'sales_cash': _toDouble(summary['cash_sales_net']),
          'sales_card': _toDouble(summary['expected_card']),
          'sales_transfer': _toDouble(summary['expected_transfer']),
          'deposits_total': _toDouble(summary['total_deposits']),
          'withdrawals_total': _toDouble(summary['total_withdrawals']),
          'expenses_total': _toDouble(summary['total_expenses']),
          'transaction_count':
              (summary['transaction_count'] as num?)?.toInt() ?? 0,
          'notes': notes,
          'is_balanced': netDifference.abs() < 0.009,
        };
      }),
    );

    closureDetails.sort((a, b) {
      final aDate = DateTime.tryParse(a['opened_at']?.toString() ?? '');
      final bDate = DateTime.tryParse(b['opened_at']?.toString() ?? '');
      if (aDate == null && bDate == null) return 0;
      if (aDate == null) return 1;
      if (bDate == null) return -1;
      return bDate.compareTo(aDate);
    });

    // Diferencia acumulada = suma de las diferencias NETAS (todos los métodos),
    // coherente con lo que muestra cada tarjeta de cierre.
    differencesTotal = closureDetails.fold<double>(
      0.0,
      (sum, c) => sum + _toDouble(c['difference']),
    );

    final typeRows = byType.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));

    final averageDifference = sessionRows.isEmpty
        ? 0.0
        : differencesTotal / sessionRows.length;

    return {
      'from': fromIso,
      'to': toIso,
      'sessions_count': sessionRows.length,
      'open_sessions_count': openSessions,
      'closed_sessions_count': closedSessions,
      'openings_total': openingsTotal,
      'closings_total': closingsTotal,
      'differences_total': differencesTotal,
      'average_difference': averageDifference,
      'sales_total': salesTotal,
      // Ventas excluidas del cierre por anulación (payments.status =
      // cancelled/void). El UI puede mostrarlas como info aparte sin
      // sumarlas al efectivo esperado.
      'voided_sales_total': voidedSalesTotal,
      'expenses_total': expensesTotal,
      'withdrawals_total': withdrawalsTotal,
      'manual_in_total': manualIn,
      'manual_out_total': manualOut,
      'net_cash_flow': salesTotal + manualIn - manualOut,
      'transactions_by_type': typeRows,
      'cash_closures': closureDetails,
    };
  }

  Future<Map<String, dynamic>> getTaxSummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) =>
      _withOfflineCache(
        kind: 'tax',
        businessId: businessId,
        from: from,
        to: to,
        loader: () =>
            _getTaxSummaryOnline(businessId: businessId, from: from, to: to),
      );

  Future<Map<String, dynamic>> _getTaxSummaryOnline({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    final taxes = List<Map<String, dynamic>>.from(
      await _client
          .from(ReportsQueries.tableTaxes)
          .select('id, name, rate, is_active, is_service_fee')
          .eq('business_id', businessId),
    );

    final businessSettings = await _client
        .from('business_settings')
        .select('service_fee_enabled, service_fee_rate')
        .eq('business_id', businessId)
        .maybeSingle();
    final serviceFeeEnabled = businessSettings?['service_fee_enabled'] == true;
    final serviceFeeRate = _toDouble(
      businessSettings?['service_fee_rate'],
    ).clamp(0, 100);
    // Nombre del cargo de servicio configurado por el comercio (taxes table
    // con is_service_fee=true). Fallback genérico — antes era 'Propina de
    // ley' hardcoded en la fila del breakdown, rompía multi-config.
    final serviceFeeTaxRow = taxes.firstWhere(
      (t) => t['is_service_fee'] == true,
      orElse: () => const <String, dynamic>{},
    );
    final serviceFeeName =
        (serviceFeeTaxRow['name']?.toString().trim().isNotEmpty == true)
            ? serviceFeeTaxRow['name'].toString().trim()
            : 'Cargo de servicio';

    final payments = await _loadScopedPaymentsForRange(
      businessId: businessId,
      from: from,
      to: to,
      select: 'id, order_id, amount, change_amount, status, created_at',
    );

    final completedOrderIds = payments
        .where((row) => row['status'] == 'completed' || row['status'] == null)
        .map((row) => row['order_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);

    final items = await _selectInBatches(
      table: ReportsQueries.tableOrderItems,
      select: 'id, order_id, product_name, qty, quantity, subtotal, total, tax, tax_rate, tax_mode, status, is_takeout, discounts',
      column: 'order_id',
      values: completedOrderIds,
    );

    final itemIds = items.map((i) => i['id']?.toString()).whereType<String>().toList();
    final modifierRows = await _selectInBatches(
      table: 'order_item_modifiers',
      select: 'item_id, name, qty, price',
      column: 'item_id',
      values: itemIds,
    );

    final modifiersByItem = <String, List<OrderItemModifier>>{};
    for (final row in modifierRows) {
      final itemId = row['item_id'] as String;
      final mod = OrderItemModifier.fromMap(row);
      modifiersByItem[itemId] = [...(modifiersByItem[itemId] ?? []), mod];
    }

    final orderRows = await _selectInBatches(
      table: ReportsQueries.tableOrders,
      select: 'id, subtotal, service_fee, total, status_ext, origin:table_sessions!inner(origin)',
      column: 'id',
      values: completedOrderIds,
    );
    
    final ordersById = <String, Order>{
      for (final row in orderRows) 
        row['id'] as String: Order.fromMap({
          ...row,
          'origin': (row['origin'] as Map?)?['origin'] ?? 'table',
        })
    };

    // Calculate how much was paid today vs total for each order
    final paymentParticipationByOrder = <String, double>{};
    for (final orderId in completedOrderIds) {
      final orderPayments = payments.where((p) => p['order_id'] == orderId);
      final paidInRange = orderPayments.fold<double>(0, (sum, p) => sum + netPaymentAmount(p['amount'], p['change_amount']));
      
      final orderRow = orderRows.firstWhere((r) => r['id'] == orderId, orElse: () => {});
      final orderTotal = _toDouble(orderRow['total']);
      
      // If total is 0 or payments cover it all, factor is proportional
      paymentParticipationByOrder[orderId] = (orderTotal <= 0) ? 1.0 : (paidInRange / orderTotal);
    }

    final taxesByRate = <String, Map<String, dynamic>>{};
    for (final tax in taxes) {
      final rate = _toDouble(tax['rate']);
      taxesByRate[rate.toStringAsFixed(4)] = tax;
    }

    double totalTaxCollected = 0;
    double totalServiceFee = 0;
    double taxableSales = 0;
    double exemptSales = 0;
    double grossSalesWithTax = 0;
    double totalQuantity = 0;
    double serviceFeeBaseTotal = 0;
    int serviceFeeOrdersCount = 0;
    final breakdown = <String, Map<String, dynamic>>{};

    final Set<String> ordersWithServiceFee = {};

    for (final row in items) {
      final status = row['status']?.toString();
      if (status == 'void') continue;

      final orderId = row['order_id'] as String;
      final itemId = row['id'] as String;
      final order = ordersById[orderId];
      if (order == null) continue;

      // PROPORTIONALITY FACTOR: Only count the part that was paid in this range
      final factor = paymentParticipationByOrder[orderId] ?? 1.0;

      final item = OrderItem.fromMap(row).copyWith(
        modifiers: modifiersByItem[itemId] ?? [],
      );

      // Use harmonized pricing to get the correct paid gross for this item.
      // We deliberately do NOT use s.tax / s.subtotal for the breakdown because
      // those values depend on what was stored in the DB (which may use wrong
      // divisors or intermediate bases). Instead, we recompute from the
      // actual paid gross using the CONFIGURED tax rates so that the effective
      // ITBIS rate always equals the configured rate (e.g. 18 %).
      final s = summarizeItemPricing(order, item, forcedOrigin: order.origin);
      final paidGross = (s.subtotal + s.tax + s.serviceFee) * factor;
      final qty = item.quantity * factor;

      grossSalesWithTax += paidGross;
      totalQuantity += qty;

      // Correcting combined rate stored as single tax_rate (e.g. 28 → 18 ITBIS)
      final effectiveItbisRate = item.taxRate >= 27.9 ? 18.0 : item.taxRate;

      if (effectiveItbisRate <= 0) {
        exemptSales += paidGross;
        continue;
      }

      // Determine whether propina de ley applies to this item
      final origin = parseSaleOrigin(order.origin);
      final applyLey = serviceFeeEnabled &&
          !item.isTakeout &&
          origin != SaleOrigin.quick &&
          origin != SaleOrigin.delivery;
      final leyRate = applyLey ? serviceFeeRate : 0.0;
      final fullRatePct = effectiveItbisRate + leyRate;

      // Recompute base and taxes from paidGross using configured rates.
      // This guarantees ITBIS / base == configuredItbisRate regardless of how
      // the order was originally stored.
      final rawBase = fullRatePct > 0 ? paidGross / (1 + fullRatePct / 100) : paidGross;
      final itbis = (rawBase * effectiveItbisRate / 100 * 100).round() / 100;
      final ley = (rawBase * leyRate / 100 * 100).round() / 100;
      // Base absorbs rounding residue so that base + itbis + ley == paidGross exactly
      final base = ((paidGross - itbis - ley) * 100).round() / 100;

      taxableSales += base;
      totalTaxCollected += itbis;

      final effectiveRateKey = effectiveItbisRate.toStringAsFixed(4);
      final taxConfig = taxesByRate[effectiveRateKey];
      final rateDisplay = effectiveItbisRate == effectiveItbisRate.truncateToDouble()
          ? effectiveItbisRate.toInt().toString()
          : effectiveItbisRate.toStringAsFixed(2);
      // Fallback genérico cuando el comercio no tiene el impuesto a esa tasa
      // nombrado en su config (raro pero pasa). Antes era 'ITBIS' siempre —
      // rompía si el comercio configuró IVA/IGV/otro nombre.
      final label = taxConfig?['name']?.toString().trim().isNotEmpty == true
          ? taxConfig!['name'].toString().trim()
          : 'Impuesto ($rateDisplay%)';

      final bucket = breakdown.putIfAbsent(
        effectiveRateKey,
        () => {
          'label': label,
          'rate': effectiveItbisRate,
          'amount': 0.0,
          'taxable_amount': 0.0,
          'gross_amount': 0.0,
          'quantity': 0.0,
          'count': 0,
        },
      );
      bucket['amount'] = _toDouble(bucket['amount']) + itbis;
      bucket['taxable_amount'] = _toDouble(bucket['taxable_amount']) + base;
      bucket['gross_amount'] = _toDouble(bucket['gross_amount']) + paidGross;
      bucket['quantity'] = _toDouble(bucket['quantity']) + qty;
      bucket['count'] = (bucket['count'] as int) + 1;

      if (ley > 0) {
        totalServiceFee += ley;
        serviceFeeBaseTotal += base;
        ordersWithServiceFee.add(orderId);
      }
    }

    serviceFeeOrdersCount = ordersWithServiceFee.length;

    if (totalServiceFee > 0) {
      breakdown['__service_fee__'] = {
        // Antes el label era 'Propina de ley' hardcoded. Ahora respeta el
        // nombre configurado por el comercio (`serviceFeeName` derivado de
        // taxes.is_service_fee), con fallback neutral si la config está
        // vacía. La tasa viene de business_settings.service_fee_rate.
        'label': serviceFeeName,
        'rate': serviceFeeRate > 0 ? serviceFeeRate : 10.0,
        'amount': totalServiceFee,
        'taxable_amount': serviceFeeBaseTotal,
        'gross_amount': serviceFeeBaseTotal + totalServiceFee,
        'quantity': serviceFeeOrdersCount.toDouble(),
        'count': serviceFeeOrdersCount,
      };
    }

    final breakdownRows = breakdown.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));

    // Final rounding of aggregated totals for the report cards
    final rTotalTax = (totalTaxCollected * 100).round() / 100;
    final rTotalService = (totalServiceFee * 100).round() / 100;

    final effectiveRate = taxableSales <= 0
        ? 0.0
        : (totalTaxCollected / taxableSales) * 100;
    final totalChargesCollected = rTotalTax + rTotalService;

    return {
      'from': fromIso,
      'to': toIso,
      'configured_taxes_count': taxes.length,
      'active_taxes_count': taxes
          .where((tax) => tax['is_active'] == true)
          .length,
      'taxed_items_count': breakdownRows.fold<int>(
        0,
        (sum, row) => sum + ((row['count'] as int?) ?? 0),
      ),
      'items_quantity': totalQuantity,
      'gross_sales': (grossSalesWithTax * 100).round() / 100,
      'taxable_sales': (taxableSales * 100).round() / 100,
      'exempt_sales': (exemptSales * 100).round() / 100,
      'total_tax_collected': rTotalTax,
      'total_service_fee': rTotalService,
      // PRD 1: leer la tasa real del negocio en vez del hardcode 10.0.
      'service_fee_rate': serviceFeeEnabled ? serviceFeeRate.toDouble() : 0.0,
      'service_fee_orders_count': serviceFeeOrdersCount,
      'service_fee_base_total': (serviceFeeBaseTotal * 100).round() / 100,
      'total_charges_collected': (totalChargesCollected * 100).round() / 100,
      'effective_tax_rate': effectiveRate,
      'tax_breakdown': breakdownRows.map((r) => {
        ...r,
        'amount': (r['amount'] * 100).round() / 100,
        'taxable_amount': (r['taxable_amount'] * 100).round() / 100,
        'gross_amount': (r['gross_amount'] * 100).round() / 100,
      }).toList(),
    };
  }

  String _cashTypeLabel(String type) {
    switch (type) {
      case 'sale':
        return 'Ventas';
      case 'deposit':
        return 'Depósitos';
      case 'withdrawal':
        return 'Retiros';
      case 'expense':
        return 'Gastos';
      case 'income':
        return 'Ingresos';
      default:
        return type;
    }
  }

  Future<Map<String, dynamic>> getPurchasesSummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) =>
      _withOfflineCache(
        kind: 'purchases',
        businessId: businessId,
        from: from,
        to: to,
        loader: () => _getPurchasesSummaryOnline(
            businessId: businessId, from: from, to: to),
      );

  Future<Map<String, dynamic>> _getPurchasesSummaryOnline({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    final orders = List<Map<String, dynamic>>.from(
      await _client
          .from(ReportsQueries.tablePurchaseOrders)
          .select('id, supplier_id, status, total, created_at')
          .eq('business_id', businessId)
          .gte('created_at', fromIso)
          .lt('created_at', toIso),
    );

    final suppliers = List<Map<String, dynamic>>.from(
      await _client
          .from(ReportsQueries.tableSuppliers)
          .select('id, name')
          .eq('business_id', businessId)
          .eq('is_active', true),
    );

    final supplierIds = orders
        .map((row) => row['supplier_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final suppliersById = <String, String>{
      for (final row in suppliers)
        row['id']?.toString() ?? '': row['name']?.toString() ?? 'Proveedor',
    };

    double totalOrdered = 0;
    double totalReceived = 0;
    int receivedCount = 0;
    int partialCount = 0;
    int draftCount = 0;
    final statusBuckets = <String, Map<String, dynamic>>{};
    final supplierBuckets = <String, Map<String, dynamic>>{};

    for (final order in orders) {
      final total = _toDouble(order['total']);
      final status = order['status']?.toString() ?? 'draft';
      final supplierId = order['supplier_id']?.toString() ?? '';
      totalOrdered += total;

      final statusBucket = statusBuckets.putIfAbsent(
        status,
        () => {
          'label': _purchaseStatusLabel(status),
          'amount': 0.0,
          'count': 0,
        },
      );
      statusBucket['amount'] = _toDouble(statusBucket['amount']) + total;
      statusBucket['count'] = (statusBucket['count'] as int) + 1;

      final supplierLabel =
          suppliersById[supplierId] ?? 'Proveedor no asignado';
      final supplierBucket = supplierBuckets.putIfAbsent(
        supplierLabel,
        () => {'label': supplierLabel, 'amount': 0.0, 'count': 0},
      );
      supplierBucket['amount'] = _toDouble(supplierBucket['amount']) + total;
      supplierBucket['count'] = (supplierBucket['count'] as int) + 1;

      switch (status) {
        case 'received':
          totalReceived += total;
          receivedCount += 1;
          break;
        case 'partial':
          partialCount += 1;
          break;
        case 'draft':
          draftCount += 1;
          break;
      }
    }

    final avgOrder = orders.isEmpty ? 0.0 : totalOrdered / orders.length;
    final supplierRows = supplierBuckets.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));
    final statusRows = statusBuckets.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));

    return {
      'from': fromIso,
      'to': toIso,
      'orders_count': orders.length,
      'suppliers_count': suppliers.length,
      'suppliers_with_orders_count': supplierIds.length,
      'total_ordered': totalOrdered,
      'total_received': totalReceived,
      'avg_order_total': avgOrder,
      'received_count': receivedCount,
      'partial_count': partialCount,
      'draft_count': draftCount,
      'status_breakdown': statusRows,
      'top_suppliers': supplierRows.take(8).toList(growable: false),
    };
  }

  Future<Map<String, dynamic>> getFiscalDocumentsSummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) =>
      _withOfflineCache(
        kind: 'fiscal',
        businessId: businessId,
        from: from,
        to: to,
        loader: () => _getFiscalDocumentsSummaryOnline(
            businessId: businessId, from: from, to: to),
      );

  Future<Map<String, dynamic>> _getFiscalDocumentsSummaryOnline({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    // Carga en UN viaje vía RPC get_fiscal_summary_bundle (documents + taxes +
    // order_items + orders del rango). Antes eran 7-15 round-trips
    // (fiscal_documents, taxes, y order_items/orders en lotes de 150). La
    // AGREGACIÓN sigue 100% en Dart, así que los números no cambian; este
    // RPC solo mueve el fetch al servidor. Fallback al camino multi-query si
    // el RPC todavía no está desplegado.
    List<Map<String, dynamic>> rows;
    List<Map<String, dynamic>> taxConfigs;
    List<Map<String, dynamic>>? bundledItems;
    List<Map<String, dynamic>>? bundledOrders;
    try {
      final bundle = await _client.rpc(
        'get_fiscal_summary_bundle',
        params: {'_business_id': businessId, '_from': fromIso, '_to': toIso},
      );
      List<Map<String, dynamic>> asMaps(Object? v) =>
          List<Map<String, dynamic>>.from(
            (v as List? ?? const [])
                .map((e) => Map<String, dynamic>.from(e as Map)),
          );
      final m = Map<String, dynamic>.from(bundle as Map);
      rows = asMaps(m['documents']);
      taxConfigs = asMaps(m['taxes']);
      bundledItems = asMaps(m['order_items']);
      bundledOrders = asMaps(m['orders']);
    } catch (_) {
      // Fallback legacy: queries directas (el RPC no existe o falló).
      rows = List<Map<String, dynamic>>.from(
        await _client
            .from('fiscal_documents')
            .select(
              'id, order_id, payment_id, customer_id, ncf_type, ncf_number, customer_rnc, customer_name, subtotal, taxable_amount, itbis_amount, service_fee, total, status, issued_at',
            )
            .eq('business_id', businessId)
            .gte('issued_at', fromIso)
            .lt('issued_at', toIso)
            .order('issued_at', ascending: true),
      );
      taxConfigs = List<Map<String, dynamic>>.from(
        await _client
            .from(ReportsQueries.tableTaxes)
            .select('id, name, rate, is_active, is_service_fee')
            .eq('business_id', businessId),
      );
    }
    final taxNameByRate = <String, String>{};
    double configuredServiceFeeRate = 0;
    double configuredTaxOnlyRate = 0;
    // Default neutral. Si el comercio tiene un tax con is_service_fee=true,
    // sobreescribimos abajo con su nombre real. Antes default era 'Propina
    // de ley' que es DR-específico.
    String configuredServiceFeeName = 'Cargo de servicio';
    for (final t in taxConfigs) {
      final rate = _toDouble(t['rate']);
      final name = t['name']?.toString().trim() ?? '';
      if (name.isNotEmpty) {
        taxNameByRate[rate.toStringAsFixed(4)] = name;
      }
      final isService = t['is_service_fee'] == true;
      final nameLower = name.toLowerCase();
      // Heurística para detectar "propina de ley" en config legacy
      // donde el flag is_service_fee no está seteado: nombre contiene
      // alguna palabra clave + rate típico (10%). "ley" cubre el caso
      // del usuario que tiene el tax llamado solo "LEY".
      final isHeuristic = (rate - 10).abs() < 0.001 &&
          (nameLower.contains('propina') ||
              nameLower.contains('servicio') ||
              nameLower == 'ley' ||
              nameLower.contains(' ley') ||
              nameLower.startsWith('ley '));
      if (t['is_active'] == true) {
        if (isService || isHeuristic) {
          configuredServiceFeeRate = rate;
          if (name.isNotEmpty) configuredServiceFeeName = name;
        } else {
          configuredTaxOnlyRate += rate;
        }
      }
    }

    // --- Collect order IDs from active fiscal docs ---
    final activeRows = rows.where(
      (d) => (d['status']?.toString() ?? 'active') == 'active',
    );
    final orderIds = activeRows
        .map((d) => d['order_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);

    // --- Order items + orders: del bundle si vino del RPC; si no, fallback. ---
    final orderItems = bundledItems ??
        (orderIds.isEmpty
            ? <Map<String, dynamic>>[]
            : await _selectInBatches(
                table: ReportsQueries.tableOrderItems,
                select:
                    'order_id, tax, tax_rate, subtotal, total, qty, quantity, status',
                column: 'order_id',
                values: orderIds,
              ));

    final orderRows = bundledOrders ??
        (orderIds.isEmpty
            ? <Map<String, dynamic>>[]
            : await _selectInBatches(
                table: ReportsQueries.tableOrders,
                select: 'id, service_fee, status_ext',
                column: 'id',
                values: orderIds,
              ));
    final serviceFeeByOrder = <String, double>{};
    for (final o in orderRows) {
      final oid = o['id']?.toString() ?? '';
      final status = o['status_ext']?.toString().trim().toLowerCase() ?? '';
      if (status == 'void' || status == 'cancelled') continue;
      final fee = _toDouble(o['service_fee']);
      if (fee > 0 && oid.isNotEmpty) {
        serviceFeeByOrder[oid] = fee;
      }
    }

    // --- Build per-order tax breakdown ---
    // key: order_id -> list of { label, rate, taxAmount, base }
    final taxBreakdownByOrder = <String, List<Map<String, dynamic>>>{};
    // Derivado: porción de propina cuando los items vienen con
    // tax_rate combinado (28% = ITBIS+Ley). Los pagos viejos / flujos
    // que no separan la propina al guardarla la dejan baked dentro
    // del item.tax, así que la rescatamos para que la columna
    // "Propina de ley" no salga en cero cuando sí se cobró.
    final derivedServiceFeeByOrder = <String, double>{};
    for (final item in orderItems) {
      final status = item['status']?.toString();
      if (status == 'void') continue;
      final oid = item['order_id']?.toString() ?? '';
      if (oid.isEmpty) continue;

      var taxAmount = _toDouble(item['tax']);
      var taxRate = _toDouble(item['tax_rate']);
      final subtotal = _toDouble(item['subtotal']);

      if (taxRate <= 0 && taxAmount <= 0) continue;

      // Items con tax_rate ≈ configured service fee son propina baked
      // adentro de items.tax (caso legacy donde el motor viejo trataba
      // la propina como un impuesto más). La rescatamos al
      // derivedServiceFeeByOrder y NO la metemos al breakdown — si no,
      // sale como columna "LEY (10%)" duplicando "Propina de ley".
      if (configuredServiceFeeRate > 0 &&
          (taxRate - configuredServiceFeeRate).abs() < 0.01) {
        derivedServiceFeeByOrder[oid] =
            (derivedServiceFeeByOrder[oid] ?? 0) + taxAmount;
        continue;
      }

      // Detect combined rate (e.g. 28 = 18% ITBIS + 10% Ley) y partir
      // el tax_amount proporcionalmente. Antes solo cambiábamos el rate
      // a 18 pero seguíamos sumando los 28 puntos al bucket ITBIS — eso
      // inflaba ITBIS y hacía desaparecer la propina del breakdown.
      if (configuredServiceFeeRate > 0 &&
          configuredTaxOnlyRate > 0 &&
          (taxRate - configuredTaxOnlyRate - configuredServiceFeeRate).abs() <
              0.01) {
        final combined = configuredTaxOnlyRate + configuredServiceFeeRate;
        final propinaPortion =
            taxAmount * (configuredServiceFeeRate / combined);
        final itbisPortion = taxAmount - propinaPortion;
        derivedServiceFeeByOrder[oid] =
            (derivedServiceFeeByOrder[oid] ?? 0) + propinaPortion;
        taxRate = configuredTaxOnlyRate;
        taxAmount = itbisPortion;
      }

      final rateKey = taxRate.toStringAsFixed(4);
      final label =
          taxNameByRate[rateKey] ?? 'Impuesto ${taxRate.toStringAsFixed(2)}%';

      final list = taxBreakdownByOrder.putIfAbsent(oid, () => []);
      // Merge into existing bucket for same rate in same order
      final existing = list
          .where((b) => b['rate_key'] == rateKey)
          .toList(growable: false);
      if (existing.isNotEmpty) {
        existing.first['tax_amount'] =
            _toDouble(existing.first['tax_amount']) + taxAmount;
        existing.first['base'] = _toDouble(existing.first['base']) + subtotal;
      } else {
        list.add({
          'rate_key': rateKey,
          'label': label,
          'rate': taxRate,
          'tax_amount': taxAmount,
          'base': subtotal,
        });
      }
    }

    // --- Global tax type aggregation ---
    final globalTaxBreakdown = <String, Map<String, dynamic>>{};
    // ITBIS (y todo impuesto NO marcado como servicio/propina) derivado de
    // los items REALES, por orden. Sale de taxBreakdownByOrder, que ya
    // excluye la porción de servicio/LEY. Es la base config-driven del ITBIS
    // del reporte: refleja lo que de verdad se cobró por línea, así que un
    // producto exento o una venta sin impuesto simplemente no suma nada y
    // sale sin impuesto. Nunca se imputa con base × tasa.
    final derivedItbisByOrder = <String, double>{};

    for (final oid in orderIds) {
      final items = taxBreakdownByOrder[oid] ?? const [];
      var orderItbis = 0.0;
      for (final item in items) {
        final rateKey = item['rate_key'] as String;
        final bucket = globalTaxBreakdown.putIfAbsent(
          rateKey,
          () => {
            'label': item['label'],
            'rate': item['rate'],
            'tax_amount': 0.0,
            'base': 0.0,
            'count': 0,
          },
        );
        bucket['tax_amount'] =
            _toDouble(bucket['tax_amount']) + _toDouble(item['tax_amount']);
        bucket['base'] = _toDouble(bucket['base']) + _toDouble(item['base']);
        bucket['count'] = (bucket['count'] as int) + 1;
        orderItbis += _toDouble(item['tax_amount']);
      }
      if (orderItbis != 0) derivedItbisByOrder[oid] = orderItbis;
    }

    // taxBreakdownRows is built after standard aggregations so it can use
    // totalServiceFee read directly from fiscal_documents.service_fee.

    // --- Standard aggregations (all values read directly from fiscal_documents) ---
    double totalSubtotal = 0;
    double totalItbis = 0;
    double totalServiceFee = 0;
    double totalAmount = 0;
    int activeCount = 0;
    int voidCount = 0;
    final byType = <String, Map<String, dynamic>>{};

    final enrichedDocs = <Map<String, dynamic>>[];
    for (final doc in rows) {
      final status = doc['status']?.toString() ?? 'active';
      final subtotal = _toDouble(doc['subtotal']);
      final itbis = _toDouble(doc['itbis_amount']);
      final docServiceFee = _toDouble(doc['service_fee']);
      final total = _toDouble(doc['total']);
      final ncfType = doc['ncf_type']?.toString() ?? 'B02';
      final oid = doc['order_id']?.toString() ?? '';

      // --- Desglose config-driven (ITBIS vs LEY/servicio) ---
      // El split sale de lo que REALMENTE se cobró por línea (order_items.tax)
      // cruzado con la config de `taxes`, NO de fiscal_documents.itbis_amount
      // —que en muchos negocios trae el combinado (18+10) junto, o 0 cuando el
      // precio es inclusive—. Así aplica igual a negocios 18+10, solo-10 o
      // solo-18, y un producto/venta sin impuesto sale sin impuesto.
      final orderLevelServiceFee = docServiceFee > 0
          ? docServiceFee
          : (serviceFeeByOrder[oid] ?? 0);
      final derivedSvc = derivedServiceFeeByOrder[oid] ?? 0;
      final derivedItbis = derivedItbisByOrder[oid] ?? 0;
      final itemTaxTotal = derivedItbis + derivedSvc;

      double pureItbis;
      double serviceFee;
      if (itemTaxTotal > 0.005) {
        // Los items cargan el impuesto: usar el split derivado de la config.
        // Refleja exactamente lo cobrado; nada se imputa.
        pureItbis = derivedItbis;
        serviceFee = orderLevelServiceFee + derivedSvc;
      } else if (configuredServiceFeeRate > 0 &&
          configuredTaxOnlyRate > 0 &&
          subtotal > 0 &&
          (((itbis / subtotal) * 100) -
                      (configuredTaxOnlyRate + configuredServiceFeeRate))
                  .abs() <
              0.5) {
        // Sin impuesto en items, pero itbis_amount trae el combinado (28%)
        // metido junto (docs manuales/quick legacy). Lo partimos por las
        // tasas configuradas para no inflar el ITBIS con la porción de LEY.
        final combined = configuredTaxOnlyRate + configuredServiceFeeRate;
        final svcPortion = itbis * (configuredServiceFeeRate / combined);
        pureItbis = itbis - svcPortion;
        serviceFee = orderLevelServiceFee + svcPortion;
      } else {
        // Camino legacy: confiar en las columnas del documento tal cual.
        pureItbis = (itbis - derivedSvc).clamp(0.0, double.infinity);
        serviceFee = orderLevelServiceFee + derivedSvc;
      }

      // Comprobante de cortesía/comp o anulado de facto (total <= 0): no se
      // cobró nada, así que no aporta impuesto ni base. Sin esto, una orden
      // con descuento 100% (subtotales y tax negativos en los items) hace
      // que el fallback `(itbis - derivedSvc)` con derivedSvc negativo
      // fabrique ITBIS/LEY fantasma.
      if (total <= 0.005) {
        pureItbis = 0;
        serviceFee = 0;
      }

      // Base gravable consistente: total menos los impuestos resueltos.
      // Evita el sobreconteo en documentos con precio inclusive donde
      // fiscal_documents.subtotal == total. Garantiza base + itbis + ley = total.
      final taxableBase =
          (total - pureItbis - serviceFee).clamp(0.0, double.infinity);

      if (status == 'active') {
        activeCount += 1;
        totalSubtotal += taxableBase;
        totalItbis += pureItbis;
        totalServiceFee += serviceFee;
        totalAmount += total;
      } else {
        voidCount += 1;
      }

      final bucket = byType.putIfAbsent(
        ncfType,
        () => {
          'label': _ncfTypeLabel(ncfType),
          'amount': 0.0,
          'subtotal': 0.0,
          'itbis': 0.0,
          'service_fee': 0.0,
          'count': 0,
        },
      );
      if (status == 'active') {
        bucket['amount'] = _toDouble(bucket['amount']) + total;
        bucket['subtotal'] = _toDouble(bucket['subtotal']) + taxableBase;
        bucket['itbis'] = _toDouble(bucket['itbis']) + pureItbis;
        bucket['service_fee'] = _toDouble(bucket['service_fee']) + serviceFee;
        bucket['count'] = (bucket['count'] as int) + 1;
      }

      // El DETALLE por comprobante refleja los valores GUARDADOS en la DB (que
      // cuadran: subtotal + itbis_amount + service_fee = total). NO recalcular
      // el ITBIS desde items —daba un split distinto al guardado y descuadraba
      // la vista (136.72 + 26.69 + 13.67 = 177 vs total 175). La DB es la fuente
      // de verdad (corregida por la migración + backfill).
      final storedRate = configuredTaxOnlyRate > 0 ? configuredTaxOnlyRate : 18.0;
      enrichedDocs.add({
        ...doc, // conserva subtotal, itbis_amount, service_fee y total guardados
        'tax_breakdown': itbis.abs() > 0.005
            ? <Map<String, dynamic>>[
                {
                  'rate_key': storedRate.toStringAsFixed(4),
                  'label': taxNameByRate[storedRate.toStringAsFixed(4)] ?? 'ITBIS',
                  'rate': storedRate,
                  'tax_amount': itbis,
                  'base': subtotal,
                }
              ]
            : const <Map<String, dynamic>>[],
      });
    }

    final typeRows = byType.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));

    // Add service fee bucket using the fiscal_documents.service_fee total
    if (totalServiceFee > 0) {
      globalTaxBreakdown['__service_fee__'] = {
        'label': configuredServiceFeeName,
        'rate': configuredServiceFeeRate,
        'tax_amount': totalServiceFee,
        'base': configuredServiceFeeRate > 0
            ? totalServiceFee / (configuredServiceFeeRate / 100.0)
            : totalSubtotal,
        'count': activeCount,
      };
    }

    final taxBreakdownRows = globalTaxBreakdown.values.toList(growable: false)
      ..sort((a, b) =>
          _toDouble(b['tax_amount']).compareTo(_toDouble(a['tax_amount'])));

    return {
      'from': fromIso,
      'to': toIso,
      'documents_count': rows.length,
      'active_count': activeCount,
      'void_count': voidCount,
      'total_subtotal': totalSubtotal,
      'total_itbis': totalItbis,
      'total_amount': totalAmount,
      'total_service_fee': totalServiceFee,
      'service_fee_label': configuredServiceFeeName,
      'service_fee_rate': configuredServiceFeeRate,
      'by_type': typeRows,
      'tax_breakdown': taxBreakdownRows,
      'documents': enrichedDocs,
    };
  }

  // NCF label centralizado en core/fiscal/ncf_types.dart. Antes este método
  // era un switch de 30 líneas duplicado en 4 archivos.
  String _ncfTypeLabel(String type) => ncfTypeName(type);

  String _purchaseStatusLabel(String status) {
    switch (status) {
      case 'received':
        return 'Recibidas';
      case 'partial':
        return 'Parciales';
      case 'draft':
        return 'Borradores';
      case 'cancelled':
        return 'Canceladas';
      default:
        return status;
    }
  }

  Future<Map<String, dynamic>> getInventorySummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) =>
      _withOfflineCache(
        kind: 'inventory',
        businessId: businessId,
        from: from,
        to: to,
        loader: () => _getInventorySummaryOnline(
            businessId: businessId, from: from, to: to),
      );

  Future<Map<String, dynamic>> _getInventorySummaryOnline({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final items = List<Map<String, dynamic>>.from(
      await _client
          .from(ReportsQueries.tableInventoryItems)
          .select('id, sku, name, unit, cost, min_stock, max_stock, is_active')
          .eq('business_id', businessId),
    );

    final itemIds = items
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toList(growable: false);

    final stockRows = await _selectInBatches(
      table: ReportsQueries.tableInventoryStock,
      select: 'item_id, quantity',
      column: 'item_id',
      values: itemIds,
    );

    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    final movementRows = itemIds.isEmpty
        ? <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from(ReportsQueries.tableInventoryMovements)
                .select('item_id, movement_type, quantity, created_at')
                .eq('business_id', businessId)
                .gte('created_at', fromIso)
                .lt('created_at', toIso)
                .order('created_at', ascending: false)
                .limit(120),
          );

    final stockByItem = <String, double>{};
    for (final row in stockRows) {
      final itemId = row['item_id']?.toString();
      if (itemId == null || itemId.isEmpty) continue;
      stockByItem[itemId] =
          (stockByItem[itemId] ?? 0) + _toDouble(row['quantity']);
    }

    double totalUnits = 0;
    double totalStockValue = 0;
    int activeItems = 0;
    int lowStock = 0;
    int outOfStock = 0;
    final topStock = <Map<String, dynamic>>[];
    final alertItems = <Map<String, dynamic>>[];

    for (final item in items) {
      final itemId = item['id']?.toString();
      if (itemId == null || itemId.isEmpty) continue;
      final stock = stockByItem[itemId] ?? 0;
      final minStock = _toDouble(item['min_stock']);
      final cost = _toDouble(item['cost']);
      final isActive = item['is_active'] == true;
      final name = item['name']?.toString() ?? 'Insumo';
      final unit = item['unit']?.toString() ?? 'unidad';

      totalUnits += stock;
      totalStockValue += stock * cost;
      if (isActive) activeItems += 1;
      if (stock <= 0) {
        outOfStock += 1;
      } else if (minStock > 0 && stock <= minStock) {
        lowStock += 1;
      }

      topStock.add({
        'label': name,
        'amount': stock,
        'quantity': stock,
        'count': 1,
        'unit': unit,
      });

      if (stock <= 0 || (minStock > 0 && stock <= minStock)) {
        alertItems.add({
          'label': name,
          'amount': stock,
          'quantity': minStock,
          'count': stock <= 0 ? 0 : 1,
          'unit': unit,
        });
      }
    }

    topStock.sort(
      (a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])),
    );
    alertItems.sort((a, b) {
      final aOut = _toDouble(a['amount']) <= 0 ? 1 : 0;
      final bOut = _toDouble(b['amount']) <= 0 ? 1 : 0;
      if (aOut != bOut) return bOut.compareTo(aOut);
      return _toDouble(a['amount']).compareTo(_toDouble(b['amount']));
    });

    final movementBuckets = <String, Map<String, dynamic>>{};
    for (final row in movementRows) {
      final type = row['movement_type']?.toString() ?? 'adjustment';
      final qty = _toDouble(row['quantity']).abs();
      final bucket = movementBuckets.putIfAbsent(
        type,
        () => {
          'label': _inventoryMovementLabel(type),
          'amount': 0.0,
          'count': 0,
        },
      );
      bucket['amount'] = _toDouble(bucket['amount']) + qty;
      bucket['count'] = (bucket['count'] as int) + 1;
    }

    final movementSummary = movementBuckets.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));

    return {
      'from': fromIso,
      'to': toIso,
      'items_count': items.length,
      'active_items_count': activeItems,
      'total_units': totalUnits,
      'total_stock_value': totalStockValue,
      'low_stock_count': lowStock,
      'out_of_stock_count': outOfStock,
      'top_stock_items': topStock.take(8).toList(growable: false),
      'alert_items': alertItems.take(8).toList(growable: false),
      'movement_summary': movementSummary,
    };
  }

  String _inventoryMovementLabel(String type) {
    switch (type) {
      case 'purchase':
        return 'Compras';
      case 'sale':
        return 'Ventas';
      case 'adjustment':
        return 'Ajustes';
      case 'waste':
        return 'Mermas';
      case 'transfer':
        return 'Transferencias';
      default:
        return type;
    }
  }

  /// Proyección de cantidades vendidas por producto para el mes en curso.
  ///
  /// Algoritmo: 8 semanas (56 días) de ventas pagadas como base, agrupado
  /// por día de la semana — los restaurantes tienen patrones fuertes
  /// (lunes flojo, viernes alto). Proyecta cada día del mes con el
  /// promedio histórico del DOW correspondiente.
  ///
  /// Usa RPC `get_monthly_product_projection_v2` que hace toda la
  /// agregación server-side (~25ms vs varios segundos del approach
  /// anterior con múltiples queries + cálculo en Dart).
  ///
  /// Retorna `Map<productId, projectedQty>`. Productos sin historial
  /// no aparecen en el map.
  Future<Map<String, double>> getMonthlyProductProjection({
    required String businessId,
  }) async {
    final response = await _client.rpc(
      'get_monthly_product_projection_v2',
      params: {'_business_id': businessId},
    );

    if (response == null) return const {};

    final map = Map<String, dynamic>.from(response as Map);
    return map.map((key, value) => MapEntry(key, _toDouble(value)));
  }
}
