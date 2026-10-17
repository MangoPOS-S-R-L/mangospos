import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/data/utils/issued_receipt_order.dart';

OrderItem item(
  String id, {
  double qty = 1,
  double subtotal = 250,
  double discount = 0,
}) => OrderItem.fromMap({
  'id': id,
  'order_id': 'order',
  'qty': qty,
  'unit_price': 250,
  'subtotal': subtotal,
  'tax': 0,
  'discounts': discount,
  'total': subtotal - discount,
  'status': 'paid',
  'created_at': '2026-10-15T00:00:00Z',
});
Order receipt({double subtotal = 500, double discount = 0}) => Order.fromMap({
  'id': 'order',
  'subtotal': subtotal,
  'tax': 0,
  'discounts': discount,
  'total': subtotal - discount,
  'created_at': '2026-10-15T00:00:00Z',
});
void main() {
  test('el cero por defecto fiscal no borra el descuento de la venta', () {
    final printed = issuedReceiptOrder(receipt(subtotal: 0), {
      'ncf_number': 'B0100000012',
      'ncf_type': 'B01',
      'subtotal': 4296.88,
      'itbis_amount': 773.46,
      'service_fee': 429.67,
      'discount': 0,
      'total': 4250,
    });
    expect(printed.discounts, 1250.01);
    expect(printed.total, 4250);
    expect(printed.subtotal, 4296.88);
    expect(printed.tax, 773.46);
    expect(printed.serviceFee, 429.67);
  });

  test('la nota conserva su descuento explícito aunque no cuadre', () {
    final printed = issuedReceiptOrder(receipt(subtotal: 0), {
      'note_number': 'NV-000123',
      'subtotal': 500,
      'tax': 0,
      'discount': 0,
      'total': 400,
    });
    expect(printed.discounts, 0);
    expect(
      () => validateIssuedReceiptItems(printed, [item('a'), item('b')]),
      throwsStateError,
    );
  });

  test('un descuento fiscal explícito distinto de cero se conserva', () {
    final printed = issuedReceiptOrder(receipt(subtotal: 0), {
      'ncf_number': 'B0100000012',
      'subtotal': 500,
      'itbis_amount': 0,
      'discount': 50,
      'total': 400,
    });
    expect(printed.discounts, 50);
    expect(
      () => validateIssuedReceiptItems(printed, [
        item('a', discount: 25),
        item('b', discount: 25),
      ]),
      throwsStateError,
    );
  });

  test('derivar el descuento fiscal no admite un detalle sin descuento', () {
    final printed = issuedReceiptOrder(receipt(subtotal: 0), {
      'ncf_number': 'B0100000012',
      'subtotal': 500,
      'itbis_amount': 0,
      'discount': 0,
      'total': 400,
    });
    expect(
      () => validateIssuedReceiptItems(printed, [item('a'), item('b')]),
      throwsStateError,
    );
  });

  test('una factura válida conserva su detalle completo', () {
    expect(
      () => validateIssuedReceiptItems(receipt(), [item('a'), item('b')]),
      returnsNormally,
    );
  });
  test('una factura con solo la mitad del detalle no imprime', () {
    expect(
      () => validateIssuedReceiptItems(receipt(), [item('a')]),
      throwsStateError,
    );
  });
  test(
    'falta una unidad gratis: aunque el total cuadre, subtotal y descuento no cuadran',
    () {
      expect(
        () => validateIssuedReceiptItems(receipt(discount: 250), [item('a')]),
        throwsStateError,
      );
    },
  );
  test('el detalle repetido por paginación concurrente no se acepta', () {
    expect(
      () => validateIssuedReceiptItems(receipt(), [item('a'), item('a')]),
      throwsStateError,
    );
  });
  test('no se aceptan importes no finitos de una línea', () {
    expect(
      () => validateIssuedReceiptItems(receipt(), [
        item('a').copyWith(subtotal: double.nan),
        item('b'),
      ]),
      throwsStateError,
    );
  });
  test(
    'la reimpresión carga todas las páginas, también más de 500 líneas',
    () async {
      final offsets = <int>[];
      final client = SupabaseClient(
        'http://localhost:54321',
        'test',
        httpClient: MockClient((r) async {
          Object payload = [];
          if (r.url.path.endsWith('/orders')) payload = {'id': 'order'};
          if (r.url.path.endsWith('/order_items')) {
            final start = int.parse(r.url.queryParameters['offset'] ?? '0');
            final limit = int.parse(r.url.queryParameters['limit'] ?? '250');
            offsets.add(start);
            final count = (601 - start).clamp(0, limit);
            payload = List.generate(
              count,
              (i) => {
                'id': 'item-${start + i}',
                'order_id': 'order',
                'qty': 1,
                'unit_price': 250,
                'subtotal': 250,
                'tax': 0,
                'discounts': 0,
                'total': 250,
                'status': 'paid',
                'created_at': '2026-10-15T00:00:00Z',
              },
            );
          }
          return http.Response(
            jsonEncode(payload),
            200,
            request: r,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final result = await SalesRepository(
        client,
      ).getAllOrderItems('order', businessId: 'biz');
      expect(result, hasLength(601));
      expect(result.last.id, 'item-600');
      expect(offsets, [0, 250, 500]);
      await client.dispose();
    },
  );
}
