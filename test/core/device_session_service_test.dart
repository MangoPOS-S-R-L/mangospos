import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/auth/device_session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// La session_key distingue "login nuevo en este equipo" de "la misma sesión
/// que sigue viva" (migración 20260918_0001). Si se regenera de más, un
/// cierre remoto pendiente se pierde; si no se regenera al cambiar de
/// cuenta, dos personas quedan como una sola sesión.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('sessionKey', () {
    test('se crea una vez y se reusa (sobrevive reinicios)', () async {
      final a = await DeviceSessionService.sessionKey('u1');
      final b = await DeviceSessionService.sessionKey('u1');
      expect(a, isNotEmpty);
      expect(b, a);
    });

    test('otra cuenta en el mismo equipo = otra key', () async {
      final a = await DeviceSessionService.sessionKey('u1');
      final b = await DeviceSessionService.sessionKey('u2');
      expect(b, isNot(a));
      // Y la guardada pasa a ser la de u2.
      expect(await DeviceSessionService.sessionKey('u2'), b);
    });

    test('rotate genera una distinta para el mismo usuario', () async {
      final a = await DeviceSessionService.sessionKey('u1');
      final b = await DeviceSessionService.rotateSessionKey('u1');
      expect(b, isNot(a));
      expect(await DeviceSessionService.sessionKey('u1'), b);
    });

    test('tras clear, el próximo login trae key nueva', () async {
      final a = await DeviceSessionService.sessionKey('u1');
      await DeviceSessionService.clearSessionKey();
      final b = await DeviceSessionService.sessionKey('u1');
      expect(b, isNot(a));
    });
  });

  group('parseStoredKey', () {
    test('formato userId|key', () {
      final p = DeviceSessionService.parseStoredKey('u1|abc');
      expect(p?.userId, 'u1');
      expect(p?.key, 'abc');
    });

    test('valores corruptos se ignoran', () {
      for (final bad in [null, '', 'sinseparador', '|abc', 'u1|']) {
        expect(DeviceSessionService.parseStoredKey(bad), isNull, reason: bad);
      }
    });
  });

  test('reportSignedOut sin negocio: no lanza y borra la key igual', () async {
    final before = await DeviceSessionService.sessionKey('u1');
    await DeviceSessionService.reportSignedOut(null);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('device_session_key'), isNull);
    expect(await DeviceSessionService.sessionKey('u1'), isNot(before));
  });

  test('el aviso de cierre remoto se consume una sola vez', () {
    expect(DeviceSessionService.consumeRevokedNotice(), isFalse);
    DeviceSessionService.markRevokedNotice();
    expect(DeviceSessionService.consumeRevokedNotice(), isTrue);
    expect(DeviceSessionService.consumeRevokedNotice(), isFalse);
  });
}
