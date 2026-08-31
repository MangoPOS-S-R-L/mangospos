import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

/// Caso real 2026-08-30 (MESA4): un ticket salió con el encabezado, el NCF,
/// la hora y los pagos de una orden ya cobrada, pero con los productos de la
/// cuenta que se abrió después en la misma mesa. El comprobante amparaba
/// mercancía que ese NCF no vendió.
///
/// `generateInvoice` es el único punto por el que pasa TODA factura, así que
/// el candado vive ahí. Estos tests lo fijan.

const _ordenA = 'aa2686ee-562e-46e4-9349-386507e1957a';
const _ordenB = 'db5fe207-4438-4b11-a471-4bd0095c31d9';

Order _order({String id = _ordenA}) => Order(
  id: id,
  sessionId: 'session-1',
  status: 'paid',
  subtotal: 100,
  discounts: 0,
  serviceFee: 0,
  tax: 18,
  total: 118,
  createdAt: DateTime(2026, 8, 30, 17, 26),
);

OrderItem _item({
  required String id,
  required String orderId,
  String name = 'PRESIDENTE REGULAR GRANDE',
}) => OrderItem(
  id: id,
  orderId: orderId,
  productName: name,
  quantity: 1,
  unitPrice: 100,
  subtotal: 100,
  discounts: 0,
  tax: 18,
  total: 118,
  isTakeout: false,
  status: 'paid',
  taxMode: 'exclusive',
  taxRate: 18,
  createdAt: DateTime(2026, 8, 30, 17, 20),
);

PrintTicket _invoice(Order order, List<OrderItem> items) =>
    PrintTicketService.generateInvoice(
      order: order,
      items: items,
      payments: const [],
      tableName: 'MESA4',
      fiscalNcf: 'B0200019990',
      fiscalType: 'B02',
    );

void main() {
  group('generateInvoice: los ítems tienen que ser de la orden', () {
    test('imprime cuando todos los ítems son de la orden', () {
      final ticket = _invoice(_order(), [
        _item(id: 'i1', orderId: _ordenA),
        _item(id: 'i2', orderId: _ordenA),
      ]);
      expect(ticket.escPosCommands, isNotEmpty);
    });

    test('SE NIEGA a imprimir si un ítem es de otra orden', () {
      expect(
        () => _invoice(_order(), [
          _item(id: 'i1', orderId: _ordenA),
          _item(id: 'i2', orderId: _ordenB, name: 'LA BENEDICTA 12 OZ'),
        ]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('no pertenecen a la orden'),
              contains('LA BENEDICTA 12 OZ'),
              contains(_ordenB),
            ),
          ),
        ),
      );
    });

    test('se niega aunque TODOS los ítems sean de la otra orden', () {
      expect(
        () => _invoice(_order(), [_item(id: 'i1', orderId: _ordenB)]),
        throwsA(isA<StateError>()),
      );
    });

    test('tolera ítems locales sin orderId (aún sin sincronizar)', () {
      final ticket = _invoice(_order(), [
        _item(id: 'i1', orderId: ''),
        _item(id: 'i2', orderId: _ordenA),
      ]);
      expect(ticket.escPosCommands, isNotEmpty);
    });

    // No hay caso para `order.id` vacío: `generateInvoice` hace
    // `order.id.substring(0, 8)` para el nº de orden del encabezado, así que
    // una orden sin id revienta ahí antes de llegar al candado. La rama
    // `order.id.isNotEmpty` del guard es defensiva, no un caso de uso.
  });
}
