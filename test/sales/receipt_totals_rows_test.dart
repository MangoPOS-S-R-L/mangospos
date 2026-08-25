import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';

OrderPricingSummary _summary({
  required double subtotal,
  required double tax,
  required double total,
  double discounts = 0,
  double serviceFee = 0,
  double deliveryFee = 0,
}) => OrderPricingSummary(
  subtotal: subtotal,
  tax: tax,
  discounts: discounts,
  serviceFee: serviceFee,
  extraServiceFee: 0,
  deliveryFee: deliveryFee,
  total: total,
);

double _closes(List<ReceiptTotalRow> rows) => rows.fold<double>(
  0,
  (sum, row) => sum + (row.isNegative ? -row.amount : row.amount),
);

ReceiptTotalRow _row(List<ReceiptTotalRow> rows, String label) =>
    rows.firstWhere((row) => row.label == label);

void main() {
  // Mesa A21, 2026-08-24: 4 Margaritas + 2 Palomas + 1 Piña Colada con un 2x1.
  // Gross 2,700 · descuento 1,230 · total 1,470, todo tax-inclusive al 28%
  // (ITBIS 18 + Ley 10).
  final a21 = _summary(
    subtotal: 2109.38,
    tax: 590.62,
    discounts: 1230,
    total: 1470,
  );
  const a21Breakdown = <({String label, double amount})>[
    (label: 'ITBIS (18%)', amount: 379.69),
    (label: 'LEY (10%)', amount: 210.94),
  ];

  group('buildReceiptTotalsRows — el bloque tiene que cuadrar', () {
    test('mesa A21: impuestos separados y descuento después de impuestos', () {
      final rows = buildReceiptTotalsRows(
        summary: a21,
        taxBreakdown: a21Breakdown,
      );

      expect(
        rows.map((r) => r.label),
        ['Subtotal', 'ITBIS (18%)', 'LEY (10%)', 'Descuento'],
      );
      expect(_row(rows, 'Subtotal').amount, 2109.38);
      expect(_row(rows, 'ITBIS (18%)').amount, 379.69);
      expect(_row(rows, 'LEY (10%)').amount, 210.94);
      expect(_row(rows, 'Descuento').amount, 1230);
      expect(_row(rows, 'Descuento').isNegative, isTrue);
      // Antes salía "2,109.38 + ITBIS 590.62" contra un TOTAL de 1,470.
      expect(_closes(rows), closeTo(a21.total, 0.02));
    });

    test('modo post_discount: base neta y descuento informativo', () {
      final rows = buildReceiptTotalsRows(
        summary: a21,
        taxBreakdown: a21Breakdown,
        postDiscountMode: true,
      );

      expect(_row(rows, 'Subtotal').amount, 1148.44);
      expect(_row(rows, 'ITBIS (18%)').amount, 206.72);
      expect(_row(rows, 'LEY (10%)').amount, 114.84);
      // No resta: el total ya viene con el descuento aplicado.
      expect(_row(rows, 'Descuento').isNegative, isFalse);
      expect(
        _row(rows, 'Subtotal').amount +
            _row(rows, 'ITBIS (18%)').amount +
            _row(rows, 'LEY (10%)').amount,
        closeTo(a21.total, 0.02),
      );
    });

    test('sin descuento no aparece la línea', () {
      final rows = buildReceiptTotalsRows(
        summary: _summary(subtotal: 2109.38, tax: 590.62, total: 2700),
        taxBreakdown: a21Breakdown,
      );

      expect(rows.map((r) => r.label), ['Subtotal', 'ITBIS (18%)', 'LEY (10%)']);
      expect(_closes(rows), closeTo(2700, 0.02));
    });

    test('el fee de delivery es exento: fuera de la base, suma al final', () {
      final rows = buildReceiptTotalsRows(
        summary: _summary(
          subtotal: 1000,
          tax: 280,
          total: 1480,
          deliveryFee: 200,
        ),
        taxBreakdown: const [
          (label: 'ITBIS (18%)', amount: 180),
          (label: 'LEY (10%)', amount: 100),
        ],
      );

      expect(_row(rows, 'Subtotal').amount, 1000);
      expect(_row(rows, 'Delivery').amount, 200);
      expect(_closes(rows), closeTo(1480, 0.02));
    });

    test('tasas mixtas: usa los valores nativos del summary', () {
      // Takeout (sin Ley) + dine-in juntos: la tasa efectiva no coincide con
      // la declarada, así que no se puede reconstruir la base desde el total.
      final rows = buildReceiptTotalsRows(
        summary: _summary(
          subtotal: 1000,
          tax: 180,
          discounts: 100,
          total: 1080,
        ),
        taxBreakdown: const [
          (label: 'ITBIS (18%)', amount: 180),
          (label: 'LEY (10%)', amount: 50),
        ],
      );

      expect(_row(rows, 'Subtotal').amount, 1000);
      expect(_row(rows, 'ITBIS (18%)').amount, 180);
      expect(_row(rows, 'LEY (10%)').amount, 50);
      expect(_row(rows, 'Descuento').isNegative, isTrue);
    });

    test('sin desglose de impuestos cae a ITBIS del summary', () {
      final rows = buildReceiptTotalsRows(
        summary: _summary(subtotal: 1000, tax: 180, total: 1180),
        taxBreakdown: const [],
      );

      expect(rows.map((r) => r.label), ['Subtotal', 'ITBIS']);
      expect(_closes(rows), closeTo(1180, 0.02));
    });
  });

  group('parseTaxRatePercentFromLabel', () {
    test('lee la tasa de las labels reales', () {
      expect(parseTaxRatePercentFromLabel('ITBIS (18%)'), 18);
      expect(parseTaxRatePercentFromLabel('LEY (10%)'), 10);
      expect(parseTaxRatePercentFromLabel('ITBIS (16.5%)'), 16.5);
      expect(parseTaxRatePercentFromLabel('Propina Ley (10 %)'), 10);
      expect(parseTaxRatePercentFromLabel('Impuesto'), isNull);
    });
  });
}
