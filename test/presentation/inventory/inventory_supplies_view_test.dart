// Pantalla «Gastables y menaje» (20260930_0051): las dos pestañas, el consumo
// por área, la ficha, la clasificación en lote y los estados sin datos o sin
// la migración. Y que en un teléfono de 360 px nada se desborde.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/supplies_repository.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';
import 'package:mangopos/presentation/inventory/view/inventory_supplies_view.dart';
import 'package:mangopos/presentation/inventory/viewmodel/supplies_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeSupplies implements SuppliesRepository {
  _FakeSupplies(this.overview);

  Map<String, dynamic> overview;
  Object? overviewError;
  final classified = <({List<String> ids, String classification})>[];
  List<ClassifiableItem> classifiable = const [];

  @override
  Future<Map<String, dynamic>> getOverview({
    required String businessId,
    int daysBack = 30,
    String? warehouseId,
  }) async {
    final e = overviewError;
    if (e != null) throw e;
    return overview;
  }

  @override
  Future<List<ClassifiableItem>> getClassifiableItems(String businessId) async =>
      classifiable;

  @override
  Future<int> setClassification({
    required String businessId,
    required List<String> itemIds,
    required String classification,
  }) async {
    classified.add((ids: itemIds, classification: classification));
    return itemIds.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeInventory implements InventoryRepository {
  @override
  Future<List<InventoryWarehouse>> getWarehouses(String businessId) async =>
      const [
        InventoryWarehouse(id: 'w1', name: 'Principal', isMain: true),
        InventoryWarehouse(id: 'w2', name: 'Bar', isMain: false),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session extends SessionController {
  _Session(this.perms);
  final Set<String> perms;

  @override
  SessionState build() => SessionState(permissions: perms);
}

Map<String, dynamic> _item(
  String id,
  String name,
  String cls, {
  double stock = 0,
  double min = 0,
  double used = 0,
  double broken = 0,
  double lost = 0,
}) => {
  'item_id': id,
  'item_name': name,
  'item_unit': cls == 'supply' ? 'rollo' : 'u',
  'classification': cls,
  'unit_cost': 20,
  'stock': stock,
  'min_stock': min,
  'min_source': 'insumo',
  'used_qty': used,
  'used_value': used * 20,
  'broken_qty': broken,
  'broken_value': broken * 20,
  'lost_qty': lost,
  'lost_value': lost * 20,
  'by_warehouse': [
    {'warehouse_id': 'w1', 'warehouse_name': 'Principal', 'qty': stock},
  ],
};

Map<String, dynamic> _overview() => {
  'days': 30,
  'items': [
    _item('p', 'Papel higiénico', 'supply', stock: 5, min: 48, used: 43),
    _item('cl', 'Cloro', 'supply', stock: 10, used: 6),
    _item('c', 'Copa de vino', 'smallware', stock: 100, min: 120, broken: 6),
    _item('o', 'Olla 20 L', 'smallware', stock: 2, min: 2),
  ],
  'by_destination': [
    {'destination': 'Baños', 'value': 480, 'count': 3},
    {'destination': 'Cocina', 'value': 240, 'count': 1},
    {'destination': null, 'value': 140, 'count': 2},
  ],
};

const _allPerms = {
  'inventario.acceso',
  'inventario.ajustes.crear',
  'inventario.productos.crear_editar',
};

Future<_FakeSupplies> _pump(
  WidgetTester tester, {
  Size size = const Size(1400, 1000),
  Map<String, dynamic>? overview,
  Object? error,
  Set<String> perms = _allPerms,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final repo = _FakeSupplies(overview ?? _overview())..overviewError = error;
  final vm = SuppliesViewModel(
    repo,
    _FakeInventory(),
    resolveBusiness: () async => 'biz-1',
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        suppliesViewModelProvider.overrideWith((ref) => vm),
        sessionProvider.overrideWith(() => _Session(perms)),
      ],
      child: const MaterialApp(home: InventorySuppliesView()),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('gastables: consumo, por reponer y consumo por área', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Gastables y menaje'), findsOneWidget);
    expect(find.text('Gastables · 2'), findsOneWidget);
    expect(find.text('Menaje · 2'), findsOneWidget);
    expect(find.byKey(const Key('supplies-kpi-consumed')), findsOneWidget);
    expect(find.byKey(const Key('supplies-destinations')), findsOneWidget);
    expect(find.text('Baños'), findsOneWidget);
    expect(find.text('Sin área'), findsOneWidget);
    // El papel está bajo el mínimo: va primero y dice «Reponer».
    expect(find.byKey(const ValueKey('supplies-row-p')), findsOneWidget);
    expect(find.text('Reponer'), findsOneWidget);
    // El menaje no está en esta pestaña.
    expect(find.byKey(const ValueKey('supplies-row-c')), findsNothing);
  });

  testWidgets('menaje: roturas y cuántas faltan para el par', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('Menaje · 2'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('smallware-kpi-broken')), findsOneWidget);
    expect(find.byKey(const Key('supplies-destinations')), findsNothing);
    expect(find.text('Faltan 20'), findsOneWidget);
    expect(find.byKey(const ValueKey('supplies-row-o')), findsOneWidget);
  });

  testWidgets('tocar un artículo abre su ficha con dónde está', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('supplies-row-p')));
    await tester.pumpAndSettle();

    expect(find.byType(SupplyItemDialog), findsOneWidget);
    expect(find.text('Dónde está'), findsOneWidget);
    expect(find.text('Consumo interno'), findsOneWidget);
  });

  testWidgets('«Por reponer» deja solo lo que hay que comprar', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('supplies-only-attention')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('supplies-row-p')), findsOneWidget);
    expect(find.byKey(const ValueKey('supplies-row-cl')), findsNothing);
  });

  testWidgets('sin gastables explica qué marcar y ofrece clasificar', (
    tester,
  ) async {
    await _pump(tester, overview: {'days': 30, 'items': []});
    expect(find.byKey(const Key('supplies-empty')), findsOneWidget);
    expect(find.text('Todavía no hay gastables'), findsOneWidget);
  });

  testWidgets('sin la migración lo dice en vez de quedarse en blanco', (
    tester,
  ) async {
    await _pump(
      tester,
      error: const PostgrestException(message: 'no fn', code: 'PGRST202'),
    );
    expect(find.text('Falta habilitarlo en el servidor'), findsOneWidget);
  });

  testWidgets('sin permisos no se clasifica ni se registra salida', (
    tester,
  ) async {
    await _pump(tester, perms: const {'inventario.acceso'});
    final classify = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('supplies-classify')),
    );
    final outflow = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('supplies-register-outflow')),
    );
    expect(classify.onPressed, isNull);
    expect(outflow.onPressed, isNull);
  });

  testWidgets('clasificar en lote marca los elegidos con la clase elegida', (
    tester,
  ) async {
    final repo = await _pump(tester);
    repo.classifiable = const [
      ClassifiableItem(
        id: 'i1',
        name: 'Servilletas',
        sku: '',
        unit: 'paquete',
        classification: 'simple',
      ),
      ClassifiableItem(
        id: 'i2',
        name: 'Fundas negras',
        sku: '',
        unit: 'paquete',
        classification: 'simple',
      ),
      ClassifiableItem(
        id: 'i3',
        name: 'Papel higiénico',
        sku: '',
        unit: 'rollo',
        classification: 'supply',
      ),
    ];
    await tester.tap(find.byKey(const Key('supplies-classify')));
    await tester.pumpAndSettle();

    // El que ya es gastable no se puede marcar otra vez.
    final papel = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('classify-i3')),
    );
    expect(papel.onChanged, isNull);
    expect(find.text('Ya es Gastable'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('classify-i1')));
    await tester.tap(find.byKey(const ValueKey('classify-i2')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('classify-apply')));
    await tester.pumpAndSettle();

    expect(repo.classified.single.classification, 'supply');
    expect(repo.classified.single.ids, unorderedEquals(['i1', 'i2']));
    expect(find.text('Clasificar artículos'), findsOneWidget); // solo el botón
  });

  testWidgets('volver a «Insumo» solo ofrece gastables y menaje', (
    tester,
  ) async {
    final repo = await _pump(tester);
    repo.classifiable = const [
      ClassifiableItem(
        id: 'i1',
        name: 'Leche',
        sku: '',
        unit: 'l',
        classification: 'raw_material',
      ),
      ClassifiableItem(
        id: 'i3',
        name: 'Papel higiénico',
        sku: '',
        unit: 'rollo',
        classification: 'supply',
      ),
    ];
    await tester.tap(find.byKey(const Key('supplies-classify')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('classify-target')),
        matching: find.text('Insumo'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('classify-i1')), findsNothing);
    expect(find.byKey(const ValueKey('classify-i3')), findsOneWidget);
  });

  testWidgets('teléfono de 360 px: las dos pestañas sin desbordes', (
    tester,
  ) async {
    await _pump(tester, size: const Size(360, 800));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('supplies-row-p')), findsOneWidget);

    await tester.tap(find.text('Menaje · 2'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('supplies-row-c')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
