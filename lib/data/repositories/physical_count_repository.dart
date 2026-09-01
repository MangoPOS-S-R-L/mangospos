// Repositorio del módulo de conteo físico (inventory).
// Llama RPCs `fn_physical_count_*` y lee desde
// `v_physical_count_sessions_summary` + `v_physical_count_lines_detail`.

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

double? _parseDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

class PhysicalCountSummary {
  final String id;
  final String code;
  final PhysicalCountStatus status;

  /// Conteo a ciegas: la UI oculta el stock del sistema mientras se cuenta.
  final bool isBlind;

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

  /// Líneas marcadas para 2ª vuelta y todavía sin re-contar.
  final int pendingRecount;

  /// Impacto neto en costo de los ajustes aplicados (solo tras completar).
  final double varianceValueTotal;

  /// Suma de los ajustes negativos: la merma del período.
  final double shrinkageValue;

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
    this.isBlind = false,
    this.pendingRecount = 0,
    this.varianceValueTotal = 0,
    this.shrinkageValue = 0,
    this.notes,
    this.cancellationReason,
    this.frozenAt,
    this.completedAt,
    this.cancelledAt,
  });

  /// Contadores recalculados en memoria tras guardar una línea. Evita
  /// recargar la sesión completa sólo para refrescar el encabezado.
  PhysicalCountSummary withCounters({
    required int countedLines,
    required int pendingRecount,
  }) {
    return PhysicalCountSummary(
      id: id,
      code: code,
      status: status,
      isBlind: isBlind,
      warehouseId: warehouseId,
      warehouseName: warehouseName,
      notes: notes,
      cancellationReason: cancellationReason,
      startedAt: startedAt,
      frozenAt: frozenAt,
      completedAt: completedAt,
      cancelledAt: cancelledAt,
      linesCount: linesCount,
      countedLines: countedLines,
      adjustmentsCount: adjustmentsCount,
      pendingRecount: pendingRecount,
      varianceValueTotal: varianceValueTotal,
      shrinkageValue: shrinkageValue,
    );
  }

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
      isBlind: map['is_blind'] == true,
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
      pendingRecount: parseInt(map['pending_recount']),
      varianceValueTotal: _parseDouble(map['variance_value_total']) ?? 0,
      shrinkageValue: _parseDouble(map['shrinkage_value']) ?? 0,
    );
  }
}

class PhysicalCountLine {
  final String id;
  final String itemId;
  final String itemName;
  final String? itemSku;
  final String unit;

  /// Stock del sistema al congelar la sesión.
  final double snapshotQuantity;

  /// Lo que se contó físicamente. Null = pendiente.
  final double? countedQuantity;

  /// Valor de la 1ª vuelta, cuando la línea se recontó.
  final double? firstCountQuantity;

  /// Marcada para 2ª vuelta.
  final bool recountRequested;
  final DateTime? recountedAt;

  /// Stock vivo en el momento de completar — base real del ajuste.
  final double? stockAtComplete;

  /// Delta efectivamente aplicado al inventario.
  final double? appliedVariance;

  /// Costo congelado al completar.
  final double? unitCost;

  /// Impacto en costo del ajuste aplicado.
  final double? varianceValue;

  /// Costo actual del insumo — permite valuar en pantalla antes de cerrar.
  final double unitCostCurrent;

  final String? counterNotes;
  final String? appliedAdjustmentId;

  const PhysicalCountLine({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.snapshotQuantity,
    this.itemSku,
    this.countedQuantity,
    this.firstCountQuantity,
    this.recountRequested = false,
    this.recountedAt,
    this.stockAtComplete,
    this.appliedVariance,
    this.unitCost,
    this.varianceValue,
    this.unitCostCurrent = 0,
    this.counterNotes,
    this.appliedAdjustmentId,
  });

  /// Copia con el conteo recién guardado, para actualizar la pantalla SIN
  /// volver a bajar la sesión entera. En un conteo de mil líneas, recargar
  /// tras cada número tecleado hace parpadear la pantalla, pierde el foco y
  /// tarda más en cada renglón.
  PhysicalCountLine withCount(double value, {required bool wasRecount}) {
    return PhysicalCountLine(
      id: id,
      itemId: itemId,
      itemName: itemName,
      unit: unit,
      snapshotQuantity: snapshotQuantity,
      itemSku: itemSku,
      countedQuantity: value,
      // La 1ª vuelta se preserva cuando la línea venía marcada para recuento
      // — mismo criterio que aplica el RPC del servidor.
      firstCountQuantity: wasRecount ? countedQuantity : firstCountQuantity,
      recountRequested: false,
      recountedAt: wasRecount ? DateTime.now() : recountedAt,
      stockAtComplete: stockAtComplete,
      appliedVariance: appliedVariance,
      unitCost: unitCost,
      varianceValue: varianceValue,
      unitCostCurrent: unitCostCurrent,
      counterNotes: counterNotes,
      appliedAdjustmentId: appliedAdjustmentId,
    );
  }

