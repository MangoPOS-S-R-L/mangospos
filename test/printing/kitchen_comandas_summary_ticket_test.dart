// Resumen impreso de comandas: cuántas comandas y órdenes, cada comanda, y
// AL FINAL cuánto salió de cada producto. Y que a 58mm (32 columnas) nada se
// salga del papel ni se trunque el nombre de un plato.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/kitchen_comanda_report.dart';
import 'package:mangopos/data/models/kitchen_missing_report.dart';
import 'package:mangopos/services/printing/kitchen_comandas_summary_ticket.dart';

var _seq = 0;

Map<String, dynamic> _row({
  String order = '0d000000-aaaa',
  required String sent,
  required String name,
  num quantity = 1,
  String table = 'Mesa 5',
  String? author,
  List<Map<String, dynamic>> modifiers = const [],
  String? notes,
}) => {
  'item_id': 'item-${_seq++}',
  'order_id': order,
  'kitchen_sent_at': sent,
  'product_id': 'p-$name',
  'product_name': name,
  'quantity': quantity,
  'notes': notes,
  'table_name': table,
  'item_author': author,
  'opener_name': 'Avila',
  'area_codes': const ['cocina'],
  'area_names': const ['Cocina'],
  'modifiers': modifiers,
};

final _report = KitchenComandaReport.fromRows([
  _row(
    sent: '2026-09-19T14:05:00Z',
    name: 'Burrito',
    quantity: 2,
    author: 'Claudia Reyes',
    modifiers: [
      {'name': 'Extra queso', 'qty': 2},
    ],
    notes: 'Bien cocido',
  ),
  _row(sent: '2026-09-19T14:05:00Z', name: 'Mojito', author: 'Claudia Reyes'),
  _row(
    order: '0d000000-bbbb',
    sent: '2026-09-19T15:30:00Z',
    name: 'Filete de res a la parrilla con papas y ensalada',
    table: 'Venta rápida',
  ),
  // Misma orden = misma mesa (en la realidad no puede ser otra).
  _row(
    order: '0d000000-bbbb',
    sent: '2026-09-19T15:30:00Z',
    name: 'Burrito',
    table: 'Venta rápida',
  ),
]);

String _ticket({
  int paperWidth = 80,
  bool includeComandas = true,
  KitchenComandaReport? report,
  DateTime? to,
}) =>
    KitchenComandasSummaryTicket.generate(
      report: report ?? _report,
      businessName: 'Restaurante La Esquina del Sabor',
      from: DateTime(2026, 9, 19),
      to: to ?? DateTime(2026, 9, 20),
      stationLabel: 'Cocina',
      includeComandas: includeComandas,
      paperWidth: paperWidth,
      printedAt: DateTime.utc(2026, 9, 19, 22),
    ).rawText ??
    '';

int _widestLine(String text) => text
    .split('\n')
    .map((l) => l.trimRight().length)
    .fold(0, (a, b) => a > b ? a : b);

