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

/// Fila del desglose por producto: una por (empleado, producto).
/// Viene de la RPC `fn_sales_by_waiter_products` (migration 20260728_0002).
class WaiterProductRow {
  final String employeeId;
  final String employeeName;
  final String productName;
  final String sku;
  final double units;
  final int itemsCount;
  final double grossAmount;
  final double discountsAmount;
  final double netAmount;

  const WaiterProductRow({
    required this.employeeId,
    required this.employeeName,
    required this.productName,
    required this.sku,
    required this.units,
    required this.itemsCount,
    required this.grossAmount,
    required this.discountsAmount,
    required this.netAmount,
  });

  factory WaiterProductRow.fromMap(Map<String, dynamic> map) {
    return WaiterProductRow(
      employeeId: map['employee_id']?.toString() ?? '',
      employeeName: map['employee_name']?.toString() ?? 'Sin nombre',
      productName: map['product_name']?.toString() ?? 'Sin nombre',
      sku: map['sku']?.toString() ?? '',
      units: (map['units'] as num?)?.toDouble() ?? 0,
      itemsCount: (map['items_count'] as num?)?.toInt() ?? 0,
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
  /// Las fechas son días LOCALES del negocio: la RPC resuelve la zona desde
  /// `business_settings.timezone` (mig 20260919_0004). Antes comparaba contra
  /// `oi.created_at::date`, que en PostgREST (UTC) cortaba el día a las 8 PM
  /// hora RD y mandaba la venta nocturna al día siguiente.
  ///
  /// [productSearch] filtra los items por nombre de producto o SKU (ilike).
  ///
  /// [startTime]/[endTime] ('HH:mm:ss') acotan una franja horaria que se
  /// aplica a CADA día del rango; si el fin es <= el inicio, la franja cruza
  /// la medianoche (20:00→03:00 = la noche completa de cada día).
  ///
  /// Los tres son opcionales y solo se envían cuando traen valor, así la
  /// llamada sigue resolviendo contra firmas viejas si las migraciones
  /// 20260728_0001 / 20260919_0004 aún no están aplicadas.
  Future<List<WaiterSalesRow>> fetch({
    required String businessId,
    required DateTime from,
    required DateTime to,
    String? productSearch,
    String? startTime,
    String? endTime,
  }) async {
    final fromStr = _formatDate(from);
    final toStr = _formatDate(to);
    final search = productSearch?.trim() ?? '';

    final response = await _client.rpc(
      'fn_sales_by_waiter',
      params: {
        'p_business_id': businessId,
        'p_from_date': fromStr,
        'p_to_date': toStr,
        if (search.isNotEmpty) 'p_search': search,
        if (startTime != null && endTime != null) ...{
          'p_start_time': startTime,
          'p_end_time': endTime,
        },
      },
    );

    if (response is! List) return const [];
    return response
        .whereType<Map>()
        .map((row) => WaiterSalesRow.fromMap(Map<String, dynamic>.from(row)))
        .toList(growable: false);
  }

  /// Desglose de productos vendidos por cada mesero en el rango.
  /// Mismos filtros que [fetch] para que cuadre con el resumen. Si la
  /// migración 20260728_0002 no está aplicada, la RPC no existe — el
  /// caller debe tolerar el error y mostrar solo el resumen.
  Future<List<WaiterProductRow>> fetchProducts({
    required String businessId,
    required DateTime from,
    required DateTime to,
    String? productSearch,
    String? startTime,
    String? endTime,
  }) async {
    final search = productSearch?.trim() ?? '';

    final response = await _client.rpc(
      'fn_sales_by_waiter_products',
      params: {
        'p_business_id': businessId,
        'p_from_date': _formatDate(from),
        'p_to_date': _formatDate(to),
        if (search.isNotEmpty) 'p_search': search,
        if (startTime != null && endTime != null) ...{
          'p_start_time': startTime,
          'p_end_time': endTime,
        },
      },
    );

    if (response is! List) return const [];
    return response
        .whereType<Map>()
        .map((row) => WaiterProductRow.fromMap(Map<String, dynamic>.from(row)))
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
