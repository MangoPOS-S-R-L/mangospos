import 'package:supabase_flutter/supabase_flutter.dart';

import '../datasources/queries/reports_queries.dart';

class ReportsRepository {
  final SupabaseClient _client;

  ReportsRepository(this._client);

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
      if (amount is num) {
        totalSales += amount.toDouble();
      } else if (amount is String) {
        totalSales += double.tryParse(amount) ?? 0;
      }
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
          'id, start_amount, end_amount, difference, status, opened_at, closed_at',
        )
        .eq('business_id', businessId)
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
      final normalized = amount is num
          ? amount.toDouble()
          : double.tryParse(amount?.toString() ?? '') ?? 0;

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
}
