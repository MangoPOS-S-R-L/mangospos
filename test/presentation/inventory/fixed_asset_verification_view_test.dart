// Verificador de activos: los caminos del escaneo (pieza esperada, grupo con
// «¿Cuántas hay?», fuera de lugar, dado de baja, código desconocido → alta
// en el acto, y la pistola sin tocar el campo), las acciones rápidas, el
// diálogo de cierre con sus valores por defecto, solo lectura al cerrar, y
// que todo quepa en 360 px.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/repositories/fixed_assets_repository.dart';
import 'package:mangopos/presentation/inventory/state/fixed_asset_verification_state.dart';
import 'package:mangopos/presentation/inventory/state/fixed_assets_state.dart';
import 'package:mangopos/presentation/inventory/view/fixed_asset_form_dialog.dart';
import 'package:mangopos/presentation/inventory/view/fixed_asset_verification_view.dart';
import 'package:mangopos/presentation/inventory/view/fixed_asset_verifications_view.dart';
import 'package:mangopos/presentation/sales/widgets/pos_barcode_scanner.dart';
import 'package:mangopos/services/session/session_controller.dart';

class _Session extends SessionController {
  _Session(this._permissions);

  final Set<String> _permissions;

  @override
  SessionState build() =>
      SessionState(userName: 'Cristian', permissions: _permissions);
}

FixedAsset _asset(
  String id,
  String code,
  String name, {
  int quantity = 1,
  double? cost = 1000,
  String? warehouseId = 'w-cocina',
  String warehouseName = 'Cocina',
  FixedAssetStatus status = FixedAssetStatus.active,
}) => FixedAsset(
  id: id,
  businessId: 'b1',
  code: code,
  name: name,
  quantity: quantity,
  purchaseCost: cost,
  warehouseId: warehouseId,
  warehouseName: warehouseName,
  status: status,
);

FixedAssetVerificationLine _line(
  FixedAsset a, {
  bool expected = true,
  int? found,
  FixedAssetStatus? observed,
  bool isNew = false,
  String? resolution,
}) => FixedAssetVerificationLine(
  id: 'line-${a.id}',
  verificationId: 'v1',
  assetId: a.id,
  assetCode: a.code,
  assetName: a.name,
  unitValue: a.purchaseCost,
  registeredWarehouseId: a.warehouseId,
  registeredWarehouseName: a.warehouseName.isEmpty ? null : a.warehouseName,
  expected: expected,
  expectedQty: expected ? a.quantity : null,
  foundQty: found,
  expectedStatus: a.status,
  observedStatus: observed,
  isNew: isNew,
  resolution: resolution,
);

final _horno = _asset('horno', 'AF-00001', 'Horno de convección', cost: 850000);
final _nevera = _asset('nevera', 'AF-00002', 'Nevera vertical', cost: 95000);
final _sillas = _asset(
  'sillas',
  'SILLA-01',
  'Silla de madera',
  quantity: 40,
  cost: 2500,
);
final _tv = _asset(
  'tv',
  'AF-00009',
  'TV de la barra',
  warehouseId: 'w-bar',
  warehouseName: 'Bar',
);
final _mesa = _asset(
  'mesa',
  'AF-00003',
  'Mesa vieja',
  status: FixedAssetStatus.retired,
);

class _Check {
  _Check(this.assetId, this.found, this.observed, this.notes);
  final String assetId;
  final int found;
  final FixedAssetStatus? observed;
  final String? notes;
}

class _FakeRepo implements FixedAssetsRepository {
  _FakeRepo({
    FixedAssetVerification? verification,
    this.missing = false,
  }) : verification = verification ?? _openVerification();

  FixedAssetVerification verification;
  final bool missing;
  List<FixedAsset> assets = [_horno, _nevera, _sillas, _tv, _mesa];
  final checks = <_Check>[];
  final unchecks = <String>[];
  final added = <(FixedAssetDraft, String?)>[];
  List<Map<String, String>>? closedWith;
  String? cancelReason;

  static FixedAssetVerification _openVerification() => FixedAssetVerification(
    id: 'v1',
    businessId: 'b1',
    number: 3,
    warehouseId: 'w-cocina',
    warehouseName: 'Cocina',
    startedByName: 'Dueño Penda',
    startedAt: DateTime(2026, 10, 1, 10),
    lines: sortVerificationLines([
      _line(_horno),
      _line(_nevera),
      _line(_sillas),
    ]),
  );

  @override
  bool get quantitySupported => true;

