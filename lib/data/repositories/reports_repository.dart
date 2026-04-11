import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/app_time.dart';
import '../datasources/queries/reports_queries.dart';
import '../utils/payment_amount_utils.dart';

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

    final paymentRows = List<Map<String, dynamic>>.from(
      await _client
          .from(ReportsQueries.tablePayments)
          .select(select)
          .gte('created_at', fromIso)
          .lt('created_at', toIso),
    );

    final orderIds = paymentRows
        .map((row) => row['order_id']?.toString().trim())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);

    if (orderIds.isEmpty) return const <Map<String, dynamic>>[];

    final scopedOrders = await _selectInBatches(
      table: ReportsQueries.tableOrders,
      select: 'id, table_sessions!inner(business_id)',
      column: 'id',
      values: orderIds,
    );

    final allowedOrderIds = scopedOrders
        .where((row) {
          final tableSession = row['table_sessions'];
          final sessionMap = tableSession is Map<String, dynamic>
              ? tableSession
              : (tableSession is Map
                    ? Map<String, dynamic>.from(tableSession)
                    : const <String, dynamic>{});
          return sessionMap['business_id']?.toString() == businessId;
        })
        .map((row) => row['id']?.toString().trim())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();

    return paymentRows
        .where(
          (row) => allowedOrderIds.contains(row['order_id']?.toString().trim()),
        )
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> getSalesSummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);
    final paymentRows = await _loadScopedPaymentsForRange(
      businessId: businessId,
      from: from,
      to: to,
      select:
          'id, amount, change_amount, order_id, check_id, fiscal_document_id, status, created_at, payment_method_id, payment_methods(name, code)',
    );
    final completedPayments = paymentRows
        .where((row) => row['status'] == 'completed' || row['status'] == null)
        .toList(growable: false);
    final voidedPayments = paymentRows
        .where((row) => row['status'] == 'void' || row['status'] == 'cancelled')
        .toList(growable: false);

    double totalSales = 0;
    for (final payment in completedPayments) {
      totalSales += netPaymentAmount(
        payment['amount'],
        payment['change_amount'],
      );
    }

    double voidedSales = 0;
    for (final payment in voidedPayments) {
      voidedSales += netPaymentAmount(
        payment['amount'],
        payment['change_amount'],
      );
    }

    final orderIds = completedPayments
        .map((row) => row['order_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final items = await _selectInBatches(
      table: ReportsQueries.tableOrderItems,
      select:
          'id, order_id, check_id, product_name, quantity, qty, subtotal, discounts, tax, total, status, product_id, notes',
      column: 'order_id',
      values: orderIds,
    );

    final itemById = <String, Map<String, dynamic>>{};
    for (final item in items) {
      final itemId = item['id']?.toString();
      if (itemId != null && itemId.isNotEmpty) {
        itemById[itemId] = item;
      }
    }

    final itemIds = itemById.keys.toList(growable: false);
    final modifierRows = await _selectInBatches(
      table: 'order_item_modifiers',
      select: 'item_id, name, qty, price',
      column: 'item_id',
      values: itemIds,
    );

    final checkIds = completedPayments
        .map((row) => row['check_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final checkRows = await _selectInBatches(
      table: 'order_checks',
      select: 'id, order_id, label, position',
      column: 'id',
      values: checkIds,
    );
    final checkById = <String, Map<String, dynamic>>{
      for (final row in checkRows)
        if ((row['id']?.toString() ?? '').isNotEmpty) row['id'].toString(): row,
    };
    final checksCountByOrder = <String, int>{};
    for (final row in checkRows) {
      final orderId = row['order_id']?.toString() ?? '';
      if (orderId.isEmpty) continue;
      checksCountByOrder[orderId] = (checksCountByOrder[orderId] ?? 0) + 1;
    }

    final fiscalDocumentIds = completedPayments
        .map((row) => row['fiscal_document_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final fiscalRows = await _selectInBatches(
      table: 'fiscal_documents',
      select: 'id, ncf_type, ncf_number, status',
      column: 'id',
      values: fiscalDocumentIds,
    );
    final fiscalById = <String, Map<String, dynamic>>{
      for (final row in fiscalRows)
        if ((row['id']?.toString() ?? '').isNotEmpty) row['id'].toString(): row,
    };

    String receiptLabelForPayment(Map<String, dynamic> payment) {
      final fiscalId = payment['fiscal_document_id']?.toString() ?? '';
      if (fiscalId.isNotEmpty) {
        final doc = fiscalById[fiscalId];
        final ncfType = doc?['ncf_type']?.toString() ?? 'Comprobante fiscal';
        return _ncfTypeLabel(ncfType);
      }

      final checkId = payment['check_id']?.toString() ?? '';
      if (checkId.isNotEmpty) {
        final check = checkById[checkId];
        final orderId = payment['order_id']?.toString() ?? '';
        final hasSplit = (checksCountByOrder[orderId] ?? 0) > 1;
        final baseLabel = hasSplit ? 'Recibo dividido' : 'Recibo de cuenta';
        final checkLabel = check?['label']?.toString().trim() ?? '';
        return checkLabel.isNotEmpty ? '$baseLabel · $checkLabel' : baseLabel;
      }

      return 'Recibo estándar';
    }

    String adjustmentLabelForItem(Map<String, dynamic> item) {
      final notes = item['notes']?.toString() ?? '';
      final lineGross = _toDouble(item['subtotal']) + _toDouble(item['tax']);
      final discount = _toDouble(item['discounts']);
      final isCourtesy =
          notes.contains('[CORTESIA:') ||
          (lineGross > 0 && discount >= lineGross - 0.01);
      if (isCourtesy) return 'Cortesías';
      if (notes.contains('[PROMO_AUTO:')) return 'Promociones automáticas';
      return 'Descuentos manuales';
    }

    // Collect unique product_ids to look up their categories
    final productIds = items
        .map((i) => i['product_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final categoryByProductId = <String, String>{};
    final productCostById = <String, double>{};
    if (productIds.isNotEmpty) {
      final menuItems = await _selectInBatches(
        table: 'menu_items',
        select: 'id, category_id, cost, categories(name)',
        column: 'id',
        values: productIds,
      );
      for (final mi in menuItems) {
        final pid = mi['id']?.toString() ?? '';
        final cat = mi['categories'];
        final catMap = cat is Map<String, dynamic>
            ? cat
            : (cat is Map
                  ? Map<String, dynamic>.from(cat)
                  : <String, dynamic>{});
        final catName = catMap['name']?.toString().trim();
        if (pid.isNotEmpty) {
          productCostById[pid] = _toDouble(mi['cost']);
        }
        if (pid.isNotEmpty && catName != null && catName.isNotEmpty) {
          categoryByProductId[pid] = catName;
        }
      }
    }

    double totalItems = 0;
    double modifiersSalesTotal = 0;
    double discountsTotal = 0;
    double courtesyTotal = 0;
    int discountedLinesCount = 0;
    int courtesyLinesCount = 0;

    final topProducts = <String, Map<String, dynamic>>{};
    final productSales = <String, Map<String, dynamic>>{};
    final byCategory = <String, Map<String, dynamic>>{};
    final byModifier = <String, Map<String, dynamic>>{};
    final byAdjustment = <String, Map<String, dynamic>>{};

    for (final item in items) {
      final status = item['status']?.toString();
      if (status == 'void') continue;

      final qty = _toDouble(item['qty'] ?? item['quantity']);
      totalItems += qty;

      final label = item['product_name']?.toString().trim().isNotEmpty == true
          ? item['product_name'].toString().trim()
          : 'Producto sin nombre';
      final bucket = topProducts.putIfAbsent(
        label,
        () => {'label': label, 'amount': 0.0, 'quantity': 0.0, 'count': 0},
      );
      bucket['amount'] = _toDouble(bucket['amount']) + _toDouble(item['total']);
      bucket['quantity'] = _toDouble(bucket['quantity']) + qty;
      bucket['count'] = (bucket['count'] as int) + 1;

      final productId = item['product_id']?.toString() ?? '';
      final categoryName = categoryByProductId[productId] ?? 'Sin categoría';
      final discount = _toDouble(item['discounts']);
      final adjustmentLabel =
          discount > 0.009 ? adjustmentLabelForItem(item) : null;
      final courtesyAmount = adjustmentLabel == 'Cortesías' ? discount : 0.0;
      final itemGrossSales = _toDouble(item['subtotal']) + _toDouble(item['tax']);
      final itemNetSales = _toDouble(item['total']);
      final itemCost = (productCostById[productId] ?? 0) * qty;
      final productKey = productId.isNotEmpty ? productId : label;
      final productBucket = productSales.putIfAbsent(
        productKey,
        () => {
          'product': label,
          'category': categoryName,
          'quantity_sold': 0.0,
          'gross_sales': 0.0,
          'discounts': 0.0,
          'courtesies': 0.0,
          'net_sales': 0.0,
          'cost': 0.0,
          'gross_profit': 0.0,
          'tickets': 0,
        },
      );
      productBucket['quantity_sold'] =
          _toDouble(productBucket['quantity_sold']) + qty;
      productBucket['gross_sales'] =
          _toDouble(productBucket['gross_sales']) + itemGrossSales;
      productBucket['discounts'] =
          _toDouble(productBucket['discounts']) + discount;
      productBucket['courtesies'] =
          _toDouble(productBucket['courtesies']) + courtesyAmount;
      productBucket['net_sales'] =
          _toDouble(productBucket['net_sales']) + itemNetSales;
      productBucket['cost'] = _toDouble(productBucket['cost']) + itemCost;
      productBucket['gross_profit'] =
          _toDouble(productBucket['gross_profit']) + (itemNetSales - itemCost);
      productBucket['tickets'] = (productBucket['tickets'] as int) + 1;

      final catBucket = byCategory.putIfAbsent(
        categoryName,
        () => {
          'label': categoryName,
          'amount': 0.0,
          'quantity': 0.0,
          'count': 0,
        },
      );
      catBucket['amount'] =
          _toDouble(catBucket['amount']) + _toDouble(item['total']);
      catBucket['quantity'] = _toDouble(catBucket['quantity']) + qty;
      catBucket['count'] = (catBucket['count'] as int) + 1;

      if (discount > 0.009) {
        discountsTotal += discount;
        discountedLinesCount += 1;
        if (adjustmentLabel == 'Cortesías') {
          courtesyTotal += discount;
          courtesyLinesCount += 1;
        }
        final adjustmentBucket = byAdjustment.putIfAbsent(
          adjustmentLabel ?? 'Ajuste',
          () => {
            'label': adjustmentLabel ?? 'Ajuste',
            'amount': 0.0,
            'quantity': 0.0,
            'count': 0,
          },
        );
        adjustmentBucket['amount'] =
            _toDouble(adjustmentBucket['amount']) + discount;
        adjustmentBucket['quantity'] =
            _toDouble(adjustmentBucket['quantity']) + qty;
        adjustmentBucket['count'] = (adjustmentBucket['count'] as int) + 1;
      }
    }

    for (final modifier in modifierRows) {
      final itemId = modifier['item_id']?.toString() ?? '';
      final item = itemById[itemId];
      if (item == null || item['status']?.toString() == 'void') continue;

      final label = modifier['name']?.toString().trim().isNotEmpty == true
          ? modifier['name'].toString().trim()
          : 'Modificador';
      final qty = _toDouble(modifier['qty']);
      final amount = _toDouble(modifier['price']) * qty;
      modifiersSalesTotal += amount;

      final bucket = byModifier.putIfAbsent(
        label,
        () => {'label': label, 'amount': 0.0, 'quantity': 0.0, 'count': 0},
      );
      bucket['amount'] = _toDouble(bucket['amount']) + amount;
      bucket['quantity'] = _toDouble(bucket['quantity']) + qty;
      bucket['count'] = (bucket['count'] as int) + 1;
    }

    final byMethod = <String, Map<String, dynamic>>{};
    final byHour = <int, Map<String, dynamic>>{};
    final byReceipt = <String, Map<String, dynamic>>{};

    for (final payment in completedPayments) {
      final method = payment['payment_methods'];
      final methodMap = method is Map<String, dynamic>
          ? method
          : (method is Map
                ? Map<String, dynamic>.from(method)
                : <String, dynamic>{});
      final code =
          methodMap['code']?.toString() ??
          payment['payment_method_id']?.toString() ??
          'other';
      final label = methodMap['name']?.toString() ?? code;
      final amount = netPaymentAmount(
        payment['amount'],
        payment['change_amount'],
      );

      final methodBucket = byMethod.putIfAbsent(
        code,
        () => {'label': label, 'amount': 0.0, 'count': 0},
      );
      methodBucket['amount'] = _toDouble(methodBucket['amount']) + amount;
      methodBucket['count'] = (methodBucket['count'] as int) + 1;

      final receiptLabel = receiptLabelForPayment(payment);
      final receiptBucket = byReceipt.putIfAbsent(
        receiptLabel,
        () => {'label': receiptLabel, 'amount': 0.0, 'count': 0},
      );
      receiptBucket['amount'] = _toDouble(receiptBucket['amount']) + amount;
      receiptBucket['count'] = (receiptBucket['count'] as int) + 1;

      final createdAt = DateTime.tryParse(
        payment['created_at']?.toString() ?? '',
      );
      if (createdAt != null) {
        final hour = AppTime.astFromInstant(createdAt).hour;
        final hourBucket = byHour.putIfAbsent(
          hour,
          () => {
            'label': '${hour.toString().padLeft(2, '0')}:00',
            'amount': 0.0,
            'count': 0,
            'hour': hour,
          },
        );
        hourBucket['amount'] = _toDouble(hourBucket['amount']) + amount;
        hourBucket['count'] = (hourBucket['count'] as int) + 1;
      }
    }

    final amountByOrder = <String, double>{};
    for (final payment in completedPayments) {
      final oid = payment['order_id']?.toString() ?? '';
      if (oid.isEmpty) continue;
      amountByOrder[oid] =
          (amountByOrder[oid] ?? 0.0) +
          netPaymentAmount(payment['amount'], payment['change_amount']);
    }

    final orderSessionRows = await _selectInBatches(
      table: ReportsQueries.tableOrders,
      select:
          'id, session_id, table_sessions!inner(waiter_user_id, profiles!table_sessions_waiter_user_id_profiles_fkey(full_name), dining_tables!left(zones!left(name)))',
      column: 'id',
      values: orderIds,
    );

    final byEmployee = <String, Map<String, dynamic>>{};
    final byZone = <String, Map<String, dynamic>>{};
    for (final row in orderSessionRows) {
      final oid = row['id']?.toString() ?? '';
      final amount = amountByOrder[oid] ?? 0.0;
      if (amount == 0) continue;

      final session = row['table_sessions'];
      final sessionMap = session is Map<String, dynamic>
          ? session
          : (session is Map
                ? Map<String, dynamic>.from(session)
                : <String, dynamic>{});

      final profile = sessionMap['profiles'];
      final profileMap = profile is Map<String, dynamic>
          ? profile
          : (profile is Map
                ? Map<String, dynamic>.from(profile)
                : <String, dynamic>{});
      final empName =
          profileMap['full_name']?.toString().trim().isNotEmpty == true
          ? profileMap['full_name'].toString().trim()
          : 'Sin empleado';
      final empBucket = byEmployee.putIfAbsent(
        empName,
        () => {'label': empName, 'amount': 0.0, 'count': 0},
      );
      empBucket['amount'] = _toDouble(empBucket['amount']) + amount;
      empBucket['count'] = (empBucket['count'] as int) + 1;

      final table = sessionMap['dining_tables'];
      final tableMap = table is Map<String, dynamic>
          ? table
          : (table is Map
                ? Map<String, dynamic>.from(table)
                : <String, dynamic>{});
      final zone = tableMap['zones'];
      final zoneMap = zone is Map<String, dynamic>
          ? zone
          : (zone is Map
                ? Map<String, dynamic>.from(zone)
                : <String, dynamic>{});
      final zoneName = zoneMap['name']?.toString().trim().isNotEmpty == true
          ? zoneMap['name'].toString().trim()
          : 'Sin zona';
      final zoneBucket = byZone.putIfAbsent(
        zoneName,
        () => {'label': zoneName, 'amount': 0.0, 'count': 0},
      );
      zoneBucket['amount'] = _toDouble(zoneBucket['amount']) + amount;
      zoneBucket['count'] = (zoneBucket['count'] as int) + 1;
    }

    final avgTicket = completedPayments.isEmpty
        ? 0.0
        : totalSales / completedPayments.length;

    final salesByMethod = byMethod.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));
    final salesByReceipt = byReceipt.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));
    final salesByHour = byHour.values.toList(growable: false)
      ..sort((a, b) => (a['hour'] as int).compareTo(b['hour'] as int));
    final salesByModifier = byModifier.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));
    final salesByAdjustment = byAdjustment.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));
    final topProductsList = topProducts.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));
    final productSalesList = productSales.values.toList(growable: false)
      ..sort(
        (a, b) => _toDouble(b['net_sales']).compareTo(_toDouble(a['net_sales'])),
      );

    return {
      'from': fromIso,
      'to': toIso,
      'total_sales': totalSales,
      'voided_sales': voidedSales,
      'net_sales': totalSales - voidedSales,
      'payments_count': completedPayments.length,
      'voided_payments_count': voidedPayments.length,
      'items_sold': totalItems.round(),
      'avg_ticket': avgTicket,
      'modifier_sales_total': modifiersSalesTotal,
      'discounts_total': discountsTotal,
      'courtesy_total': courtesyTotal,
      'discounted_lines_count': discountedLinesCount,
      'courtesy_lines_count': courtesyLinesCount,
      'sales_by_method': salesByMethod,
      'sales_by_receipt': salesByReceipt,
      'sales_by_hour': salesByHour,
      'sales_by_modifier': salesByModifier,
      'sales_by_adjustment': salesByAdjustment,
      'top_products': topProductsList,
      'product_sales': productSalesList,
      'sales_by_category': byCategory.values.toList(growable: false)
        ..sort(
          (a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])),
        ),
      'sales_by_employee': byEmployee.values.toList(growable: false)
        ..sort(
          (a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])),
        ),
      'sales_by_zone': byZone.values.toList(growable: false)
        ..sort(
          (a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])),
        ),
    };
  }

  Future<Map<String, dynamic>> getCashSummary({
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
      final difference = session['difference'];
      final status = session['status']?.toString();

      if (startAmount is num) openingsTotal += startAmount.toDouble();
      if (endAmount is num) closingsTotal += endAmount.toDouble();
      if (difference is num) differencesTotal += difference.toDouble();
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
      select: 'session_id, amount, type, created_at',
      column: 'session_id',
      values: sessionIds,
      transform: (query) =>
          query.gte('created_at', fromIso).lt('created_at', toIso),
    );

    double manualIn = 0;
    double manualOut = 0;
    double salesTotal = 0;
    double expensesTotal = 0;
    double withdrawalsTotal = 0;
    final byType = <String, Map<String, dynamic>>{};

    for (final tx in transactions) {
      final amount = tx['amount'];
      final type = tx['type']?.toString() ?? 'other';
      final normalized = _toDouble(amount);

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
          'difference': difference,
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
          'is_balanced': difference.abs() < 0.009,
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
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    final taxes = List<Map<String, dynamic>>.from(
      await _client
          .from(ReportsQueries.tableTaxes)
          .select('id, name, rate, is_active')
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
      select:
          'order_id, product_name, qty, quantity, subtotal, total, tax, tax_rate, tax_mode, status',
      column: 'order_id',
      values: completedOrderIds,
    );
    final orders = await _selectInBatches(
      table: ReportsQueries.tableOrders,
      select: 'id, subtotal, service_fee, total, status_ext',
      column: 'id',
      values: completedOrderIds,
    );

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

    for (final item in items) {
      final status = item['status']?.toString();
      if (status == 'void') continue;

      final taxAmount = _toDouble(item['tax']);
      final taxRate = _toDouble(item['tax_rate']);
      final subtotal = _toDouble(item['subtotal']);
      final total = _toDouble(item['total']);
      final qty = _toDouble(item['qty'] ?? item['quantity']);

      grossSalesWithTax += total;
      totalQuantity += qty;

      if (taxRate <= 0 || taxAmount <= 0) {
        exemptSales += subtotal;
        continue;
      }

      taxableSales += subtotal;
      totalTaxCollected += taxAmount;

      final rateKey = taxRate.toStringAsFixed(4);
      final taxConfig = taxesByRate[rateKey];
      final label = taxConfig?['name']?.toString().trim().isNotEmpty == true
          ? taxConfig!['name'].toString().trim()
          : 'Impuesto ${taxRate.toStringAsFixed(2)}%';

      final bucket = breakdown.putIfAbsent(
        rateKey,
        () => {
          'label': label,
          'rate': taxRate,
          'amount': 0.0,
          'taxable_amount': 0.0,
          'gross_amount': 0.0,
          'quantity': 0.0,
          'count': 0,
        },
      );
      bucket['amount'] = _toDouble(bucket['amount']) + taxAmount;
      bucket['taxable_amount'] = _toDouble(bucket['taxable_amount']) + subtotal;
      bucket['gross_amount'] = _toDouble(bucket['gross_amount']) + total;
      bucket['quantity'] = _toDouble(bucket['quantity']) + qty;
      bucket['count'] = (bucket['count'] as int) + 1;
    }

    for (final order in orders) {
      final status = order['status_ext']?.toString().trim().toLowerCase();
      if (status == 'void' || status == 'cancelled') continue;

      final serviceFee = _toDouble(order['service_fee']);
      if (serviceFee <= 0) continue;

      totalServiceFee += serviceFee;
      serviceFeeOrdersCount += 1;

      final inferredBase = serviceFeeEnabled && serviceFeeRate > 0
          ? serviceFee / (serviceFeeRate / 100.0)
          : _toDouble(order['subtotal']);
      serviceFeeBaseTotal += inferredBase;
    }

    if (totalServiceFee > 0) {
      final serviceRate = serviceFeeEnabled ? serviceFeeRate : 0.0;
      breakdown['__service_fee__'] = {
        'label': 'Propina de ley',
        'rate': serviceRate,
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

    final effectiveRate = taxableSales <= 0
        ? 0.0
        : (totalTaxCollected / taxableSales) * 100;
    final totalChargesCollected = totalTaxCollected + totalServiceFee;

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
      'gross_sales': grossSalesWithTax,
      'taxable_sales': taxableSales,
      'exempt_sales': exemptSales,
      'total_tax_collected': totalTaxCollected,
      'total_service_fee': totalServiceFee,
      'service_fee_rate': serviceFeeRate,
      'service_fee_orders_count': serviceFeeOrdersCount,
      'service_fee_base_total': serviceFeeBaseTotal,
      'total_charges_collected': totalChargesCollected,
      'effective_tax_rate': effectiveRate,
      'tax_breakdown': breakdownRows,
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
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    final rows = List<Map<String, dynamic>>.from(
      await _client
          .from('fiscal_documents')
          .select(
            'id, order_id, payment_id, customer_id, ncf_type, ncf_number, customer_rnc, customer_name, subtotal, taxable_amount, itbis_amount, total, status, issued_at',
          )
          .eq('business_id', businessId)
          .gte('issued_at', fromIso)
          .lt('issued_at', toIso)
          .order('issued_at', ascending: true),
    );

    // --- Fetch configured taxes for label lookup ---
    final taxConfigs = List<Map<String, dynamic>>.from(
      await _client
          .from(ReportsQueries.tableTaxes)
          .select('id, name, rate, is_active')
          .eq('business_id', businessId),
    );
    final taxNameByRate = <String, String>{};
    for (final t in taxConfigs) {
      final rate = _toDouble(t['rate']);
      final name = t['name']?.toString().trim() ?? '';
      if (name.isNotEmpty) {
        taxNameByRate[rate.toStringAsFixed(4)] = name;
      }
    }

    // --- Fetch service fee config ---
    final businessSettings = await _client
        .from('business_settings')
        .select('service_fee_enabled, service_fee_rate')
        .eq('business_id', businessId)
        .maybeSingle();
    final serviceFeeEnabled = businessSettings?['service_fee_enabled'] == true;
    final serviceFeeRate = _toDouble(
      businessSettings?['service_fee_rate'],
    ).clamp(0, 100);

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

    // --- Fetch order items (tax_rate, tax, subtotal) for those orders ---
    final orderItems = orderIds.isEmpty
        ? <Map<String, dynamic>>[]
        : await _selectInBatches(
            table: ReportsQueries.tableOrderItems,
            select:
                'order_id, tax, tax_rate, subtotal, total, qty, quantity, status',
            column: 'order_id',
            values: orderIds,
          );

    // --- Fetch orders for service_fee ---
    final orderRows = orderIds.isEmpty
        ? <Map<String, dynamic>>[]
        : await _selectInBatches(
            table: ReportsQueries.tableOrders,
            select: 'id, service_fee, status_ext',
            column: 'id',
            values: orderIds,
          );
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
    for (final item in orderItems) {
      final status = item['status']?.toString();
      if (status == 'void') continue;
      final oid = item['order_id']?.toString() ?? '';
      if (oid.isEmpty) continue;

      final taxAmount = _toDouble(item['tax']);
      final taxRate = _toDouble(item['tax_rate']);
      final subtotal = _toDouble(item['subtotal']);

      if (taxRate <= 0 && taxAmount <= 0) continue;

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
    double totalServiceFee = 0;

    for (final oid in orderIds) {
      // Tax items
      final items = taxBreakdownByOrder[oid] ?? const [];
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
      }

      // Service fee
      final fee = serviceFeeByOrder[oid] ?? 0;
      if (fee > 0) {
        totalServiceFee += fee;
      }
    }

    // Add service fee as a tax type in the global breakdown
    if (totalServiceFee > 0) {
      final sfLabel = serviceFeeEnabled
          ? 'Propina de ley (${serviceFeeRate.toStringAsFixed(0)}%)'
          : 'Propina de ley';
      globalTaxBreakdown['__service_fee__'] = {
        'label': sfLabel,
        'rate': serviceFeeRate,
        'tax_amount': totalServiceFee,
        'base': serviceFeeRate > 0
            ? totalServiceFee / (serviceFeeRate / 100.0)
            : 0.0,
        'count': serviceFeeByOrder.length,
      };
    }

    final taxBreakdownRows = globalTaxBreakdown.values.toList(growable: false)
      ..sort(
        (a, b) =>
            _toDouble(b['tax_amount']).compareTo(_toDouble(a['tax_amount'])),
      );

    // --- Standard aggregations ---
    double totalSubtotal = 0;
    double totalItbis = 0;
    double totalAmount = 0;
    int activeCount = 0;
    int voidCount = 0;
    final byType = <String, Map<String, dynamic>>{};

    // Enrich each document with its per-order tax breakdown
    final enrichedDocs = <Map<String, dynamic>>[];
    for (final doc in rows) {
      final status = doc['status']?.toString() ?? 'active';
      final subtotal = _toDouble(doc['subtotal']);
      final itbis = _toDouble(doc['itbis_amount']);
      final total = _toDouble(doc['total']);
      final ncfType = doc['ncf_type']?.toString() ?? 'B02';
      final oid = doc['order_id']?.toString() ?? '';

      if (status == 'active') {
        activeCount += 1;
        totalSubtotal += subtotal;
        totalItbis += itbis;
        totalAmount += total;
      } else {
        voidCount += 1;
      }

      final bucket = byType.putIfAbsent(
        ncfType,
        () => {
          'label': _ncfTypeLabel(ncfType),
          'amount': 0.0,
          'itbis': 0.0,
          'count': 0,
        },
      );
      if (status == 'active') {
        bucket['amount'] = _toDouble(bucket['amount']) + total;
        bucket['itbis'] = _toDouble(bucket['itbis']) + itbis;
        bucket['count'] = (bucket['count'] as int) + 1;
      }

      // Attach per-doc tax breakdown + service fee
      final docTaxes = taxBreakdownByOrder[oid] ?? const [];
      final docServiceFee = serviceFeeByOrder[oid] ?? 0.0;
      enrichedDocs.add({
        ...doc,
        'tax_breakdown': docTaxes,
        'service_fee': docServiceFee,
      });
    }

    final typeRows = byType.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));

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
      'by_type': typeRows,
      'tax_breakdown': taxBreakdownRows,
      'documents': enrichedDocs,
    };
  }

  String _ncfTypeLabel(String type) {
    switch (type) {
      case 'B01':
      case 'E31':
        return 'Crédito Fiscal';
      case 'B02':
      case 'E32':
        return 'Consumo';
      case 'B03':
      case 'E33':
        return 'Nota de Débito';
      case 'B04':
      case 'E34':
        return 'Nota de Crédito';
      case 'B11':
      case 'E41':
        return 'Compras';
      case 'B13':
      case 'E43':
        return 'Gastos Menores';
      case 'B14':
      case 'E44':
        return 'Regímenes Especiales';
      case 'B15':
      case 'E45':
        return 'Gubernamental';
      case 'B16':
      case 'E46':
        return 'Exportaciones';
      default:
        return type;
    }
  }

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
}
