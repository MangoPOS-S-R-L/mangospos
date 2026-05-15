// Repositorio del módulo de conteo físico (inventory).
// Llama RPCs `fn_physical_count_*` y lee desde
// `v_physical_count_sessions_summary` + `physical_count_lines`.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// =============================================================================
// MODELOS
// =============================================================================

enum PhysicalCountStatus { draft, inProgress, completed, cancelled }

extension PhysicalCountStatusX on PhysicalCountStatus {
  String get wire {
    switch (this) {
      case PhysicalCountStatus.draft:
        return 'draft';
      case PhysicalCountStatus.inProgress:
        return 'in_progress';
      case PhysicalCountStatus.completed:
        return 'completed';
      case PhysicalCountStatus.cancelled:
        return 'cancelled';
    }
  }

  String get label {
    switch (this) {
      case PhysicalCountStatus.draft:
        return 'Borrador';
      case PhysicalCountStatus.inProgress:
        return 'En conteo';
      case PhysicalCountStatus.completed:
        return 'Completado';
      case PhysicalCountStatus.cancelled:
        return 'Cancelado';
    }
  }

  static PhysicalCountStatus fromWire(String? value) {
    switch (value) {
      case 'in_progress':
        return PhysicalCountStatus.inProgress;
      case 'completed':
        return PhysicalCountStatus.completed;
      case 'cancelled':
        return PhysicalCountStatus.cancelled;
      case 'draft':
      default:
        return PhysicalCountStatus.draft;
    }
  }
}

class PhysicalCountSummary {
  final String id;
  final String code;
  final PhysicalCountStatus status;
  final String warehouseId;
  final String warehouseName;
  final String? notes;
  final String? cancellationReason;
  final DateTime startedAt;
  final DateTime? frozenAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final int linesCount;
  final int countedLines;
  final int adjustmentsCount;

  const PhysicalCountSummary({
    required this.id,
    required this.code,
    required this.status,
    required this.warehouseId,
    required this.warehouseName,
    required this.startedAt,
    required this.linesCount,
    required this.countedLines,
    required this.adjustmentsCount,
    this.notes,
    this.cancellationReason,
    this.frozenAt,
    this.completedAt,
    this.cancelledAt,
  });

  factory PhysicalCountSummary.fromMap(Map<String, dynamic> map) {
    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      return DateTime.tryParse(v.toString());
    }

    int parseInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v?.toString() ?? '') ?? 0;
    }

    return PhysicalCountSummary(
      id: map['id']?.toString() ?? '',
      code: map['code']?.toString() ?? '',
      status: PhysicalCountStatusX.fromWire(map['status']?.toString()),
      warehouseId: map['warehouse_id']?.toString() ?? '',
      warehouseName: map['warehouse_name']?.toString() ?? '',
      notes: map['notes']?.toString(),
      cancellationReason: map['cancellation_reason']?.toString(),
      startedAt: parseDate(map['started_at']) ?? DateTime.now(),
      frozenAt: parseDate(map['frozen_at']),
      completedAt: parseDate(map['completed_at']),
      cancelledAt: parseDate(map['cancelled_at']),
      linesCount: parseInt(map['lines_count']),
      countedLines: parseInt(map['counted_lines']),
      adjustmentsCount: parseInt(map['adjustments_count']),
    );
  }
}

class PhysicalCountLine {
  final String id;
  final String itemId;
  final String itemName;
  final String unit;
  final double snapshotQuantity;
  final double? countedQuantity;
  final String? counterNotes;
  final String? appliedAdjustmentId;

  const PhysicalCountLine({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.snapshotQuantity,
    this.countedQuantity,
    this.counterNotes,
    this.appliedAdjustmentId,
  });

  double? get variance =>
      countedQuantity == null ? null : countedQuantity! - snapshotQuantity;