  @override
  Future<String?> resolveBusinessId() async => 'b1';

  @override
  Future<FixedAssetVerification> getVerification(String id) async {
    if (missing) throw const FixedAssetVerificationMigrationMissing();
    return verification;
  }

  @override
  Future<List<FixedAsset>> listAssets(String businessId) async => assets;

  @override
  Future<List<FixedAssetOption>> listWarehouses(String businessId) async =>
      const [
        FixedAssetOption('w-cocina', 'Cocina'),
        FixedAssetOption('w-bar', 'Bar'),
      ];

  @override
  Future<List<FixedAssetOption>> listEmployees(String businessId) async =>
      const [FixedAssetOption('e1', 'Juan Pérez')];

  @override
  Future<String> getBusinessName(String businessId) async => 'La Penda';

  FixedAsset _byId(String id) => assets.firstWhere((a) => a.id == id);

  /// Como el servidor: null conserva lo anotado; el estado actual = «sin
  /// cambio»; sin línea = «fuera de lugar».
  @override
  Future<FixedAssetVerificationLine> checkVerificationLine({
    required String verificationId,
    required String assetId,
    required int foundQty,
    FixedAssetStatus? observedStatus,
    String? notes,
  }) async {
    checks.add(_Check(assetId, foundQty, observedStatus, notes));
    final asset = _byId(assetId);
    final old = verification.lineFor(assetId);
    final observed = observedStatus == null
        ? old?.observedStatus
        : (observedStatus == asset.status ? null : observedStatus);
    final base = old ?? _line(asset, expected: false);
    final line = FixedAssetVerificationLine(
      id: base.id,
      verificationId: base.verificationId,
      assetId: base.assetId,
      assetCode: base.assetCode,
      assetName: base.assetName,
      unitValue: base.unitValue,
      registeredWarehouseId: base.registeredWarehouseId,
      registeredWarehouseName: base.registeredWarehouseName,
      expected: base.expected,
      expectedQty: base.expectedQty,
      foundQty: foundQty,
      expectedStatus: base.expectedStatus,
      observedStatus: observed,
      isNew: base.isNew,
      notes: notes ?? old?.notes,
    );
    verification = verification.withLine(line);
    return line;
  }

  @override
  Future<VerificationUncheckResult> uncheckVerificationLine({
    required String verificationId,
    required String assetId,
  }) async {
    unchecks.add(assetId);
    final old = verification.lineFor(assetId)!;
    if (!old.expected) {
      verification = verification.withoutLine(assetId);
      return (removed: true, line: null);
    }
    final line = _line(_byId(assetId));
    verification = verification.withLine(line);
    return (removed: false, line: line);
  }

  @override
  Future<VerificationAddResult> addVerificationAsset({
    required String verificationId,
    required FixedAssetDraft draft,
    String? clientRequestId,
  }) async {
    added.add((draft, clientRequestId));
    final asset = FixedAsset(
      id: 'nuevo-${added.length}',
      businessId: 'b1',
      code: draft.code ?? 'AF-00010',
      name: draft.name,
      quantity: draft.quantity ?? 1,
      purchaseCost: draft.purchaseCost,
      warehouseId: 'w-cocina',
      warehouseName: 'Cocina',
    );
    assets = [...assets, asset];
    final line = _line(asset, expected: false, isNew: true, found: asset.quantity);
    verification = verification.withLine(line);
    return (asset: asset, line: line);
  }

  @override
  Future<FixedAssetVerification> closeVerification({
    required String verificationId,
    required List<Map<String, String>> decisions,
    String? notes,
  }) async {
    closedWith = decisions;
    verification = FixedAssetVerification(
      id: 'v1',
      businessId: 'b1',
      number: 3,
      warehouseId: 'w-cocina',
      warehouseName: 'Cocina',
      status: FixedAssetVerificationStatus.closed,
      startedByName: 'Dueño Penda',
      startedAt: DateTime(2026, 10, 1, 10),
      closedByName: 'Dueño Penda',
      closedAt: DateTime(2026, 10, 1, 12),
      summary: const FixedAssetVerificationSummary(
        expectedCount: 3,
        okCount: 1,
        missingCount: 1,
        missingUnits: 2,
        missingValue: 5000,
        lostCount: 1,
        foundValue: 945000,
      ),
      lines: verification.lines,
    );
    return verification;
  }

