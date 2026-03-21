import 'package:supabase_flutter/supabase_flutter.dart';

import '../datasources/queries/reports_queries.dart';

class ReportsRepository {
  final SupabaseClient _client;

  ReportsRepository(this._client);

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<Map<String, dynamic>> getSalesSummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromIso = from.toUtc().toIso8601String();
    final toIso = to.toUtc().toIso8601String();

    final payments = await _client
        .from(ReportsQueries.tablePayments)
        .select('id, amount, order_id, status, created_at')
        .eq('business_id', businessId)
        .gte('created_at', fromIso)
        .lt('created_at', toIso);

    final validPayments = List<Map<String, dynamic>>.from(payments)
        .where((row) => row['status'] == 'completed' || row['status'] == null)
        .toList(growable: false);

    double totalSales = 0;
    for (final payment in validPayments) {
      final amount = payment['amount'];
      totalSales += _toDouble(amount);
    }

    final orderIds = validPayments
        .map((row) => row['order_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final items = orderIds.isEmpty
        ? <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from(ReportsQueries.tableOrderItems)
                .select('quantity, total, status')
                .inFilter('order_id', orderIds),
          );

    int totalItems = 0;
    for (final item in items) {
      final status = item['status']?.toString();
      if (status == 'void') continue;
      final qty = item['quantity'];
      if (qty is num) {
        totalItems += qty.round();
      } else if (qty is String) {
        totalItems += (double.tryParse(qty)?.round() ?? 0);
      }
    }

    return {
      'from': fromIso,
      'to': toIso,
      'total_sales': totalSales,
      'payments_count': validPayments.length,
      'items_sold': totalItems,
    };
  }

  Future<Map<String, dynamic>> getCashSummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromIso = from.toUtc().toIso8601String();
    final toIso = to.toUtc().toIso8601String();

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

    for (final session in sessionRows) {
      final startAmount = session['start_amount'];
      final endAmount = session['end_amount'];
      final difference = session['difference'];

      if (startAmount is num) openingsTotal += startAmount.toDouble();
      if (endAmount is num) closingsTotal += endAmount.toDouble();
      if (difference is num) differencesTotal += difference.toDouble();
    }

    final sessionIds = sessionRows
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final transactions = sessionIds.isEmpty
        ? <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from(ReportsQueries.tableCashTransactions)
                .select('amount, type, created_at')
                .inFilter('session_id', sessionIds)
                .gte('created_at', fromIso)
                .lt('created_at', toIso),
          );

    double manualIn = 0;
    double manualOut = 0;
    for (final tx in transactions) {
      final amount = tx['amount'];
      final type = tx['type']?.toString();
      final normalized = _toDouble(amount);

      if (type == 'deposit' || type == 'income') {
        manualIn += normalized;
      }
      if (type == 'withdrawal' || type == 'expense') {
        manualOut += normalized;
      }
    }

    return {
      'from': fromIso,
      'to': toIso,
      'sessions_count': sessionRows.length,
      'openings_total': openingsTotal,
      'closings_total': closingsTotal,
      'differences_total': differencesTotal,
      'manual_in_total': manualIn,
      'manual_out_total': manualOut,
    };
  }

  Future<Map<String, dynamic>> getPurchasesSummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromIso = from.toUtc().toIso8601String();
    final toIso = to.toUtc().toIso8601String();

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
          .select('id')
          .eq('business_id', businessId)
          .eq('is_active', true),
    );

    double totalOrdered = 0;
    double totalReceived = 0;
    int receivedCount = 0;
    int partialCount = 0;
    int draftCount = 0;

    for (final order in orders) {
      final total = _toDouble(order['total']);
      final status = order['status']?.toString() ?? 'draft';
      totalOrdered += total;

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

    return {
      'from': fromIso,
      'to': toIso,
      'orders_count': orders.length,
      'suppliers_count': suppliers.length,
      'total_ordered': totalOrdered,
      'total_received': totalReceived,
      'received_count': receivedCount,
      'partial_count': partialCount,
      'draft_count': draftCount,
    };
  }

  Future<Map<String, dynamic>> getInventorySummary({
    required String businessId,
  }) async {
    final items = List<Map<String, dynamic>>.from(
      await _client
          .from(ReportsQueries.tableInventoryItems)
          .select('id, min_stock, is_active')
          .eq('business_id', businessId),
    );

    final itemIds = items
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toList(growable: false);

    final stockRows = itemIds.isEmpty
        ? <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from(ReportsQueries.tableInventoryStock)
                .select('item_id, quantity')
                .inFilter('item_id', itemIds),
          );

    final stockByItem = <String, double>{};
    for (final row in stockRows) {
      final itemId = row['item_id']?.toString();
      if (itemId == null || itemId.isEmpty) continue;
      stockByItem[itemId] = (stockByItem[itemId] ?? 0) + _toDouble(row['quantity']);
    }

    double totalUnits = 0;
    int activeItems = 0;
    int lowStock = 0;
    int outOfStock = 0;

    for (final item in items) {
      final itemId = item['id']?.toString();
      if (itemId == null || itemId.isEmpty) continue;
      final stock = stockByItem[itemId] ?? 0;
      final minStock = _toDouble(item['min_stock']);
      final isActive = item['is_active'] == true;

      totalUnits += stock;
      if (isActive) activeItems += 1;
      if (stock <= 0) {
        outOfStock += 1;
      } else if (minStock > 0 && stock <= minStock) {
        lowStock += 1;
      }
    }

    return {
      'items_count': items.length,
      'active_items_count': activeItems,
      'total_units': totalUnits,
      'low_stock_count': lowStock,
      'out_of_stock_count': outOfStock,
    };
  }
}