  factory PhysicalCountLine.fromMap(Map<String, dynamic> map) {
    double? parseDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    final item = map['inventory_items'];
    final itemMap = item is Map<String, dynamic>
        ? item
        : (item is Map ? Map<String, dynamic>.from(item) : null);

    return PhysicalCountLine(
      id: map['id']?.toString() ?? '',
      itemId: map['item_id']?.toString() ?? '',
      itemName: itemMap?['name']?.toString() ?? '',
      unit: itemMap?['unit']?.toString() ?? 'unidad',
      snapshotQuantity: parseDouble(map['snapshot_quantity']) ?? 0,
      countedQuantity: parseDouble(map['counted_quantity']),
      counterNotes: map['counter_notes']?.toString(),
      appliedAdjustmentId: map['applied_adjustment_id']?.toString(),
    );
  }
}

class PhysicalCountDetail {
  final PhysicalCountSummary header;
  final List<PhysicalCountLine> lines;
  const PhysicalCountDetail({required this.header, required this.lines});
}

// =============================================================================
// REPO
// =============================================================================

class PhysicalCountRepository {
  PhysicalCountRepository(this._client);
  final SupabaseClient _client;

  Future<List<PhysicalCountSummary>> listByBusiness({
    required String businessId,
    Set<PhysicalCountStatus>? statusFilter,
    int limit = 200,
  }) async {
    var query = _client
        .from('v_physical_count_sessions_summary')
        .select()
        .eq('business_id', businessId);

    if (statusFilter != null && statusFilter.isNotEmpty) {
      final wires = statusFilter.map((s) => s.wire).toList(growable: false);
      query = query.inFilter('status', wires);
    }

    final response = await query
        .order('started_at', ascending: false)
        .limit(limit);

    return (response as List)
        .whereType<Map>()
        .map((row) => PhysicalCountSummary.fromMap(Map<String, dynamic>.from(row)))
        .toList(growable: false);
  }

  Future<PhysicalCountDetail> getDetail(String sessionId) async {
    final header = await _client
        .from('v_physical_count_sessions_summary')
        .select()
        .eq('id', sessionId)
        .single();

    final lineRows = await _client
        .from('physical_count_lines')
        .select(
          'id, item_id, snapshot_quantity, counted_quantity, '
          'counter_notes, applied_adjustment_id, '
          'inventory_items(name, unit)',
        )
        .eq('session_id', sessionId)
        .order('id');

    return PhysicalCountDetail(
      header: PhysicalCountSummary.fromMap(Map<String, dynamic>.from(header)),
      lines: (lineRows as List)
          .whereType<Map>()
          .map((row) => PhysicalCountLine.fromMap(Map<String, dynamic>.from(row)))
          .toList(growable: false),
    );
  }

  Future<Map<String, dynamic>> create({
    required String businessId,
    required String warehouseId,
    String? notes,
  }) async {
    final response = await _client.rpc(
      'fn_physical_count_create',
      params: {
        'p_business_id': businessId,
        'p_warehouse_id': warehouseId,
        'p_notes': notes,
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<Map<String, dynamic>> freeze(String sessionId) async {
    final response = await _client.rpc(
      'fn_physical_count_freeze',
      params: {'p_session_id': sessionId},
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<void> setCount({
    required String sessionId,
    required String itemId,
    required double countedQuantity,
    String? notes,
  }) async {
    await _client.rpc(
      'fn_physical_count_set_count',
      params: {
        'p_session_id': sessionId,
        'p_item_id': itemId,
        'p_counted_quantity': countedQuantity,
        'p_notes': notes,
      },
    );
  }

  Future<Map<String, dynamic>> complete(String sessionId) async {
    final response = await _client.rpc(
      'fn_physical_count_complete',
      params: {'p_session_id': sessionId},
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<void> cancel({required String sessionId, String? reason}) async {
    await _client.rpc(
      'fn_physical_count_cancel',
      params: {'p_session_id': sessionId, 'p_reason': reason},
    );
  }
}

final physicalCountRepositoryProvider = Provider<PhysicalCountRepository>(
  (ref) => PhysicalCountRepository(Supabase.instance.client),
);
