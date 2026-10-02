// Verificación de activos: lectura de lo que devuelve el servidor, en qué
// pestaña cae cada línea, el avance, qué hay que decidir al cerrar y el
// payload de esas decisiones. Más lo nuevo de la ficha: cantidad, total,
// «sin verificar» y el código de etiqueta.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/fixed_asset_verification_state.dart';
import 'package:mangopos/presentation/inventory/state/fixed_assets_state.dart';

Map<String, dynamic> _l(
  String assetId, {
  bool expected = true,
  int? expectedQty = 1,
  int? found,
  String? observed,
  String expectedStatus = 'active',
  bool isNew = false,
  double? unit = 1000,
  String? registered = 'Cocina',
  String? resolution,
}) => {
  'id': 'line-$assetId',
  'verification_id': 'v1',
  'asset_id': assetId,
  'asset_code': 'AF-$assetId',
  'asset_name': 'Activo $assetId',
  'unit_value': unit,
  'registered_warehouse_name': registered,
  'expected': expected,
  'expected_qty': expected ? expectedQty : null,
  'found_qty': found,
  'expected_status': expectedStatus,
  'observed_status': observed,
  'is_new': isNew,
  'resolution': resolution,
};

/// L1 sin revisar · L2 encontrado · L3 grupo con faltante · L4 estado visto
/// distinto · L5 fuera de lugar · L6 nuevo · L7 sobrante · L8 «no está».
List<Map<String, dynamic>> _lines() => [
  _l('00001'),
  _l('00002', found: 1),
  _l('00003', expectedQty: 40, found: 38, unit: 2500),
  _l('00004', found: 1, observed: 'damaged'),
  _l('00005', expected: false, found: 1, registered: 'Bar'),
  _l('00006', expected: false, isNew: true, found: 3),
  _l('00007', expectedQty: 10, found: 12),
  _l('00008', found: 0, unit: 600),
];

FixedAssetVerification _verification({
  String? warehouseId = 'w-cocina',
  String status = 'open',
  List<Map<String, dynamic>>? lines,
}) => FixedAssetVerification.fromMap({
  'id': 'v1',
  'business_id': 'b1',
  'number': 3,
  'warehouse_id': warehouseId,
  'warehouse_name': warehouseId == null ? null : 'Cocina',
  'status': status,
  'started_by_name': 'Dueño',
  'started_at': '2026-10-01T14:00:00Z',
  'lines': lines ?? _lines(),
  'resumed': true,
});

String _id(FixedAssetVerificationLine l) => l.assetId;

