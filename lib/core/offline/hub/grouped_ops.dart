/// El grupo es una única operación durable. Los proyectores lo aplican en
/// memoria como una secuencia indivisible, sin guardar mutaciones parciales.
Iterable<Map<String, dynamic>> expandGroupedOps(Map<String, dynamic> op) sync* {
  if (op['type'] != 'edit_item_group') {
    yield op;
    return;
  }
  final added = ((op['actions'] as List?) ?? [])
      .whereType<Map>()
      .where((a) => a['kind'] == 'add')
      .map((a) => a['item_id'])
      .toSet();
  for (final id in (op['removed_ids'] as List?) ?? []) {
    yield {...op, 'type': 'delete_item', 'item_id': id};
  }
  for (final row in ((op['result_items'] as List?) ?? []).whereType<Map>()) {
    final base = {
      ...op,
      'item_id': row['id'],
      'qty': row['qty'],
      'quantity': row['qty'],
      'product_name': row['product_name'],
      'product_price': row['unit_price'],
      'check_pos': row['check_id'],
      'notes': row['notes'],
      'is_takeout': row['is_takeout'],
      'item_snapshot': Map<String, dynamic>.from(row),
    };
    yield {
      ...base,
      'type': added.contains(row['id']) ? 'add_item' : 'update_item_quantity',
    };
    if (!added.contains(row['id'])) {
      yield {...base, 'type': 'update_item_notes'};
      yield {...base, 'type': 'toggle_item_takeout'};
    }
  }
}
