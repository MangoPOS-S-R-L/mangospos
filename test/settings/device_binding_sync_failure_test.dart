import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/core/auth/offline_auth_service.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/presentation/settings/more settings/system settings/device/view/device_binding_view.dart';

class _Session extends SessionController {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    userId: 'user',
    activeBusinessId: 'biz',
  );
}

class _Auth implements OfflineAuthService {
  bool bound = false;
  int binds = 0;
  int downloads = 0;
  @override
  Future<bool> isDeviceBound() async => bound;
  @override
  Future<String?> currentBoundBusinessId() async => bound ? 'biz' : null;
  @override
  Future<DateTime?> rosterSyncedAt(String id) async => null;
  @override
  Future<List<OfflineRosterUser>> cachedRoster(String id) async => [];
  @override
  Future<void> bindDevice({
    required String businessId,
    required String deviceName,
  }) async {
    binds++;
    bound = true;
  }

  @override
  Future<List<OfflineRosterUser>> syncRoster() async {
    downloads++;
    throw const PostgrestException(
      message: 'function crypt(text, text) does not exist',
      code: '42883',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'fallo inicial conserva vinculación y muestra error rojo sin SQL',
    (tester) async {
      final service = _Auth();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWith(_Session.new)],
          child: MaterialApp(home: DeviceBindingView(service: service)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Vincular dispositivo'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Dispositivo vinculado'), findsOneWidget);
      expect(
        find.textContaining('No necesitas vincularlo de nuevo.'),
        findsOneWidget,
      );
      expect(find.textContaining('PostgrestException'), findsNothing);
      expect(
        find.textContaining('roster sincronizado correctamente'),
        findsNothing,
      );
      final error = find.textContaining('falta una actualización del servidor');
      final container = tester.widget<Container>(
        find.ancestor(of: error, matching: find.byType(Container)).first,
      );
      expect(
        (container.decoration as BoxDecoration).color,
        const Color(0xFFFEE2E2),
      );
      expect(service.binds, 1);
      await tester.ensureVisible(find.text('Sincronizar ahora'));
      await tester.tap(find.text('Sincronizar ahora'));
      await tester.pumpAndSettle();
      expect(
        service.binds,
        1,
        reason: 'reintentar no debe volver a registrar el equipo',
      );
      expect(service.downloads, 2);
      expect(
        find.textContaining('falta una actualización del servidor'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
