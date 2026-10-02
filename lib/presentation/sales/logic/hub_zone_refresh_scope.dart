const _tableEventTypes = <String>{
  'open_table',
  'add_item',
  'delete_item',
  'update_item_quantity',
  'update_item_notes',
  'toggle_item_takeout',
  'move_item_to_check',
  'mark_order_takeout',
  'send_to_kitchen',
  'confirm_local_order',
  'void_order',
  'release_empty_order',
  'process_payment',
};

/// Returns null when the event cannot be safely scoped to loaded zones.
Set<String>? zonesForHubEvent(
  Map<String, dynamic> event, {
  required Map<String, String> tableToZone,
  required Map<String, String> orderToTable,
}) {
  if (!_tableEventTypes.contains(event['type'])) return null;
  final orderId = event['order_id']?.toString();
  final tableId = event['table_id']?.toString();
  final previousTableId = orderId == null ? null : orderToTable[orderId];
  final tableIds = <String>{
    if (tableId != null && tableId.isNotEmpty) tableId,
    if (previousTableId != null && previousTableId.isNotEmpty) previousTableId,
  };
  if (tableIds.isEmpty) return null;

  final zones = <String>{};
  for (final id in tableIds) {
    final zone = tableToZone[id];
    if (zone == null) return null;
    zones.add(zone);
  }
  if (orderId != null && orderId.isNotEmpty && tableId != null) {
    orderToTable[orderId] = tableId;
  }
  return zones;
}
