// Reporte de comandas: agrupación por envío, conteos, total por producto,
// filtro por estación y el "Mesero" de cada comanda (misma regla que la
// comanda impresa).

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/kitchen_comanda_report.dart';

var _seq = 0;

/// Una fila como la devuelve `fn_kitchen_comandas_report`. [sent]/[created]
/// en UTC: RD es UTC-4.
Map<String, dynamic> _row({
  String order = 'order-mesa-5',
  required String sent,
  String? created,
  String? productId,
  required String name,
  num quantity = 1,
  String table = 'Mesa 5',
  String? author,
  String? opener = 'Avila Soto',
  List<String> codes = const [],
  List<String> names = const [],
  List<Map<String, dynamic>> modifiers = const [],
  String? notes,
  String status = 'pending',
  bool courtesy = false,
  String orderStatus = 'open',
  String? orderClosedAt,
  String? sessionClosedAt,
}) => {
  'item_id': 'item-${_seq++}',
  'order_id': order,
  'kitchen_sent_at': sent,
  'item_created_at': created ?? sent,
  'product_id': productId,
  'product_name': name,
  'quantity': quantity,
  'notes': notes,
  'status': status,
  'is_courtesy': courtesy,
  'order_status': orderStatus,
  'order_closed_at': orderClosedAt,
  'session_closed_at': sessionClosedAt,
  'is_takeout': false,
  'table_name': table,
  'origin': 'dine_in',
  'item_author': author,
  'opener_name': opener,
  'area_codes': codes,
  'area_names': names,
  'modifiers': modifiers,
};

List<Map<String, dynamic>> _day() => [
  // Mesa 5, ronda 1 (10:05 en RD)
  _row(
    sent: '2026-09-19T14:05:00Z',
    productId: 'burrito',
    name: 'Burrito',
    quantity: 2,
    author: 'Claudia Reyes',
    codes: ['cocina'],
    names: ['Cocina'],
    modifiers: [
      {'name': 'Extra queso', 'qty': 2},
      {'name': 'Sin cebolla', 'qty': 1},
    ],
  ),
  _row(
    sent: '2026-09-19T14:05:00Z',
    productId: 'mojito',
    name: 'Mojito',
    author: 'Claudia Reyes',
    codes: ['bar'],
    names: ['Bar'],
  ),
  _row(
    sent: '2026-09-19T14:05:00Z',
    productId: 'picadera',
    name: 'Picadera',
    codes: ['bar', 'cocina'],
    names: ['Bar', 'Cocina'],
  ),
  // Mesa 5, ronda 2 (10:40): nadie firmó → sale quien abrió la mesa
  _row(
    sent: '2026-09-19T14:40:00Z',
    productId: 'agua',
    name: 'Agua',
    quantity: 3,
    codes: ['bar'],
    names: ['Bar'],
  ),
  _row(sent: '2026-09-19T14:40:00Z', productId: 'pan', name: 'Pan'),
  // Venta rápida (11:01)
  _row(
    order: 'order-rapida',
    sent: '2026-09-19T15:01:00Z',
    productId: 'burrito',
    name: 'Burrito',
    table: 'Venta rápida',
    opener: 'Cuenta Tablet',
    codes: ['cocina'],
    names: ['Cocina'],
  ),
];

