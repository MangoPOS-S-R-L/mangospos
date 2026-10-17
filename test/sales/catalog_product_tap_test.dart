import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/sales/logic/catalog_product_tap.dart';

class _CatalogTap {
  String? orderId = 'order-A';
  String? businessId = 'business-A';
  String origin = 'table';
  String? tableId = 'table-A';
  Object? visitId = Object();
  bool mounted = true;
  int consumedMultipliers = 0;
  final added = <({String? orderId, double price, List<String> modifiers})>[];
  final calls = <String>[];
  final started = Completer<void>();
  final release = Completer<List<String>>();
  final tracker = CatalogProductTapTracker();

  CatalogProductTapSelection get selection => CatalogProductTapSelection(
    orderId: orderId,
    businessId: businessId,
    origin: origin,
    tableId: tableId,
    visitId: visitId,
  );

  Future<void> tap({String? defer, bool combo = false}) {
    final captured = selection;
    Future<List<String>> step(String name, List<String> result) async {
      calls.add(name);
      if (name == defer) {
        started.complete();
        return release.future;
      }
      return result;
    }

    // Este es el mismo flujo que ejecuta _handleProductTap, con catálogo y
    // diálogos controlados para reproducir la respuesta después de navegar.
    Future<void> prepare() => runCatalogProductTap<String, String>(
      isCombo: combo,
      selectionStillCurrent: () => mounted && captured.matches(selection),
      loadComboGroups: () => step('load-combo', ['combo-group']),
      chooseCombo: (_) => step('choose-combo', ['a las rocas']),
      loadModifierGroups: () => step('load-modifiers', ['modifier-group']),
      chooseModifiers: (_) => step('choose-modifiers', ['limón']),
      addItem: (modifiers) async {
        consumedMultipliers++;
        added.add((orderId: orderId, price: 425, modifiers: modifiers));
      },
    );
    if (captured.orderId == null || captured.businessId == null) {
      return prepare();
    }
    return tracker.track(
      businessId: captured.businessId!,
      orderId: captured.orderId!,
      action: prepare,
    );
  }

  void goToB() {
    orderId = 'order-B';
    tableId = 'table-B';
    visitId = Object();
  }
}

