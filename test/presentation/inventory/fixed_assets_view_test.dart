// Activos fijos: la pantalla pinta indicadores, tabla (laptop) o tarjetas
// (teléfono de 360 px) sin desbordes, filtra, esconde los dados de baja, abre
// la ficha con su historia y respeta el permiso de escritura.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/data/repositories/fixed_assets_repository.dart';
import 'package:mangopos/presentation/inventory/state/fixed_asset_verification_state.dart';
import 'package:mangopos/presentation/inventory/state/fixed_assets_state.dart';
import 'package:mangopos/presentation/inventory/view/fixed_asset_detail_dialog.dart';
import 'package:mangopos/presentation/inventory/view/fixed_asset_form_dialog.dart';
import 'package:mangopos/presentation/inventory/view/fixed_assets_view.dart';
import 'package:mangopos/services/session/session_controller.dart';

/// `SessionController.build()` toca Supabase; acá solo importan los permisos.
class _Session extends SessionController {
  _Session(this._permissions);

  final Set<String> _permissions;

  @override
  SessionState build() => SessionState(
    userName: 'Cristian',
    permissions: _permissions,
  );
}

class _FakeRepo implements FixedAssetsRepository {
  _FakeRepo(this.assets, {this.missing = false, this.supportsQuantity = true});

  List<FixedAsset> assets;
  final bool missing;
  final bool supportsQuantity;
  final created = <FixedAssetDraft>[];
  final requestIds = <String?>[];
  final updated = <FixedAssetDraft>[];
  final started = <String?>[];

  @override
  bool get quantitySupported => supportsQuantity;

  @override
  Future<Map<String, int>> getVerificationNumbers(List<String> ids) async => {
    for (final id in ids) id: 3,
  };

  @override
  Future<FixedAsset> updateAsset({
    required String assetId,
    required FixedAssetDraft draft,
  }) async {
    updated.add(draft);
    final current = assets.firstWhere((a) => a.id == assetId);
    final next = current.copyWith(quantity: draft.quantity);
    assets = [
      for (final a in assets)
        if (a.id == assetId) next else a,
    ];
    return next;
  }

  @override
  Future<FixedAssetVerification> startVerification({
    required String businessId,
    required String? warehouseId,
    String? notes,
  }) async {
    started.add(warehouseId);
    return FixedAssetVerification(
      id: 'ver-1',
      businessId: businessId,
      number: 3,
      warehouseId: warehouseId,
      warehouseName: warehouseId == null ? kAllLocationsLabel : 'Cocina',
      resumed: true,
    );
  }

  @override
  Future<String?> resolveBusinessId() async => 'b1';

  @override
  Future<List<FixedAsset>> listAssets(String businessId) async {
    if (missing) throw const FixedAssetsMigrationMissing();
    return sortFixedAssetsByCode(assets);
  }

  @override
  Future<List<FixedAssetMovement>> listMovements(String assetId) async => [
    FixedAssetMovement.fromMap({
      'id': 'm2',
      'asset_id': assetId,
      'event_type': 'relocated',
      'from_warehouse_name': 'Principal',
      'to_warehouse_name': 'Cocina',
      'notes': 'Remodelación',
      'created_by_name': 'Dueño Penda',
      'created_at': '2026-09-30T15:00:00Z',
    }),
    FixedAssetMovement.fromMap({
      'id': 'm1',
      'asset_id': assetId,
      'event_type': 'created',
      'to_warehouse_name': 'Principal',
      'to_status': 'active',
      'created_by_name': 'Dueño Penda',
      'created_at': '2026-09-01T12:00:00Z',
    }),
  ];

  @override
  Future<List<FixedAssetOption>> listWarehouses(String businessId) async =>
      const [
        FixedAssetOption('w-cocina', 'Cocina'),
        FixedAssetOption('w-salon', 'Salón'),
      ];

  @override
  Future<List<FixedAssetOption>> listEmployees(String businessId) async =>
      const [
        FixedAssetOption('e1', 'Juan Pérez'),
        FixedAssetOption('e2', 'Ana Gómez'),
      ];

  @override
  Future<String> getBusinessName(String businessId) async => 'La Penda';

  @override
  Future<FixedAsset> createAsset({
    required String businessId,
    required FixedAssetDraft draft,
    String? clientRequestId,
  }) async {
    created.add(draft);
    requestIds.add(clientRequestId);
    final asset = FixedAsset(
      id: 'new-${created.length}',
      businessId: businessId,
      code: (draft.code ?? '').isEmpty
          ? 'AF-0000${assets.length + 1}'
          : draft.code!,
      name: draft.name.trim(),
      category: draft.category,
      purchaseCost: draft.purchaseCost,
      quantity: draft.quantity ?? 1,
    );
    assets = [...assets, asset];
    return asset;
  }

