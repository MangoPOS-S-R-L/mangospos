// Layout de 58mm para factura, comanda, precuenta, cierre de caja y recibo
// de movimiento.
//
// Las térmicas de 58mm dan 32 columnas (16 a doble ancho) contra las 48 de
// 80mm. Antes los builders hardcodeaban 80: separadores de 48 guiones que se
// doblaban a dos renglones y títulos/TOTAL en 2x que se salían del papel.
//
// Estas pruebas fijan el contrato: NINGUNA línea del ticket puede pasar del
// ancho del papel, y a 80mm el layout histórico queda intacto.

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/cashier/services/print_service.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Order _order() => Order(
  // 8+ chars: `generateInvoice` imprime `order.id.substring(0, 8)`.
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

OrderItem _item({
  String name = 'Sandwich de pernil con queso y vegetales',
  bool isTakeout = false,
  String notes = '',
}) => OrderItem(
  id: 'item-1',
  orderId: 'order-1234',
  productName: name,
  quantity: 2,
  unitPrice: 500,
  subtotal: 1000,
  discounts: 0,
  tax: 180,
  total: 1180,
  isTakeout: isTakeout,
  status: 'completed',
  taxMode: 'exclusive',
  taxRate: 18,
  notes: notes,
  createdAt: DateTime(2026, 1, 1, 12, 0),
  modifiers: const [
    OrderItemModifier(
      id: 'mod-1',
      itemId: 'item-1',
      name: 'Extra queso cheddar derretido',
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
  paymentMethodName: 'Efectivo',
  amount: 1180,
  changeAmount: 20,
  status: 'completed',
  createdAt: DateTime(2026, 1, 1, 12, 5),
);

/// Renglón más largo del espejo en texto plano, que respeta el mismo ancho
/// de columnas que sale por papel.
int _widestLine(String? rawText) => (rawText ?? '')
    .split('\n')
    .map((line) => line.trimRight().length)
    .fold<int>(0, (max, len) => len > max ? len : max);

void main() {
  // El ticket de cierre formatea fecha/hora en es_DO.
  setUpAll(() => initializeDateFormatting('es_DO'));

  group('Factura', () {
    test('a 58mm ninguna línea pasa de 32 columnas', () {
      final ticket = PrintTicketService.generateInvoice(
        order: _order(),
        items: [_item(notes: 'Sin cebolla y con la salsa aparte')],
        payments: [_payment()],
        tableName: 'TERRAZA 12',
        waiterName: 'Juana',
        businessName: 'Restaurante La Esquina del Sabor',
        businessAddress: 'Calle Duarte #45, Santo Domingo Este',
        businessRnc: '130123456',
        fiscalNcf: 'B0200000001',
        fiscalType: 'B02',
        customerName: 'Cliente de Prueba',
        deliveryAddress: 'Av. Charles de Gaulle km 8, edificio 3, apto 201',
        title: '*** FACTURA ***',
        paperWidth: 58,
      );

      expect(_widestLine(ticket.rawText), lessThanOrEqualTo(32));
      expect(ticket.rawText, contains('=' * 32));
      expect(ticket.rawText, isNot(contains('=' * 33)));
    });

    test('a 80mm el layout histórico no cambia', () {
      final ticket = PrintTicketService.generateInvoice(
        order: _order(),
        items: [_item()],
        payments: [_payment()],
        tableName: 'TERRAZA 12',
        businessName: 'Restaurante La Esquina del Sabor',
        title: '*** FACTURA ***',
      );

      expect(_widestLine(ticket.rawText), lessThanOrEqualTo(48));
      expect(ticket.rawText, contains('=' * 48));
      // Los asteriscos del título solo se quitan en 58mm / plantillas
      // compactas.
      expect(ticket.rawText, contains('*** FACTURA ***'));
    });
  });

  group('Comanda', () {
    test('a 58mm ninguna línea pasa de 32 columnas', () {
      final ticket = PrintTicketService.generateKitchenTicket(
        order: _order(),
        items: [
          // Dos platos en la MISMA sección para que salga el separador
          // punteado entre items, más uno para llevar (segunda franja).
          _item(notes: 'Bien cocido'),
          _item(name: 'Yaroa de pollo con queso'),
          _item(name: 'Jugo de chinola grande', isTakeout: true),
        ],
        tableName: 'TERRAZA 12',
        waiterName: 'Juana',
        cashierName: 'Pedro',
        customerName: 'Cliente de Prueba',
        areaCode: 'kitchen_hot',
        isAddition: true,
        paperWidth: 58,
      );

      expect(_widestLine(ticket.rawText), lessThanOrEqualTo(32));
      expect(ticket.rawText, contains('-' * 32));
      expect(ticket.rawText, isNot(contains('-' * 33)));
    });

    test('a 80mm sigue en 24 columnas de texto grande y 48 de normal', () {
      final ticket = PrintTicketService.generateKitchenTicket(
        order: _order(),
        items: [_item()],
        tableName: 'TERRAZA 12',
        areaCode: 'kitchen_hot',
      );

      expect(_widestLine(ticket.rawText), lessThanOrEqualTo(48));
      expect(ticket.rawText, contains('=' * 48));
    });
  });

  group('Precuenta', () {
    test('a 58mm ninguna línea pasa de 32 columnas', () {
      final ticket = PrintTicketService.generatePrecheck(
        order: _order(),
        items: [_item(notes: 'Sin cebolla y con la salsa aparte')],
        tableName: 'TERRAZA 12',
        waiterName: 'Juana',
        customerName: 'Cliente de Prueba',
        businessName: 'Restaurante La Esquina del Sabor',
        businessAddress: 'Calle Duarte #45, Santo Domingo Este',
        businessRnc: '130123456',
        title: '*** PRECUENTA ***',
        paperWidth: 58,
      );

      expect(_widestLine(ticket.rawText), lessThanOrEqualTo(32));
      expect(ticket.rawText, contains('=' * 32));
      expect(ticket.rawText, isNot(contains('=' * 33)));
    });

    test('a 80mm el layout histórico no cambia', () {
      final ticket = PrintTicketService.generatePrecheck(
        order: _order(),
        items: [_item()],
        tableName: 'TERRAZA 12',
        businessName: 'Restaurante La Esquina del Sabor',
        title: '*** PRECUENTA ***',
      );

      expect(_widestLine(ticket.rawText), lessThanOrEqualTo(48));
      expect(ticket.rawText, contains('=' * 48));
      expect(ticket.rawText, contains('RNC/CÉDULA: ______________________'));
    });
  });

  group('Recibo de movimiento de caja', () {
    test('a 58mm ninguna línea pasa de 32 columnas', () {
      final ticket = PrintTicketService.generateCashMovementReceipt(
        businessName: 'Restaurante La Esquina del Sabor',
        movementType: 'expense',
        amount: 1500,
        reasonLabel: 'Compra de gas para la cocina',
        description: 'Se pagó al suplidor de siempre en efectivo',
        cashierName: 'Juana',
        sessionId: 'session-12345678',
        when: DateTime(2026, 1, 1, 12, 0),
        paperWidth: 58,
      );

      expect(_widestLine(ticket.rawText), lessThanOrEqualTo(32));
    });

    test('a 80mm el layout histórico no cambia', () {
      final ticket = PrintTicketService.generateCashMovementReceipt(
        businessName: 'Restaurante La Esquina del Sabor',
        movementType: 'expense',
        amount: 1500,
        reasonLabel: 'Compra de gas para la cocina',
        cashierName: 'Juana',
        when: DateTime(2026, 1, 1, 12, 0),
      );

      expect(_widestLine(ticket.rawText), lessThanOrEqualTo(48));
      expect(ticket.rawText, contains('_' * 30));
    });
  });

  group('Cierre de caja', () {
    // El builder no toca Supabase: el cliente es solo para satisfacer el
    // constructor del servicio.
    final service = CashClosePrintService(
      SupabaseClient('https://example.supabase.co', 'anon-key'),
    );

    final input = CashCloseInput(
      expectedCash: 12500,
      expectedCard: 8300,
      expectedTransfer: 2200,
      totalSales: 23000,
      transactionCount: 47,
      cashierName: 'Juana Martínez',
      businessName: 'Restaurante La Esquina del Sabor',
      startAmount: 2000,
      movements: [
        CashMovementEntry(
          type: 'expense',
          amount: 1500,
          reasonLabel: 'Compra de gas para la cocina del segundo piso',
          createdAt: DateTime(2026, 1, 1, 18, 0),
        ),
      ],
    );

    const result = CashCloseResult(
      totalCounted: 12480,
      numericCard: 8300,
      numericTransfer: 2200,
      totalReported: 22980,
      expectedTotal: 23000,
      cashDifference: -20,
      cardDifference: 0,
      transferDifference: 0,
      totalDifference: -20,
    );

    const denominations = [
      DenominationCount(value: 2000, label: '2000', count: 5),
      DenominationCount(value: 500, label: '500', count: 4),
    ];

    final salesByArea = [
      {
        'label': 'Cocina caliente del segundo piso',
        'amount': 15000.0,
        'quantity': 42.0,
        'count': 20,
      },
    ];
    final productsByArea = [
      {
        'label': 'Cocina caliente del segundo piso',
        'products': [
          {'product': 'Sandwich de pernil con queso y vegetales', 'quantity': 12.0},
        ],
      },
    ];

    test('a 58mm ninguna línea pasa de 32 columnas', () {
      final ticket = service.buildEscPos(
        input: input,
        result: result,
        denominations: denominations,
        printedAt: DateTime(2026, 1, 1, 22, 30),
        salesByArea: salesByArea,
        productsByArea: productsByArea,
        paperWidth: 58,
      );

      expect(_widestLine(ticket.plainText), lessThanOrEqualTo(32));
      expect(ticket.plainText, contains('=' * 32));
      expect(ticket.plainText, isNot(contains('=' * 33)));
      // La tabla de 4 columnas se reemplaza por bloques etiqueta/monto.
      expect(ticket.plainText, isNot(contains('Concepto   Esperado')));
      expect(ticket.plainText, contains('Diferencia'));
    });

    test('a 80mm el layout histórico no cambia', () {
      final ticket = service.buildEscPos(
        input: input,
        result: result,
        denominations: denominations,
        printedAt: DateTime(2026, 1, 1, 22, 30),
        salesByArea: salesByArea,
        productsByArea: productsByArea,
      );

      expect(_widestLine(ticket.plainText), lessThanOrEqualTo(48));
      expect(ticket.plainText, contains('Concepto   Esperado   Reportado   Dif.'));
    });
  });
}
