import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mangopos/data/repositories/app_release_repository.dart';
import 'package:mangopos/presentation/settings/widgets/app_update_provider.dart';
import 'package:mangopos/presentation/settings/widgets/system_update_dialog.dart';

/// Pedido del dueño (10-oct): «una pestaña junto al sistema y, si hay
/// actualización, que lo diga» (app_releases, 20261010_0025).
void main() {
  const r2021 = AppRelease(
    platform: 'macos',
    version: '2.0.21',
    build: 20021,
    downloadUrl: 'https://mangopos.com/MangoPOS-2.0.21-macOS.dmg',
    notes: 'Cuentas en revisión',
  );

  group('comparar versiones', () {
    test('por partes numéricas, no como texto', () {
      expect(compareVersions('2.0.10', '2.0.9'), greaterThan(0));
      expect(compareVersions('2.0.9', '2.0.10'), lessThan(0));
      expect(compareVersions('2.1', '2.0.21'), greaterThan(0));
      expect(compareVersions('2.0.21+20021', '2.0.21'), 0);
    });

    test('manda el número de build', () {
      expect(
        isNewerRelease(
          latest: r2021,
          installedVersion: '2.0.20',
          installedBuild: '20020',
        ),
        isTrue,
      );
      expect(
        isNewerRelease(
          latest: r2021,
          installedVersion: '2.0.21',
          installedBuild: '20021',
        ),
        isFalse,
      );
      expect(
        isNewerRelease(
          latest: r2021,
          installedVersion: '9.9.9',
          installedBuild: '30000',
        ),
        isFalse,
      );
    });

    test('sin build instalado, compara la versión', () {
      expect(
        isNewerRelease(
          latest: r2021,
          installedVersion: '1.8.3',
          installedBuild: '',
        ),
        isTrue,
      );
    });
  });

  Future<void> pumpDialog(
    WidgetTester tester, {
    required Future<AppUpdateStatus> Function() status,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          installedAppVersionProvider.overrideWith(
            (ref) async => (version: '2.0.20', build: '20020'),
          ),
          appUpdateStatusProvider.overrideWith((ref) => status()),
        ],
        child: const MaterialApp(home: Scaffold(body: SystemUpdateDialog())),
      ),
    );
    await tester.pumpAndSettle();
  }

  AppUpdateStatus statusWith(AppRelease? latest) => AppUpdateStatus(
    platform: 'macos',
    installedVersion: '2.0.20',
    installedBuild: '20020',
    latest: latest,
  );

  testWidgets('hay una versión nueva: lo dice y ofrece descargarla', (t) async {
    await pumpDialog(t, status: () async => statusWith(r2021));
    expect(find.text('Versión instalada: 2.0.20 (20020)'), findsOneWidget);
    expect(find.text('Hay una versión nueva: 2.0.21'), findsOneWidget);
    expect(find.text('Cuentas en revisión'), findsOneWidget);
    expect(find.text('Descargar la versión nueva'), findsOneWidget);
  });

  testWidgets('al día', (t) async {
    await pumpDialog(
      t,
      status: () async => statusWith(
        const AppRelease(platform: 'macos', version: '2.0.20', build: 20020),
      ),
    );
    expect(find.text('Estás al día.'), findsOneWidget);
    expect(find.textContaining('Hay una versión nueva'), findsNothing);
  });

  testWidgets('sin versiones publicadas para la plataforma', (t) async {
    await pumpDialog(t, status: () async => statusWith(null));
    expect(
      find.text('Todavía no hay versiones publicadas para este equipo.'),
      findsOneWidget,
    );
  });

  testWidgets('sin conexión: lo explica, no dice «al día»', (t) async {
    await pumpDialog(t, status: () async => throw Exception('sin red'));
    expect(
      find.text('No se pudo consultar si hay versiones nuevas.'),
      findsOneWidget,
    );
    expect(find.text('Estás al día.'), findsNothing);
  });

  test('el punto del menú se prende solo con una versión más nueva', () async {
    for (final (latest, expected) in [(r2021, true), (null, false)]) {
      final container = ProviderContainer(
        overrides: [
          appUpdateStatusProvider.overrideWith(
            (ref) async => statusWith(latest),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appUpdateStatusProvider.future);
      expect(container.read(appUpdateAvailableProvider), expected);
    }
  });
}
