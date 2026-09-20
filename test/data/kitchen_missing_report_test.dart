// Comandas "desaparecidas": salieron a cocina y hoy no están en ninguna
// cuenta (fn_kitchen_missing_report, migración 20260919_0002). Y el caso que
// el comparador pintaba como "Orden anulada": producto cargado DESPUÉS de
// cerrar o anular la orden.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/kitchen_comanda_report.dart';
import 'package:mangopos/data/models/kitchen_missing_report.dart';

var _seq = 0;

/// Una fila como la devuelve `fn_kitchen_missing_report`. Horas en UTC: RD
/// es UTC-4.
Map<String, dynamic> _row({
  required String kind,
  String order = 'order-mueble31',
  String sent = '2026-09-19T23:10:00Z',
  String? created,
  String? productId,
  required String name,
  num quantity = 1,
  num unitPrice = 100,
  String table = 'MUEBLE31',
  String? author = 'Claudia Reyes',
  List<String> codes = const ['bar'],
  List<String> names = const ['Bar'],
  String status = 'pending',
  String orderStatus = 'sent',
  String? orderClosedAt,
  String? removedAt,
  String? reason,
  String? removedBy,
  num? qtyBefore,
  num? qtyAfter,
}) => {
  'item_id': 'item-${_seq++}',
  'order_id': order,
  'kitchen_sent_at': sent,
  'item_created_at': created ?? sent,
  'product_id': productId,
  'product_name': name,
  'quantity': quantity,
  'notes': null,
  'status': status,
  'is_takeout': false,
  'table_name': table,
  'origin': 'dine_in',
  'item_author': author,
  'opener_name': null,
  'area_codes': codes,
  'area_names': names,
  'modifiers': const [],
  'unit_price': unitPrice,
  'is_courtesy': false,
  'order_status': orderStatus,
  'order_closed_at': orderClosedAt,
  'session_closed_at': null,
  'sent_source': 'stamp',
  'is_zero_value': false,
  'void_note': null,
  'void_at': null,
  'void_source': null,
  'missing_kind': kind,
  'removed_at': removedAt,
  'removed_reason': reason,
  'removed_by': removedBy,
  'qty_before': qtyBefore,
  'qty_after': qtyAfter,
};

List<Map<String, dynamic>> _rows() => [
  // MUEBLE31: se borró un Blue Label y se redujo la cerveza de 3 a 1.
  _row(
    kind: 'deleted',
    productId: 'blue',
    name: 'Blue Label',
    unitPrice: 9000,
    removedAt: '2026-09-20T01:14:00Z',
    reason: 'Cliente no lo quiso',
    removedBy: 'Avila Soto',
    qtyBefore: 1,
    qtyAfter: 0,
  ),
  _row(
    kind: 'reduced',
    productId: 'cerveza',
    name: 'Cerveza',
    quantity: 2,
    removedAt: '2026-09-20T01:20:00Z',
    reason: 'Se cayó una',
    qtyBefore: 3,
    qtyAfter: 1,
  ),
  // Borrado sin motivo anotado (p. ej. app vieja).
  _row(
    kind: 'deleted',
    order: 'order-mesa-2',
    table: 'Mesa 2',
    sent: '2026-09-19T20:00:00Z',
    name: 'Mofongo',
    codes: const ['cocina'],
    names: const ['Cocina'],
    removedAt: '2026-09-19T20:30:00Z',
  ),
  // Fuera de toda cuenta: huérfana y cargado a una orden anulada.
  _row(
    kind: 'orphan',
    order: 'order-mesa-5',
    table: 'Mesa 5',
    sent: '2026-09-19T18:00:00Z',
    name: 'Mofongo',
    quantity: 2,
    codes: const ['cocina'],
    names: const ['Cocina'],
  ),
  _row(
    kind: 'loaded_after_close',
    order: 'order-mesa-7',
    table: 'Mesa 7',
    sent: '2026-09-19T19:16:00Z',
    name: 'Lavado',
    orderStatus: 'canceled',
    orderClosedAt: '2026-09-19T19:00:00Z',
    codes: const [],
    names: const [],
  ),
];

