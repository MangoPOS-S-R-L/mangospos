// Las notas del ítem NO salen en la factura ni en la precuenta: en el papel
// del cliente solo van los modificadores. La nota es para cocina (y además
// arrastra marcadores internos como `[REDUCCION:motivo]`, que se colaban en
// la factura). La comanda sí la sigue imprimiendo.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

const _notes = 'Sin cebolla\n[REDUCCION:Producto en mal estado]';

Order _order() => Order(
  id: 'order-1234',
  sessionId: 'session-1',
  status: 'paid',
  subtotal: 1000,
  discounts: 0,
  serviceFee: 0,
  tax: 180,
  total: 1180,
  createdAt: DateTime(2026, 1, 1, 12, 0),
);

OrderItem _item() => OrderItem(
  id: 'item-1',
  orderId: 'order-1234',
  productName: 'Mofongo de chicharrón',
  quantity: 2,
  unitPrice: 500,
  subtotal: 1000,
  discounts: 0,
  tax: 180,
  total: 1180,
  isTakeout: false,
  status: 'completed',
  taxMode: 'exclusive',
  taxRate: 18,
  notes: _notes,
  createdAt: DateTime(2026, 1, 1, 12, 0),
  modifiers: const [
    OrderItemModifier(
      id: 'mod-1',
      itemId: 'item-1',
      name: 'Extra queso',
      qty: 1,
      price: 50,
    ),
  ],
);

Payment _payment() => Payment(
  id: 'payment-1',
  businessId: 'biz-1',
  orderId: 'order-1234',
  paymentMethodId: 'cash',
  paymentMethodCode: 'cash',
  paymentMethodName: 'EFECTIVO',
  amount: 1200,
  changeAmount: 20,
  status: 'completed',
  createdAt: DateTime(2026, 1, 1, 12, 5),
);

void _expectOnlyModifiers(String text) {
  // A 58mm la plantilla compacta recorta el nombre del modificador.
  expect(text, contains('Extra'));
  expect(text, isNot(contains('Sin cebolla')));
  expect(text, isNot(contains('REDUCCION')));
  expect(text, isNot(contains('Producto en mal estado')));
  expect(text.toUpperCase(), isNot(contains('NOTA:')));
}

void main() {
  const templates = ['standard', 'compact', 'simple', 'modern'];

  for (final template in templates) {
    for (final paperWidth in [80, 58]) {
      test('factura $template ${paperWidth}mm: solo modificadores', () {
        final ticket = PrintTicketService.generateInvoice(
          order: _order(),
          items: [_item()],
          payments: [_payment()],
          tableName: 'TERRAZA 12',
          businessName: 'Restaurante La Esquina',
          fiscalNcf: 'B0200000001',
          fiscalType: 'B02',
          title: '*** FACTURA ***',
          template: template,
          paperWidth: paperWidth,
        );
        _expectOnlyModifiers(ticket.rawText ?? '');
      });

      test('precuenta $template ${paperWidth}mm: solo modificadores', () {
        final ticket = PrintTicketService.generatePrecheck(
          order: _order(),
          items: [_item()],
          tableName: 'TERRAZA 12',
          businessName: 'Restaurante La Esquina',
          title: '*** PRECUENTA ***',
          template: template,
          paperWidth: paperWidth,
        );
        _expectOnlyModifiers(ticket.rawText ?? '');
      });
    }
  }

  test('la comanda sigue mostrando la nota para cocina', () {
    final ticket = PrintTicketService.generateKitchenTicket(
      order: _order(),
      items: [_item()],
      tableName: 'TERRAZA 12',
      areaCode: 'kitchen_hot',
    );
    expect(ticket.rawText ?? '', contains('Sin cebolla'));
  });
}
