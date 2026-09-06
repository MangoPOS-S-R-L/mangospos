// "MESERO:" de la COMANDA = quien digitó los platos, no quien abrió la mesa.
//
// En modo multimesero cada mesera entra a la mesa con su PIN y ese PIN queda
// en `order_items.created_by_employee_id` (embed → `createdByEmployeeName`).
// Antes la comanda imprimía siempre el opener de la mesa vía
// `fn_order_opener_name`, así que con 3 meseras compartiendo mesas todos los
// papeles salían a nombre de una sola. Estas pruebas fijan la regla nueva y
// el respaldo al opener cuando los ítems no traen atribución.

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

Order _order() => Order(
  id: 'order-1234',
  sessionId: 'session-1',
  status: 'open',
  subtotal: 500,
  discounts: 0,
  serviceFee: 0,
  tax: 90,
  total: 590,
  createdAt: DateTime(2026, 9, 5, 20, 0),
);

OrderItem _item({
  required String id,
  required String name,
  String? author,
  DateTime? createdAt,
}) => OrderItem(
  id: id,
  orderId: 'order-1234',
  productName: name,
  quantity: 1,
  unitPrice: 250,
  subtotal: 250,
  discounts: 0,
  tax: 45,
  total: 295,
  isTakeout: false,
  status: 'draft',
  taxMode: 'exclusive',
  taxRate: 18,
  createdAt: createdAt ?? DateTime(2026, 9, 5, 20, 0),
  createdByEmployeeName: author,
);

/// Renglón que sigue a la cabecera `MESERO ... HORA` — ahí va el nombre.
String _waiterLine(String? rawText) {
  final lines = (rawText ?? '').split('\n');
  final header = lines.indexWhere((l) => l.contains('MESERO'));
  expect(header, isNot(-1), reason: 'la comanda no imprimió el bloque MESERO');
  return lines[header + 1];
}

void main() {
  setUpAll(() => initializeDateFormatting('es_DO'));

  group('Comanda — mesero que digita', () {
    test('imprime el autor de los ítems, no el opener de la mesa', () {
      final ticket = PrintTicketService.generateKitchenTicket(
        order: _order(),
        items: [
          _item(id: 'i1', name: 'Presidente Light', author: 'Claudia Pérez'),
          _item(id: 'i2', name: 'Daikiri Fresa', author: 'Claudia Pérez'),
        ],
        tableName: 'MESA1',
        waiterName: 'Avila', // opener de la mesa
        areaCode: 'bar',
      );

      expect(_waiterLine(ticket.rawText), contains('Claudia Pérez'));
      expect(ticket.rawText, isNot(contains('Avila')));
    });

    test('ronda con dos autores: manda el ítem más reciente (quien envió)', () {
      final ticket = PrintTicketService.generateKitchenTicket(
        order: _order(),
        items: [
          _item(
            id: 'i1',
            name: 'Presidente Light',
            author: 'Claudia Pérez',
            createdAt: DateTime(2026, 9, 5, 20, 0),
          ),
          _item(
            id: 'i2',
            name: 'Daikiri Fresa',
            author: 'Rosa Then',
            createdAt: DateTime(2026, 9, 5, 20, 3),
          ),
        ],
        tableName: 'MESA1',
        waiterName: 'Avila',
        areaCode: 'bar',
      );

      expect(_waiterLine(ticket.rawText), contains('Rosa Then'));
    });

    test('ítems sin atribución: cae al opener que resuelve el caller', () {
      final ticket = PrintTicketService.generateKitchenTicket(
        order: _order(),
        items: [_item(id: 'i1', name: 'Presidente Light')],
        tableName: 'MESA1',
        waiterName: 'Avila',
        areaCode: 'bar',
      );

      expect(_waiterLine(ticket.rawText), contains('Avila'));
    });
  });
}