void main() {
  test('encabezado: comandas enviadas y órdenes', () {
    final raw = _ticket();
    expect(raw, contains('RESUMEN DE COMANDAS'));
    expect(raw, contains('Estación: Cocina'));
    expect(raw, contains('Impreso: 19/09/2026 18:00'));
    expect(raw, matches(RegExp(r'Comandas enviadas: +2')));
    expect(raw, matches(RegExp(r'Órdenes: +2')));
    expect(raw, matches(RegExp(r'Productos: +5')));
  });

  test('cada comanda con hora, mesa, orden, mesero y productos', () {
    final raw = _ticket();
    expect(raw, contains('10:05 MESA 5'));
    expect(raw, contains('#0D000000'));
    expect(raw, contains('Mesero: CLAUDIA REYES'));
    expect(raw, contains(' 2 x Burrito'));
    expect(raw, contains('+ Extra queso x2'));
    expect(raw, contains('Nota: Bien cocido'));
    expect(raw, contains('11:30 VENTA RÁPIDA'));
  });

  test('el total por producto va AL FINAL, después de la última comanda', () {
    final raw = _ticket();
    final totals = raw.indexOf('TOTAL POR PRODUCTO');
    expect(totals, greaterThan(raw.indexOf('11:30 VENTA RÁPIDA')));
    final section = raw.substring(totals);
    expect(section, matches(RegExp(r'Burrito +3')));
    expect(section, matches(RegExp(r'Mojito +1')));
    expect(section, matches(RegExp(r'TOTAL: +5')));
  });

  test('"solo total por producto" no imprime el detalle', () {
    final raw = _ticket(includeComandas: false);
    // La sección se llama "COMANDAS" a secas (el título dice "RESUMEN DE
    // COMANDAS", por eso se busca la línea exacta).
    expect(raw, isNot(matches(RegExp(r'^COMANDAS$', multiLine: true))));
    expect(_ticket(), matches(RegExp(r'^COMANDAS$', multiLine: true)));
    expect(raw, isNot(contains('Mesero:')));
    expect(raw, contains('TOTAL POR PRODUCTO'));
    expect(raw, matches(RegExp(r'Comandas enviadas: +2')));
  });

  test('rango de varios días: cada comanda lleva la fecha', () {
    final raw = _ticket(to: DateTime(2026, 9, 21));
    expect(raw, contains('19/09 10:05 MESA 5'));
  });

  test('a 58mm ninguna línea pasa de 32 columnas', () {
    expect(_widestLine(_ticket(paperWidth: 58)), lessThanOrEqualTo(32));
  });

  test('a 80mm ninguna línea pasa de 48 columnas', () {
    expect(_widestLine(_ticket()), lessThanOrEqualTo(48));
  });

  test('a 58mm un plato de nombre largo no se trunca en el total', () {
    final section = _ticket(
      paperWidth: 58,
    ).split('TOTAL POR PRODUCTO').last.replaceAll('\n', ' ');
    expect(section, contains('con papas y ensalada'));
  });

  group('Comandas vs. cobrado', () {
    Map<String, dynamic> st(
      Map<String, dynamic> row, {
      required String status,
      String orderStatus = 'open',
      String? closed,
      bool courtesy = false,
    }) => {
      ...row,
      'status': status,
      'order_status': orderStatus,
      'order_closed_at': closed,
      'session_closed_at': closed,
      'is_courtesy': courtesy,
    };

    final report = KitchenComandaReport.fromRows([
      st(
        _row(sent: '2026-09-19T14:05:00Z', name: 'Burrito', quantity: 2),
        status: 'paid',
      ),
      st(
        _row(
          sent: '2026-09-19T14:05:00Z',
          name: 'Mojito',
          author: 'Claudia Reyes',
        ),
        status: 'paid',
        courtesy: true,
      ),
      st(
        _row(
          order: '0d000000-cccc',
          sent: '2026-09-19T15:30:00Z',
          name: 'Filete de res a la parrilla con papas y ensalada',
          author: 'Rosa',
        ),
        status: 'served',
        orderStatus: 'paid',
        closed: '2026-09-19T16:00:00Z',
      ),
      st(
        _row(
          order: '0d000000-dddd',
          sent: '2026-09-19T16:00:00Z',
          name: 'Burrito',
        ),
        status: 'served',
      ),
    ]);

    String cmp({int paperWidth = 80, KitchenComandaReport? r, double? sold}) =>
        KitchenComandasSummaryTicket.generateComparison(
          report: r ?? report,
          businessName: 'Restaurante La Esquina del Sabor',
          from: DateTime(2026, 9, 19),
          to: DateTime(2026, 9, 20),
          paperWidth: paperWidth,
          printedAt: DateTime.utc(2026, 9, 19, 22),
          salesItemsSold: sold,
        ).rawText ??
        '';

    test('totales y diferencia', () {
      final raw = cmp();
      expect(raw, contains('COMANDAS VS. COBRADO'));
      expect(raw, matches(RegExp(r'Enviado a cocina: +5')));
      // 2 burritos + 1 mojito de cortesía: la cortesía va en la factura.
      expect(raw, matches(RegExp(r'Cobrado: +3')));
      expect(raw, matches(RegExp(r'de eso, cortesía: +1')));
      expect(raw, matches(RegExp(r'DIFERENCIA: +2')));
      expect(raw, matches(RegExp(r'Pendiente \(abiertas\): +1')));
      expect(raw, matches(RegExp(r'Sin cobrar: +1')));
      expect(raw, isNot(contains('Según Ventas')));
    });

    test('aún sin cobrar (ahora): cada cuenta con sus productos', () {
      final openNow = KitchenComandaReport.fromRows([
        st(
          _row(
            order: '0d000000-eeee',
            sent: '2026-09-18T23:40:00Z',
            name: 'Presidente',
            quantity: 6,
          ),
          status: 'served',
        ),
        {
          ...st(
            _row(
              order: '0d000000-ffff',
              sent: '2026-09-19T12:00:00Z',
              name: 'Burrito',
              table: 'Mesa 9',
            ),
            status: 'pending',
            orderStatus: 'sent',
          ),
          'session_closed_at': '2026-09-19T12:30:00Z',
        },
      ]);
      final raw =
          KitchenComandasSummaryTicket.generateComparison(
            report: report,
            businessName: 'La Esquina',
            from: DateTime(2026, 9, 19),
            to: DateTime(2026, 9, 20),
            openNow: openNow,
            printedAt: DateTime.utc(2026, 9, 19, 22),
          ).rawText ??
          '';
      final section = raw.substring(raw.indexOf('AÚN SIN COBRAR (AHORA)'));
      expect(section, contains('7 productos en 2 cuentas'));
      // Lo más viejo primero: la de anoche.
      expect(section.indexOf('MESA 5'), lessThan(section.indexOf('MESA 9')));
      expect(section, contains('Desde 18/09/2026 19:40'));
      expect(section, contains(' 6 x Presidente'));
      expect(section, contains('Mesa cerrada con la orden abierta'));
    });

    test('sin la foto de "ahora", no imprime esa sección', () {
      expect(cmp(), isNot(contains('AÚN SIN COBRAR')));
    });

    test('cobrado a 0 y cortesía en mesa abierta: dentro de lo cobrado', () {
      final r = KitchenComandaReport.fromRows([
        {
          ...st(
            _row(sent: '2026-09-19T14:05:00Z', name: 'Pan de la casa'),
            status: 'served',
          ),
          'is_zero_value': true,
        },
        st(
          _row(sent: '2026-09-19T14:05:00Z', name: 'Mojito'),
          status: 'served',
          courtesy: true,
        ),
      ]);
      final raw = cmp(r: r);
      expect(raw, matches(RegExp(r'Cobrado: +2')));
      expect(raw, matches(RegExp(r'de eso, a 0: +1')));
      expect(raw, matches(RegExp(r'Pendiente \(abiertas\): +0')));
      expect(raw, contains('Todo lo enviado a cocina está cobrado.'));
    });

    test('las comandas cobradas también salen, primero', () {
      final raw = cmp();
      final paid = raw.indexOf('COMANDAS COBRADAS (1)');
      expect(paid, greaterThan(0));
      expect(paid, lessThan(raw.indexOf('COMANDAS SIN COBRAR')));
      expect(raw.substring(paid), contains(' 2 x Burrito'));
    });

    test('cobrado sin comanda y el RESUMEN al final, cuadrando todo', () {
      final withoutComanda = KitchenComandaReport.fromRows([
        {
          ..._row(
            order: '0d000000-aaaa',
            sent: '2026-09-19T17:30:00Z',
            name: 'Agua',
            quantity: 2,
            table: 'MUEBLE20',
          ),
          'status': 'paid',
          'sent_source': 'none',
        },
      ]);
      final raw =
          KitchenComandasSummaryTicket.generateComparison(
            report: report,
            withoutComanda: withoutComanda,
            businessName: 'La Esquina',
            from: DateTime(2026, 9, 19),
            to: DateTime(2026, 9, 20),
            salesItemsSold: 5,
            printedAt: DateTime.utc(2026, 9, 19, 22),
          ).rawText ??
          '';
      final sinComanda = raw.indexOf('COBRADO SIN COMANDA (1)');
      expect(sinComanda, greaterThan(0));
      expect(raw.substring(sinComanda), contains(' 2 x Agua'));
      expect(raw, contains('Cobrado 19/09/2026 13:30'));
      // El resumen va al final de todo.
      final resumen = raw.lastIndexOf('RESUMEN');
      expect(resumen, greaterThan(sinComanda));
      final tail = raw.substring(resumen);
      expect(tail, matches(RegExp(r'Cobrado sin comanda: +2')));
      // 3 cobrados en comandas + 2 sin comanda.
      expect(tail, matches(RegExp(r'TOTAL COBRADO: +5')));
      expect(tail, matches(RegExp(r'Según Ventas: +5')));
      expect(tail, matches(RegExp(r'Comandas cobradas: +1')));
    });

    test('con el número de Ventas, lo imprime para cuadrar', () {
      expect(cmp(sold: 756), matches(RegExp(r'Según Ventas: +756')));
    });

    test('detalle por comanda: sin cobrar primero, con motivo y mesero', () {
      final raw = cmp();
      final unpaid = raw.indexOf('COMANDAS SIN COBRAR (1)');
      final pending = raw.indexOf('COMANDAS PENDIENTES - MESA ABIERTA (1)');
      final courtesy = raw.indexOf('COMANDAS CON CORTESÍA (1)');
      expect(unpaid, greaterThan(0));
      expect(pending, greaterThan(unpaid));
      expect(courtesy, greaterThan(pending));
      expect(raw, contains('La orden se cobró sin este producto'));
      expect(raw, contains('Mesero: ROSA'));
    });

    test('a 58mm ninguna línea pasa de 32 columnas', () {
      expect(_widestLine(cmp(paperWidth: 58)), lessThanOrEqualTo(32));
    });

    test('todo cobrado: lo dice y no imprime tablas vacías', () {
      final raw = cmp(
        r: KitchenComandaReport.fromRows([
          st(
            _row(sent: '2026-09-19T14:05:00Z', name: 'Burrito'),
            status: 'paid',
          ),
        ]),
      );
      expect(raw, contains('Todo lo enviado a cocina está cobrado.'));
      expect(raw, isNot(contains('POR PRODUCTO')));
    });
  });

  group('Notas de las anulaciones', () {
    Map<String, dynamic> anulada(String order, String name, String? note) => {
      ..._row(order: order, sent: '2026-09-19T16:00:00Z', name: name),
      'status': 'pending',
      'order_status': 'canceled',
      'order_closed_at': '2026-09-19T16:30:00Z',
      'session_closed_at': '2026-09-19T16:30:00Z',
      'is_zero_value': false,
      'void_note': note,
    };

    final withVoids = KitchenComandaReport.fromRows([
      {
        ..._row(sent: '2026-09-19T14:05:00Z', name: 'Burrito'),
        'status': 'paid',
        'is_zero_value': false,
      },
      anulada('0d000000-9999', 'Mojito', 'Juleisy: el cliente se fue'),
      anulada('0d000000-8888', 'Agua', null),
    ]);

    String full({bool includeComandas = true}) =>
        KitchenComandasSummaryTicket.generate(
          report: withVoids,
          businessName: 'La Esquina',
          from: DateTime(2026, 9, 19),
          to: DateTime(2026, 9, 20),
          includeComandas: includeComandas,
          printedAt: DateTime.utc(2026, 9, 19, 22),
        ).rawText ??
        '';

    test('"todas las comandas": sección de anuladas con su nota, antes del '
        'total', () {
      final raw = full();
      final voided = raw.indexOf('COMANDAS ANULADAS (2)');
      expect(voided, greaterThan(0));
      expect(voided, lessThan(raw.indexOf('TOTAL POR PRODUCTO')));
      expect(raw, contains('Nota: Juleisy: el cliente se fue'));
      expect(raw, contains('Nota: (sin nota)'));
      expect(raw, contains('Orden anulada'));
      // Lo anulado no suma en el total por producto.
      expect(raw, matches(RegExp(r'TOTAL: +1')));
    });

    test('"solo total por producto" no imprime las anuladas', () {
      expect(full(includeComandas: false), isNot(contains('ANULADAS')));
    });

    test('"enviado vs. cobrado": la nota en las comandas con anulados', () {
      final raw =
          KitchenComandasSummaryTicket.generateComparison(
            report: withVoids,
            businessName: 'La Esquina',
            from: DateTime(2026, 9, 19),
            to: DateTime(2026, 9, 20),
            printedAt: DateTime.utc(2026, 9, 19, 22),
          ).rawText ??
          '';
      final section = raw.substring(raw.indexOf('COMANDAS CON ANULADOS'));
      expect(section, contains('Nota: Juleisy: el cliente se fue'));
      expect(section, contains('Nota: (sin nota)'));
    });

    test('servidor sin notas: lo dice en vez de "sin nota"', () {
      final old = KitchenComandaReport.fromRows([
        {
          ..._row(sent: '2026-09-19T16:00:00Z', name: 'Mojito'),
          'status': 'pending',
          'order_status': 'canceled',
          'order_closed_at': '2026-09-19T16:30:00Z',
          'session_closed_at': '2026-09-19T16:30:00Z',
          'is_zero_value': false,
        },
      ]);
      final raw =
          KitchenComandasSummaryTicket.generate(
            report: old,
            businessName: 'La Esquina',
            from: DateTime(2026, 9, 19),
            to: DateTime(2026, 9, 20),
            paperWidth: 58,
          ).rawText ??
          '';
      expect(raw, isNot(contains('(sin nota)')));
      expect(raw, contains('no disponible'));
      expect(_widestLine(raw), lessThanOrEqualTo(32));
    });

    test('factura anulada: etiqueta y nota con hora en el ticket', () {
      final r = KitchenComandaReport.fromRows([
        {
          ..._row(sent: '2026-09-18T23:34:00Z', name: 'Johnnie Blue Label'),
          'status': 'void',
          'order_status': 'canceled',
          'order_closed_at': '2026-09-18T23:49:00Z',
          'session_closed_at': '2026-09-18T23:49:00Z',
          'is_zero_value': false,
          'void_note': 'Cristian: Devolviendo A Mesa',
          'void_at': '2026-09-18T23:49:00Z',
          'void_source': 'factura',
        },
      ]);
      final raw =
          KitchenComandasSummaryTicket.generateComparison(
            report: r,
            businessName: 'La Esquina',
            from: DateTime(2026, 9, 18),
            to: DateTime(2026, 9, 19),
            printedAt: DateTime.utc(2026, 9, 19, 22),
          ).rawText ??
          '';
      expect(raw, contains('Factura anulada'));
      expect(raw, contains('Nota (18/09 19:49): Cristian: Devolviendo A Mesa'));
    });

    test('a 58mm la nota no se sale del papel', () {
      final raw =
          KitchenComandasSummaryTicket.generate(
            report: withVoids,
            businessName: 'La Esquina',
            from: DateTime(2026, 9, 19),
            to: DateTime(2026, 9, 20),
            paperWidth: 58,
          ).rawText ??
          '';
      expect(_widestLine(raw), lessThanOrEqualTo(32));
    });
  });

  test('sin comandas: avisa en vez de imprimir tablas vacías', () {
    final raw = _ticket(report: KitchenComandaReport.empty);
    expect(raw, contains('No se enviaron comandas.'));
    expect(raw, contains('Sin productos.'));
  });

  group('Comandas desaparecidas', () {
    Map<String, dynamic> missingRow(
      String kind, {
      required String name,
      String order = '0d000000-cccc',
      String table = 'MUEBLE31',
      num quantity = 1,
      String? removedAt,
      String? reason,
      String? removedBy,
      num? qtyBefore,
      num? qtyAfter,
    }) => {
      ..._row(
        order: order,
        sent: '2026-09-19T23:10:00Z',
        name: name,
        quantity: quantity,
        table: table,
        author: 'Claudia Reyes',
      ),
      'missing_kind': kind,
      'removed_at': removedAt,
      'removed_reason': reason,
      'removed_by': removedBy,
      'qty_before': qtyBefore,
      'qty_after': qtyAfter,
    };

    final missing = KitchenMissingReport.fromRows([
      missingRow(
        'deleted',
        name: 'Blue Label',
        removedAt: '2026-09-20T01:14:00Z',
        reason: 'Cliente no lo quiso',
        removedBy: 'Avila Soto',
        qtyBefore: 1,
        qtyAfter: 0,
      ),
      missingRow(
        'orphan',
        name: 'Mofongo con camarones al ajillo',
        order: '0d000000-dddd',
        table: 'Mesa 5',
        quantity: 2,
      ),
    ]);

    String cmp({KitchenMissingReport? m, int paperWidth = 80}) =>
        KitchenComandasSummaryTicket.generateComparison(
          report: _report,
          businessName: 'La Esquina',
          from: DateTime(2026, 9, 19),
          to: DateTime(2026, 9, 20),
          paperWidth: paperWidth,
          printedAt: DateTime.utc(2026, 9, 19, 22),
          missing: m,
        ).rawText ??
        '';

    test('comparador: los dos grupos, quién, cuándo, motivo y el resumen', () {
      final raw = cmp(m: missing);
      expect(raw, contains('COMANDAS DESAPARECIDAS'));
      expect(raw, contains('BORRADO O REDUCIDO DESPUÉS DE ENVIAR: 1'));
      expect(raw, contains('FUERA DE TODA CUENTA: 2'));
      expect(raw, contains(' 1 x Blue Label'));
      expect(raw, contains('     Borrado 19/09 21:14 por Avila Soto\n'));
      expect(raw, contains('     Motivo: Cliente no lo quiso\n'));
      // La explicación se envuelve en el papel.
      expect(raw, contains('La mesa se cerró con la orden abierta'));
      expect(raw, matches(RegExp(r'Borrado/reducido \(aparte\): +1')));
      expect(raw, matches(RegExp(r'Fuera de toda cuenta: +2')));
      // La sección va antes del resumen.
      expect(
        raw.indexOf('COMANDAS DESAPARECIDAS'),
        lessThan(raw.indexOf('RESUMEN')),
      );
    });

    test('sin el dato (falta la migración) no se imprime nada de eso', () {
      final raw = cmp();
      expect(raw, isNot(contains('DESAPARECIDAS')));
      expect(raw, isNot(contains('Borrado/reducido')));
    });

    test('todas las comandas: sale antes del total; solo total: no', () {
      String full({required bool includeComandas}) =>
          KitchenComandasSummaryTicket.generate(
            report: _report,
            businessName: 'La Esquina',
            from: DateTime(2026, 9, 19),
            to: DateTime(2026, 9, 20),
            includeComandas: includeComandas,
            missing: missing,
          ).rawText ??
          '';
      final withList = full(includeComandas: true);
      expect(withList, contains('COMANDAS DESAPARECIDAS'));
      expect(
        withList.indexOf('COMANDAS DESAPARECIDAS'),
        lessThan(withList.indexOf('TOTAL POR PRODUCTO')),
      );
      expect(full(includeComandas: false), isNot(contains('DESAPARECIDAS')));
    });

    test('a 58mm nada se sale del papel', () {
      expect(
        _widestLine(cmp(m: missing, paperWidth: 58)),
        lessThanOrEqualTo(32),
      );
    });

    test('el conteo de eliminaciones va arriba, con y sin detalle', () {
      String full({required bool detail}) =>
          KitchenComandasSummaryTicket.generate(
            report: _report,
            businessName: 'La Esquina',
            from: DateTime(2026, 9, 19),
            to: DateTime(2026, 9, 20),
            missing: missing,
            includeMissingDetail: detail,
          ).rawText ??
          '';
      for (final detail in [true, false]) {
        final raw = full(detail: detail);
        expect(raw, matches(RegExp(r'Eliminaciones: +1')));
        expect(raw, matches(RegExp(r'Productos eliminados: +1')));
      }
      // "Solo total por producto": el conteo sí, el detalle no.
      expect(full(detail: false), isNot(contains('DESAPARECIDAS')));
      expect(full(detail: true), contains('COMANDAS DESAPARECIDAS'));
    });

    test('el comparador cuenta las eliminaciones en el resumen', () {
      expect(cmp(m: missing), matches(RegExp(r'Eliminaciones: +1')));
    });
  });

  group('Turno que cruza la medianoche', () {
    // 19/09 6:00 p. m. → 20/09 6:00 a. m.
    final from = DateTime(2026, 9, 19, 18);
    final to = DateTime(2026, 9, 20, 6);

    String shiftTicket() =>
        KitchenComandasSummaryTicket.generate(
          report: _report,
          businessName: 'La Esquina',
          from: from,
          to: to,
          printedAt: DateTime.utc(2026, 9, 20, 10),
        ).rawText ??
        '';

    test('el encabezado trae las horas, no el día completo', () {
      final raw = shiftTicket();
      expect(raw, contains('Rango: 19/09/2026 18:00 - 20/09/2026 06:00'));
    });

    test('cada comanda lleva el día junto a la hora', () {
      // Sin el día, "10:05" y "11:30" no dicen de cuál de los dos días son.
      expect(shiftTicket(), contains('19/09 10:05'));
    });

    test('un solo día sigue imprimiendo solo la hora', () {
      final raw =
          KitchenComandasSummaryTicket.generate(
            report: _report,
            businessName: 'La Esquina',
            from: DateTime(2026, 9, 19),
            to: DateTime(2026, 9, 20),
          ).rawText ??
          '';
      expect(raw, contains('Rango: 19/09/2026'));
      expect(raw, isNot(contains('19/09 10:05')));
      expect(raw, contains('10:05'));
    });
  });
}
