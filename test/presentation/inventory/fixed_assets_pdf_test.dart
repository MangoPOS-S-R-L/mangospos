// Activos fijos en papel: el inventario agrupado por ubicación y el acta de
// asignación salen en A4, pasan de página con muchos activos y no se caen
// con texto raro (emojis, rayas largas, €).

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/currency/business_currency.dart';
import 'package:mangopos/presentation/inventory/services/fixed_assets_pdf.dart';
import 'package:mangopos/presentation/inventory/state/fixed_asset_verification_state.dart';
import 'package:mangopos/presentation/inventory/state/fixed_assets_state.dart';

String _mediaBox(List<int> bytes) {
  final text = String.fromCharCodes(bytes);
  final match = RegExp(r'/MediaBox\s*\[[^\]]*\]').firstMatch(text);
  return match?.group(0) ?? '';
}

int _pages(List<int> bytes) =>
    RegExp(r'/Type\s*/Page\b').allMatches(String.fromCharCodes(bytes)).length;

FixedAsset _asset(
  int i, {
  String warehouse = 'Cocina',
  String? employee = 'Juan Pérez',
  FixedAssetStatus status = FixedAssetStatus.active,
  double? cost = 25000,
}) => FixedAsset(
  id: 'a$i',
  businessId: 'b1',
  code: 'AF-${i.toString().padLeft(5, '0')}',
  name: 'Licuadora industrial $i',
  category: 'Equipo de cocina',
  brand: 'Vitamix',
  model: 'XL',
  serialNumber: 'SN-$i',
  purchaseDate: DateTime(2025, 1, 10),
  purchaseCost: cost,
  warrantyUntil: DateTime(2027, 1, 10),
  warehouseId: warehouse.isEmpty ? null : 'w-$warehouse',
  warehouseName: warehouse,
  locationNote: 'Estación $i',
  employeeName: employee ?? '',
  status: status,
);