  final statusCalls = <(FixedAssetStatus, String?)>[];

  @override
  Future<FixedAsset> setStatus({
    required String assetId,
    required FixedAssetStatus status,
    String? notes,
  }) async {
    statusCalls.add((status, notes));
    final current = assets.firstWhere((a) => a.id == assetId);
    final updated = FixedAsset(
      id: current.id,
      businessId: current.businessId,
      code: current.code,
      name: current.name,
      category: current.category,
      warehouseId: current.warehouseId,
      warehouseName: current.warehouseName,
      status: status,
      retiredAt: status.isRetired ? DateTime(2026, 9, 30) : null,
      retiredReason: status.isRetired ? notes : null,
      purchaseCost: current.purchaseCost,
    );
    assets = [
      for (final a in assets)
        if (a.id == assetId) updated else a,
    ];
    return updated;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<FixedAsset> _assets() => [
  FixedAsset.fromMap({
    'id': 'horno',
    'business_id': 'b1',
    'code': 'AF-00001',
    'name': 'Horno de convección con un nombre largo para probar el ancho',
    'category': 'Equipo de cocina',
    'brand': 'Rational',
    'model': 'iCombi Pro 6-1/1',
    'serial_number': 'RAT-12345',
    'purchase_cost': 850000,
    'warehouse_id': 'w-cocina',
    'location_note': 'Cocina caliente, junto a la plancha',
    'status': 'needs_repair',
    'warehouses': {'name': 'Cocina'},
    'employees': {'first_name': 'Juan', 'last_name': 'Pérez'},
  }),
  FixedAsset.fromMap({
    'id': 'nevera',
    'business_id': 'b1',
    'code': 'AF-00002',
    'name': 'Nevera vertical',
    'category': 'Refrigeración',
    'purchase_cost': 95000,
    'warehouse_id': 'w-cocina',
    'status': 'active',
    'warehouses': {'name': 'Cocina'},
  }),
  FixedAsset.fromMap({
    'id': 'mesa',
    'business_id': 'b1',
    'code': 'AF-00003',
    'name': 'Mesa de madera',
    'category': 'Mobiliario',
    'purchase_cost': 12000,
    'status': 'retired',
    'retired_at': '2026-09-20T10:00:00Z',
    'retired_reason': 'Se rompió',
  }),
  FixedAsset.fromMap({
    'id': 'sillas',
    'business_id': 'b1',
    'code': 'SILLA-01',
    'name': 'Silla de madera',
    'category': 'Mobiliario',
    'quantity': 40,
    'purchase_cost': 2500,
    'warehouse_id': 'w-salon',
    'status': 'active',
    'last_verified_at': '2026-09-20T10:00:00Z',
    'last_verification_id': 'ver-old',
    'warehouses': {'name': 'Salón'},
  }),
  FixedAsset.fromMap({
    'id': 'aire',
    'business_id': 'b1',
    'code': 'AF-00004',
    'name': 'Aire acondicionado',
    'category': 'Climatización',
    'warehouse_id': 'w-salon',
    'status': 'active',
    'warehouses': {'name': 'Salón'},
  }),
];

Future<_FakeRepo> _pump(
  WidgetTester tester, {
  required Size size,
  Set<String> permissions = const {'*'},
  _FakeRepo? repo,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fake = repo ?? _FakeRepo(_assets());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        fixedAssetsRepositoryProvider.overrideWithValue(fake),
        sessionProvider.overrideWith(() => _Session(permissions)),
      ],
      child: const MaterialApp(home: FixedAssetsView()),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

Finder _row(String id) => find.byKey(ValueKey('fixed-asset-row-$id'));

void main() {
  testWidgets('laptop: indicadores y tabla, sin los dados de baja', (
    tester,
  ) async {
    await _pump(tester, size: const Size(1440, 1400));

    expect(find.text('Activos fijos'), findsOneWidget);
    expect(find.byKey(const Key('fixed-assets-new')), findsOneWidget);
    expect(find.byKey(const Key('fixed-assets-print')), findsOneWidget);

    // 3 en uso de 4 vigentes (42 unidades en uso). Valor = 850,000 +
    // 95,000 + 40 × 2,500 = 1,045,000; la mesa dada de baja no suma.
    final inUse = find.byKey(const Key('fixed-assets-kpi-in-use'));
    expect(find.descendant(of: inUse, matching: find.text('3')), findsOneWidget);
    expect(
      find.descendant(of: inUse, matching: find.textContaining('42 unidades')),
      findsOneWidget,
    );
    final value = find.byKey(const Key('fixed-assets-kpi-value'));
    expect(
      find.descendant(of: value, matching: find.textContaining('1,045,000')),
      findsOneWidget,
    );
    final retired = find.byKey(const Key('fixed-assets-kpi-retired'));
    expect(find.descendant(of: retired, matching: find.text('1')), findsOneWidget);

    expect(find.text('Código'), findsOneWidget, reason: 'cabecera de tabla');
    expect(_row('horno'), findsOneWidget);
    expect(_row('nevera'), findsOneWidget);
    expect(_row('aire'), findsOneWidget);
    expect(_row('mesa'), findsNothing, reason: 'dado de baja: escondido');
    expect(find.text('4 activos'), findsOneWidget);
    // El grupo muestra su cantidad y el total con el unitario.
    expect(find.text('Silla de madera  ×40'), findsOneWidget);
    expect(find.textContaining('40 × RD\$2,500.00'), findsOneWidget);
    expect(find.byKey(const Key('fixed-assets-verify')), findsOneWidget);
    expect(find.byKey(const Key('fixed-assets-verifications')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el interruptor muestra los dados de baja', (tester) async {
    await _pump(tester, size: const Size(1440, 1400));
    await tester.tap(find.byKey(const Key('fixed-assets-show-retired')));
    await tester.pumpAndSettle();
    expect(_row('mesa'), findsOneWidget);
  });

  testWidgets('buscar por serie y filtrar por estado', (tester) async {
    await _pump(tester, size: const Size(1440, 1400));

    await tester.enterText(
      find.byKey(const Key('fixed-assets-search')),
      'rat-123',
    );
    await tester.pumpAndSettle();
    expect(_row('horno'), findsOneWidget);
    expect(_row('nevera'), findsNothing);
    expect(find.text('1 activo con estos filtros'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('fixed-assets-search')), '');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('fixed-assets-status-null')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('En uso').last);
    await tester.pumpAndSettle();
    expect(_row('nevera'), findsOneWidget);
    expect(_row('aire'), findsOneWidget);
    expect(_row('horno'), findsNothing);
  });

  testWidgets('filtro sin resultados ofrece limpiar', (tester) async {
    await _pump(tester, size: const Size(1440, 1400));
    await tester.enterText(
      find.byKey(const Key('fixed-assets-search')),
      'no existe',
    );
    await tester.pumpAndSettle();
    expect(find.text('Ningún activo coincide con los filtros.'), findsOneWidget);
    await tester.tap(find.text('Limpiar filtros'));
    await tester.pumpAndSettle();
    expect(_row('horno'), findsOneWidget);
  });

  testWidgets('teléfono 360 px: tarjetas, sin desbordes', (tester) async {
    await _pump(tester, size: const Size(360, 2600));
    expect(find.text('Código'), findsNothing, reason: 'sin tabla');
    expect(_row('horno'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('fixed-assets-show-retired')));
    await tester.pumpAndSettle();
    expect(_row('mesa'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('la ficha muestra datos e historia (y cabe en 360 px)', (
    tester,
  ) async {
    await _pump(tester, size: const Size(360, 2600));
    await tester.tap(_row('horno'));
    await tester.pumpAndSettle();

    final dialog = find.byType(FixedAssetDetailDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('RAT-12345')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('Juan Pérez')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('De Principal a Cocina')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('«Remodelación»')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('fixed-asset-edit')), findsOneWidget);
    expect(find.byKey(const Key('fixed-asset-move')), findsOneWidget);
    expect(find.byKey(const Key('fixed-asset-retire')), findsOneWidget);
    expect(find.byKey(const Key('fixed-asset-act')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dado de baja: la ficha ofrece reactivar, no mover', (
    tester,
  ) async {
    await _pump(tester, size: const Size(1440, 1400));
    await tester.tap(find.byKey(const Key('fixed-assets-show-retired')));
    await tester.pumpAndSettle();
    await tester.tap(_row('mesa'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Motivo: Se rompió'), findsOneWidget);
    expect(find.byKey(const Key('fixed-asset-reactivate')), findsOneWidget);
    expect(find.byKey(const Key('fixed-asset-move')), findsNothing);
    expect(find.byKey(const Key('fixed-asset-retire')), findsNothing);
  });

  testWidgets('sin inventario.activos.gestionar: solo lectura', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(1440, 1400),
      permissions: const {'inventario.activos.acceso'},
    );
    expect(find.byKey(const Key('fixed-assets-new')), findsNothing);
    expect(find.byKey(const Key('fixed-assets-print')), findsOneWidget);

    await tester.tap(_row('horno'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fixed-asset-act')), findsOneWidget);
    expect(find.byKey(const Key('fixed-asset-edit')), findsNothing);
    expect(find.byKey(const Key('fixed-asset-move')), findsNothing);
    expect(find.byKey(const Key('fixed-asset-retire')), findsNothing);
  });

  testWidgets('alta: nombre obligatorio, costo con coma de miles', (
    tester,
  ) async {
    final repo = await _pump(tester, size: const Size(1440, 1400));
    await tester.tap(find.byKey(const Key('fixed-assets-new')));
    await tester.pumpAndSettle();
    expect(find.byType(FixedAssetFormDialog), findsOneWidget);

    await tester.tap(find.byKey(const Key('fixed-asset-form-save')));
    await tester.pumpAndSettle();
    expect(find.text('Escribe el nombre del activo.'), findsOneWidget);
    expect(repo.created, isEmpty);

    await tester.enterText(
      find.byKey(const Key('fixed-asset-form-name')),
      'Freidora doble',
    );
    await tester.tap(find.widgetWithText(ChoiceChip, 'Equipo de cocina'));
    await tester.enterText(
      find.byKey(const Key('fixed-asset-form-cost')),
      '85,000',
    );
    await tester.tap(find.byKey(const Key('fixed-asset-form-save')));
    await tester.pumpAndSettle();

    expect(repo.created, hasLength(1));
    expect(repo.created.single.name, 'Freidora doble');
    expect(repo.created.single.category, 'Equipo de cocina');
    expect(repo.created.single.purchaseCost, 85000);
    expect(repo.requestIds.single, isNotNull);
    expect(find.byType(FixedAssetFormDialog), findsNothing);
    expect(find.text('5 activos'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('alta en 360 px: el formulario cabe', (tester) async {
    await _pump(tester, size: const Size(360, 1400));
    await tester.tap(find.byKey(const Key('fixed-assets-new')));
    await tester.pumpAndSettle();
    expect(find.byType(FixedAssetFormDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dar de baja pide el motivo y deja la ficha para reactivar', (
    tester,
  ) async {
    final repo = await _pump(tester, size: const Size(1440, 1400));
    await tester.tap(_row('nevera'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fixed-asset-retire')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('fixed-asset-note-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Escribe el motivo.'), findsOneWidget);
    expect(repo.statusCalls, isEmpty);

    await tester.enterText(
      find.byKey(const Key('fixed-asset-note')),
      'Se vendió',
    );
    await tester.tap(find.byKey(const Key('fixed-asset-note-confirm')));
    await tester.pumpAndSettle();

    expect(repo.statusCalls.single, (FixedAssetStatus.retired, 'Se vendió'));
    // La ficha abierta se actualiza sola: ahora ofrece reactivar.
    expect(find.byKey(const Key('fixed-asset-reactivate')), findsOneWidget);
    expect(find.textContaining('Motivo: Se vendió'), findsOneWidget);

    // Y en la lista queda escondida (dado de baja).
    await tester.tap(find.byTooltip('Cerrar'));
    await tester.pumpAndSettle();
    expect(_row('nevera'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  for (final size in const [Size(768, 1200), Size(1024, 600)]) {
    testWidgets('tableta ${size.width.toInt()}x${size.height.toInt()}: '
        'sin desbordes', (tester) async {
      await _pump(tester, size: size);
      expect(_row('horno'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(_row('horno'));
      await tester.pumpAndSettle();
      await tester.tap(_row('horno'));
      await tester.pumpAndSettle();
      expect(find.byType(FixedAssetDetailDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('alta con código de etiqueta, cantidad y total a la vista', (
    tester,
  ) async {
    final repo = await _pump(tester, size: const Size(1440, 1400));
    await tester.tap(find.byKey(const Key('fixed-assets-new')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('fixed-asset-form-code')),
      'MESA-07',
    );
    await tester.enterText(
      find.byKey(const Key('fixed-asset-form-quantity')),
      '40',
    );
    await tester.enterText(
      find.byKey(const Key('fixed-asset-form-name')),
      'Mesa plegable',
    );
    await tester.enterText(
      find.byKey(const Key('fixed-asset-form-cost')),
      '2,500',
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Total: RD\$100,000.00 (40 × RD\$2,500.00)'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('fixed-asset-form-save')));
    await tester.pumpAndSettle();
    final draft = repo.created.single;
    expect(draft.code, 'MESA-07');
    expect(draft.quantity, 40);
    expect(draft.purchaseCost, 2500);
    expect(draft.createJson()['code'], 'MESA-07');
    expect(draft.createJson()['quantity'], 40);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('editar: si la cantidad baja pide el motivo', (tester) async {
    final repo = await _pump(tester, size: const Size(1440, 1600));
    await tester.tap(_row('sillas'));
    await tester.pumpAndSettle();
    final dialog = find.byType(FixedAssetDetailDialog);
    expect(
      find.descendant(of: dialog, matching: find.text('40 unidades')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('RD\$100,000.00')),
      findsOneWidget,
      reason: 'valor total',
    );
    expect(
      find.descendant(of: dialog, matching: find.text('20/09/2026 (#3)')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('fixed-asset-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('fixed-asset-form-quantity')),
      '38',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fixed-asset-form-change-note')), findsOneWidget);

    await tester.tap(find.byKey(const Key('fixed-asset-form-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Escribe por qué baja la cantidad'), findsOneWidget);
    expect(repo.updated, isEmpty);

    await tester.enterText(
      find.byKey(const Key('fixed-asset-form-change-note')),
      'Se rompieron 2',
    );
    await tester.tap(find.byKey(const Key('fixed-asset-form-save')));
    await tester.pumpAndSettle();
    final json = repo.updated.single.dataJson();
    expect(json['quantity'], 38);
    expect(json['change_note'], 'Se rompieron 2');
    expect(json['code'], 'SILLA-01');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('filtro «sin verificar en 6 meses»', (tester) async {
    await _pump(tester, size: const Size(1440, 1400));
    await tester.tap(find.byKey(const Key('fixed-assets-stale')));
    await tester.pumpAndSettle();
    // Las sillas se verificaron el 20/09; el resto, nunca.
    expect(_row('sillas'), findsNothing);
    expect(_row('horno'), findsOneWidget);
    expect(_row('aire'), findsOneWidget);
  });

  testWidgets('base con solo 0052: sin código propio ni cantidad', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(1440, 1400),
      repo: _FakeRepo(_assets(), supportsQuantity: false),
    );
    expect(find.byKey(const Key('fixed-assets-stale')), findsNothing);
    await tester.tap(find.byKey(const Key('fixed-assets-new')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fixed-asset-form-code')), findsNothing);
    expect(find.byKey(const Key('fixed-asset-form-quantity')), findsNothing);
    expect(find.textContaining('20261001_0050'), findsOneWidget);
  });

  testWidgets('«Verificar» abre la verificación y avisa si ya había una', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeRepo(_assets());
    final router = GoRouter(
      initialLocation: AppRoutes.inventoryFixedAssets,
      routes: [
        GoRoute(
          path: AppRoutes.inventoryFixedAssets,
          builder: (_, _) => const FixedAssetsView(),
        ),
        GoRoute(
          path: AppRoutes.inventoryFixedAssetVerification,
          builder: (_, state) => Scaffold(
            body: Text('abierta ${state.pathParameters['verificationId']}'),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fixedAssetsRepositoryProvider.overrideWithValue(repo),
          sessionProvider.overrideWith(() => _Session(const {'*'})),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('fixed-assets-verify')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('verification-start-scope')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Todas las ubicaciones').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('verification-start-confirm')));
    await tester.pumpAndSettle();

    expect(repo.started, [null]);
    expect(find.text('abierta ver-1'), findsOneWidget);
    expect(
      find.text(
        'Ya había una verificación abierta de esta ubicación: la continúas.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('sin la migración lo dice en vez de quedarse en blanco', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(1200, 900),
      repo: _FakeRepo(const [], missing: true),
    );
    expect(
      find.byKey(const Key('fixed-assets-migration-missing')),
      findsOneWidget,
    );
    expect(find.textContaining('20260930_0052'), findsOneWidget);
    expect(find.textContaining('Falta aplicar la migración'), findsOneWidget);
  });

  testWidgets('registro vacío invita a registrar el primero', (tester) async {
    await _pump(
      tester,
      size: const Size(1200, 900),
      repo: _FakeRepo(const []),
    );
    expect(find.text('Todavía no hay activos registrados'), findsOneWidget);
    expect(find.text('Registrar el primero'), findsOneWidget);
  });
}
