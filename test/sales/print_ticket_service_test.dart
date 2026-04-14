import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/payment_models.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

Order _order({
  double subtotal = 0,
  double discounts = 0,
  double serviceFee = 0,
  double tax = 0,
  double total = 0,
}) {
  return Order(
    id: 'order-1',
    sessionId: 'session-1',
    status: 'paid',
    subtotal: subtotal,
    discounts: discounts,
    serviceFee: serviceFee,
    tax: tax,
    total: total,
    createdAt: DateTime(2026, 1, 1, 12, 0),
  );
}

OrderItem _item({
  required String id,
  required double quantity,
  required double unitPrice,
  required double subtotal,
  required double tax,
  required double total,
  double discounts = 0,
  bool isTakeout = false,
  String taxMode = 'exclusive',
  double taxRate = 0,
  double? originalTaxRate,
  List<OrderItemModifier> modifiers = const [],
}) {
  return OrderItem(
    id: id,
    orderId: 'order-1',
    productName: 'Item $id',
    quantity: quantity,
    unitPrice: unitPrice,
    subtotal: subtotal,
    discounts: discounts,
    tax: tax,
    total: total,
    isTakeout: isTakeout,
    status: 'completed',
    taxMode: taxMode,
    taxRate: taxRate,
    originalTaxRate: originalTaxRate,
    createdAt: DateTime(2026, 1, 1, 12, 0),
    modifiers: modifiers,
  );
}

Payment _payment({double amount = 0, double changeAmount = 0}) {
  return Payment(
    id: 'payment-1',
    businessId: 'biz-1',
    orderId: 'order-1',
    paymentMethodId: 'cash',
    paymentMethodCode: 'cash',
    paymentMethodName: 'Efectivo',
    amount: amount,
    changeAmount: changeAmount,
    status: 'completed',
    createdAt: DateTime(2026, 1, 1, 12, 5),
  );
}

PaymentMethod _paymentMethod() {
  return const PaymentMethod(
    id: 'cash',
    businessId: 'biz-1',
    name: 'Efectivo',
    code: 'cash',
    isActive: true,
    requiresReference: false,
    position: 0,
  );
}

FiscalDocument _fiscalDoc({
  double subtotal = 0,
  double itbisAmount = 0,
  double total = 0,
}) {
  return FiscalDocument(
    id: 'fiscal-1',
    businessId: 'biz-1',
    orderId: 'order-1',
    paymentId: 'payment-1',
    ncfType: 'B02',
    ncfNumber: 'B0200000001',
    customerName: 'CONSUMIDOR FINAL',
    subtotal: subtotal,
    taxableAmount: subtotal,
    itbisAmount: itbisAmount,
    total: total,
    status: 'active',
    issuedAt: DateTime(2026, 1, 1, 12, 5),
  );
}

String _ticketText(List<int> commands) =>
    latin1.decode(commands, allowInvalid: true);

void main() {
  group('PrintTicketService pricing reconciliation', () {
    test(
      'fiscal invoice prints canonical item and order totals instead of raw drifted fields',
      () {
        final order = _order(
          subtotal: 999.99,
          serviceFee: 999.99,
          tax: 999.99,
          total: 999.99,
        );
        final item = _item(
          id: 'inclusive',
          quantity: 1,
          unitPrice: 500,
          subtotal: 390.63,
          tax: 70.31,
          total: 999.99,
          taxMode: 'inclusive',
          taxRate: 18,
          originalTaxRate: 28,
        );

        final ticket = PrintTicketService.generateFiscalInvoice(
          order: order,
          items: [item],
          fiscalDoc: _fiscalDoc(
            subtotal: 390.63,
            itbisAmount: 70.31,
            total: 500,
          ),
          payment: _payment(amount: 500),
          paymentMethod: _paymentMethod(),
          businessName: 'MangoPOS',
          businessRnc: '123',
        );

        final text = _ticketText(ticket.escPosCommands);
        expect(text, contains('RD\$ 500.00'));
        expect(text, contains('RD\$ 390.63'));
        expect(text, contains('RD\$ 70.31'));
        expect(text, isNot(contains('RD\$ 999.99')));
      },
    );

    test(
      'invoice reprint can prefer stored order and item snapshots for historical consistency',
      () {
        final order = _order(subtotal: 419.49, tax: 75.51, total: 495);
        final item = _item(
          id: 'historic',
          quantity: 1,
          unitPrice: 500,
          subtotal: 419.49,
          tax: 75.51,
          total: 495,
          taxMode: 'inclusive',
          taxRate: 18,
          originalTaxRate: 18,
        );

        final ticket = PrintTicketService.generateInvoice(
          order: order,
          items: [item],
          payments: [_payment(amount: 495)],
          tableName: 'Mesa 1',
          title: '*** REIMPRESION ***',
          preferStoredOrderTotals: true,
          preferStoredItemTotals: true,
        );

        final text = _ticketText(ticket.escPosCommands);
        expect(text, contains('RD\$ 495.00'));
        expect(text, isNot(contains('RD\$ 500.00')));
      },
    );
  });
}
