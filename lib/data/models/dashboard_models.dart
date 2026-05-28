// Modelos de los widgets de la Fase A del dashboard (Top Selling Items,
// Recent Orders, Inventory Alert). Tipos chicos y planos — el dashboard
// no necesita objetos ricos, solo data para renderizar tiles/filas.

import 'package:flutter/foundation.dart';

/// Producto con métrica de ventas — fuente del widget "Top Selling Items".
@immutable
class DashboardTopProduct {
  final String productId;
  final String productName;
  final String? imageUrl;
  final double totalQuantity;
  final double totalAmount;

  const DashboardTopProduct({
    required this.productId,
    required this.productName,
    this.imageUrl,
    required this.totalQuantity,
    required this.totalAmount,
  });

  factory DashboardTopProduct.fromMap(Map<String, dynamic> map) {
    return DashboardTopProduct(
      productId: map['product_id']?.toString() ?? '',
      productName: map['product_name']?.toString() ?? 'Producto',
      imageUrl: (map['image_url'] as String?)?.trim().isEmpty == true
          ? null
          : map['image_url'] as String?,
      totalQuantity: (map['total_quantity'] as num?)?.toDouble() ?? 0,
      totalAmount: (map['total_amount'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Orden resumida — fuente del widget "Recent Orders".
@immutable
class DashboardRecentOrder {
  final String id;
  final String orderNumber;
  final String? customerName;
  final double total;

  /// Enum `order_status` crudo: open|sent_to_kitchen|partially_paid|paid|void
  /// (más legacy text variants: sent|served|canceled).
  final String status;
  final DateTime createdAt;

  /// Resumen corto de items (ej. "Burger x2, Pizza x1 + 3 más"). Null
  /// si la orden no tiene items visibles.
  final String? itemsSummary;

  /// Total de items no-voided de la orden. Útil para mostrar conteo
  /// agregado o decidir si tiene sentido el deep-link.
  final int itemsCount;

  /// `order_origin` enum: dine_in|takeout|delivery|quick|manual|self_service.
  /// Drives la ruta de navegación al hacer tap.
  final String? origin;

  /// table_id de la sesión. Para `dine_in` permite armar el deep-link a
  /// `/sales/table/:tableId`. Null para virtuales (manual / quick).
  final String? tableId;

  /// Código visible de la mesa (ej. "M-01"). Se usa como fallback en
  /// la columna "Cliente" cuando el comensal no se nombró, y también
  /// como query param en el deep-link.
  final String? tableCode;

  /// zone_id — query param de la ruta de mesa.
  final String? zoneId;

  const DashboardRecentOrder({
    required this.id,
    required this.orderNumber,
    this.customerName,
    required this.total,
    required this.status,
    required this.createdAt,
    this.itemsSummary,
    this.itemsCount = 0,
    this.origin,
    this.tableId,
    this.tableCode,
    this.zoneId,
  });

  factory DashboardRecentOrder.fromMap(Map<String, dynamic> map) {
    String? trimOrNull(Object? raw) {
      final s = raw?.toString().trim();
      if (s == null || s.isEmpty) return null;
      return s;
    }

    return DashboardRecentOrder(
      id: map['id']?.toString() ?? '',
      orderNumber: map['order_number']?.toString() ?? '',
      customerName: trimOrNull(map['customer_name']),
      total: (map['total'] as num?)?.toDouble() ?? 0,
      status: map['status']?.toString() ?? 'open',
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? '') ??
          DateTime.now(),
      itemsSummary: trimOrNull(map['items_summary']),
      itemsCount: (map['items_count'] as num?)?.toInt() ?? 0,
      origin: trimOrNull(map['origin']),
      tableId: trimOrNull(map['table_id']),
      tableCode: trimOrNull(map['table_code']),
      zoneId: trimOrNull(map['zone_id']),
    );
  }

  /// La orden está cerrada (paid o void). El tap debe ir a historial,
  /// no a la pantalla de mesa (donde aparecería vacía).
  bool get isClosed => status == 'paid' || status == 'void';
}

/// Insumo con alerta de stock bajo — fuente del widget "Inventory Alert".
/// Mapea directamente desde `v_inventory_low_stock` (ya existe vía
/// [InventoryRepository.getLowStockAlerts]).
@immutable
class DashboardInventoryAlert {
  final String itemId;
  final String name;
  final double stock;
  final double? threshold;
  final double? shortfall;
  final String? unit;

  /// 'out_of_stock' | 'critical' | 'low'. Determina el color del badge.
  final String alertLevel;

  const DashboardInventoryAlert({
    required this.itemId,
    required this.name,
    required this.stock,
    this.threshold,
    this.shortfall,
    this.unit,
    required this.alertLevel,
  });

  factory DashboardInventoryAlert.fromMap(Map<String, dynamic> map) {
    return DashboardInventoryAlert(
      itemId: map['id']?.toString() ?? map['item_id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Insumo',
      stock: (map['stock'] as num?)?.toDouble() ??
          (map['total_stock'] as num?)?.toDouble() ??
          0,
      threshold: (map['low_stock_threshold'] as num?)?.toDouble() ??
          (map['threshold'] as num?)?.toDouble(),
      shortfall: (map['shortfall'] as num?)?.toDouble(),
      unit: (map['unit'] as String?)?.trim().isEmpty == true
          ? null
          : map['unit'] as String?,
      alertLevel: map['alert_level']?.toString() ?? 'low',
    );
  }

  bool get isOutOfStock => alertLevel == 'out_of_stock';
  bool get isCritical => alertLevel == 'critical';
}

/// Snapshot de los KPIs del "Order Summary" para un periodo dado (hoy o
/// ayer). Mapea 1:1 a una fila del RPC `fn_dashboard_kpis`.
@immutable
class DashboardKpiSnapshot {
  final double income;
  final int ordersTotal;
  final int ordersInProgress;
  final int ordersCompleted;
  final double itemsSold;

  const DashboardKpiSnapshot({
    required this.income,
    required this.ordersTotal,
    required this.ordersInProgress,
    required this.ordersCompleted,
    required this.itemsSold,
  });

  static const empty = DashboardKpiSnapshot(
    income: 0,
    ordersTotal: 0,
    ordersInProgress: 0,
    ordersCompleted: 0,
    itemsSold: 0,
  );

  factory DashboardKpiSnapshot.fromMap(Map<String, dynamic> map) {
    return DashboardKpiSnapshot(
      income: (map['income'] as num?)?.toDouble() ?? 0,
      ordersTotal: (map['orders_total'] as num?)?.toInt() ?? 0,
      ordersInProgress: (map['orders_in_progress'] as num?)?.toInt() ?? 0,
      ordersCompleted: (map['orders_completed'] as num?)?.toInt() ?? 0,
      itemsSold: (map['items_sold'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Bundle con HOY + AYER (mismo tramo del día) para alimentar la KPI
/// strip del dashboard. Si el periodo no existe en la respuesta del RPC
/// se asume `empty` (cero todo) — el delta queda como null.
@immutable
class DashboardKpis {
  final DashboardKpiSnapshot today;
  final DashboardKpiSnapshot yesterday;

  const DashboardKpis({required this.today, required this.yesterday});

  static const empty = DashboardKpis(
    today: DashboardKpiSnapshot.empty,
    yesterday: DashboardKpiSnapshot.empty,
  );

  /// Construye desde el listado crudo del RPC (hasta 2 filas, una por
  /// periodo). Falta de fila = `empty` para ese lado.
  factory DashboardKpis.fromRpcRows(List<Map<String, dynamic>> rows) {
    DashboardKpiSnapshot today = DashboardKpiSnapshot.empty;
    DashboardKpiSnapshot yesterday = DashboardKpiSnapshot.empty;
    for (final row in rows) {
      final period = row['period']?.toString();
      final snap = DashboardKpiSnapshot.fromMap(row);
      if (period == 'today') today = snap;
      if (period == 'yesterday') yesterday = snap;
    }
    return DashboardKpis(today: today, yesterday: yesterday);
  }

  /// Delta % vs ayer, para un selector dado.
  /// Devuelve null cuando ayer fue 0 (división indefinida → "—" en UI).
  double? deltaPercent(double Function(DashboardKpiSnapshot) selector) {
    final t = selector(today);
    final y = selector(yesterday);
    if (y == 0) return null;
    return ((t - y) / y) * 100.0;
  }
}