void main() {
  group('lectura', () {
    test('cabecera, líneas, resumed y resumen', () {
      final v = FixedAssetVerification.fromMap({
        'id': 'v9',
        'business_id': 'b1',
        'number': '7',
        'warehouse_id': null,
        'warehouse_name': 'Todas las ubicaciones',
        'status': 'closed',
        'summary': {
          'expected_count': 30,
          'ok_count': 27,
          'missing_count': 2,
          'missing_units': 3,
          'missing_value': '7500.50',
          'lost_count': 1,
          'pending_count': 1,
          'new_count': 2,
          'found_value': 850000,
        },
        'lines': [_l('00002', found: 1)],
      });
      expect(v.title, 'Verificación #7');
      expect(v.fullTitle, 'Verificación #7 · Todas las ubicaciones');
      expect(v.isAllLocations, isTrue);
      expect(v.isOpen, isFalse);
      expect(v.resumed, isFalse);
      expect(v.summary!.missingValue, 7500.5);
      expect(v.summary!.lostCount, 1);
      expect(v.summary!.pendingCount, 1);
      expect(v.lines.single.foundQty, 1);
      expect(_verification().resumed, isTrue);
    });

    test('sin warehouse_name y sin bodega: «Todas las ubicaciones»', () {
      final v = FixedAssetVerification.fromMap({
        'id': 'v1',
        'number': 1,
        'status': 'open',
      });
      expect(v.warehouseName, kAllLocationsLabel);
      expect(v.lines, isEmpty);
    });

    test('las líneas salen ordenadas por número de código', () {
      final v = _verification(
        lines: [
          {..._l('x'), 'asset_code': 'AF-00010'},
          {..._l('y'), 'asset_code': 'AF-00002'},
        ],
      );
      expect(v.lines.map((l) => l.assetCode), ['AF-00002', 'AF-00010']);
    });
  });

  group('pestañas y avance', () {
    test('cada línea cae en UNA pestaña', () {
      final groups = {for (final l in _verification().lines) _id(l): l.group};
      expect(groups['00001'], VerificationLineGroup.pending);
      expect(groups['00002'], VerificationLineGroup.found);
      expect(groups['00003'], VerificationLineGroup.difference);
      expect(groups['00004'], VerificationLineGroup.difference);
      expect(groups['00005'], VerificationLineGroup.misplaced);
      expect(groups['00006'], VerificationLineGroup.isNew);
      expect(groups['00007'], VerificationLineGroup.difference);
      expect(groups['00008'], VerificationLineGroup.difference);

      final counts = countVerificationGroups(_verification().lines);
      expect(counts[VerificationLineGroup.pending], 1);
      expect(counts[VerificationLineGroup.found], 1);
      expect(counts[VerificationLineGroup.difference], 4);
      expect(counts[VerificationLineGroup.misplaced], 1);
      expect(counts[VerificationLineGroup.isNew], 1);
    });

    test('faltante, sobrante y valor', () {
      final byId = {for (final l in _verification().lines) _id(l): l};
      expect(byId['00001']!.shortfall, 1, reason: 'sin revisar falta todo');
      expect(byId['00003']!.shortfall, 2);
      expect(byId['00003']!.missingValue, 5000);
      expect(byId['00007']!.surplus, 2);
      expect(byId['00005']!.shortfall, 0, reason: 'no era esperado');
      expect(byId['00004']!.hasConditionChange, isTrue);
      expect(byId['00003']!.countsLabel, 'Esperado 40 · Encontrado 38');
      expect(byId['00008']!.countsLabel, 'Esperado 1 · No está');
      expect(byId['00001']!.countsLabel, 'Esperado 1 · Sin revisar');
      expect(byId['00005']!.countsLabel, 'Encontrado 1');
    });

    test('estado visto igual al registrado no es diferencia', () {
      final l = FixedAssetVerificationLine.fromMap(
        _l('a', found: 1, observed: 'active'),
      );
      expect(l.hasConditionChange, isFalse);
      expect(l.group, VerificationLineGroup.found);
    });

    test('avance: solo cuenta lo que estaba en la lista', () {
      final p = _verification().progress;
      expect(p.expected, 6);
      expect(p.checked, 5);
      expect(p.label, '5 de 6 revisados');
      expect(p.extrasLabel, '1 fuera de lugar · 1 nuevo');
      expect(p.fraction, closeTo(5 / 6, 1e-9));
      expect(const VerificationProgress().fraction, 1);
    });

    test('filtrar por pestaña y por texto', () {
      final lines = _verification().lines;
      expect(
        filterVerificationLines(lines, group: VerificationLineGroup.difference)
            .map(_id),
        ['00003', '00004', '00007', '00008'],
      );
      expect(filterVerificationLines(lines, query: 'af-00005').map(_id), [
        '00005',
      ]);
      expect(filterVerificationLines(lines), hasLength(8));
    });

    test('reemplazar y quitar una línea', () {
      final v = _verification();
      final checked = FixedAssetVerificationLine.fromMap(_l('00001', found: 1));
      final next = v.withLine(checked);
      expect(next.lineFor('00001')!.foundQty, 1);
      expect(next.lines, hasLength(8));
      final added = v.withLine(
        FixedAssetVerificationLine.fromMap(
          _l('00099', expected: false, found: 1),
        ),
      );
      expect(added.lines, hasLength(9));
      expect(v.withoutLine('00005').lineFor('00005'), isNull);
    });
  });

  group('cierre', () {
    test('el plan trae solo lo que no cuadra', () {
      final plan = VerificationClosePlan.from(_verification());
      expect(plan.shortfalls.map(_id), ['00001', '00003', '00008']);
      expect(plan.surpluses.map(_id), ['00007']);
      expect(plan.misplaced.map(_id), ['00005']);
      expect(plan.conditionChanges.map(_id), ['00004']);
      expect(plan.canMove, isTrue);
      expect(plan.isEmpty, isFalse);
      // 1 × 1000 + 2 × 2500 + 1 × 600.
      expect(plan.missingValue, 6600);
    });

    test('por defecto: nada perdido, sí cantidades, traslados y estados', () {
      final plan = VerificationClosePlan.from(_verification());
      final choices = VerificationCloseChoices.defaults(plan);
      expect(choices.toDecisions(plan), [
        {'asset_id': '00007', 'action': 'set_quantity'},
        {'asset_id': '00005', 'action': 'move_here'},
        {'asset_id': '00004', 'action': 'apply_condition'},
      ]);
      expect(choices.lostValue(plan), 0);
    });

    test('marcar perdido y apagar un traslado', () {
      final plan = VerificationClosePlan.from(_verification());
      final choices = VerificationCloseChoices.defaults(plan)
          .toggle('mark_lost', '00003', true)
          .toggle('move_here', '00005', false);
      final decisions = choices.toDecisions(plan);
      expect(
        decisions,
        anyElement(equals({'asset_id': '00003', 'action': 'mark_lost'})),
      );
      expect(
        decisions.where((d) => d['action'] == 'move_here'),
        isEmpty,
      );
      expect(choices.lostValue(plan), 5000);
      // Volver a «pendiente».
      expect(
        choices.toggle('mark_lost', '00003', false).toDecisions(plan).where(
          (d) => d['action'] == 'mark_lost',
        ),
        isEmpty,
      );
    });

    test('un id que el plan no trae no se cuela', () {
      final plan = VerificationClosePlan.from(_verification());
      final choices = const VerificationCloseChoices(
        markLost: {'00002', '00005'},
        setQuantity: {'00003'},
      );
      expect(choices.toDecisions(plan), isEmpty);
    });

    test('todas las ubicaciones: no hay a dónde trasladar', () {
      final plan = VerificationClosePlan.from(_verification(warehouseId: null));
      expect(plan.canMove, isFalse);
      final choices = VerificationCloseChoices.defaults(plan)
          .toggle('move_here', '00005', true);
      expect(
        choices.toDecisions(plan).where((d) => d['action'] == 'move_here'),
        isEmpty,
      );
    });

    test('un estado visto en algo que no apareció no se ofrece', () {
      final plan = VerificationClosePlan.from(
        _verification(lines: [_l('a', found: 0, observed: 'damaged')]),
      );
      expect(plan.conditionChanges, isEmpty);
      expect(plan.shortfalls, hasLength(1));
    });

    test('todo cuadra', () {
      final plan = VerificationClosePlan.from(
        _verification(
          lines: [
            _l('a', found: 1),
            _l('b', isNew: true, expected: false, found: 2),
          ],
        ),
      );
      expect(plan.isEmpty, isTrue);
      expect(VerificationCloseChoices.defaults(plan).toDecisions(plan), isEmpty);
    });

    test('resultado de cada línea en palabras', () {
      expect(fixedAssetResolutionLabel('pending'), 'Pendiente de búsqueda');
      expect(fixedAssetResolutionLabel('lost'), 'Perdido');
      expect(fixedAssetResolutionLabel('moved'), 'Trasladado');
      expect(fixedAssetResolutionLabel(null), '');
    });
  });

  group('la ficha con cantidad', () {
    final now = DateTime(2026, 10, 1);

    FixedAsset a(
      String id, {
      int quantity = 1,
      double? cost,
      FixedAssetStatus status = FixedAssetStatus.active,
      DateTime? verified,
    }) => FixedAsset(
      id: id,
      businessId: 'b1',
      code: 'AF-$id',
      name: id,
      quantity: quantity,
      purchaseCost: cost,
      status: status,
      lastVerifiedAt: verified,
    );

    test('cantidad: falta o rara = 1; total = cantidad × unitario', () {
      expect(FixedAsset.fromMap({'id': 'x'}).quantity, 1);
      expect(FixedAsset.fromMap({'id': 'x', 'quantity': 0}).quantity, 1);
      final g = FixedAsset.fromMap({
        'id': 'x',
        'quantity': '40',
        'purchase_cost': 2500,
        'last_verified_at': '2026-09-20T10:00:00Z',
        'last_verification_id': 'v3',
      });
      expect(g.quantity, 40);
      expect(g.totalValue, 100000);
      expect(g.quantityLabel, '×40');
      expect(g.lastVerificationId, 'v3');
      expect(a('y').quantityLabel, '');
      expect(a('y').totalValue, isNull);
    });

    test('indicadores: valor y unidades con la cantidad', () {
      final k = FixedAssetsKpis.from([
        a('sillas', quantity: 40, cost: 2500, verified: DateTime(2026, 9, 20)),
        a('horno', cost: 850000, status: FixedAssetStatus.needsRepair),
        a('vieja', quantity: 5, cost: 100, status: FixedAssetStatus.retired),
        a('tv', quantity: 2),
      ], now: now);
      expect(k.registered, 3);
      expect(k.inUse, 2);
      expect(k.units, 43);
      expect(k.unitsInUse, 42);
      expect(k.purchaseValue, 950000);
      expect(k.withoutCost, 1);
      expect(k.needVerification, 2, reason: 'horno y tv nunca se verificaron');
    });

    test('«sin verificar en 6 meses»', () {
      expect(a('x').needsVerification(now), isTrue, reason: 'nunca');
      expect(
        a('x', verified: DateTime(2026, 5, 1)).needsVerification(now),
        isFalse,
        reason: 'hace 5 meses',
      );
      expect(
        a('x', verified: DateTime(2026, 4, 1, 12)).needsVerification(now),
        isFalse,
        reason: 'justo 6 meses',
      );
      expect(
        a('x', verified: DateTime(2026, 3, 31)).needsVerification(now),
        isTrue,
        reason: 'más de 6 meses',
      );
      expect(
        a('x', status: FixedAssetStatus.retired).needsVerification(now),
        isFalse,
        reason: 'lo dado de baja no se verifica',
      );
      final filtro = const FixedAssetsFilter(staleOnly: true);
      expect(filtro.isFiltering, isTrue);
      expect(
        filtro
            .apply([
              a('nunca'),
              a('reciente', verified: DateTime(2026, 9, 1)),
            ], now: now)
            .map((x) => x.id),
        ['nunca'],
      );
    });

    test('código de etiqueta: identidad sin mayúsculas ni espacios', () {
      final list = [
        FixedAsset(id: '1', businessId: 'b', code: 'SILLA-01', name: 's'),
        FixedAsset(id: '2', businessId: 'b', code: 'AF-10', name: 'h'),
      ];
      expect(findFixedAssetByCode(list, '  silla-01 ')?.id, '1');
      expect(findFixedAssetByCode(list, 'AF-1'), isNull);
      expect(findFixedAssetByCode(list, ''), isNull);
    });

    test('payload: código y cantidad solo si traen algo', () {
      const vacio = FixedAssetDraft(name: 'x', code: '  ');
      expect(vacio.createJson().containsKey('code'), isFalse);
      expect(vacio.createJson().containsKey('quantity'), isFalse);
      expect(vacio.dataJson().containsKey('change_note'), isFalse);
      const lleno = FixedAssetDraft(
        name: 'x',
        code: ' MESA-07 ',
        quantity: 38,
        changeNote: 'se rompieron 2',
      );
      expect(lleno.dataJson()['code'], 'MESA-07');
      expect(lleno.dataJson()['quantity'], 38);
      expect(lleno.dataJson()['change_note'], 'se rompieron 2');
    });

    test('historia: cantidad y verificación', () {
      final q = FixedAssetMovement.fromMap({
        'id': 'm',
        'asset_id': 'a',
        'event_type': 'quantity_changed',
        'from_quantity': 40,
        'to_quantity': 38,
        'notes': 'Faltaron 2 en la verificación #1',
      });
      expect(q.description, 'Cantidad: 40 → 38');
      expect(q.displayNotes, 'Faltaron 2 en la verificación #1');

      final v = FixedAssetMovement.fromMap({
        'id': 'm',
        'asset_id': 'a',
        'event_type': 'verified',
        'from_quantity': 38,
        'to_quantity': 36,
        'verification_id': 'v1',
        'notes': 'Verificación #1 (Cocina): 36 de 38',
      });
      expect(v.eventType, FixedAssetEventType.verified);
      expect(v.verificationId, 'v1');
      expect(
        v.describe(verificationNumber: 1),
        'Verificado en la verificación #1: 36 de 38',
      );
      // El servidor ya escribe la frase: se usa tal cual y no se repite.
      expect(v.displayDescription, 'Verificación #1 (Cocina): 36 de 38');
      expect(v.displayNotes, isNull);
    });

    test('errores nuevos en palabras', () {
      expect(
        fixedAssetErrorMessage('FIXED_ASSET_CODE_TAKEN'),
        contains('ya lo tiene otro activo'),
      );
      expect(
        fixedAssetErrorMessage('FIXED_ASSET_INVALID_CODE'),
        contains('40 caracteres'),
      );
      expect(
        fixedAssetErrorMessage('FIXED_ASSET_VERIFICATION_NOT_OPEN'),
        contains('ya no está abierta'),
      );
      expect(
        fixedAssetErrorMessage('FIXED_ASSET_VERIFICATION_IS_NEW'),
        contains('desde su ficha'),
      );
      expect(
        fixedAssetErrorMessage('FIXED_ASSET_VERIFICATION_REASON_REQUIRED'),
        'Escribe el motivo de la cancelación.',
      );
      expect(
        fixedAssetErrorMessage('FIXED_ASSET_VERIFICATION_BAD_DECISION'),
        contains('decisiones'),
      );
      expect(
        fixedAssetErrorMessage('FIXED_ASSET_VERIFICATION_NOT_FOUND'),
        contains('no existe'),
      );
    });
  });
}
