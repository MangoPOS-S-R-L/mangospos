import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_order_projector.dart';
import 'package:mangopos/core/offline/order_item_snapshot.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/utils/offer_deal_pricing.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/presentation/sales/logic/unit_removal_plan.dart';
import 'package:mangopos/presentation/sales/view/widgets/product_detail_modal.dart';
import 'package:mangopos/services/session/session_controller.dart';

class _Session extends SessionController {
  @override
  SessionState build() => const SessionState();
}

OrderItem offer(
  String id, {
  double qty = 4,
  double discount = 250,
  bool rule = true,
}) => OrderItem.fromMap({
  'id': id,
  'order_id': 'order',
  'product_id': 'beer',
  'product_name': '4x3 Presidente Normal',
  'qty': qty,
  'unit_price': 250,
  'subtotal': qty * 250 / 1.28,
  'tax': qty * 250 - qty * 250 / 1.28,
  'tax_mode': 'inclusive',
  'tax_rate': 28,
  'discounts': discount,
  'total': qty * 250 - discount,
  'status': 'pending',
  'notes': '[DEAL:promo]\n${rule ? '[DEAL_RULE:4:250.00]' : ''}',
  'created_at': '2026-10-14T23:50:00Z',
});

void main() {
  for (final (quantity, discount, total) in [
    (8.0, 500.0, 1500.0),
    (7.0, 250.0, 1500.0),
    (6.0, 250.0, 1250.0),
    (5.0, 250.0, 1000.0),
    (4.0, 250.0, 750.0),
    (3.0, 0.0, 750.0),
    (2.0, 0.0, 500.0),
    (1.0, 0.0, 250.0),
  ]) {
    test('$quantity cervezas: descuento $discount y total $total', () {
      final row = offer('one', qty: 8, discount: 500);
      expect(discountAtQuantity(row, quantity), discount);
      final next = row.copyWith(
        quantity: quantity,
        subtotal: quantity * 250 / 1.28,
        tax: quantity * 250 - quantity * 250 / 1.28,
        discounts: discountAtQuantity(row, quantity),
      );
      expect(summarizeOrderPricing(null, [next]).total, total);
    });
  }
  for (final quantity in [4.0, 6.0, 7.0]) {
    test(
      'grupo de dos paquetes a $quantity coincide con Eliminar unidades',
      () {
        final rows = [offer('a'), offer('b')];
        final discount = discountForGroupQuantity(rows, quantity);
        expect(discount, 250);
        final steps = planUnitRemoval(rows, 8 - quantity);
        var retainedDiscount = 0.0;
        var remaining = quantity;
        for (final row in rows) {
          final next = remaining.clamp(0, row.quantity).toDouble();
          retainedDiscount += groupLineDiscount(
            item: row,
            quantity: next,
            groupDiscount: discount,
            groupGross: 2000,
          );
          remaining -= next;
        }
        expect(
          retainedDiscount,
          250,
          reason: 'no reparte descuento a la fila eliminada',
        );
        var removalDiscount = 0.0;
        for (final row in rows) {
          final matches = steps.where((s) => s.item.id == row.id);
          final qty = matches.isEmpty
              ? row.quantity
              : matches.single.nextQuantity;
          removalDiscount += discountAtQuantity(row, qty);
        }
        expect(removalDiscount, retainedDiscount);
      },
    );
  }
  test('cada promoción exige su paquete completo, también 2x1 y 3x2', () {
    for (final (units, discount) in [(2, 400.0), (3, 250.0), (4, 500.0)]) {
      final rule = OfferDealRule(units, discount);
      // Desde dos paquetes, cualquier unidad retirada rompe el segundo.
      for (var removed = 1; removed <= units; removed++) {
        expect(rule.discountFor(units * 2.0 - removed), discount);
      }
      expect(rule.discountFor(units - 1.0), 0);
      expect(rule.discountFor(units * 2.0), discount * 2);
    }
  });
  test('un paquete legacy sin cambios conserva sus 250 al borrar el otro', () {
    expect(
      groupLineDiscount(
        item: offer('a', rule: false),
        quantity: 4,
        groupDiscount: 250,
        groupGross: 2000,
      ),
      250,
    );
  });
  test('notas agrupadas conservan la identidad y regla de cada paquete', () {
    final notes = preserveOfferRule(
      'sin hielo\n[DEAL:otra]\n[DEAL_RULE:2:100.00]',
      offer('a'),
    );
    expect(notes, contains('[DEAL:promo]'));
    expect(notes, contains('[DEAL_RULE:4:250.00]'));
    expect(notes, isNot(contains('[DEAL:otra]')));
    expect(cleanOrderItemNote(notes), 'sin hielo');
  });
  test('cortesías y descuentos comunes conservan prorrateo', () {
    final row = offer(
      'a',
    ).copyWith(notes: '[CORTESIA:autorizada]', discounts: 1000);
    expect(discountAtQuantity(row, 3), 750);
    expect(
      groupLineDiscount(
        item: offer('a'),
        quantity: 4,
        groupDiscount: 1000,
        groupGross: 2000,
        managedOfferDiscount: false,
      ),
      500,
    );
  });
  for (final qty in [4.0, 6.0, 7.0]) {
    test('Hub sin WAN recibe cantidad $qty sin fraccionar descuento', () {
      final row = offer('a', qty: 8, discount: 500);
      final projected = HubOrderProjector.projectOrder([
        {
          'seq': 1,
          'type': 'add_item',
          'order_id': 'order',
          'table_id': 'table',
          'item_id': 'a',
          'qty': 8,
          'product_price': 250,
          'notes': row.notes,
          'item_snapshot': OrderItemSnapshot.encode(row),
        },
        {
          'seq': 2,
          'type': 'update_item_quantity',
          'order_id': 'order',
          'item_id': 'a',
          'quantity': qty,
        },
      ], orderId: 'order')!;
      expect(projected.items.single.discounts, 250);
      expect(projected.total, qty * 250 - 250);
    });
  }
  for (final qty in [4, 6, 7]) {
    testWidgets('modal agrupado guarda $qty con descuento 250, no 125', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      OrderItem? saved;
      final rows = [offer('a'), offer('b')];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWith(_Session.new)],
          child: MaterialApp(
            home: Scaffold(
              body: ProductDetailModal(
                item: rows.first,
                groupedItems: rows,
                onSave: (_) async {},
                onDelete: (_) async {},
                onSaveBatch: (items, item, reduction) async {
                  saved = item;
                  expect(reduction, isNotNull);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.controller?.text.contains('[DEAL_RULE:') == true,
        ),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const ValueKey('product-detail-qty')),
        '$qty',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardar cambios').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Error de digitación'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('QUITAR PRODUCTO'));
      await tester.pumpAndSettle();
      expect(saved?.quantity, qty.toDouble());
      expect(saved?.discounts, 250);
      expect(saved?.notes, contains('[DEAL_RULE:4:250.00]'));
    });
  }
}
