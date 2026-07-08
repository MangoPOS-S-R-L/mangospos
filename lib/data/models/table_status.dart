class TableStatus {
  final String tableId, zoneId, code;
  final String? sessionId;
  final String? status;
  final int ordersCount;
  final int? minutesOpen;
  final int itemsCount;
  final double total;
  final int peopleCount;
  final String? waiterName;
  final String? customerName;
  final bool isOwn;

  /// True si la mesa proviene de un borrador LOCAL de ESTE dispositivo aún no
  /// sincronizado con el servidor (orden `local-order-…`). Es un overlay del
  /// grid para que la mesa no desaparezca al recargar desde el server. Las
  /// filas de `v_zone_table_status` nunca lo traen → siempre false para ellas.
  final bool isPendingSync;
  TableStatus({
    required this.tableId,
    required this.zoneId,
    required this.code,
    required this.sessionId,
    required this.ordersCount,
    required this.minutesOpen,
    this.itemsCount = 0,
    this.total = 0,
    this.peopleCount = 0,
    this.status,
    this.waiterName,
    this.customerName,
    this.isOwn = false,
    this.isPendingSync = false,
  });
  factory TableStatus.fromMap(Map<String, dynamic> r) => TableStatus(
    tableId: r['table_id'],
    zoneId: r['zone_id'],
    code: r['code'],
    sessionId: r['session_id'],
    ordersCount: r['orders_count'] ?? 0,
    minutesOpen: r['minutes_open'],
    itemsCount: r['items_count'] ?? 0,
    total: (r['total'] ?? 0).toDouble(),
    peopleCount: r['people_count'] ?? 0,
    status: r['status'],
    waiterName: r['waiter_name'] ?? r['server_name'],
    customerName: r['customer_name'],
    isOwn: r['is_own'] ?? false,
    // El server no expone este flag; solo lo setea el overlay offline.
  );
}
