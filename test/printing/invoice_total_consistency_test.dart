import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/payment_models.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

Order _order({
  double total = 6800,
  double discounts = 0,
  double deliveryFee = 0,
}) => Order(
  id: 'order-1',
  sessionId: 'session-1',
  status: 'paid',
  subtotal: 5312.50,
  tax: 956.25,
  serviceFee: 531.25,
  discounts: discounts,
  deliveryFee: deliveryFee,
  total: total,
  createdAt: DateTime(2026, 10, 16, 21),
);

OrderItem _item({bool missingTax = false}) => OrderItem(
  id: 'item-1',
  orderId: 'order-1',
  productName: 'Consumo',
  quantity: 1,
  unitPrice: missingTax ? 5312.50 : 6800,
  subtotal: 5312.50,
  tax: missingTax ? 0 : 1487.50,
  total: missingTax ? 5312.50 : 6800,
  taxMode: missingTax ? 'exclusive' : 'inclusive',
  taxRate: missingTax ? 0 : 28,
  originalTaxRate: missingTax ? 0 : 28,
  discounts: 0,
  isTakeout: false,
  status: 'paid',
  createdAt: DateTime(2026, 10, 16, 21),
);

Payment _payment() => Payment(
  id: 'payment-1',
  businessId: 'business-1',
  orderId: 'order-1',
  paymentMethodId: 'card',
  paymentMethodCode: 'card',
  paymentMethodName: 'TARJETA',
  amount: 6900,
  changeAmount: 0,
  status: 'completed',
  createdAt: DateTime(2026, 10, 16, 21),
);

String _invoice(
  Order order, {
  String template = 'compact',
  String discountDisplayMode = 'pre_discount',
  bool preferStoredOrderTotals = true,
  bool missingItemTax = false,
}) =>
    PrintTicketService.generateInvoice(
      order: order,
      items: [_item(missingTax: missingItemTax)],
      payments: [_payment()],
      tableName: 'S2',
      businessName: 'Restaurante',
      title: 'REIMPRESION',
      template: template,
      discountDisplayMode: discountDisplayMode,
      preferStoredOrderTotals: preferStoredOrderTotals,
      taxBreakdown: const [
        (label: 'ITBIS (18%)', amount: 956.25),
        (label: 'Ley (10%)', amount: 531.25),
      ],
    ).rawText ??
    '';

String _totalLine(String text) => text
    .split('\n')
    .firstWhere((line) => line.trimLeft().startsWith('TOTAL'));

void main() {
  for (final template in ['standard', 'compact', 'simple', 'modern']) {
    for (final discountDisplayMode in ['pre_discount', 'post_discount']) {
      test(
        '$template $discountDisplayMode: total guardado 6800 con pago 6900',
        () {
          final text = _invoice(
            _order(),
            template: template,
            discountDisplayMode: discountDisplayMode,
          );
          // El pago permanece para conciliación; no reemplaza el documento.
          expect(text, contains('RD\$6,900.00'));
          expect(_totalLine(text), contains('RD\$6,800.00'));
        },
      );

      test(
        '$template $discountDisplayMode: rechaza total 6900 si las partes suman 6800',
        () {
          expect(
            () => _invoice(
              _order(total: 6900),
              template: template,
              discountDisplayMode: discountDisplayMode,
            ),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'explica la diferencia',
                allOf(contains('6800.00'), contains('6900.00')),
              ),
            ),
          );
        },
      );
    }
  }

  test('el respaldo guardado por impuestos ausentes también debe cuadrar', () {
    expect(
      () => _invoice(
        _order(total: 6900),
        preferStoredOrderTotals: false,
        missingItemTax: true,
      ),
      throwsStateError,
    );
  });

  test('admite un centavo de redondeo sin modificar el total guardado', () {
    final text = _invoice(_order(total: 6800.01));
    expect(_totalLine(text), contains('RD\$6,800.01'));
  });

  test('rechaza dos centavos de diferencia entre partes y total guardado', () {
    expect(() => _invoice(_order(total: 6800.02)), throwsStateError);
  });

  test('la validación incluye delivery y resta el descuento', () {
    expect(
      () => _invoice(_order(total: 6875, deliveryFee: 175, discounts: 100)),
      returnsNormally,
    );
    expect(
      () => _invoice(_order(total: 6975, deliveryFee: 175, discounts: 100)),
      throwsStateError,
    );
  });

  test('un comprobante guardado no acepta importes no finitos', () {
    expect(
      () => _invoice(_order().copyWith(tax: double.nan)),
      throwsStateError,
    );
  });

  for (final total in [6800.0, 6900.0]) {
    test('factura fiscal valida también el total guardado $total', () {
      final order = _order(total: total);
      final fiscalDoc = FiscalDocument(
        id: 'fiscal-1',
        businessId: 'business-1',
        orderId: 'order-1',
        paymentId: 'payment-1',
        ncfType: 'B02',
        ncfNumber: 'B0200000248',
        customerName: 'CONSUMIDOR FINAL',
        subtotal: order.subtotal,
        taxableAmount: order.subtotal,
        itbisAmount: order.tax,
        total: order.total,
        status: 'active',
        issuedAt: order.createdAt,
      );
      void generate() => PrintTicketService.generateFiscalInvoice(
        order: order,
        items: [_item()],
        fiscalDoc: fiscalDoc,
        payment: _payment(),
        paymentMethod: const PaymentMethod(
          id: 'card',
          businessId: 'business-1',
          name: 'Tarjeta',
          code: 'card',
          isActive: true,
          requiresReference: false,
          position: 0,
        ),
        tableName: 'S2',
        businessName: 'Restaurante',
        businessRnc: '132261682',
        preferStoredOrderTotals: true,
      );

      expect(generate, total == 6800 ? returnsNormally : throwsStateError);
    });
  }
}
