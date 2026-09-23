import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/core/offline/offline_readiness.dart';
import 'package:mangopos/core/offline/offline_readiness_provider.dart';
import 'package:mangopos/core/offline/offline_refreshers.dart';
import 'package:mangopos/core/offline/offline_sync_coordinator.dart';
import 'package:mangopos/presentation/shell/offline_preparation_banner.dart';

void main() {
  OfflineReadiness ready(bool complete) => OfflineReadiness(
    checkedAt: DateTime(2026, 9, 22, 10, 30),
    checks: [
      OfflineReadinessCheck(
        'Productos y precios',
        complete,
        complete ? 'Catálogo guardado.' : 'Falta descargar el catálogo.',
      ),
    ],
  );

  Future<void> mount(
    WidgetTester tester,
    OfflineSyncCoordinator coordinator, {
    bool complete = true,
    OfflineReadiness? snapshot,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          offlineSyncCoordinatorProvider.overrideWith((ref) => coordinator),
          offlineReadinessProvider.overrideWith((ref) async {
            ref.watch(offlineSyncCoordinatorProvider);
            return snapshot ?? ready(complete);
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(body: OfflinePreparationBanner()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'muestra pendiente y revisión local sin iniciar descargas offline',
    (tester) async {
      var downloads = 0;
      final coordinator = OfflineSyncCoordinator(
        connectionStream: const Stream.empty(),
        isConnectedNow: () => false,
        refreshers: [() async => downloads++],
      );
      await mount(tester, coordinator, complete: false);
      expect(find.text('Preparación offline pendiente'), findsOneWidget);
      await tester.tap(find.text('Ver detalles'));
      await tester.pumpAndSettle();
      expect(find.text('Falta descargar el catálogo.'), findsOneWidget);
      await tester.tap(find.text('Revisar datos guardados'));
      await tester.pumpAndSettle();
      expect(downloads, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actualización manual muestra progreso e impide doble pulsación',
    (tester) async {
      var downloads = 0;
      final gate = Completer<void>();
      final coordinator = OfflineSyncCoordinator(
        connectionStream: const Stream.empty(),
        isConnectedNow: () => true,
        refreshers: [
          () async {
            downloads++;
            await gate.future;
          },
        ],
      );
      await mount(tester, coordinator);
      expect(find.text('Datos offline listos'), findsOneWidget);
      await tester.tap(find.text('Ver detalles'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Actualizar descargas'));
      await tester.pump();
      expect(find.text('Descargando: Productos y precios'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Descargando…'),
      );
      expect(button.onPressed, isNull);
      expect(downloads, 1);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Actualizar descargas'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'un fallo de descarga no anuncia listo por tener caché anterior',
    (tester) async {
      final coordinator = OfflineSyncCoordinator(
        connectionStream: const Stream.empty(),
        isConnectedNow: () => true,
        refreshers: [() async => throw StateError('timeout')],
      );
      await mount(tester, coordinator);
      await coordinator.refreshAll();
      await tester.pumpAndSettle();
      expect(find.text('Datos offline listos'), findsNothing);
      await tester.tap(find.text('Ver detalles'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'No se completó la actualización de: Productos y precios',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'vinculación pendiente explica la causa y abre la pantalla correcta',
    (tester) async {
      var bound = false;
      final coordinator = OfflineSyncCoordinator(
        connectionStream: const Stream.empty(),
        isConnectedNow: () => true,
        refreshers: [],
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: OfflinePreparationBanner()),
          ),
          GoRoute(
            path: AppRoutes.settingsDeviceBinding,
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () {
                  bound = true;
                  context.pop();
                },
                child: const Text('Volver de vinculación'),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            offlineSyncCoordinatorProvider.overrideWith((ref) => coordinator),
            offlineReadinessProvider.overrideWith(
              (ref) async => OfflineReadiness(
                checkedAt: DateTime(2026, 9, 22),
                checks: [
                  const OfflineReadinessCheck(
                    'Productos y precios',
                    true,
                    '16 productos guardados.',
                  ),
                  OfflineReadinessCheck(
                    'Acceso con PIN',
                    bound,
                    bound ? 'Disponible' : 'Vincula este equipo.',
                    action: bound ? null : OfflineReadinessAction.bindDevice,
                  ),
                ],
              ),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ver detalles'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Los datos de ventas y cocina están guardados.'),
        findsOneWidget,
      );
      expect(find.textContaining('Revisa la conexión'), findsNothing);
      await tester.ensureVisible(find.text('Vincular este equipo'));
      await tester.tap(find.text('Vincular este equipo'));
      await tester.pumpAndSettle();
      expect(
        GoRouterState.of(
          tester.element(find.text('Volver de vinculación')),
        ).uri.path,
        AppRoutes.settingsDeviceBinding,
      );
      expect(find.text('Preparación sin internet'), findsNothing);
      await tester.tap(find.text('Volver de vinculación'));
      await tester.pumpAndSettle();
      expect(find.text('Datos offline listos'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('vincular queda deshabilitado sin internet', (tester) async {
    final coordinator = OfflineSyncCoordinator(
      connectionStream: const Stream.empty(),
      isConnectedNow: () => false,
      refreshers: [],
    );
    await mount(
      tester,
      coordinator,
      snapshot: OfflineReadiness(
        checkedAt: DateTime(2026, 9, 22),
        checks: const [
          OfflineReadinessCheck(
            'Acceso con PIN',
            false,
            'Vincula este equipo.',
            action: OfflineReadinessAction.bindDevice,
          ),
        ],
      ),
    );
    await tester.tap(find.text('Ver detalles'));
    await tester.pumpAndSettle();
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Vincular este equipo'),
    );
    expect(button.onPressed, isNull);
    expect(
      find.textContaining('La vinculación necesita internet'),
      findsOneWidget,
    );
  });

  for (final width in [320.0, 1280.0]) {
    testWidgets('panel sin desbordes a ${width.toInt()} px', (tester) async {
      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final coordinator = OfflineSyncCoordinator(
        connectionStream: const Stream.empty(),
        isConnectedNow: () => true,
        refreshers: [],
      );
      await mount(tester, coordinator, complete: false);
      await tester.tap(find.text('Ver detalles'));
      await tester.pumpAndSettle();
      expect(find.text('Preparación sin internet'), findsOneWidget);
      expect(find.text('Actualizar descargas'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
