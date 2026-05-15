// Repositorio del reporte "Ventas por mesero" (multimesero feature).
// Llama a la RPC `fn_sales_by_waiter` (migration 20260516_0002).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class WaiterSalesRow {
  final String employeeId;
  final String employeeName;
  final int ordersCount;
  final int itemsCount;
  final double units;
  final double grossAmount;
  final double discountsAmount;
  final double netAmount;

  const WaiterSalesRow({
    required this.employeeId,
    required this.employeeName,
    required this.ordersCount,
    required this.itemsCount,
    required this.units,
    required this.grossAmount,
    required this.discountsAmount,
    required this.netAmount,
  });

  factory WaiterSalesRow.fromMap(Map<String, dynamic> map) {
    return WaiterSalesRow(
      employeeId: map['employee_id']?.toString() ?? '',
      employeeName: map['employee_name']?.toString() ?? 'Sin nombre',
      ordersCount: (map['orders_count'] as num?)?.toInt() ?? 0,
      itemsCount: (map['items_count'] as num?)?.toInt() ?? 0,
      units: (map['units'] as num?)?.toDouble() ?? 0,
      grossAmount: (map['gross_amount'] as num?)?.toDouble() ?? 0,
      discountsAmount: (map['discounts_amount'] as num?)?.toDouble() ?? 0,
      netAmount: (map['net_amount'] as num?)?.toDouble() ?? 0,
    );
  }
}

class SalesByWaiterRepository {
  SalesByWaiterRepository(this._client);

  final SupabaseClient _client;

  /// Devuelve una fila por empleado dentro del rango [from, to] (inclusive).
  /// Las fechas se interpretan en zona local del cliente — se pasan como
  /// `date` (sin hora) y la RPC compara contra `oi.created_at::date`.
  Future<List<WaiterSalesRow>> fetch({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromStr = _formatDate(from);
    final toStr = _formatDate(to);

    final response = await _client.rpc(
      'fn_sales_by_waiter',
      params: {
        'p_business_id': businessId,
        'p_from_date': fromStr,
        'p_to_date': toStr,
      },
    );

    if (response is! List) return const [];
    return response
        .whereType<Map>()
        .map((row) => WaiterSalesRow.fromMap(Map<String, dynamic>.from(row)))
        .toList(growable: false);
  }

  String _formatDate(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }
}

final salesByWaiterRepositoryProvider = Provider<SalesByWaiterRepository>(
  (ref) => SalesByWaiterRepository(Supabase.instance.client),
);
