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
          'id, amount, change_amount, order_id, status, created_at, payment_method_id, payment_methods(name, code)',
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
      select: 'order_id, product_name, quantity, qty, total, status',
      column: 'order_id',
      values: orderIds,
    );

    double totalItems = 0;
    final topProducts = <String, Map<String, dynamic>>{};
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
    }

    final byMethod = <String, Map<String, dynamic>>{};
    final byHour = <int, Map<String, dynamic>>{};

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

    final avgTicket = completedPayments.isEmpty
        ? 0.0
        : totalSales / completedPayments.length;

    final salesByMethod = byMethod.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));
    final salesByHour = byHour.values.toList(growable: false)
      ..sort((a, b) => (a['hour'] as int).compareTo(b['hour'] as int));
    final topProductsList = topProducts.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));

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
      'sales_by_method': salesByMethod.take(6).toList(growable: false),
      'sales_by_hour': salesByHour,
      'top_products': topProductsList.take(8).toList(growable: false),
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
          'id, start_amount, end_amount, difference, status, opened_at, closed_at, cash_registers!inner(business_id)',
        )
        .eq('cash_registers.business_id', businessId)
        .gte('opened_at', fromIso)
        .lt('opened_at', toIso);

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
      select: 'amount, type, created_at',
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
