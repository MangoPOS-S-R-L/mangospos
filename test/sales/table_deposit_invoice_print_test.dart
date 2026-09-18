import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

Order _order({double total = 1000}) => Order(
  id: 'order-1',
  sessionId: 'session-1',
  status: 'paid',
  subtotal: total,
  discounts: 0,
  serviceFee: 0,
  tax: 0,
  total: total,
  createdAt: DateTime(2026, 9, 17, 22, 15),
);

OrderItem _item({double total = 1000}) => OrderItem(
  id: 'item-1',
  orderId: 'order-1',
  productName: 'Botella',
  quantity: 1,
  unitPrice: total,
  subtotal: total,
  discounts: 0,
  tax: 0,
  total: total,
  isTakeout: false,
  status: 'paid',
  taxMode: 'exclusive',
  taxRate: 0,
  createdAt: DateTime(2026, 9, 17, 22, 15),
);

Payment _payment({
  required String code,
  required String name,
  required double amount,
  String id = 'payment-1',
}) => Payment(
  id: id,
  businessId: 'biz-1',
  orderId: 'order-1',
  paymentMethodId: code,
  paymentMethodCode: code,
  paymentMethodName: name,
  amount: amount,
  changeAmount: 0,
  status: 'completed',
  createdAt: DateTime(2026, 9, 17, 22, 20),
);

String _text(List<int> commands) => latin1.decode(commands, allowInvalid: true);

void main() {
  // Lo que el negocio pidió textualmente: "que vaya saliendo una factura que
  // diga, monto restante 9000".
  group('la factura dice con cuánto quedó la mesa', () {
    test('abonó 10,000 y consumió 1,000: el ticket imprime 9,000', () {
      final ticket = PrintTicketService.generateInvoice(
        order: _order(total: 1000),
        items: [_item(total: 1000)],
        payments: [
          _payment(
            code: 'table_deposit',
            name: 'Saldo de mesa',
            amount: 1000,
          ),
        ],
        tableName: 'VIP 1',
        businessName: 'Negocio',
        tableDepositBalanceAfter: 9000,
      );

      final text = _text(ticket.escPosCommands);
      expect(text, contains('SALDO RESTANTE:'));
      expect(text, contains('9,000.00'));
    });

    test(
      'cobro mixto 9,000 de saldo + 500 en efectivo: el saldo queda en cero',
      () {
        final ticket = PrintTicketService.generateInvoice(
          order: _order(total: 9500),
          items: [_item(total: 9500)],
          payments: [
            _payment(
              code: 'table_deposit',
              name: 'Saldo de mesa',
              amount: 9000,
            ),
            _payment(
              code: 'cash',
              name: 'Efectivo',
              amount: 500,
              id: 'payment-2',
            ),
          ],
          tableName: 'VIP 1',
          businessName: 'Negocio',
          tableDepositBalanceAfter: 0,
        );

        final text = _text(ticket.escPosCommands);
        // Los dos pagos salen desglosados: el cliente ve qué pagó con saldo y
        // qué puso de diferencia.
        expect(text, contains('SALDO DE MESA'));
        expect(text, contains('EFECTIVO'));
        expect(text, contains('9,000.00'));
        expect(text, contains('500.00'));
        expect(text, contains('SALDO RESTANTE:'));
      },
    );

    test('una venta sin abono no imprime nada de saldo', () {
      final ticket = PrintTicketService.generateInvoice(
        order: _order(total: 1000),
        items: [_item(total: 1000)],
        payments: [
          _payment(code: 'cash', name: 'Efectivo', amount: 1000),
        ],
        tableName: 'Mesa 3',
        businessName: 'Negocio',
      );

      expect(_text(ticket.escPosCommands), isNot(contains('SALDO RESTANTE')));
    });

    test(
      'el pago con saldo se nombra "SALDO DE MESA" aunque no venga el nombre',
      () {
        final ticket = PrintTicketService.generateInvoice(
          order: _order(total: 1000),
          items: [_item(total: 1000)],
          payments: [
            Payment(
              id: 'payment-1',
              businessId: 'biz-1',
              orderId: 'order-1',
              // Sin paymentMethodName: el ticket tiene que resolverlo por
              // código y no caer en "OTRO".
              paymentMethodId: 'table_deposit',
              paymentMethodCode: 'table_deposit',
              amount: 1000,
              changeAmount: 0,
              status: 'completed',
              createdAt: DateTime(2026, 9, 17, 22, 20),
            ),
          ],
          tableName: 'VIP 1',
          businessName: 'Negocio',
          tableDepositBalanceAfter: 9000,
        );

        final text = _text(ticket.escPosCommands);
        expect(text, contains('SALDO DE MESA'));
        expect(text, isNot(contains('OTRO')));
      },
    );
  });
}
