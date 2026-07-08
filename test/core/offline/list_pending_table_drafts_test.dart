import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// §11.1 (Hub híbrido / anti-pérdida): `listPendingTableDrafts` devuelve las
/// mesas con borrador LOCAL sin sincronizar (orden `local-order-…`) para que el
/// grid del salón las overlaye y NO desaparezcan al recargar desde el server.
/// - Solo origen 'table'.
/// - Solo mientras la orden siga siendo local (tras el remap a uuid real, ya
///   no es "pendiente").
/// - Aisladas por negocio.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mock del canal de flutter_secure_storage (clave del SecureBlobCipher que
  // cifra los snapshots).
  const channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureStore = <String, String>{};
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      switch (call.method) {
        case 'write':
          secureStore[args['key'] as String] = args['value'] as String;
          return null;
        case 'read':
          return secureStore[args['key'] as String];
        case 'delete':
          secureStore.remove(args['key']);
          return null;
        case 'containsKey':
          return secureStore.containsKey(args['key']);
        case 'readAll':
          return Map<String, String>.from(secureStore);
        case 'deleteAll':
          secureStore.clear();
          return null;
      }
      return null;
    });
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final svc = OfflinePosService();

  // NOTA: OfflinePosService + StorageService son singletons y los snapshots se
  // acumulan durante la corrida; usamos un businessId único por test (todo
  // está namespaced por negocio) para aislar sin depender de un reset global.

  test('vacío cuando no hay borradores', () async {
    expect(await svc.listPendingTableDrafts('biz-empty'), isEmpty);
  });

  test('devuelve la mesa con borrador local sin sincronizar', () async {
    await svc.createLocalDraft(
      businessId: 'biz-a',
      origin: 'table',
      tableId: 'table-A',
    );
    final drafts = await svc.listPendingTableDrafts('biz-a');
    expect(drafts.length, 1);
    expect(drafts.first.tableId, 'table-A');
  });

  test('excluye orígenes que no son mesa (venta rápida)', () async {
    await svc.createLocalDraft(
      businessId: 'biz-quick',
      origin: 'quick',
    );
    expect(await svc.listPendingTableDrafts('biz-quick'), isEmpty);
  });

  test('los negocios no se mezclan', () async {
    await svc.createLocalDraft(
      businessId: 'biz-iso-1',
      origin: 'table',
      tableId: 'table-A',
    );
    expect(await svc.listPendingTableDrafts('biz-iso-2'), isEmpty);
    expect((await svc.listPendingTableDrafts('biz-iso-1')).length, 1);
  });

  test('excluye la mesa ya sincronizada (remap a uuid real)', () async {
    final draft = await svc.createLocalDraft(
      businessId: 'biz-remap',
      origin: 'table',
      tableId: 'table-A',
    );
    final localId = draft.order!.id;
    // Simula el sync: el id local pasa a un uuid real y local_only=false.
    await svc.remapSnapshotOrderId(
      businessId: 'biz-remap',
      localOrderId: localId,
      remoteOrderId: 'real-uuid-123',
    );
    expect(await svc.listPendingTableDrafts('biz-remap'), isEmpty);
  });
}