void main() {
  group('KitchenMissingReport', () {
    test('separa lo quitado de lo que quedó fuera de toda cuenta', () {
      final r = KitchenMissingReport.fromRows(_rows());
      expect(r.isEmpty, isFalse);
      expect(r.removals.map((e) => e.item.productName), [
        'Mofongo',
        'Blue Label',
        'Cerveza',
      ]);
      expect(r.outsideAccounts.map((e) => e.kind), [
        KitchenMissingKind.orphan,
        KitchenMissingKind.loadedAfterClose,
      ]);
      // La reducción cuenta lo quitado (2), no lo que queda.
      expect(r.removedUnits, 4);
      expect(r.outsideUnits, 3);
    });

    test('agrupa por comanda y forma de desaparecer, en orden de envío', () {
      final r = KitchenMissingReport.fromRows(_rows());
      final removals = r.groups(removals: true);
      // Mesa 2 (20:00Z) primero; MUEBLE31 tiene un borrado y una reducción:
      // dos grupos de la misma comanda.
      expect(removals.map((g) => g.comanda.tableName), [
        'Mesa 2',
        'MUEBLE31',
        'MUEBLE31',
      ]);
      expect(removals.map((g) => g.kind), [
        KitchenMissingKind.deleted,
        KitchenMissingKind.deleted,
        KitchenMissingKind.reduced,
      ]);
      expect(removals[1].comanda.waiterName, 'Claudia Reyes');
      expect(removals[1].units, 1);

      final outside = r.groups(removals: false);
      expect(outside.map((g) => g.comanda.tableName), ['Mesa 5', 'Mesa 7']);
    });

    test('el detalle dice cuándo, quién y el motivo', () {
      final r = KitchenMissingReport.fromRows(_rows());
      final blue = r.removals.firstWhere(
        (e) => e.item.productName == 'Blue Label',
      );
      // 01:14Z del 20 = 21:14 del 19 en RD.
      expect(
        blue.detail,
        'Borrado 19/09 21:14 por Avila Soto · Motivo: Cliente no lo quiso',
      );
      final beer = r.removals.firstWhere(
        (e) => e.kind == KitchenMissingKind.reduced,
      );
      expect(
        beer.detail,
        'Reducido de 3 a 1 19/09 21:20 · Motivo: Se cayó una',
      );
      final noReason = r.removals.firstWhere(
        (e) => e.item.tableName == 'Mesa 2',
      );
      expect(noReason.detail, 'Borrado 19/09 16:30 · Motivo: (no se anotó)');
      // Lo de fuera de cuenta explica por qué ninguna cuenta lo muestra.
      expect(
        r.outsideAccounts.first.detail,
        KitchenMissingKind.orphan.explanation,
      );
    });

    test('filtra por estación igual que las comandas', () {
      final r = KitchenMissingReport.fromRows(_rows());
      expect(r.forArea('bar').entries.map((e) => e.item.productName), [
        'Blue Label',
        'Cerveza',
      ]);
      expect(
        r
            .forArea(KitchenComandaReport.noAreaCode)
            .entries
            .map((e) => e.item.productName),
        ['Lavado'],
      );
      expect(identical(r.forArea(null), r), isTrue);
    });

    test('filas sin tipo conocido o sin envío se ignoran', () {
      final r = KitchenMissingReport.fromRows([
        _row(kind: 'otra_cosa', name: 'X'),
        {..._row(kind: 'deleted', name: 'Y'), 'kitchen_sent_at': null},
      ]);
      expect(r.isEmpty, isTrue);
      expect(KitchenMissingReport.empty.isEmpty, isTrue);
    });
  });

  group('Cargado a una orden ya cerrada (comparador)', () {
    KitchenComandaItem item({required String created}) =>
        KitchenComandaItem.fromRow({
          'item_id': 'i-${_seq++}',
          'order_id': 'order-mesa-7',
          'kitchen_sent_at': '2026-09-19T19:16:00Z',
          'item_created_at': created,
          'product_name': 'Lavado',
          'quantity': 1,
          'status': 'pending',
          'table_name': 'Mesa 7',
          'unit_price': 500,
          'order_status': 'canceled',
          'order_closed_at': '2026-09-19T19:00:00Z',
          'is_zero_value': false,
        })!;

    test('después de anular la orden: sin cobrar, no "Orden anulada"', () {
      final i = item(created: '2026-09-19T19:15:00Z');
      expect(i.loadedAfterClose, isTrue);
      expect(i.isOrderVoided, isFalse);
      expect(i.chargeState, KitchenChargeState.unpaid);
      expect(i.stateReason, 'Se cargó a una orden ya cerrada');
    });

    test('antes de anular la orden: sigue siendo anulado', () {
      final i = item(created: '2026-09-19T18:50:00Z');
      expect(i.loadedAfterClose, isFalse);
      expect(i.chargeState, KitchenChargeState.voided);
      expect(i.stateReason, 'Orden anulada');
    });
  });
}
