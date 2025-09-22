class TableStatus {
  final String tableId, zoneId, code;
  final String? sessionId;
  final int ordersCount;
  final int? minutesOpen;
  TableStatus({
    required this.tableId, required this.zoneId, required this.code,
    required this.sessionId, required this.ordersCount, required this.minutesOpen,
  });
  factory TableStatus.fromMap(Map<String,dynamic> r) => TableStatus(
    tableId: r['table_id'], zoneId: r['zone_id'], code: r['code'],
    sessionId: r['session_id'], ordersCount: r['orders_count'] ?? 0,
    minutesOpen: r['minutes_open'],
  );
}
