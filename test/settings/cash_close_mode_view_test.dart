import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/presentation/settings/cash_close_mode/cash_close_mode_view.dart';

class _FakePosSettingsRepository extends PosSettingsRepository {
  _FakePosSettingsRepository(this.initial)
    : super(
        SupabaseClient(
          'http://localhost',
          'public-anon-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );

  String initial;
  String? lastSetMode;
  String? lastBusinessId;

  @override
  Future<String> getCashCloseMode(String businessId) async {
    lastBusinessId = businessId;
    return initial;
  }

  @override
  Future<void> setCashCloseMode({
    required String businessId,
    required String mode,
  }) async {
    lastBusinessId = businessId;
    lastSetMode = mode;
    initial = mode;
  }
}

void main() {
  Future<_FakePosSettingsRepository> pumpView(
    WidgetTester tester, {
    String initial = PosSettingsRepository.cashCloseCompact,
  }) async {
    final fake = _FakePosSettingsRepository(initial);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          posSettingsRepositoryProvider.overrideWithValue(fake),
        ],
        child: const MaterialApp(
          home: CashCloseModeView(businessId: 'biz-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return fake;
  }

  testWidgets(
    'renderiza ambas opciones y respeta el modo guardado (compact)',
    (tester) async {
      await pumpView(tester);

      expect(find.text('Modo de cierre de caja'), findsOneWidget);
      expect(find.text('Compacto (1 paso)'), findsOneWidget);
      expect(find.text('Detallado (3 pasos)'), findsOneWidget);

      final radios = tester.widgetList<RadioListTile<String>>(
        find.byType(RadioListTile<String>),
      ).toList();
      expect(radios, hasLength(2));
      expect(
        radios
            .firstWhere(
              (r) => r.value == PosSettingsRepository.cashCloseCompact,
            )
            .groupValue,
        equals(PosSettingsRepository.cashCloseCompact),
      );
    },
  );

  testWidgets('renderiza con modo detailed preseleccionado', (tester) async {
    await pumpView(tester, initial: PosSettingsRepository.cashCloseDetailed);

    final radios = tester
        .widgetList<RadioListTile<String>>(find.byType(RadioListTile<String>))
        .toList();
    final detailed = radios.firstWhere(
      (r) => r.value == PosSettingsRepository.cashCloseDetailed,
    );
    expect(
      detailed.groupValue,
      equals(PosSettingsRepository.cashCloseDetailed),
    );
  });

  testWidgets('seleccionar "Detallado" persiste el cambio', (tester) async {
    final fake = await pumpView(tester);

    await tester.tap(find.text('Detallado (3 pasos)'));
    await tester.pumpAndSettle();

    expect(fake.lastSetMode, equals(PosSettingsRepository.cashCloseDetailed));
    expect(fake.lastBusinessId, equals('biz-1'));
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('Modo de cierre: detallado (3 pasos)'), findsOneWidget);
  });

  testWidgets('volver a "Compacto" persiste el cambio', (tester) async {
    final fake = await pumpView(
      tester,
      initial: PosSettingsRepository.cashCloseDetailed,
    );

    await tester.tap(find.text('Compacto (1 paso)'));
    await tester.pumpAndSettle();

    expect(fake.lastSetMode, equals(PosSettingsRepository.cashCloseCompact));
    expect(find.text('Modo de cierre: compacto (1 paso)'), findsOneWidget);
  });
}