void main() {
  test('grupos por bodega en orden, «Sin ubicación» al final', () {
    final groups = groupFixedAssetsByLocation([
      _asset(3, warehouse: ''),
      _asset(2, warehouse: 'Salón'),
      _asset(10, warehouse: 'Barra'),
      _asset(1, warehouse: 'Barra'),
    ]);
    expect(groups.map((g) => g.key), ['Barra', 'Salón', 'Sin ubicación']);
    expect(
      groups.first.value.map((a) => a.code),
      ['AF-00001', 'AF-00010'],
      reason: 'dentro del grupo, por código',
    );
  });

  test('el inventario sale en A4', () async {
    final bytes = await FixedAssetsPdf.buildInventory(
      assets: [
        _asset(1),
        _asset(2, warehouse: 'Salón', status: FixedAssetStatus.needsRepair),
        _asset(3, warehouse: '', employee: null, cost: null),
      ],
      businessName: '1/2 Medio Tiempo Bar',
      scopeLabel: 'Sin dados de baja',
      printedBy: 'Cristian',
      printedAt: DateTime(2026, 9, 30, 10, 15),
    );
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    // A4 = 595.28 x 841.89 puntos; carta sería 612.
    final box = _mediaBox(bytes);
    expect(box, contains('595'));
    expect(box, isNot(contains('612')));
  });

  test('muchos activos pasan de página sin romper', () async {
    final bytes = await FixedAssetsPdf.buildInventory(
      assets: [
        for (var i = 0; i < 150; i++)
          _asset(i, warehouse: i.isEven ? 'Cocina' : 'Salón'),
      ],
      businessName: 'Negocio',
    );
    expect(_pages(bytes), greaterThan(1));
  });

  test('inventario vacío también genera el documento', () async {
    final bytes = await FixedAssetsPdf.buildInventory(
      assets: const [],
      businessName: '',
    );
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });

  test('el acta de asignación sale en A4, con o sin responsable', () async {
    final bytes = await FixedAssetsPdf.buildAssignmentAct(
      asset: _asset(7),
      businessName: 'La Penda',
      deliveredBy: 'Administración',
      printedAt: DateTime(2026, 9, 30),
    );
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    expect(_mediaBox(bytes), contains('595'));

    final sinResponsable = await FixedAssetsPdf.buildAssignmentAct(
      asset: _asset(8, warehouse: '', employee: null, cost: null),
      businessName: 'La Penda',
    );
    expect(String.fromCharCodes(sinResponsable.take(4)), '%PDF');
  });

  test('texto raro no tumba ningún documento', () async {
    final raro = FixedAsset(
      id: 'x',
      businessId: 'b1',
      code: 'AF-00099',
      name: 'Nevera “Imbera” — 2 puertas 🧊',
      brand: 'Imbera…',
      notes: 'Revisar el compresor → llamar al técnico ‘Pedro’',
      warehouseId: 'w1',
      warehouseName: 'Barra 🍺',
      employeeName: 'José Ñúñez',
      purchaseCost: 1500,
    );
    final euro = BusinessCurrency.catalog['EUR']!;
    final inventario = await FixedAssetsPdf.buildInventory(
      assets: [raro],
      businessName: 'Negocio — Centro 🍺',
      scopeLabel: 'Búsqueda: "nevera" · Sin dados de baja',
      currency: euro,
    );
    expect(String.fromCharCodes(inventario.take(4)), '%PDF');
    final acta = await FixedAssetsPdf.buildAssignmentAct(
      asset: raro,
      businessName: 'Negocio — Centro 🍺',
      currency: euro,
    );
    expect(String.fromCharCodes(acta.take(4)), '%PDF');
  });

  test('saneado para Helvetica: equivalentes y nada fuera de Latin-1', () {
    expect(fixedAssetsPdfSafe('A — B → C…'), 'A - B -> C...');
    expect(fixedAssetsPdfSafe('“hola” ‘x’'), '"hola" \'x\'');
    expect(fixedAssetsPdfSafe('Ñandú 🍺'), 'Ñandú ');
    expect(fixedAssetsPdfSafe('€ 10'), 'EUR  10');
  });

  test('nombres de archivo', () {
    expect(
      FixedAssetsPdf.inventoryFileName(DateTime(2026, 9, 3, 8, 5)),
      'activos_fijos_20260903_0805.pdf',
    );
    expect(
      FixedAssetsPdf.assignmentFileName(_asset(12)),
      'acta_asignacion_AF-00012.pdf',
    );
  });

  test('inventario y acta con grupos (cantidad × valor unitario)', () async {
    final sillas = FixedAsset(
      id: 's',
      businessId: 'b1',
      code: 'SILLA-01',
      name: 'Silla de madera',
      quantity: 40,
      purchaseCost: 2500,
      warehouseId: 'w1',
      warehouseName: 'Salón',
    );
    final inventario = await FixedAssetsPdf.buildInventory(
      assets: [sillas, _asset(1)],
      businessName: 'La Penda',
    );
    expect(String.fromCharCodes(inventario.take(4)), '%PDF');
    final acta = await FixedAssetsPdf.buildAssignmentAct(
      asset: sillas,
      businessName: 'La Penda',
    );
    expect(String.fromCharCodes(acta.take(4)), '%PDF');
  });

  group('acta de verificación', () {
    FixedAssetVerificationLine line(
      String id, {
      bool expected = true,
      int? expectedQty = 1,
      int? found,
      bool isNew = false,
      String? resolution,
      String? observed,
    }) => FixedAssetVerificationLine.fromMap({
      'id': 'l-$id',
      'verification_id': 'v1',
      'asset_id': id,
      'asset_code': 'AF-$id',
      'asset_name': 'Activo “$id” — prueba 🧪',
      'unit_value': 2500,
      'registered_warehouse_name': expected ? 'Cocina' : 'Bar',
      'expected': expected,
      'expected_qty': expected ? expectedQty : null,
      'found_qty': found,
      'expected_status': 'active',
      'observed_status': observed,
      'is_new': isNew,
      'resolution': resolution,
    });

    FixedAssetVerification verification({
      required FixedAssetVerificationStatus status,
      int extra = 0,
    }) => FixedAssetVerification(
      id: 'v1',
      businessId: 'b1',
      number: 3,
      warehouseId: 'w1',
      warehouseName: 'Cocina',
      status: status,
      startedByName: 'Dueño',
      startedAt: DateTime(2026, 10, 1, 9),
      closedByName: status == FixedAssetVerificationStatus.open ? null : 'Ana',
      closedAt: status == FixedAssetVerificationStatus.open
          ? null
          : DateTime(2026, 10, 1, 12),
      notes: 'Conteo de cierre — mes',
      summary: status == FixedAssetVerificationStatus.closed
          ? const FixedAssetVerificationSummary(
              okCount: 1,
              lostCount: 1,
              pendingCount: 1,
              foundValue: 97500,
            )
          : null,
      lines: [
        line('1', found: 1, resolution: 'ok'),
        line('2', expectedQty: 40, found: 38, resolution: 'lost'),
        line('3', resolution: 'pending'),
        line('4', found: 1, observed: 'damaged', resolution: 'ok'),
        line('5', expected: false, found: 1, resolution: 'moved'),
        line('6', expected: false, isNew: true, found: 2, resolution: 'new'),
        for (var i = 0; i < extra; i++) line('x$i', found: 1),
      ],
    );

    test('abierta: sale como borrador, en A4', () async {
      final bytes = await FixedAssetsPdf.buildVerificationAct(
        verification: verification(status: FixedAssetVerificationStatus.open),
        businessName: 'La Penda',
        printedBy: 'Cristian',
        printedAt: DateTime(2026, 10, 1, 11),
      );
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
      expect(_mediaBox(bytes), contains('595'));
    });

    test('cerrada, con muchas líneas: pasa de página', () async {
      final bytes = await FixedAssetsPdf.buildVerificationAct(
        verification: verification(
          status: FixedAssetVerificationStatus.closed,
          extra: 120,
        ),
        businessName: 'La Penda',
        currency: BusinessCurrency.catalog['EUR'],
      );
      expect(_pages(bytes), greaterThan(1));
    });

    test('cancelada y sin líneas también genera el documento', () async {
      final bytes = await FixedAssetsPdf.buildVerificationAct(
        verification: const FixedAssetVerification(
          id: 'v2',
          businessId: 'b1',
          number: 2,
          status: FixedAssetVerificationStatus.cancelled,
          cancelReason: 'Se abrió por error',
        ),
        businessName: '',
      );
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
      expect(
        FixedAssetsPdf.verificationFileName(
          const FixedAssetVerification(id: 'x', businessId: 'b', number: 12),
        ),
        'acta_verificacion_12.pdf',
      );
    });
  });
}
