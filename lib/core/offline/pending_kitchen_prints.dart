import 'dart:convert';

import '../storage/storage_service.dart';

class PendingKitchenPrint {
  const PendingKitchenPrint({
    required this.id,
    required this.roundId,
    required this.orderId,
    required this.areaCode,
    required this.itemIds,
    required this.tableName,
    required this.queuedAt,
  });

  final String id;
  final String roundId;
  final String orderId;
  final String areaCode;
  final List<String> itemIds;
  final String tableName;
  final DateTime queuedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'round_id': roundId,
    'order_id': orderId,
    'area_code': areaCode,
    'item_ids': itemIds,
    'table_name': tableName,
    'queued_at': queuedAt.toIso8601String(),
  };

  factory PendingKitchenPrint.fromJson(Map<String, dynamic> json) =>
      PendingKitchenPrint(
        id: json['id'] as String,
        roundId: json['round_id'] as String,
        orderId: json['order_id'] as String,
        areaCode: json['area_code'] as String,
        itemIds: (json['item_ids'] as List).map((id) => id.toString()).toList(),
        tableName: json['table_name']?.toString() ?? 'Mesa',
        queuedAt: DateTime.parse(json['queued_at'] as String),
      );
}

class PendingKitchenPrints {
  PendingKitchenPrints._();

  static final PendingKitchenPrints instance = PendingKitchenPrints._();
  final Map<String, Future<void>> _mutations = {};

  String _key(String businessId) => 'pending_kitchen_prints_$businessId';

  Future<List<PendingKitchenPrint>> list(String businessId) async {
    await _mutations[businessId];
    return _read(businessId);
  }

  Future<void> record({
    required String businessId,
    required String roundId,
    required String orderId,
    required String tableName,
    required Map<String, List<String>> itemIdsByArea,
  }) => _mutate(businessId, (entries) {
    final existing = entries.map((entry) => entry.id).toSet();
    for (final area in itemIdsByArea.entries) {
      final id = '$roundId:${area.key}';
      if (existing.contains(id)) continue;
      entries.add(
        PendingKitchenPrint(
          id: id,
          roundId: roundId,
          orderId: orderId,
          areaCode: area.key,
          itemIds: List<String>.unmodifiable(area.value),
          tableName: tableName,
          queuedAt: DateTime.now(),
        ),
      );
    }
  });

  Future<void> resolveAreas({
    required String businessId,
    required String roundId,
    required Set<String> acceptedAreas,
  }) async {
    if (acceptedAreas.isEmpty) return;
    await _mutate(businessId, (entries) {
      entries.removeWhere(
        (entry) =>
            entry.roundId == roundId && acceptedAreas.contains(entry.areaCode),
      );
    });
  }

  Future<void> dismiss({required String businessId, required String id}) =>
      _mutate(businessId, (entries) {
        entries.removeWhere((entry) => entry.id == id);
      });

  Future<List<PendingKitchenPrint>> _read(String businessId) async {
    final storage = await StorageService.getInstance();
    final raw = await storage.read(_key(businessId));
    if (raw == null) return <PendingKitchenPrint>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Registro de comandas pendientes inválido');
    }
    return decoded
        .map(
          (entry) => PendingKitchenPrint.fromJson(
            Map<String, dynamic>.from(entry as Map),
          ),
        )
        .toList();
  }

  Future<void> _mutate(
    String businessId,
    void Function(List<PendingKitchenPrint>) change,
  ) async {
    final previous = _mutations[businessId] ?? Future<void>.value();
    final run = previous.then((_) async {
      final entries = await _read(businessId);
      change(entries);
      final storage = await StorageService.getInstance();
      final saved = await storage.writeList(
        _key(businessId),
        entries.map((entry) => entry.toJson()).toList(),
      );
      if (!saved) throw StateError('No se guardó la comanda pendiente');
    });
    final settled = run.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _mutations[businessId] = settled;
    try {
      await run;
    } finally {
      if (identical(_mutations[businessId], settled)) {
        _mutations.remove(businessId);
      }
    }
  }
}
