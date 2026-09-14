import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// El registro de "este equipo cedió el Hub" (H7).
///
/// Lo escribe el uplink cuando descubre que otro equipo fue promovido; lo lee
/// Ajustes → Red local para explicar por qué el equipo dejó de ser el Hub. Sin
/// él, el dueño vería que su Hub "se convirtió solo" en respaldo sin saber por
/// qué.
///
/// Cada test usa su propio negocio: StorageService cachea su instancia de
/// SharedPreferences, así que `setMockInitialValues` no aísla entre tests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final config = HubConfigService();

  test('sin registro devuelve null', () async {
    expect(await config.readLeaseLost('biz-sin-registro'), isNull);
  });

  test('guarda quién tiene la lease, la época y lo que quedó', () async {
    await config.writeLeaseLost(
      'biz-rt',
      holderDeviceId: 'equipo-B',
      epoch: 4,
      pendingOps: 12,
    );

    final r = await config.readLeaseLost('biz-rt');
    expect(r, isNotNull);
    expect(r!['holder_device_id'], 'equipo-B');
    expect(r['epoch'], 4);
    expect(r['pending_ops'], 12);
    expect(DateTime.tryParse(r['at'] as String), isNotNull);
  });

  test('clear lo borra', () async {
    await config.writeLeaseLost('biz-clear', pendingOps: 1);
    await config.clearLeaseLost('biz-clear');
    expect(await config.readLeaseLost('biz-clear'), isNull);
  });

  test('los negocios no se mezclan', () async {
    await config.writeLeaseLost('biz-a', holderDeviceId: 'X', pendingOps: 3);
    await config.writeLeaseLost('biz-b', holderDeviceId: 'Y', pendingOps: 7);

    expect((await config.readLeaseLost('biz-a'))!['holder_device_id'], 'X');
    expect((await config.readLeaseLost('biz-b'))!['holder_device_id'], 'Y');
  });

  test('un registro corrupto devuelve null en vez de tumbar Ajustes', () async {
    final storage = await StorageService.getInstance();
    await storage.write('hub_lease_lost_biz-malo', '{esto no es json');
    expect(await config.readLeaseLost('biz-malo'), isNull);
  });

  test('negocio vacío no escribe ni lee', () async {
    await config.writeLeaseLost('', pendingOps: 1);
    expect(await config.readLeaseLost(''), isNull);
  });
}
