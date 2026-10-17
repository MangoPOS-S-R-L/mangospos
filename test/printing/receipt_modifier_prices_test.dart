import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/payment_models.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

typedef _ReceiptCase = ({
  String name,
  double quantity,
  double unitPrice,
  String modifierName,
  double modifierQty,
  double modifierPrice,
  double subtotal,
  double tax,
  double total,
  String taxMode,
  String lineAmount,
  String unitAmount,
});

const _cases = <_ReceiptCase>[
  // Una selección define todo el precio del producto, como en la foto.
  (
    name: 'FROZEN',
    quantity: 1,
    unitPrice: 0,
    modifierName: 'FROZEN DE CHINOLA',
    modifierQty: 1,
    modifierPrice: 250,
    subtotal: 195.31,
    tax: 54.69,
    total: 250,
    taxMode: 'inclusive',
    lineAmount: 'RD\$195.31',
    unitAmount: 'RD\$195.31',
  ),
  (
    name: 'MARGARITAS',
    quantity: 3,
    unitPrice: 0,
    modifierName: 'TAMARINDO',
    modifierQty: 1,
    modifierPrice: 450,
    subtotal: 1054.69,
    tax: 295.31,
    total: 1350,
    taxMode: 'inclusive',
    lineAmount: 'RD\$1,054.69',
    unitAmount: 'RD\$351.56',
  ),
  // Un extra con cantidad propia también queda incluido en el producto.
  (
    name: 'QUESADILLA',
    quantity: 2,
    unitPrice: 100,
    modifierName: 'EXTRA QUESO',
    modifierQty: 2,
    modifierPrice: 25,
    subtotal: 300,
    tax: 0,
    total: 300,
    taxMode: 'exclusive',
    lineAmount: 'RD\$300.00',
    unitAmount: 'RD\$150.00',
  ),
];

Order _order(_ReceiptCase receipt) => Order(
  id: 'order-1',
  sessionId: 'session-1',
  status: 'paid',
  subtotal: receipt.subtotal,
  discounts: 0,
  serviceFee: 0,
  tax: receipt.tax,
  total: receipt.total,
  createdAt: DateTime(2026, 10, 16, 20),
);

OrderItem _item(_ReceiptCase receipt) => OrderItem(
  id: 'item-1',
  orderId: 'order-1',
  productName: receipt.name,
  quantity: receipt.quantity,
  unitPrice: receipt.unitPrice,
  subtotal: receipt.subtotal,
  discounts: 0,
  tax: receipt.tax,
  total: receipt.total,
  isTakeout: false,
  status: 'completed',
  taxMode: receipt.taxMode,
  taxRate: receipt.taxMode == 'inclusive' ? 28 : 0,
  originalTaxRate: receipt.taxMode == 'inclusive' ? 28 : 0,
  createdAt: DateTime(2026, 10, 16, 20),
  modifiers: [
    OrderItemModifier(
      id: 'modifier-1',
      itemId: 'item-1',
      name: receipt.modifierName,
      qty: receipt.modifierQty,
      price: receipt.modifierPrice,
    ),
    const OrderItemModifier(
      id: 'modifier-2',
      itemId: 'item-1',
      name: 'SIN AZUCAR',
      qty: 1,
      price: 0,
    ),
  ],
);

final _money = RegExp(r'RD\$\s*[\d,]+\.\d{2}');

String _normalizeMoney(String value) =>
    value.replaceAll(RegExp(r'[\s,]'), '');

