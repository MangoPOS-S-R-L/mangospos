import 'dart:convert';

import '../../storage/storage_service.dart';

/// Only reference data is copied. Orders, stock deltas, queues, device
/// identities and fiscal counters keep their existing ownership.
class HubReadCache {
  HubReadCache({StorageService? storage}) : _injected = storage;
  final StorageService? _injected;
  Future<StorageService> get _storage async =>
      _injected ?? await StorageService.getInstance();

  static const _prefixes = [
    'offline_catalog_',
    'offline_business_settings_',
    'offline_business_taxes_',
    'offline_item_options_',
    'offline_zones_snapshot_',
    'offline_receipt_business_',
    'offline_cash_reasons_',
  ];

  Set<String> _baseKeys(String businessId) => {
    for (final prefix in _prefixes) '$prefix$businessId',
  };

  Set<String> _tableKeys(String businessId, Map<String, dynamic> entries) {
    final raw = entries['offline_zones_snapshot_$businessId'];
    if (raw is! String) return {};
    final decoded = jsonDecode(raw);
    final zones = decoded is Map ? decoded['zones'] : null;
    if (zones is! List) return {};
    return {
      for (final zone in zones.whereType<Map>())
        if (zone['id'] is String && (zone['id'] as String).isNotEmpty)
          'offline_zone_tables_snapshot_${zone['id']}',
    };
  }

  Future<Map<String, dynamic>> export(String businessId) async {
    if (businessId.isEmpty) throw ArgumentError.value(businessId);
    final storage = await _storage;
    final entries = <String, dynamic>{};
    Future<void> readKeys(Iterable<String> keys) async {
      for (final key in keys) {
        final raw = await storage.read(key);
        if (raw == null) continue;
        try {
          jsonDecode(raw);
          entries[key] = raw;
        } on FormatException {
          // A corrupt entry must not prevent exporting the remaining data.
        }
      }
    }

    await readKeys(_baseKeys(businessId));
    await readKeys(_tableKeys(businessId, entries));
    return {'business_id': businessId, 'entries': entries};
  }

  Future<void> import(String businessId, Map<String, dynamic> snapshot) async {
    if (businessId.isEmpty ||
        snapshot['business_id'] != businessId ||
        snapshot['entries'] is! Map) {
      throw const FormatException('Invalid business snapshot');
    }
    final entries = Map<String, dynamic>.from(snapshot['entries'] as Map);
    final allowed = {
      ..._baseKeys(businessId),
      ..._tableKeys(businessId, entries),
    };
    // Validate all keys before writing. The Hub cannot supply arbitrary keys.
    for (final entry in entries.entries) {
      if (!allowed.contains(entry.key) || entry.value is! String) {
        throw const FormatException('Unexpected cache entry');
      }
      jsonDecode(entry.value as String);
    }
    final storage = await _storage;
    for (final entry in entries.entries) {
      final incoming = entry.value as String;
      final previous = await storage.read(entry.key);
      if (incoming == previous) continue;
      DateTime? savedAt(String? raw) {
        if (raw == null) return null;
        try {
          final data = jsonDecode(raw);
          return data is Map ? DateTime.tryParse('${data['saved_at']}') : null;
        } catch (_) {
          return null;
        }
      }

      final oldTime = savedAt(previous);
      final newTime = savedAt(incoming);
      if (oldTime != null && (newTime == null || oldTime.isAfter(newTime))) {
        continue;
      }
      if (!await storage.write(entry.key, incoming)) {
        throw StateError('No se pudo guardar la copia de intranet.');
      }
    }
  }
}