  /// Diferencia contra el snapshot congelado. Es la que se muestra mientras
  /// la sesión está en conteo, cuando todavía no existe `appliedVariance`.
  double? get variance =>
      countedQuantity == null ? null : countedQuantity! - snapshotQuantity;

  /// La diferencia relevante según el estado: tras completar, el delta que
  /// realmente se aplicó; antes, la diferencia contra el snapshot.
  double? get displayVariance => appliedVariance ?? variance;

  /// Valor en costo de la diferencia. Tras completar usa el costo congelado;
  /// antes, el costo actual del insumo.
  double? get displayVarianceValue {
    if (varianceValue != null) return varianceValue;
    final v = variance;
    if (v == null) return null;
    return v * unitCostCurrent;
  }

  /// El snapshot y el stock al cerrar difieren cuando hubo movimientos
  /// (ventas, transferencias) durante el conteo.
  bool get movedDuringCount {
    final s = stockAtComplete;
    if (s == null) return false;
    return (s - snapshotQuantity).abs() >= 0.0001;
  }

  bool get wasRecounted => firstCountQuantity != null;

  factory PhysicalCountLine.fromMap(Map<String, dynamic> map) {
    return PhysicalCountLine(
      id: map['id']?.toString() ?? '',
      itemId: map['item_id']?.toString() ?? '',
      itemName: map['item_name']?.toString() ?? '',
      itemSku: map['item_sku']?.toString(),
      unit: map['unit']?.toString() ?? 'unidad',
      snapshotQuantity: _parseDouble(map['snapshot_quantity']) ?? 0,
      countedQuantity: _parseDouble(map['counted_quantity']),
      firstCountQuantity: _parseDouble(map['first_count_quantity']),
      recountRequested: map['recount_requested'] == true,
      recountedAt: map['recounted_at'] == null
          ? null
          : DateTime.tryParse(map['recounted_at'].toString()),
      stockAtComplete: _parseDouble(map['stock_at_complete']),
      appliedVariance: _parseDouble(map['applied_variance']),
      unitCost: _parseDouble(map['unit_cost']),
      varianceValue: _parseDouble(map['variance_value']),
      unitCostCurrent: _parseDouble(map['unit_cost_current']) ?? 0,
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
        .from('v_physical_count_lines_detail')
        .select()
        .eq('session_id', sessionId)
        .order('item_name');

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
    bool isBlind = false,
  }) async {
    final response = await _client.rpc(
      'fn_physical_count_create',
      params: {
        'p_business_id': businessId,
        'p_warehouse_id': warehouseId,
        'p_notes': notes,
        'p_is_blind': isBlind,
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

  /// Marca líneas para una 2ª vuelta antes de aplicar ajustes.
  Future<int> requestRecount({
    required String sessionId,
    required List<String> itemIds,
  }) async {
    if (itemIds.isEmpty) return 0;
    final response = await _client.rpc(
      'fn_physical_count_request_recount',
      params: {
        'p_session_id': sessionId,
        'p_item_ids': itemIds,
      },
    );
    final map = Map<String, dynamic>.from(response as Map);
    final flagged = map['flagged'];
    if (flagged is num) return flagged.toInt();
    return int.tryParse(flagged?.toString() ?? '') ?? 0;
  }

  /// Pone en CERO las líneas que quedaron sin contar. Devuelve cuántas.
  ///
  /// Es el paso que convierte un conteo en un REEMPLAZO del inventario: lo
  /// que nadie encontró físicamente deja de existir. Sin esto, cada línea en
  /// blanco conserva su existencia vieja.
  Future<int> zeroPending(String sessionId) async {
    final response = await _client.rpc(
      'fn_physical_count_zero_pending',
      params: {'p_session_id': sessionId},
    );
    if (response is int) return response;
    return int.tryParse(response?.toString() ?? '') ?? 0;
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
