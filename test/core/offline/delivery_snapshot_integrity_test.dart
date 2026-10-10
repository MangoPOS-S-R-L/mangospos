import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  final service = OfflinePosService();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? const {};
            if (call.method == 'write') {
              secureStore[args['key'] as String] = args['value'] as String;
            }
            if (call.method == 'read') return secureStore[args['key']];
            if (call.method == 'containsKey') {
              return secureStore.containsKey(args['key']);
            }
            return null;
          },
        );
  });

  test(
    'delivery snapshot preserves address and channel after restore',
    () async {
      const state = CurrentOrderState(
        origin: 'delivery',
        deliveryType: 'pedidos_ya',
        deliveryAddress: 'Av. México 25, 2.º piso\nFrente al café',
        sessionNote: 'Llamar al llegar',
      );
      await service.saveSnapshot(
        businessId: 'delivery-snapshot',
        slotId: 'delivery-table',
        origin: 'delivery',
        tableId: 'delivery-table',
        state: state,
      );
      final restored = await service.loadSnapshot(
        businessId: 'delivery-snapshot',
        slotId: 'delivery-table',
      );
      expect(restored?.origin, state.origin);
      expect(restored?.deliveryType, state.deliveryType);
      expect(restored?.deliveryAddress, state.deliveryAddress);
      expect(restored?.sessionNote, state.sessionNote);
    },
  );

  test('legacy snapshot without delivery fields remains readable', () async {
    final storage = await StorageService.getInstance();
    await storage.writeJson('offline_snapshot_delivery-legacy_delivery-table', {
      'slot_id': 'delivery-table',
      'business_id': 'delivery-legacy',
      'origin': 'delivery',
      'table_id': 'delivery-table',
      'state': {
        'origin': 'delivery',
        'customer_name': 'María',
        'session_note': 'Sin cebolla',
        'items': [],
        'checks': [],
      },
    });
    final restored = await service.loadSnapshot(
      businessId: 'delivery-legacy',
      slotId: 'delivery-table',
    );
    expect(restored, isNotNull);
    expect(restored?.origin, 'delivery');
    expect(restored?.customerName, 'María');
    expect(restored?.sessionNote, 'Sin cebolla');
    expect(restored?.deliveryType, isNull);
    expect(restored?.deliveryAddress, isNull);
  });
}
