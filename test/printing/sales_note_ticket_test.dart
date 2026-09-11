// NOTA DE VENTA impresa: el papel del documento NO fiscal.
//
// Lo que estas pruebas fijan:
//
//  1. NUNCA IMPRIME NCF. Una nota de venta no consumió comprobante; que el
//     ticket diga "NCF" convertiría un papel interno en algo que parece un
//     comprobante fiscal ante un cliente o una inspección.
//
//  2. IMPRIME SU NÚMERO. El correlativo propio (NV-000123) es lo único que
//     identifica el documento: sin él no se puede reimprimir ni reclamar.
//
//  3. LLEVA LA LEYENDA. "DOCUMENTO SIN VALOR FISCAL" es lo que separa este
//     papel de una factura, porque el resto del layout es idéntico.
//
//  4. LOS IMPORTES NO CAMBIAN. Es la misma venta: cambia el encabezado, no
//     la matemática.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

Order _order() => Order(
  id: 'order-77881234',
  sessionId: 'session-1',
  status: 'paid',
  subtotal: 1000,
  discounts: 0,
  serviceFee: 0,
  tax: 180,
  total: 1180,
  createdAt: DateTime(2026, 9, 10, 12, 0),
);

OrderItem _item() => OrderItem(
  id: 'item-1',
  orderId: 'order-77881234',
  productName: 'Sandwich de pernil',
  quantity: 2,
  unitPrice: 500,
  subtotal: 1000,
  discounts: 0,
  tax: 180,
  total: 1180,
  status: 'completed',
  isTakeout: false,
  taxMode: 'exclusive',
  taxRate: 18,
  createdAt: DateTime(2026, 9, 10, 12, 0),
);

Payment _payment() => Payment(
  id: 'payment-1',
  businessId: 'biz-1',
  orderId: 'order-77881234',
  paymentMethodId: 'cash',
  paymentMethodCode: 'cash',
  paymentMethodName: 'EFECTIVO',
  amount: 1200,
  changeAmount: 20,
  status: 'completed',
  createdAt: DateTime(2026, 9, 10, 12, 5),
);

PrintTicket _invoice({
  String? salesNoteNumber,
  String? fiscalNcf,
  String? fiscalType,
  String title = '*** FACTURA ***',
  String template = 'standard',
}) => PrintTicketService.generateInvoice(
  order: _order(),
  items: [_item()],
  payments: [_payment()],
  tableName: 'TERRAZA 12',
  waiterName: 'Juana',
  businessName: 'Restaurante La Esquina',
  businessRnc: '130123456',
  fiscalNcf: fiscalNcf,
  fiscalType: fiscalType,
  salesNoteNumber: salesNoteNumber,
  customerName: 'Juan Perez',
  title: title,
  template: template,
  taxBreakdown: const [(label: 'ITBIS (18%)', amount: 180)],
);

void main() {
  group('Nota de venta (modelo estándar)', () {
    test('imprime el número de la nota y NO imprime NCF', () {
      final text =
          _invoice(
            salesNoteNumber: 'NV-000123',
            title: '*** NOTA DE VENTA ***',
          ).rawText ??
          '';

      expect(text, contains('NOTA DE VENTA'));
      expect(text, contains('NV-000123'));
      // El renglón del comprobante fiscal no puede aparecer de ninguna forma.
      expect(text, isNot(contains('NCF')));
      expect(text, isNot(contains('TIPO:')));
    });

    test('lleva la leyenda de que no tiene valor fiscal', () {
      final text = _invoice(salesNoteNumber: 'NV-000123').rawText ?? '';

      expect(text, contains('DOCUMENTO SIN VALOR FISCAL'));
      expect(text, contains('No válido para crédito fiscal'));
    });

    test('la nota manda sobre el NCF si por error llegan los dos', () {
      // Defensa: un call site que olvide anular el NCF no puede terminar
      // imprimiendo un comprobante fiscal sobre una venta que no lo emitió.
      final text =
          _invoice(
            salesNoteNumber: 'NV-000123',
            fiscalNcf: 'B0200000001',
            fiscalType: 'B02',
          ).rawText ??
          '';

      expect(text, contains('NV-000123'));
      expect(text, isNot(contains('B0200000001')));
    });

    test('los importes son los mismos que en una factura', () {
      final conNota =
          _invoice(salesNoteNumber: 'NV-000123').rawText?.split('\n') ??
          const [];
      final conNcf =
          _invoice(
            fiscalNcf: 'B0200000001',
            fiscalType: 'B02',
          ).rawText?.split('\n') ??
          const [];

      String totales(List<String> lines) => lines
          .where(
            (l) =>
                l.contains('TOTAL') ||
                l.contains('ITBIS') ||
                l.contains('SUBTOTAL'),
          )
          .join('|');

      expect(totales(conNota), equals(totales(conNcf)));
    });

    test('sin nota, la factura sigue imprimiendo su NCF igual que antes', () {
      final text =
          _invoice(fiscalNcf: 'B0200000001', fiscalType: 'B02').rawText ?? '';

      expect(text, contains('NCF'));
      expect(text, contains('B0200000001'));
      expect(text, isNot(contains('SIN VALOR FISCAL')));
    });
  });

  group('Nota de venta (modelo moderno)', () {
    test('nombra el documento, imprime su número y omite el bloque NCF', () {
      final text =
          _invoice(
            salesNoteNumber: 'NV-000123',
            title: '*** NOTA DE VENTA ***',
            template: 'modern',
          ).rawText ??
          '';

      expect(text, contains('NOTA DE VENTA'));
      expect(text, contains('No. NV-000123'));
      expect(text, isNot(contains('NCF')));
      expect(text, contains('DOCUMENTO SIN VALOR FISCAL'));
    });

    test('conserva los metadatos de la orden', () {
      final text =
          _invoice(salesNoteNumber: 'NV-000123', template: 'modern').rawText ??
          '';

      expect(text, contains('TERRAZA 12'));
      expect(text, contains('Juana'));
      expect(text, contains('Juan Perez'));
    });
  });
}