void _expectProductPrices(
  String text,
  _ReceiptCase receipt, {
  required bool showsUnitPrice,
}) {
  final productStart = text.indexOf(receipt.name);
  expect(productStart, greaterThanOrEqualTo(0));
  final subtotalStart = text.indexOf(
    RegExp(r'SUBTOTAL|Subtotal'),
    productStart,
  );
  expect(subtotalStart, greaterThan(productStart));
  final productBlock = text.substring(productStart, subtotalStart);

  // Las selecciones se conservan completas, incluso si envuelven a 58mm.
  final normalized = productBlock.replaceAll(RegExp(r'\s+'), ' ');
  expect(normalized, contains(receipt.modifierName));
  expect(normalized, contains('SIN AZUCAR'));

  // Solo el producto lleva importes. Esto detecta tanto el monto del extra
  // cobrado dos veces visualmente como el RD$0.00 de selecciones gratuitas.
  expect(
    _money
        .allMatches(productBlock)
        .map((match) => _normalizeMoney(match.group(0)!)),
    unorderedEquals([
      _normalizeMoney(receipt.lineAmount),
      if (showsUnitPrice) _normalizeMoney(receipt.unitAmount),
    ]),
  );
}

Payment _payment(_ReceiptCase receipt) => Payment(
  id: 'payment-1',
  businessId: 'business-1',
  orderId: 'order-1',
  paymentMethodId: 'cash',
  paymentMethodCode: 'cash',
  amount: receipt.total,
  changeAmount: 0,
  status: 'completed',
  createdAt: DateTime(2026, 10, 16, 20),
);

FiscalDocument _fiscalDocument(_ReceiptCase receipt) => FiscalDocument(
  id: 'fiscal-1',
  businessId: 'business-1',
  orderId: 'order-1',
  paymentId: 'payment-1',
  ncfType: 'B02',
  ncfNumber: 'B0200000001',
  customerName: 'CONSUMIDOR FINAL',
  subtotal: receipt.subtotal,
  taxableAmount: receipt.subtotal,
  itbisAmount: receipt.tax,
  total: receipt.total,
  status: 'active',
  issuedAt: DateTime(2026, 10, 16, 20),
);

void main() {
  for (final receipt in _cases) {
    for (final paperWidth in [80, 58]) {
      for (final template in ['standard', 'compact', 'simple', 'modern']) {
        final showsUnitPrice =
            template == 'standard' ||
            template == 'simple' ||
            (template == 'modern' && receipt.quantity != 1);

        test(
          'precuenta $template ${paperWidth}mm ${receipt.name}: precio en producto',
          () {
            final ticket = PrintTicketService.generatePrecheck(
              order: _order(receipt),
              items: [_item(receipt)],
              tableName: 'A2',
              businessName: 'Restaurante',
              template: template,
              paperWidth: paperWidth,
            );
            _expectProductPrices(
              ticket.rawText ?? '',
              receipt,
              showsUnitPrice: showsUnitPrice,
            );
          },
        );

        test(
          'factura $template ${paperWidth}mm ${receipt.name}: precio en producto',
          () {
            final ticket = PrintTicketService.generateInvoice(
              order: _order(receipt),
              items: [_item(receipt)],
              payments: [_payment(receipt)],
              tableName: 'A2',
              businessName: 'Restaurante',
              template: template,
              paperWidth: paperWidth,
            );
            _expectProductPrices(
              ticket.rawText ?? '',
              receipt,
              showsUnitPrice: showsUnitPrice,
            );
          },
        );
      }

      test('factura fiscal ${paperWidth}mm ${receipt.name}: precio en producto', () {
        final ticket = PrintTicketService.generateFiscalInvoice(
          order: _order(receipt),
          items: [_item(receipt)],
          fiscalDoc: _fiscalDocument(receipt),
          payment: _payment(receipt),
          paymentMethod: const PaymentMethod(
            id: 'cash',
            businessId: 'business-1',
            name: 'Efectivo',
            code: 'cash',
            isActive: true,
            requiresReference: false,
            position: 0,
          ),
          tableName: 'A2',
          businessName: 'Restaurante',
          businessRnc: '132261682',
          paperWidth: paperWidth,
        );
        _expectProductPrices(
          ticket.rawText ?? '',
          receipt,
          showsUnitPrice: false,
        );
      });
    }
  }
}
