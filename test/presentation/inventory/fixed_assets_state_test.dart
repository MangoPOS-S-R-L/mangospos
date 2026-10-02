// Activos fijos: lectura de las filas (SELECT y RPC), filtros, indicadores,
// el monto con coma y el payload de los RPC.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/fixed_assets_state.dart';

FixedAsset _asset(
  String id, {
  String? code,
  String name = 'Activo',
  String? category,
  String? brand,
  String? model,
  String? serial,
  String? warehouseId,
  String warehouseName = '',
  String? locationNote,
  String employeeName = '',
  FixedAssetStatus status = FixedAssetStatus.active,
  double? cost,
}) => FixedAsset(
  id: id,
  businessId: 'b1',
  code: code ?? 'AF-$id',
  name: name,
  category: category,
  brand: brand,
  model: model,
  serialNumber: serial,
  warehouseId: warehouseId,
  warehouseName: warehouseName,
  locationNote: locationNote,
  employeeName: employeeName,
  status: status,
  purchaseCost: cost,
);

final _sample = <FixedAsset>[
  _asset(
    '1',
    code: 'AF-00001',
    name: 'Horno de convección',
    category: 'Equipo de cocina',
    brand: 'Rational',
    model: 'iCombi Pro',
    serial: 'RAT-12345',
    warehouseId: 'w-cocina',
    warehouseName: 'Cocina',
    employeeName: 'Juan Pérez',
    cost: 850000,
  ),
  _asset(
    '2',
    code: 'AF-00002',
    name: 'Nevera vertical',
    category: 'Refrigeración',
    brand: 'Imbera',
    warehouseId: 'w-cocina',
    warehouseName: 'Cocina',
    status: FixedAssetStatus.needsRepair,
    cost: 95000,
  ),
  _asset(
    '3',
    code: 'AF-00003',
    name: 'Aire acondicionado',
    category: 'Climatización',
    warehouseId: 'w-salon',
    warehouseName: 'Salón',
    status: FixedAssetStatus.inRepair,
  ),
  _asset(
    '4',
    code: 'AF-00004',
    name: 'Mesa de madera',
    category: 'Mobiliario',
    status: FixedAssetStatus.retired,
    cost: 12000,
  ),
  _asset(
    '5',
    code: 'AF-00005',
    name: 'Motor de delivery',
    category: 'Vehículo',
    status: FixedAssetStatus.lost,
    cost: 110000,
  ),
];

