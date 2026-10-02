import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mangopos/core/offline/pending_kitchen_prints.dart';
import 'package:mangopos/core/storage/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('keeps each missing area until that area is accepted', () async {
    const businessId = 'pending-print-areas';
    final ledger = PendingKitchenPrints.instance;
    await ledger.record(
      businessId: businessId,
      roundId: 'round-1',
      orderId: 'order-1',
      tableName: 'Mesa 1',
      itemIdsByArea: {
        'bar': ['item-a'],
        'cocina': ['item-a', 'item-b'],
      },
    );
    await ledger.resolveAreas(
      businessId: businessId,
      roundId: 'round-1',
      acceptedAreas: {'bar'},
    );
    final remaining = await ledger.list(businessId);
    expect(remaining, hasLength(1));
    expect(remaining.single.areaCode, 'cocina');
    expect(remaining.single.itemIds, ['item-a', 'item-b']);
    expect(remaining.single.tableName, 'Mesa 1');
  });

  test('concurrent rounds do not overwrite one another', () async {
    const businessId = 'pending-print-concurrent';
    final ledger = PendingKitchenPrints.instance;
    await Future.wait([
      ledger.record(
        businessId: businessId,
        roundId: 'round-a',
        orderId: 'order-1',
        tableName: 'Mesa 1',
        itemIdsByArea: {
          'bar': ['item-a'],
        },
      ),
      ledger.record(
        businessId: businessId,
        roundId: 'round-b',
        orderId: 'order-1',
        tableName: 'Mesa 1',
        itemIdsByArea: {
          'bar': ['item-b'],
        },
      ),
    ]);
    expect((await ledger.list(businessId)).map((entry) => entry.id), [
      'round-a:bar',
      'round-b:bar',
    ]);
    await ledger.dismiss(businessId: businessId, id: 'round-a:bar');
    expect((await ledger.list(businessId)).single.id, 'round-b:bar');
  });

  test('corrupt ledger is not overwritten by a new record', () async {
    const businessId = 'pending-print-corrupt';
    final storage = await StorageService.getInstance();
    await storage.write('pending_kitchen_prints_$businessId', 'not-json');
    await expectLater(
      PendingKitchenPrints.instance.record(
        businessId: businessId,
        roundId: 'round-1',
        orderId: 'order-1',
        tableName: 'Mesa 1',
        itemIdsByArea: {
          'bar': ['item-a'],
        },
      ),
      throwsFormatException,
    );
    expect(
      await storage.read('pending_kitchen_prints_$businessId'),
      'not-json',
    );
  });
}
