// Factura de una SUBCUENTA (división de cuenta).
//
// EL BUG (2026-10-06): "en la división de cuenta a veces me da error de
// impresión, pero cuando le doy a reintentar sí lo hace".
//
// `generateInvoice` tiene un candado (desde 2026-08-30, caso MESA4): si algún
// producto no pertenece a la orden del encabezado, NO imprime — un
// comprobante fiscal no puede amparar mercancía de otra cuenta. Y la factura
// de una subcuenta se armaba con `OrderCheck.toOrder()`, que le ponía a la
// "orden" el id de la SUBCUENTA, mientras los productos llevan el de la
// orden real. El candado veía 0 de N productos propios y cortaba: "Fallo de
// Impresión". "Reintentar" pasaba la orden capturada (id real) y salía.
//
// Lo que se fija acá:
//  1. `toOrder()` conserva el id de la orden real y los totales de la
//     subcuenta.
//  2. La factura de una subcuenta pasa el candado (y con el número de orden
//     real en el papel).
//  3. El candado sigue cortando cuando de verdad hay productos ajenos.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

const _orderId = '7f3a91c2-5b6d-4e8f-9a01-23456789abcd';
const _checkId = 'c4e8d2b1-0a9f-4c3e-8b7d-6f5e4d3c2b1a';

OrderItem _item(String id, {String orderId = _orderId}) => OrderItem(
  id: id,
  orderId: orderId,
  checkId: _checkId,
  productName: 'Producto $id',
  quantity: 1,
  unitPrice: 100,
  subtotal: 84.75,
  discounts: 0,
  tax: 15.25,
  total: 100,
  isTakeout: false,
  status: 'paid',
  taxMode: 'inclusive',
  taxRate: 18,
  createdAt: DateTime(2026, 10, 6, 10, 0),
);

const _check = OrderCheck(
  id: _checkId,
  orderId: _orderId,
  label: 'Cuenta 2',
  position: 2,
  isClosed: false,
  subtotal: 169.49,
  discounts: 0,
  serviceFee: 0,
  tax: 30.51,
  total: 200,
);

Payment _payment() => Payment(
  id: 'pay-1',
  businessId: 'biz-1',
  orderId: _orderId,
  checkId: _checkId,
  paymentMethodId: 'cash',
  paymentMethodCode: 'cash',
  paymentMethodName: 'EFECTIVO',
  amount: 200,
  changeAmount: 0,
  status: 'completed',
  createdAt: DateTime(2026, 10, 6, 10, 5),
);

PrintTicket _invoice(Order order, List<OrderItem> items) =>
    PrintTicketService.generateInvoice(
      order: order,
      items: items,
      payments: [_payment()],
      tableName: 'MESA 4',
      businessName: 'Restaurante',
      fiscalNcf: 'B0200000001',
      fiscalType: 'B02',
      title: '*** FACTURA ***',
    );

void main() {
  test('toOrder conserva la orden real y los totales de la subcuenta', () {
    final order = _check.toOrder(createdAt: DateTime(2026, 10, 6));
    expect(order.id, _orderId);
    expect(order.total, 200);
    expect(order.subtotal, 169.49);
    expect(order.tax, 30.51);
  });

  test('la factura de una subcuenta imprime al primer intento', () {
    final order = _check.toOrder(createdAt: DateTime(2026, 10, 6));
    final ticket = _invoice(order, [_item('i1'), _item('i2')]);
    expect(ticket.escPosCommands, isNotEmpty);
    // El número de orden del papel es el de la orden, no el de la subcuenta:
    // así coincide con el historial.
    expect(ticket.rawText, contains('7F3A91C2'));
    expect(ticket.rawText, isNot(contains('C4E8D2B1')));
  });

  test('el candado sigue cortando con productos de OTRA orden', () {
    final order = _check.toOrder(createdAt: DateTime(2026, 10, 6));
    expect(
      () => _invoice(order, [
        _item('i1'),
        _item('i9', orderId: '00000000-1111-2222-3333-444444444444'),
      ]),
      throwsStateError,
    );
  });
}