void main() {
  group('Comandas', () {
    final report = KitchenComandaReport.fromRows(_day());

    test('una comanda por envío (orden + ronda), del primero al último', () {
      expect(report.comandasCount, 3);
      expect(report.ordersCount, 2);
      expect(report.comandas.map((c) => c.tableName), [
        'Mesa 5',
        'Mesa 5',
        'Venta rápida',
      ]);
      expect(report.comandas.first.sentAt, DateTime(2026, 9, 19, 10, 5));
      expect(report.comandas.first.items.map((i) => i.productName), [
        'Burrito',
        'Mojito',
        'Picadera',
      ]);
    });

    test('número de orden corto, igual que el ticket', () {
      expect(report.comandas.last.orderNumber, 'ORDER-RA');
    });

    test('productos y modificadores', () {
      expect(report.units, 9);
      final burrito = report.comandas.first.items.first;
      expect(burrito.modifiers.map((m) => '${m.name}:${m.qty}'), [
        'Extra queso:2.0',
        'Sin cebolla:1.0',
      ]);
    });

    test('total por producto: el que más salió primero', () {
      final totals = {
        for (final t in report.productTotals) t.productName: t.quantity,
      };
      expect(totals, {
        'Agua': 3,
        'Burrito': 3,
        'Mojito': 1,
        'Picadera': 1,
        'Pan': 1,
      });
      expect(report.productTotals.first.quantity, 3);
      final burrito = report.productTotals.firstWhere(
        (t) => t.productName == 'Burrito',
      );
      expect(burrito.comandas, 2);
    });

    test('sin product_id se suma por nombre', () {
      final r = KitchenComandaReport.fromRows([
        _row(sent: '2026-09-19T14:00:00Z', name: 'Plato del día'),
        _row(
          order: 'otra',
          sent: '2026-09-19T15:00:00Z',
          name: ' plato del DÍA ',
          quantity: 2,
        ),
      ]);
      expect(r.productTotals.single.quantity, 3);
    });
  });

  group('Mesero de la comanda', () {
    test('autor único', () {
      final report = KitchenComandaReport.fromRows(_day());
      expect(report.comandas[0].waiterName, 'Claudia Reyes');
    });

    test('nadie firmó: quien abrió la mesa', () {
      final report = KitchenComandaReport.fromRows(_day());
      expect(report.comandas[1].waiterName, 'Avila Soto');
      expect(report.comandas[2].waiterName, 'Cuenta Tablet');
    });

    test('autores mezclados: el del ítem más reciente', () {
      final report = KitchenComandaReport.fromRows([
        _row(
          sent: '2026-09-19T14:05:00Z',
          created: '2026-09-19T14:04:00Z',
          name: 'A',
          author: 'Claudia',
        ),
        _row(
          sent: '2026-09-19T14:05:00Z',
          created: '2026-09-19T14:04:30Z',
          name: 'B',
          author: 'Rosa',
        ),
        _row(
          sent: '2026-09-19T14:05:00Z',
          created: '2026-09-19T14:04:50Z',
          name: 'C',
        ),
      ]);
      expect(report.comandas.single.waiterName, 'Rosa');
    });
  });

  group('Filtro por estación', () {
    final report = KitchenComandaReport.fromRows(_day());

    test('estaciones disponibles, "Sin área" al final', () {
      expect(report.areas.map((a) => a.name), ['Bar', 'Cocina', 'Sin área']);
    });

    test('Bar: solo lo que fue al bar', () {
      final bar = report.forArea('bar');
      expect(bar.comandasCount, 2);
      expect(bar.ordersCount, 1);
      expect(
        {for (final t in bar.productTotals) t.productName: t.quantity},
        {'Agua': 3, 'Mojito': 1, 'Picadera': 1},
      );
    });

    test('un producto de dos estaciones cuenta en las dos', () {
      final cocina = report.forArea('cocina');
      expect(cocina.productTotals.map((t) => t.productName), [
        'Burrito',
        'Picadera',
      ]);
      expect(cocina.units, 4);
      // Sin filtro la picadera cuenta una sola vez.
      expect(
        report.productTotals
            .firstWhere((t) => t.productName == 'Picadera')
            .quantity,
        1,
      );
    });

    test('Sin área: productos que no imprimen en ninguna estación', () {
      final none = report.forArea(KitchenComandaReport.noAreaCode);
      expect(none.productTotals.single.productName, 'Pan');
    });

    test('sin filtro devuelve el reporte completo', () {
      expect(report.forArea(null), same(report));
    });
  });

  group('Enviado a cocina vs. cobrado', () {
    // Un producto por cada estado posible.
    List<Map<String, dynamic>> rows() => [
      // Cobrado.
      _row(
        order: 'o-cobrada',
        sent: '2026-09-19T14:00:00Z',
        productId: 'burrito',
        name: 'Burrito',
        quantity: 2,
        status: 'paid',
        orderStatus: 'paid',
        orderClosedAt: '2026-09-19T15:00:00Z',
        sessionClosedAt: '2026-09-19T15:00:00Z',
      ),
      // Cortesía (cobrado en cero).
      _row(
        order: 'o-cobrada',
        sent: '2026-09-19T14:00:00Z',
        productId: 'mojito',
        name: 'Mojito',
        status: 'paid',
        courtesy: true,
        orderStatus: 'paid',
        orderClosedAt: '2026-09-19T15:00:00Z',
        sessionClosedAt: '2026-09-19T15:00:00Z',
      ),
      // Agregado DESPUÉS de cobrar la orden: nadie lo cobró.
      _row(
        order: 'o-cobrada',
        sent: '2026-09-19T15:10:00Z',
        productId: 'burrito',
        name: 'Burrito',
        status: 'served',
        orderStatus: 'paid',
        orderClosedAt: '2026-09-19T15:00:00Z',
        sessionClosedAt: '2026-09-19T15:00:00Z',
      ),
      // Mesa todavía abierta: pendiente.
      _row(
        order: 'o-abierta',
        sent: '2026-09-19T16:00:00Z',
        productId: 'burrito',
        name: 'Burrito',
        status: 'served',
      ),
      // Orden cancelada con el plato ya servido.
      _row(
        order: 'o-cancelada',
        sent: '2026-09-19T13:00:00Z',
        productId: 'picadera',
        name: 'Picadera',
        status: 'served',
        orderStatus: 'canceled',
        orderClosedAt: '2026-09-19T13:30:00Z',
        sessionClosedAt: '2026-09-19T13:30:00Z',
      ),
      // Huérfana: la orden sigue viva pero la mesa se cerró.
      _row(
        order: 'o-huerfana',
        sent: '2026-09-19T12:00:00Z',
        productId: 'burrito',
        name: 'Burrito',
        status: 'pending',
        orderStatus: 'sent',
        sessionClosedAt: '2026-09-19T12:00:05Z',
      ),
      // Anulado después de enviarse.
      _row(
        order: 'o-abierta',
        sent: '2026-09-19T16:00:00Z',
        productId: 'burrito',
        name: 'Burrito',
        quantity: 5,
        status: 'void',
      ),
    ];

    test('estado de cobro de cada producto y su motivo', () {
      final items = {
        for (final c in KitchenComandaReport.fromRows(rows()).allComandas)
          for (final i in c.items)
            '${c.orderId}|${i.status}|${i.productName}': i,
      };
      KitchenComandaItem item(String k) => items[k]!;
      expect(
        item('o-cobrada|paid|Burrito').chargeState,
        KitchenChargeState.charged,
      );
      expect(
        item('o-cobrada|paid|Mojito').chargeState,
        KitchenChargeState.courtesy,
      );
      expect(
        item('o-cobrada|served|Burrito').chargeState,
        KitchenChargeState.unpaid,
      );
      // Se cargó después del cobro: el motivo lo dice (no "se cobró sin él").
      expect(
        item('o-cobrada|served|Burrito').stateReason,
        'Se cargó a una orden ya cerrada',
      );
      expect(
        item('o-abierta|served|Burrito').chargeState,
        KitchenChargeState.pending,
      );
      // Anular la orden es a propósito: anulado, nunca "sin cobrar".
      expect(
        item('o-cancelada|served|Picadera').chargeState,
        KitchenChargeState.voided,
      );
      expect(item('o-cancelada|served|Picadera').stateReason, 'Orden anulada');
      expect(
        item('o-huerfana|pending|Burrito').stateReason,
        'Mesa cerrada con la orden abierta',
      );
      expect(
        item('o-abierta|void|Burrito').chargeState,
        KitchenChargeState.voided,
      );
      expect(item('o-abierta|void|Burrito').stateReason, 'Producto anulado');
    });

    test('lo anulado sale de las comandas pero no del comparador', () {
      final report = KitchenComandaReport.fromRows(rows());
      // Sin el burrito anulado (5) ni la picadera de la orden anulada (1).
      expect(report.units, 6);
      expect(
        report.productTotals
            .firstWhere((t) => t.productName == 'Burrito')
            .quantity,
        5,
      );
      expect(report.comparison.voided, 6);
      expect(
        report.productTotals.any((t) => t.productName == 'Picadera'),
        isFalse,
      );
    });

    test('cobrado incluye la cortesía (como Ventas); diferencia = pendiente + '
        'sin cobrar', () {
      final c = KitchenComandaReport.fromRows(rows()).comparison;
      expect(c.sent, 6);
      // 2 burritos cobrados + 1 mojito de cortesía: van en la factura.
      expect(c.charged, 3);
      expect(c.courtesy, 1);
      expect(c.pending, 1);
      expect(c.unpaid, 2);
      expect(c.difference, 3);
      expect(c.pending + c.unpaid, c.difference);
      expect(c.allCharged, isFalse);
    });

    test('todo cobrado aunque haya cortesía: se sigue viendo para revisar', () {
      final c = KitchenComandaReport.fromRows(
        rows().take(2).toList(),
      ).comparison;
      expect(c.allCharged, isTrue);
      expect(c.difference, 0);
      final mojito = c.products.firstWhere((p) => p.productName == 'Mojito');
      expect(mojito.hasDifference, isFalse);
      expect(mojito.needsReview, isTrue);
      expect(c.differences.single.state, KitchenChargeState.courtesy);
    });

    test('por producto: lo sin cobrar primero', () {
      final c = KitchenComandaReport.fromRows(rows()).comparison;
      final burrito = c.products.first;
      expect(burrito.productName, 'Burrito');
      expect(burrito.sent, 5);
      expect(burrito.charged, 2);
      expect(burrito.unpaid, 2);
      expect(burrito.pending, 1);
      expect(burrito.voided, 5);
      expect(burrito.difference, 3);
      // Mojito (cortesía) antes que Picadera (solo anulada).
      expect(c.products.map((p) => p.productName), [
        'Burrito',
        'Mojito',
        'Picadera',
      ]);
    });

    test(
      'detalle: sin cobrar, pendiente, cortesía y anulado, en ese orden',
      () {
        final c = KitchenComandaReport.fromRows(rows()).comparison;
        expect(c.differences.map((d) => d.state), [
          KitchenChargeState.unpaid,
          KitchenChargeState.unpaid,
          KitchenChargeState.pending,
          KitchenChargeState.courtesy,
          KitchenChargeState.voided,
          KitchenChargeState.voided,
        ]);
        // Dentro de cada estado, del primer envío al último.
        expect(c.differences.take(2).map((d) => d.comanda.orderId), [
          'o-huerfana',
          'o-cobrada',
        ]);
        expect(c.differences.skip(4).map((d) => d.comanda.orderId), [
          'o-cancelada',
          'o-abierta',
        ]);
      },
    );

    test('todo cobrado: sin diferencias', () {
      final c = KitchenComandaReport.fromRows(
        rows().take(1).toList(),
      ).comparison;
      expect(c.allCharged, isTrue);
      expect(c.difference, 0);
      expect(c.products.single.hasDifference, isFalse);
    });

    test('el filtro por estación también aplica al comparador', () {
      final report = KitchenComandaReport.fromRows([
        _row(
          sent: '2026-09-19T14:00:00Z',
          productId: 'mojito',
          name: 'Mojito',
          codes: ['bar'],
          names: ['Bar'],
          status: 'served',
          orderStatus: 'paid',
          orderClosedAt: '2026-09-19T15:00:00Z',
        ),
        _row(
          sent: '2026-09-19T14:00:00Z',
          productId: 'burrito',
          name: 'Burrito',
          codes: ['cocina'],
          names: ['Cocina'],
          status: 'paid',
        ),
      ]);
      expect(report.forArea('bar').comparison.unpaid, 1);
      expect(report.forArea('cocina').comparison.allCharged, isTrue);
    });

    test('la nota no muestra los marcadores técnicos', () {
      final report = KitchenComandaReport.fromRows([
        _row(
          sent: '2026-09-19T14:00:00Z',
          name: 'Mojito',
          notes: '[CORTESIA: dueño]\nSin hielo',
        ),
      ]);
      expect(report.comandas.single.items.single.notes, 'Sin hielo');
    });
  });

  group('Comandas no cobradas y aún sin cobrar', () {
    List<Map<String, dynamic>> rows() => [
      // Orden cobrada SIN estos productos (se agregaron después de cobrar):
      // 3 cervezas divididas (3 filas) + 1 burrito.
      for (var i = 0; i < 3; i++)
        _row(
          order: 'o-sin-cobrar',
          sent: '2026-09-19T14:00:00Z',
          productId: 'cerveza',
          name: 'Cerveza',
          status: 'served',
          orderStatus: 'paid',
          orderClosedAt: '2026-09-19T15:00:00Z',
          sessionClosedAt: '2026-09-19T15:00:00Z',
        ),
      _row(
        order: 'o-sin-cobrar',
        sent: '2026-09-19T14:00:00Z',
        productId: 'burrito',
        name: 'Burrito',
        status: 'served',
        orderStatus: 'paid',
        orderClosedAt: '2026-09-19T15:00:00Z',
        sessionClosedAt: '2026-09-19T15:00:00Z',
      ),
      // Mesa abierta: dos rondas.
      _row(
        order: 'o-abierta',
        table: 'Mesa 9',
        sent: '2026-09-19T16:00:00Z',
        productId: 'agua',
        name: 'Agua',
      ),
      _row(
        order: 'o-abierta',
        table: 'Mesa 9',
        sent: '2026-09-19T17:00:00Z',
        productId: 'agua',
        name: 'Agua',
        quantity: 2,
      ),
      // Cobrada.
      _row(
        order: 'o-cobrada',
        sent: '2026-09-19T13:00:00Z',
        productId: 'burrito',
        name: 'Burrito',
        status: 'paid',
      ),
    ];

    test('comandasIn: cuáles fueron, con solo sus productos no cobrados', () {
      final report = KitchenComandaReport.fromRows(rows());
      final unpaid = report.comandasIn(KitchenChargeState.unpaid);
      expect(unpaid, hasLength(1));
      expect(
        unpaid.single.displayItems.map((i) => '${i.quantity} ${i.productName}'),
        ['3.0 Cerveza', '1.0 Burrito'],
      );
      expect(
        unpaid.single.items.first.stateReason,
        'La orden se cobró sin este producto',
      );
      expect(report.comandasIn(KitchenChargeState.pending), hasLength(2));
      expect(
        report.comandasIn(KitchenChargeState.charged).single.orderId,
        'o-cobrada',
      );
    });

    test('byComanda: una entrada por comanda y estado, sin cobrar primero', () {
      final groups = KitchenComandaReport.fromRows(rows()).comparison.byComanda;
      expect(groups.map((g) => '${g.state.name}:${g.comanda.orderId}'), [
        'unpaid:o-sin-cobrar',
        'pending:o-abierta',
        'pending:o-abierta',
      ]);
      expect(groups.first.reason, 'La orden se cobró sin este producto');
      expect(groups.first.comanda.units, 4);
    });

    test('comandasInAny junta varios estados; accounts no filtra', () {
      final report = KitchenComandaReport.fromRows(rows());
      final any = report.comandasInAny(const {
        KitchenChargeState.charged,
        KitchenChargeState.pending,
      });
      expect(any.map((c) => c.orderId).toSet(), {'o-abierta', 'o-cobrada'});
      // accounts: una por orden, con TODO (no solo lo que se debe).
      expect(report.accounts.map((a) => a.orderId).toSet(), {
        'o-sin-cobrar',
        'o-abierta',
        'o-cobrada',
      });
    });

    test('unitsIn cuenta por estado dentro de una comanda', () {
      final c = KitchenComandaReport.fromRows(
        rows(),
      ).comandas.firstWhere((c) => c.orderId == 'o-sin-cobrar');
      expect(c.unitsIn(KitchenChargeState.unpaid), 4);
      expect(c.unitsIn(KitchenChargeState.charged), 0);
    });

    test('openAccounts: una cuenta por orden, lo más viejo primero', () {
      final openNow = KitchenComandaReport.fromRows([
        _row(
          order: 'o-hoy',
          table: 'Mesa 9',
          sent: '2026-09-19T16:00:00Z',
          productId: 'agua',
          name: 'Agua',
        ),
        _row(
          order: 'o-hoy',
          table: 'Mesa 9',
          sent: '2026-09-19T17:00:00Z',
          productId: 'agua',
          name: 'Agua',
          quantity: 2,
          author: 'Rosa',
        ),
        _row(
          order: 'o-huerfana',
          table: 'Mesa 2',
          sent: '2026-09-18T23:00:00Z',
          productId: 'burrito',
          name: 'Burrito',
          orderStatus: 'sent',
          sessionClosedAt: '2026-09-19T01:00:00Z',
        ),
      ]);
      final accounts = openNow.openAccounts;
      expect(accounts.map((a) => a.orderId), ['o-huerfana', 'o-hoy']);
      expect(accounts.first.isOrphan, isTrue);
      expect(accounts.first.since, DateTime(2026, 9, 18, 19));
      final hoy = accounts.last;
      expect(hoy.isOrphan, isFalse);
      expect(hoy.units, 3);
      // Las dos rondas del agua se leen como una línea.
      expect(hoy.displayItems.single.quantity, 3);
      expect(hoy.waiterName, 'Rosa');
    });
  });

  group('Nunca pendiente: anulado, cortesía, cobrado a 0', () {
    // Todo en una MESA ABIERTA (orden y sesión abiertas): lo único que puede
    // quedar pendiente es lo que de verdad se debe.
    List<Map<String, dynamic>> rows() => [
      {
        ..._row(
          sent: '2026-09-19T22:05:00Z',
          productId: 'mojito',
          name: 'Mojito',
          notes: '[CORTESIA: cumpleaños]',
          courtesy: true,
          status: 'served',
        ),
        'is_zero_value': true,
      },
      {
        ..._row(
          sent: '2026-09-19T22:05:00Z',
          productId: 'pan',
          name: 'Pan de la casa',
          status: 'served',
        ),
        'is_zero_value': true,
      },
      _row(
        sent: '2026-09-19T22:05:00Z',
        productId: 'burrito',
        name: 'Burrito',
        status: 'served',
      ),
      _row(
        sent: '2026-09-19T22:05:00Z',
        productId: 'picadera',
        name: 'Picadera',
        status: 'void',
      ),
    ];

    test('cortesía en mesa abierta = cortesía, no pendiente', () {
      final items = KitchenComandaReport.fromRows(
        rows(),
      ).allComandas.single.items;
      expect(items[0].chargeState, KitchenChargeState.courtesy);
      expect(items[1].chargeState, KitchenChargeState.zeroCharge);
      expect(items[2].chargeState, KitchenChargeState.pending);
      expect(items[3].chargeState, KitchenChargeState.voided);
    });

    test('solo el burrito cuenta como pendiente y como diferencia', () {
      final c = KitchenComandaReport.fromRows(rows()).comparison;
      expect(c.pending, 1);
      expect(c.difference, 1);
      // Cortesía y cobrado a 0 van dentro de lo cobrado.
      expect(c.charged, 2);
      expect(c.courtesy, 1);
      expect(c.zeroCharge, 1);
      // Cobrado a 0 no es diferencia: no aparece en el detalle.
      expect(
        c.differences.any((d) => d.state == KitchenChargeState.zeroCharge),
        isFalse,
      );
    });

    test('"aún sin cobrar" deja fuera la cortesía, lo a 0 y lo anulado', () {
      final accounts = KitchenComandaReport.fromRows(rows()).openAccounts;
      expect(accounts.single.displayItems.single.productName, 'Burrito');
      expect(accounts.single.units, 1);
    });

    test('una mesa con solo cortesía no aparece en "aún sin cobrar"', () {
      final report = KitchenComandaReport.fromRows(rows().take(2).toList());
      expect(report.openAccounts, isEmpty);
    });
  });

  group('Cuenta dividida', () {
    // fn_explode_items_to_units parte "3 x Agua con hielo" en 3 filas de 1
    // con el modificador prorrateado (1/3 = 0.333). La RPC les devuelve la
    // ronda de su original ('split').
    List<Map<String, dynamic>> rows() => [
      for (var i = 0; i < 3; i++)
        {
          ..._row(
            sent: '2026-09-19T14:05:00Z',
            productId: 'agua',
            name: 'Agua',
            modifiers: [
              {'name': 'Con hielo', 'qty': 0.333},
            ],
          ),
          'sent_source': i == 0 ? 'stamp' : 'split',
        },
      _row(sent: '2026-09-19T14:05:00Z', productId: 'pan', name: 'Pan'),
    ];

    test('la comanda la muestra en una línea: 3 × Agua', () {
      final comanda = KitchenComandaReport.fromRows(rows()).comandas.single;
      expect(comanda.items, hasLength(4));
      final display = comanda.displayItems;
      expect(display.map((i) => '${i.quantity} ${i.productName}'), [
        '3.0 Agua',
        '1.0 Pan',
      ]);
      // 0.333 × 3 = 0.999: vuelve a ser 1.
      expect(display.first.modifiers.single.qty, 1);
    });

    test('los totales cuentan las 3 unidades', () {
      final report = KitchenComandaReport.fromRows(rows());
      expect(
        report.productTotals
            .firstWhere((t) => t.productName == 'Agua')
            .quantity,
        3,
      );
      expect(report.comandas.single.items[1].sentSource, 'split');
    });

    test('notas distintas no se juntan', () {
      final comanda = KitchenComandaReport.fromRows([
        _row(sent: '2026-09-19T14:05:00Z', productId: 'agua', name: 'Agua'),
        _row(
          sent: '2026-09-19T14:05:00Z',
          productId: 'agua',
          name: 'Agua',
          notes: 'Sin hielo',
        ),
      ]).comandas.single;
      expect(comanda.displayItems, hasLength(2));
    });
  });

  test('nota de anulación: se lee y la comanda la expone', () {
    final report = KitchenComandaReport.fromRows([
      {
        ..._row(
          order: 'o-anulada',
          sent: '2026-09-19T14:00:00Z',
          productId: 'burrito',
          name: 'Burrito',
          orderStatus: 'canceled',
          orderClosedAt: '2026-09-19T15:00:00Z',
          sessionClosedAt: '2026-09-19T15:00:00Z',
        ),
        'void_note': 'Juleisy: el cliente se fue',
      },
      _row(sent: '2026-09-19T16:00:00Z', productId: 'agua', name: 'Agua'),
    ]);
    final voided = report.comandasIn(KitchenChargeState.voided).single;
    expect(voided.voidNote, 'Juleisy: el cliente se fue');
    expect(
      report.comparison.byComanda
          .firstWhere((g) => g.state == KitchenChargeState.voided)
          .note,
      'Juleisy: el cliente se fue',
    );
    // Lo que no está anulado no tiene nota.
    expect(report.comandas.single.voidNote, isNull);
  });

  test('factura anulada: la etiqueta y la nota con hora (caso 04B71463)', () {
    final report = KitchenComandaReport.fromRows([
      {
        ..._row(
          order: '04b71463-x',
          sent: '2026-09-18T23:34:00Z',
          name: 'Johnnie Blue Label 750Ml',
          table: 'MUEBLE08',
          status: 'void',
          orderStatus: 'canceled',
          orderClosedAt: '2026-09-18T23:49:00Z',
          sessionClosedAt: '2026-09-18T23:49:00Z',
        ),
        'void_note': 'Cristian: Devolviendo A Mesa',
        'void_at': '2026-09-18T23:49:00Z',
        'void_source': 'factura',
      },
    ]);
    final c = report.comandasIn(KitchenChargeState.voided).single;
    // Anular la factura deja los productos en 'void', pero NO es "producto
    // anulado": es la factura.
    expect(c.items.single.stateReason, 'Factura anulada');
    expect(
      report.voidNoteLabel(c),
      'Nota (18/09 19:49): Cristian: Devolviendo A Mesa',
    );
  });

  test('orden anulada desde la mesa y producto anulado suelto', () {
    final report = KitchenComandaReport.fromRows([
      {
        ..._row(
          order: 'mesa',
          sent: '2026-09-18T23:50:00Z',
          name: 'A',
          orderStatus: 'canceled',
          orderClosedAt: '2026-09-19T00:07:00Z',
        ),
        'void_note': 'Cristian: 0',
        'void_at': '2026-09-19T00:07:14Z',
        'void_source': 'mesa',
      },
      {
        ..._row(order: 'suelto', sent: '2026-09-18T23:55:00Z', name: 'B'),
        'status': 'void',
        'void_note': null,
      },
    ]);
    final byOrder = {
      for (final c in report.comandasIn(KitchenChargeState.voided))
        c.orderId: c,
    };
    expect(byOrder['mesa']!.items.single.stateReason, 'Orden anulada');
    expect(
      report.voidNoteLabel(byOrder['mesa']!),
      'Nota (18/09 20:07): Cristian: 0',
    );
    expect(byOrder['suelto']!.items.single.stateReason, 'Producto anulado');
    expect(report.voidNoteLabel(byOrder['suelto']!), 'Nota: (sin nota)');
  });

  test('"sin nota" solo si el servidor manda notas; si no, lo dice', () {
    Map<String, dynamic> anulada({bool withNoteColumn = true}) => {
      ..._row(
        order: 'o-anulada',
        sent: '2026-09-19T14:00:00Z',
        name: 'Burrito',
        orderStatus: 'canceled',
        orderClosedAt: '2026-09-19T15:00:00Z',
        sessionClosedAt: '2026-09-19T15:00:00Z',
      ),
      if (withNoteColumn) 'void_note': null,
    };
    final fresh = KitchenComandaReport.fromRows([anulada()]);
    final old = KitchenComandaReport.fromRows([anulada(withNoteColumn: false)]);
    final c = fresh.comandasIn(KitchenChargeState.voided).single;
    expect(fresh.voidNoteLabel(c), 'Nota: (sin nota)');
    expect(old.hasVoidNotes, isFalse);
    expect(
      old.voidNoteLabel(old.comandasIn(KitchenChargeState.voided).single),
      contains('falta actualizar la migración 20260919_0001'),
    );
    expect(old.forArea('cocina').hasVoidNotes, isFalse);
  });

  test('detecta la RPC vieja (sin columnas de cobro)', () {
    final fresh = KitchenComandaReport.fromRows([
      {
        ..._row(sent: '2026-09-19T14:00:00Z', name: 'A'),
        'is_zero_value': false,
      },
    ]);
    final old = KitchenComandaReport.fromRows([
      _row(sent: '2026-09-19T14:00:00Z', name: 'A'),
    ]);
    expect(fresh.hasChargeData, isTrue);
    expect(old.hasChargeData, isFalse);
    // El filtro por estación no la pierde.
    expect(old.forArea('cocina').hasChargeData, isFalse);
    expect(KitchenComandaReport.empty.hasChargeData, isTrue);
  });

  test('filas inválidas se ignoran; reporte vacío', () {
    final report = KitchenComandaReport.fromRows([
      {'item_id': 'x', 'order_id': 'o', 'kitchen_sent_at': null},
    ]);
    expect(report.isEmpty, isTrue);
    expect(report.productTotals, isEmpty);
    expect(report.areas, isEmpty);
  });
}
