import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/sales/logic/hub_zone_refresh_scope.dart';

void main() {
  test('open_table indexes the order and refreshes only its zone', () {
    final orderToTable = <String, String>{};
    const tableToZone = {'table-1': 'zone-a', 'table-2': 'zone-b'};

    expect(
      zonesForHubEvent(
        {'type': 'open_table', 'order_id': 'order-1', 'table_id': 'table-1'},
        tableToZone: tableToZone,
        orderToTable: orderToTable,
      ),
      {'zone-a'},
    );
    expect(orderToTable['order-1'], 'table-1');
    expect(
      zonesForHubEvent(
        {'type': 'add_item', 'order_id': 'order-1'},
        tableToZone: tableToZone,
        orderToTable: orderToTable,
      ),
      {'zone-a'},
    );
    expect(
      zonesForHubEvent(
        {'type': 'process_payment', 'order_id': 'order-1'},
        tableToZone: tableToZone,
        orderToTable: orderToTable,
      ),
      {'zone-a'},
    );
  });

  test('an order changing tables refreshes both old and new zones', () {
    final orderToTable = {'order-1': 'table-1'};
    const tableToZone = {'table-1': 'zone-a', 'table-2': 'zone-b'};
    expect(
      zonesForHubEvent(
        {'type': 'open_table', 'order_id': 'order-1', 'table_id': 'table-2'},
        tableToZone: tableToZone,
        orderToTable: orderToTable,
      ),
      {'zone-a', 'zone-b'},
    );
    expect(orderToTable['order-1'], 'table-2');
  });

  test('unknown or unresolved events require a full refresh', () {
    final orderToTable = <String, String>{};
    const tableToZone = {'table-1': 'zone-a'};
    for (final event in <Map<String, dynamic>>[
      {'type': 'process_payment', 'order_id': 'unknown'},
      {'type': 'open_table', 'order_id': 'order-2', 'table_id': 'not-loaded'},
      {'type': 'transfer_table', 'table_id': 'table-1'},
      {'type': 'add_item'},
    ]) {
      expect(
        zonesForHubEvent(
          event,
          tableToZone: tableToZone,
          orderToTable: orderToTable,
        ),
        isNull,
      );
    }
  });
}
