import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_read_cache.dart';
import 'package:mangopos/core/storage/storage_service.dart';

class _Memory implements StorageService {
  final entries = <String, String>{};
  @override
  Future<String?> read(String key) async => entries[key];
  @override
  Future<bool> write(String key, String value) async {
    entries[key] = value;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'shares reference data, preserving dates and excluding local operations',
    () async {
      final host = _Memory();
      host.entries.addAll({
        'offline_catalog_b':
            '{"saved_at":"2026-01-01T00:00:00Z","products":[]}',
        'offline_zones_snapshot_b': '{"zones":[{"id":"z"}]}',
        'offline_zone_tables_snapshot_z': '{"rows":[{"id":"t"}]}',
        'offline_queue_b': 'pending sale',
        'offline_inventory_snapshot_b_w': 'pending stock delta',
        'mp_offline_roster_b': 'sensitive',
        'offline_catalog_other': '{}',
      });
      final snapshot = await HubReadCache(storage: host).export('b');
      final client = _Memory();
      client.entries['offline_queue_b'] = 'my pending sale';
      await HubReadCache(storage: client).import('b', snapshot);
      expect(
        client.entries['offline_catalog_b'],
        host.entries['offline_catalog_b'],
      );
      expect(
        client.entries['offline_zone_tables_snapshot_z'],
        host.entries['offline_zone_tables_snapshot_z'],
      );
      expect(client.entries['offline_queue_b'], 'my pending sale');
      expect(client.entries.containsKey('offline_catalog_other'), isFalse);
      expect(client.entries.containsKey('mp_offline_roster_b'), isFalse);
      expect(
        client.entries.containsKey('offline_inventory_snapshot_b_w'),
        isFalse,
      );
    },
  );

  test(
    'rejects foreign businesses and unexpected keys before writing',
    () async {
      final storage = _Memory();
      final cache = HubReadCache(storage: storage);
      await expectLater(
        cache.import('b', {'business_id': 'other', 'entries': {}}),
        throwsFormatException,
      );
      await expectLater(
        cache.import('b', {
          'business_id': 'b',
          'entries': {'offline_catalog_b': '{}', 'offline_queue_b': '[]'},
        }),
        throwsFormatException,
      );
      expect(storage.entries, isEmpty);
    },
  );

  test(
    'an older host cache does not replace newer local reference data',
    () async {
      final storage = _Memory();
      final newer = jsonEncode({'saved_at': '2026-09-28T12:00:00Z'});
      storage.entries['offline_catalog_b'] = newer;
      await HubReadCache(storage: storage).import('b', {
        'business_id': 'b',
        'entries': {'offline_catalog_b': '{"saved_at":"2026-09-28T11:00:00Z"}'},
      });
      expect(storage.entries['offline_catalog_b'], newer);
    },
  );
}