  @override
  Future<FixedAssetVerification> cancelVerification({
    required String verificationId,
    required String reason,
  }) async {
    cancelReason = reason;
    verification = FixedAssetVerification(
      id: 'v1',
      businessId: 'b1',
      number: 3,
      warehouseId: 'w-cocina',
      warehouseName: 'Cocina',
      status: FixedAssetVerificationStatus.cancelled,
      cancelReason: reason,
      lines: verification.lines,
    );
    return verification;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_FakeRepo> _pump(
  WidgetTester tester, {
  Size size = const Size(1440, 1400),
  _FakeRepo? repo,
  Set<String> permissions = const {'*'},
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fake = repo ?? _FakeRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        fixedAssetsRepositoryProvider.overrideWithValue(fake),
        sessionProvider.overrideWith(() => _Session(permissions)),
      ],
      child: const MaterialApp(
        home: FixedAssetVerificationView(verificationId: 'v1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

Future<void> _scan(WidgetTester tester, String code) async {
  await tester.enterText(find.byKey(const Key('verification-scan')), code);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

Finder _lineKey(String id) => find.byKey(ValueKey('verification-line-$id'));

KeyDownEvent _down(LogicalKeyboardKey key, {String? character}) =>
    KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      character: character,
      timeStamp: Duration.zero,
    );

void main() {
  tearDown(ScanDispatcher.instance.resetForTest);

  testWidgets('cabecera, avance y líneas pendientes', (tester) async {
    await _pump(tester);
    expect(find.text('Verificación #3 · Cocina'), findsOneWidget);
    expect(find.text('0 de 3 revisados'), findsOneWidget);
    expect(find.text('Pendientes (3)'), findsOneWidget);
    expect(find.byKey(const Key('verification-scan')), findsOneWidget);
    expect(_lineKey('sillas'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pieza esperada: se marca al escanear (sin importar mayúsculas)', (
    tester,
  ) async {
    final repo = await _pump(tester);
    await _scan(tester, '  af-00001 ');

    expect(repo.checks.single.assetId, 'horno');
    expect(repo.checks.single.found, 1);
    expect(repo.checks.single.observed, isNull);
    expect(find.text('1 de 3 revisados'), findsOneWidget);
    expect(find.text('Encontrados (1)'), findsOneWidget);
    expect(find.text('Encontrado: Horno de convección'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('grupo: «¿Cuántas hay?» con lo esperado y estado visto', (
    tester,
  ) async {
    final repo = await _pump(tester);
    await _scan(tester, 'SILLA-01');

    expect(find.text('¿Cuántas hay?'), findsOneWidget);
    expect(find.text('Esperado: 40'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const Key('verification-found-qty')),
    );
    expect(field.controller!.text, '40');

    await tester.enterText(find.byKey(const Key('verification-found-qty')), '38');
    await tester.tap(find.byKey(const ValueKey('verification-observed-damaged')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('verification-found-confirm')));
    await tester.pumpAndSettle();

    final c = repo.checks.single;
    expect(c.assetId, 'sillas');
    expect(c.found, 38);
    expect(c.observed, FixedAssetStatus.damaged);
    expect(find.text('Con diferencia (1)'), findsOneWidget);
    expect(find.text('Esperado 40 · Encontrado 38'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('fuera de lugar: pregunta y queda en su pestaña', (tester) async {
    final repo = await _pump(tester);
    await _scan(tester, 'AF-00009');

    expect(find.text('Este activo está registrado en Bar'), findsOneWidget);
    expect(find.text('¿Lo encontraste aquí, en Cocina?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('verification-found-confirm')));
    await tester.pumpAndSettle();

    expect(repo.checks.single.assetId, 'tv');
    expect(repo.checks.single.found, 1);
    expect(find.text('Fuera de lugar (1)'), findsOneWidget);
    expect(find.text('Registrado en Bar'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('dado de baja: lo explica y no marca nada', (tester) async {
    final repo = await _pump(tester);
    await _scan(tester, 'AF-00003');
    expect(find.byKey(const Key('verification-retired-dialog')), findsOneWidget);
    expect(find.textContaining('reactívalo desde su ficha'), findsOneWidget);
    expect(repo.checks, isEmpty);
    await tester.tap(find.text('Entendido'));
    await tester.pumpAndSettle();
  });

  testWidgets('código desconocido: se registra en el acto, en esta ubicación', (
    tester,
  ) async {
    final repo = await _pump(tester);
    await _scan(tester, 'NUEVO-77');

    expect(find.text('El código «NUEVO-77» no está registrado. ¿Registrarlo?'),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('verification-unknown-create')));
    await tester.pumpAndSettle();

    expect(find.byType(FixedAssetFormDialog), findsOneWidget);
    final code = tester.widget<TextField>(
      find.byKey(const Key('fixed-asset-form-code')),
    );
    expect(code.controller!.text, 'NUEVO-77');
    expect(find.byKey(const Key('fixed-asset-locked-warehouse')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('fixed-asset-form-name')),
      'Licuadora',
    );
    await tester.enterText(
      find.byKey(const Key('fixed-asset-form-quantity')),
      '2',
    );
    await tester.tap(find.byKey(const Key('fixed-asset-form-save')));
    await tester.pumpAndSettle();

    final (draft, requestId) = repo.added.single;
    expect(draft.code, 'NUEVO-77');
    expect(draft.quantity, 2);
    expect(requestId, isNotNull);
    expect(find.text('Nuevos (1)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('la pistola funciona sin tocar el campo', (tester) async {
    final repo = await _pump(tester);
    for (final c in 'AF-00002'.split('')) {
      ScanDispatcher.instance.feedKey(
        _down(LogicalKeyboardKey(c.codeUnitAt(0)), character: c),
      );
    }
    ScanDispatcher.instance.feedKey(_down(LogicalKeyboardKey.enter));
    await tester.pumpAndSettle();
    expect(repo.checks.single.assetId, 'nevera');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('acciones rápidas: Está, No está y Deshacer', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('line-ok-sillas')));
    await tester.pumpAndSettle();
    expect(repo.checks.last.found, 40);
    expect(repo.checks.last.observed, isNull, reason: '«Está» conserva lo anotado');

    await tester.tap(find.byKey(const ValueKey('line-missing-nevera')));
    await tester.pumpAndSettle();
    expect(repo.checks.last.found, 0);
    expect(find.text('Esperado 1 · No está'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('line-undo-nevera')));
    await tester.pumpAndSettle();
    expect(repo.unchecks, ['nevera']);
    expect(find.text('1 de 3 revisados'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('cerrar: solo lo que no cuadra, con los valores por defecto', (
    tester,
  ) async {
    final repo = _FakeRepo(
      verification: FixedAssetVerification(
        id: 'v1',
        businessId: 'b1',
        number: 3,
        warehouseId: 'w-cocina',
        warehouseName: 'Cocina',
        lines: sortVerificationLines([
          _line(_horno, found: 1, observed: FixedAssetStatus.damaged),
          _line(_nevera),
          _line(_sillas, found: 38),
          _line(_tv, expected: false, found: 1),
        ]),
      ),
    );
    await _pump(tester, repo: repo);
    await tester.tap(find.byKey(const Key('verification-close')));
    await tester.pumpAndSettle();

    final dialog = find.byType(VerificationCloseDialog);
    expect(dialog, findsOneWidget);
    expect(find.text('Faltantes (2)'), findsOneWidget);
    expect(find.text('Bajar cantidad a 38'), findsOneWidget);
    expect(find.text('Marcar perdido'), findsOneWidget);
    // Por defecto los faltantes quedan «pendiente de búsqueda».
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('close-pending-sillas')))
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('close-move_here-tv')),
          )
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('close-apply_condition-horno')),
          )
          .value,
      isTrue,
    );
    // 2 × 2,500 + 1 × 95,000.
    expect(
      find.text(
        'Valor faltante: RD\$100,000.00 · se da por perdido: RD\$0.00',
      ),
      findsOneWidget,
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey('close-mark_lost-sillas')),
    );
    await tester.tap(find.byKey(const ValueKey('close-mark_lost-sillas')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Valor faltante: RD\$100,000.00 · se da por perdido: RD\$5,000.00',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('close-confirm')));
    await tester.pumpAndSettle();

    expect(repo.closedWith, [
      {'asset_id': 'sillas', 'action': 'mark_lost'},
      {'asset_id': 'tv', 'action': 'move_here'},
      {'asset_id': 'horno', 'action': 'apply_condition'},
    ]);
    // Cerrada: resumen y solo lectura.
    expect(find.byKey(const Key('verification-summary')), findsOneWidget);
    expect(find.byKey(const Key('verification-scan')), findsNothing);
    expect(find.byKey(const Key('verification-close')), findsNothing);
    expect(find.byKey(const ValueKey('line-ok-nevera')), findsNothing);
    expect(find.byKey(const Key('verification-act')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('cancelar pide el motivo', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.byKey(const Key('verification-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('verification-cancel-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Escribe el motivo de la cancelación.'), findsOneWidget);
    expect(repo.cancelReason, isNull);

    await tester.enterText(
      find.byKey(const Key('verification-cancel-reason')),
      'Se abrió por error',
    );
    await tester.tap(find.byKey(const Key('verification-cancel-confirm')));
    await tester.pumpAndSettle();
    expect(repo.cancelReason, 'Se abrió por error');
    expect(find.textContaining('Motivo: Se abrió por error'), findsOneWidget);
    expect(find.byKey(const Key('verification-scan')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('sin gestionar: solo lectura aunque esté abierta', (tester) async {
    await _pump(tester, permissions: const {'inventario.activos.acceso'});
    expect(find.byKey(const Key('verification-scan')), findsNothing);
    expect(find.byKey(const Key('verification-close')), findsNothing);
    expect(find.byKey(const ValueKey('line-ok-horno')), findsNothing);
    expect(find.byKey(const Key('verification-act')), findsOneWidget);
  });

  testWidgets('360 px: tarjetas, diálogos y cierre sin desbordes', (
    tester,
  ) async {
    final repo = _FakeRepo(
      verification: FixedAssetVerification(
        id: 'v1',
        businessId: 'b1',
        number: 3,
        warehouseId: 'w-cocina',
        warehouseName: 'Cocina caliente del segundo piso',
        lines: sortVerificationLines([
          _line(_horno, found: 1, observed: FixedAssetStatus.needsRepair),
          _line(_nevera),
          _line(_sillas, found: 38),
          _line(_tv, expected: false, found: 1),
        ]),
      ),
    );
    await _pump(tester, size: const Size(360, 3000), repo: repo);
    expect(tester.takeException(), isNull);

    await _scan(tester, 'SILLA-01');
    expect(find.text('¿Cuántas hay?'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancelar').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('verification-close')));
    await tester.pumpAndSettle();
    expect(find.byType(VerificationCloseDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sin la migración lo dice', (tester) async {
    await _pump(tester, repo: _FakeRepo(missing: true));
    expect(
      find.byKey(const Key('verification-migration-missing')),
      findsOneWidget,
    );
    expect(find.textContaining('20261001_0050'), findsOneWidget);
  });

  testWidgets('historial: abiertas primero, con avance y resumen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _ListRepo();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fixedAssetsRepositoryProvider.overrideWithValue(repo),
          sessionProvider.overrideWith(() => _Session(const {'*'})),
        ],
        child: const MaterialApp(home: FixedAssetVerificationsView()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Verificación #4 · Bar'), findsOneWidget);
    expect(find.text('18 de 30 revisados · 2 fuera de lugar'), findsOneWidget);
    expect(find.textContaining('27 en orden'), findsOneWidget);
    expect(find.textContaining('Cancelada: Se abrió por error'), findsOneWidget);
    expect(find.byKey(const Key('verifications-new')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _ListRepo implements FixedAssetsRepository {
  @override
  Future<String?> resolveBusinessId() async => 'b1';

  @override
  Future<List<FixedAssetOption>> listWarehouses(String businessId) async =>
      const [FixedAssetOption('w-bar', 'Bar')];

  @override
  Future<List<FixedAssetVerification>> listVerifications(
    String businessId,
  ) async => [
    FixedAssetVerification(
      id: 'v4',
      businessId: 'b1',
      number: 4,
      warehouseId: 'w-bar',
      warehouseName: 'Bar',
      startedAt: DateTime(2026, 10, 1, 9),
      startedByName: 'Ana',
      listProgress: const VerificationProgress(
        expected: 30,
        checked: 18,
        misplaced: 2,
      ),
    ),
    FixedAssetVerification(
      id: 'v3',
      businessId: 'b1',
      number: 3,
      warehouseId: 'w-cocina',
      warehouseName: 'Cocina',
      status: FixedAssetVerificationStatus.closed,
      startedAt: DateTime(2026, 9, 1, 9),
      summary: const FixedAssetVerificationSummary(
        okCount: 27,
        missingCount: 2,
        missingValue: 5000,
        newCount: 1,
      ),
    ),
    FixedAssetVerification(
      id: 'v2',
      businessId: 'b1',
      number: 2,
      status: FixedAssetVerificationStatus.cancelled,
      cancelReason: 'Se abrió por error',
      startedAt: DateTime(2026, 8, 1, 9),
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