void main() {
  group('lectura', () {
    test('fila del SELECT de PostgREST con bodega y responsable embebidos', () {
      final a = FixedAsset.fromMap({
        'id': 'a1',
        'business_id': 'b1',
        'code': 'AF-00001',
        'name': 'Horno',
        'category': 'Equipo de cocina',
        'brand': 'Rational',
        'model': ' ',
        'serial_number': 'RAT-1',
        'purchase_date': '2025-03-15',
        'purchase_cost': '850000.50',
        'warranty_until': '2027-03-15',
        'warehouse_id': 'w1',
        'location_note': 'Junto a la plancha',
        'assigned_employee_id': 'e1',
        'status': 'needs_repair',
        'warehouses': {'name': 'Cocina'},
        'employees': {'first_name': 'Juan', 'last_name': 'Pérez'},
      });
      expect(a.code, 'AF-00001');
      expect(a.purchaseCost, 850000.5);
      expect(a.purchaseDate, DateTime(2025, 3, 15));
      expect(a.model, isNull, reason: 'un texto en blanco es «sin dato»');
      expect(a.brandModel, 'Rational');
      expect(a.warehouseName, 'Cocina');
      expect(a.employeeName, 'Juan Pérez');
      expect(a.locationLabel, 'Cocina · Junto a la plancha');
      expect(a.status, FixedAssetStatus.needsRepair);
      expect(a.warrantyActive(DateTime(2027, 3, 15)), isTrue);
      expect(a.warrantyActive(DateTime(2027, 3, 16)), isFalse);
    });

    test('lo que devuelve el RPC sin bodega ni responsable', () {
      final a = FixedAsset.fromMap({
        'id': 'a2',
        'business_id': 'b1',
        'code': 'AF-00002',
        'name': 'Silla',
        'status': 'retired',
        'retired_at': '2026-09-30T12:00:00Z',
        'retired_reason': 'Se rompió',
        'warehouses': null,
        'employees': null,
      });
      expect(a.warehouseName, '');
      expect(a.locationLabel, 'Sin ubicación');
      expect(a.responsibleLabel, 'Sin responsable');
      expect(a.status.isRetired, isTrue);
      expect(a.retiredReason, 'Se rompió');
      expect(a.locationGroup, 'Sin ubicación');
    });

    test('estados en español y uno desconocido cae en «En uso»', () {
      expect(
        FixedAssetStatus.values.map((s) => s.label),
        [
          'En uso',
          'Necesita reparación',
          'En reparación',
          'Dañado',
          'Perdido',
          'Dado de baja',
        ],
      );
      expect(FixedAssetStatus.fromWire('in_repair'), FixedAssetStatus.inRepair);
      expect(FixedAssetStatus.fromWire('raro'), FixedAssetStatus.active);
      expect(FixedAssetStatus.selectable, isNot(contains(FixedAssetStatus.retired)));
    });

    test('historia: cada evento se cuenta en una línea', () {
      FixedAssetMovement m(Map<String, dynamic> extra) =>
          FixedAssetMovement.fromMap({'id': 'm', 'asset_id': 'a', ...extra});

      expect(
        m({
          'event_type': 'created',
          'to_warehouse_name': 'Cocina',
          'to_employee_name': 'Juan Pérez',
        }).description,
        'Registrado en Cocina, a cargo de Juan Pérez',
      );
      expect(
        m({
          'event_type': 'relocated',
          'from_warehouse_name': 'Cocina',
          'from_location_note': 'Plancha',
          'to_warehouse_name': 'Principal',
        }).description,
        'De Cocina · Plancha a Principal',
      );
      expect(
        m({'event_type': 'reassigned', 'to_employee_name': 'Ana'}).description,
        'De sin responsable a Ana',
      );
      final retired = m({
        'event_type': 'retired',
        'from_status': 'needs_repair',
        'to_status': 'retired',
        'notes': 'Chatarra',
        'created_by_name': 'Dueño',
        'created_at': '2026-09-30T15:00:00Z',
      });
      expect(retired.eventType, FixedAssetEventType.retired);
      expect(retired.description, 'Necesita reparación → Dado de baja');
      expect(retired.createdByName, 'Dueño');
      final updated = m({
        'event_type': 'updated',
        'changes': {
          'name': {'from': 'Horno', 'to': 'Horno combinado'},
          'purchase_cost': {'from': 850000, 'to': 900000},
        },
      });
      expect(updated.changes['purchase_cost']?.to, '900000');
      expect(updated.description, 'Cambió: Nombre, Valor unitario');
    });
  });

  group('filtros', () {
    test('por defecto esconde los dados de baja', () {
      final ids = const FixedAssetsFilter().apply(_sample).map((a) => a.id);
      expect(ids, ['1', '2', '3', '5']);
    });

    test('el interruptor los muestra', () {
      final f = const FixedAssetsFilter().copyWith(showRetired: true);
      expect(f.apply(_sample), hasLength(5));
    });

    test('pedir «Dado de baja» los muestra aunque el interruptor esté apagado',
        () {
      final f = const FixedAssetsFilter(status: FixedAssetStatus.retired);
      expect(f.apply(_sample).map((a) => a.id), ['4']);
    });

    test('estado', () {
      final f = const FixedAssetsFilter(status: FixedAssetStatus.needsRepair);
      expect(f.apply(_sample).map((a) => a.id), ['2']);
    });

    test('categoría sin importar tildes ni mayúsculas', () {
      final f = const FixedAssetsFilter(category: 'refrigeracion');
      expect(f.apply(_sample).map((a) => a.id), ['2']);
    });

    test('ubicación, y «Sin ubicación»', () {
      expect(
        const FixedAssetsFilter(warehouseId: 'w-cocina')
            .apply(_sample)
            .map((a) => a.id),
        ['1', '2'],
      );
      expect(
        const FixedAssetsFilter(warehouseId: kFixedAssetNoWarehouse)
            .apply(_sample)
            .map((a) => a.id),
        ['5'],
        reason: 'la mesa no tiene bodega pero está dada de baja',
      );
    });

    test('búsqueda por nombre, código, serie, marca y modelo', () {
      List<String> q(String text) => FixedAssetsFilter(query: text)
          .apply(_sample)
          .map((a) => a.id)
          .toList();
      expect(q('conveccion'), ['1'], reason: 'sin tilde');
      expect(q('AF-00003'), ['3']);
      expect(q('rat-123'), ['1'], reason: 'serie');
      expect(q('imbera'), ['2'], reason: 'marca');
      expect(q('icombi'), ['1'], reason: 'modelo');
      expect(q('rational horno'), ['1'], reason: 'palabras en otro orden');
      expect(q('horno imbera'), isEmpty);
      expect(q('   '), hasLength(4));
    });

    test('isFiltering no cuenta el interruptor de bajas', () {
      expect(const FixedAssetsFilter(showRetired: true).isFiltering, isFalse);
      expect(const FixedAssetsFilter(query: 'x').isFiltering, isTrue);
      final f = const FixedAssetsFilter(category: 'x', status: FixedAssetStatus.lost)
          .copyWith(clearCategory: true, clearStatus: true);
      expect(f.isFiltering, isFalse);
    });

    test('categorías para el filtro, sin repetir', () {
      final extra = [
        ..._sample,
        _asset('6', category: 'refrigeración'),
        _asset('7', category: 'Cristalería de bar'),
      ];
      expect(fixedAssetCategoriesIn(extra), [
        'Climatización',
        'Cristalería de bar',
        'Equipo de cocina',
        'Mobiliario',
        'Refrigeración',
        'Vehículo',
      ]);
    });

    test('orden por número de código, no por texto', () {
      final sorted = sortFixedAssetsByCode([
        _asset('a', code: 'AF-100000'),
        _asset('b', code: 'AF-00010'),
        _asset('c', code: 'AF-00002'),
      ]);
      expect(sorted.map((a) => a.code), ['AF-00002', 'AF-00010', 'AF-100000']);
    });
  });

  group('indicadores', () {
    test('sobre todo el registro; el valor no cuenta las bajas', () {
      final k = FixedAssetsKpis.from(_sample);
      expect(k.registered, 4);
      expect(k.inUse, 1);
      expect(k.needsRepair, 1);
      expect(k.inRepair, 1);
      expect(k.repairTotal, 2);
      expect(k.lost, 1);
      expect(k.retired, 1);
      // 850,000 + 95,000 + 110,000 (la mesa dada de baja no suma).
      expect(k.purchaseValue, 1055000);
      expect(k.withoutCost, 1, reason: 'el aire no tiene costo cargado');
    });

    test('registro vacío', () {
      final k = FixedAssetsKpis.from(const []);
      expect(k.registered, 0);
      expect(k.purchaseValue, 0);
    });
  });

  group('monto escrito a mano', () {
    test('las dos costumbres', () {
      expect(parseFixedAssetAmount('1,250.50'), 1250.5);
      expect(parseFixedAssetAmount('1250,50'), 1250.5);
      expect(parseFixedAssetAmount('1.250,50'), 1250.5);
      expect(parseFixedAssetAmount('1250.5'), 1250.5);
      expect(parseFixedAssetAmount('850000'), 850000);
    });

    test('coma con tres dígitos es de miles, no decimal', () {
      expect(parseFixedAssetAmount('85,000'), 85000);
      expect(parseFixedAssetAmount('1,250,000'), 1250000);
      expect(parseFixedAssetAmount('1,5'), 1.5);
      expect(parseFixedAssetAmount('1.250.000'), 1250000);
    });

    test('símbolo y espacios', () {
      expect(parseFixedAssetAmount(r'RD$ 2,500'), 2500);
      expect(parseFixedAssetAmount(' 300 '), 300);
    });

    test('lo que no es número', () {
      expect(parseFixedAssetAmount(''), isNull);
      expect(parseFixedAssetAmount('abc'), isNull);
      expect(parseFixedAssetAmount('12,34,56'), isNull);
    });
  });

  group('payload de los RPC', () {
    final draft = FixedAssetDraft(
      name: '  Horno  ',
      category: 'Equipo de cocina',
      brand: '  ',
      purchaseDate: DateTime(2025, 3, 5),
      purchaseCost: 850000,
      warrantyUntil: DateTime(2027, 3, 5),
      warehouseId: 'w1',
      locationNote: ' Plancha ',
      assignedEmployeeId: 'e1',
    );

    test('la edición manda la ficha completa, sin ubicación ni responsable',
        () {
      final json = draft.dataJson();
      expect(json['name'], 'Horno');
      expect(json['brand'], isNull, reason: 'vacío borra');
      expect(json.containsKey('brand'), isTrue);
      expect(json['purchase_date'], '2025-03-05');
      expect(json['warranty_until'], '2027-03-05');
      expect(json['purchase_cost'], 850000);
      expect(json.containsKey('warehouse_id'), isFalse);
      expect(json.containsKey('assigned_employee_id'), isFalse);
      expect(json.containsKey('status'), isFalse);
    });

    test('el alta suma dónde queda, quién responde y el id del intento', () {
      final json = draft.createJson(clientRequestId: 'req-1');
      expect(json['warehouse_id'], 'w1');
      expect(json['location_note'], 'Plancha');
      expect(json['assigned_employee_id'], 'e1');
      expect(json['client_request_id'], 'req-1');
      expect(draft.createJson().containsKey('client_request_id'), isFalse);
    });
  });

  test('errores del servidor en palabras', () {
    expect(
      fixedAssetErrorMessage(Exception('FIXED_ASSET_DENIED')),
      contains('No tienes permiso'),
    );
    expect(
      fixedAssetErrorMessage('FIXED_ASSET_RETIRE_REASON_REQUIRED'),
      'Escribe el motivo de la baja.',
    );
    expect(
      fixedAssetErrorMessage('FIXED_ASSET_RETIRED'),
      contains('Reactívalo'),
    );
    expect(fixedAssetErrorMessage('otra cosa'), isNull);
  });
}