void main() {
  test(
    'precuenta espera al producto aun antes de que exista la línea',
    () async {
      final tap = _CatalogTap();
      final pending = tap.tap(defer: 'load-modifiers');
      await tap.started.future;
      expect(tap.added, isEmpty);
      expect(
        tap.tracker.isPending(businessId: 'business-A', orderId: 'order-A'),
        isTrue,
      );
      tap.release.complete([]);
      await pending;
      expect(tap.added.single.price, 425);
      expect(
        tap.tracker.isPending(businessId: 'business-A', orderId: 'order-A'),
        isFalse,
      );
    },
  );

  test('la cuenta espera todas las selecciones simultáneas', () async {
    final tracker = CatalogProductTapTracker();
    final first = Completer<void>();
    final second = Completer<void>();
    final pendingFirst = tracker.track(
      businessId: 'business-A',
      orderId: 'order-A',
      action: () => first.future,
    );
    final pendingSecond = tracker.track(
      businessId: 'business-A',
      orderId: 'order-A',
      action: () => second.future,
    );
    first.complete();
    await pendingFirst;
    expect(
      tracker.isPending(businessId: 'business-A', orderId: 'order-A'),
      isTrue,
    );
    expect(
      tracker.isPending(businessId: 'business-B', orderId: 'order-A'),
      isFalse,
    );
    expect(
      tracker.isPending(businessId: 'business-A', orderId: 'order-B'),
      isFalse,
    );
    second.complete();
    await pendingSecond;
    expect(
      tracker.isPending(businessId: 'business-A', orderId: 'order-A'),
      isFalse,
    );
  });

  test('un error de catálogo libera la cuenta para reintentar', () async {
    final tracker = CatalogProductTapTracker();
    final attempt = tracker.track<void>(
      businessId: 'business-A',
      orderId: 'order-A',
      action: () async => throw StateError('sin catálogo'),
    );
    await expectLater(attempt, throwsStateError);
    expect(
      tracker.isPending(businessId: 'business-A', orderId: 'order-A'),
      isFalse,
    );
  });

  for (final wait in [
    'load-combo',
    'choose-combo',
    'load-modifiers',
    'choose-modifiers',
  ]) {
    test(
      'trago de 425 preparado en A no entra en B tras $wait lento',
      () async {
        final tap = _CatalogTap();
        final pending = tap.tap(defer: wait, combo: true);
        await tap.started.future;
        tap.goToB();
        final callsAtNavigation = List<String>.of(tap.calls);
        tap.release.complete(['selección tardía']);
        await pending;

        expect(
          tap.added,
          isEmpty,
          reason: 'la caja de B no sube de 1770 a 2195',
        );
        expect(tap.consumedMultipliers, 0);
        expect(
          tap.calls,
          callsAtNavigation,
          reason: 'no abre otro diálogo en B',
        );
      },
    );
  }

  test('A → B → A con la misma orden descarta la visita anterior', () async {
    final tap = _CatalogTap();
    final firstVisit = tap.visitId;
    final pending = tap.tap(defer: 'load-modifiers');
    await tap.started.future;
    tap.goToB();
    tap.orderId = 'order-A';
    tap.tableId = 'table-A';
    tap.visitId = Object();
    expect(identical(tap.visitId, firstVisit), isFalse);
    tap.release.complete([]);
    await pending;
    expect(tap.added, isEmpty);
    expect(tap.consumedMultipliers, 0);
  });

  test(
    'cambio de negocio invalida una selección con iguales ids de venta',
    () async {
      final tap = _CatalogTap();
      final pending = tap.tap(defer: 'load-modifiers');
      await tap.started.future;
      tap.businessId = 'business-B';
      tap.release.complete([]);
      await pending;
      expect(tap.added, isEmpty);
    },
  );

  test('salir de la pantalla mientras carga no agrega ni consume N×', () async {
    final tap = _CatalogTap();
    final pending = tap.tap(defer: 'load-modifiers');
    await tap.started.future;
    tap.mounted = false;
    tap.release.complete([]);
    await pending;
    expect(tap.added, isEmpty);
    expect(tap.consumedMultipliers, 0);
  });

  test(
    'misma visita agrega una vez con las opciones de combo y modificador',
    () async {
      final tap = _CatalogTap();
      await tap.tap(combo: true);
      expect(tap.added, hasLength(1));
      expect(tap.added.single.orderId, 'order-A');
      expect(tap.added.single.price, 425);
      expect(tap.added.single.modifiers, ['a las rocas', 'limón']);
      expect(tap.consumedMultipliers, 1);
    },
  );

  test(
    'producto sin grupos se agrega en la cuenta capturada sin diálogo',
    () async {
      final tap = _CatalogTap();
      final pending = tap.tap(defer: 'load-modifiers');
      await tap.started.future;
      tap.release.complete([]);
      await pending;
      expect(tap.added.single.orderId, 'order-A');
      expect(tap.added.single.price, 425);
      expect(tap.added.single.modifiers, isEmpty);
      expect(tap.calls, ['load-modifiers']);
    },
  );

  test('sin una orden abierta no empieza a preparar el producto', () async {
    final tap = _CatalogTap()..orderId = null;
    await tap.tap();
    expect(tap.calls, isEmpty);
    expect(tap.added, isEmpty);
    expect(tap.consumedMultipliers, 0);
  });

  test('cancelar opciones no agrega el producto', () async {
    var additions = 0;
    await runCatalogProductTap<String, String>(
      isCombo: false,
      selectionStillCurrent: () => true,
      loadComboGroups: () async => [],
      chooseCombo: (_) async => [],
      loadModifierGroups: () async => ['sabor'],
      chooseModifiers: (_) async => null,
      addItem: (_) async => additions++,
    );
    expect(additions, 0);
  });
}
