// Verificación de activos fijos: el levantamiento físico por ubicación
// (20261001_0050).
//
// Se abre una verificación de una bodega (o de todas), el sistema arma la
// lista de lo que DEBERÍA estar ahí, y se va escaneando la etiqueta de cada
// cosa: «está», «no está», «hay 38 de 40», «está pero dañado». Lo que
// aparece y no estaba en la lista queda «fuera de lugar»; lo que no tiene
// etiqueta se registra en el momento («nuevo»). Al cerrar, solo se decide lo
// que no cuadra.
//
// Acá viven los modelos y las reglas como funciones puras (agrupar líneas,
// progreso, qué hay que decidir al cerrar y el payload de esas decisiones):
// la pantalla solo los pinta.

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import 'fixed_assets_state.dart';

/// Etiqueta de la verificación que abarca todo el negocio.
const kAllLocationsLabel = 'Todas las ubicaciones';

int? _int(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.round();
  return int.tryParse(v.toString().trim()) ??
      double.tryParse(v.toString().trim())?.round();
}

double? _double(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

String? _text(dynamic v) {
  final s = v?.toString().trim();
  return (s == null || s.isEmpty) ? null : s;
}

DateTime? _date(dynamic v) {
  final s = v?.toString();
  if (s == null || s.isEmpty) return null;
  return DateTime.tryParse(s);
}

bool _bool(dynamic v) => v == true || v?.toString() == 'true';

FixedAssetStatus? _status(dynamic v) {
  final s = _text(v);
  return s == null ? null : FixedAssetStatus.fromWire(s);
}

enum FixedAssetVerificationStatus {
  open('open', 'Abierta'),
  closed('closed', 'Cerrada'),
  cancelled('cancelled', 'Cancelada');

  const FixedAssetVerificationStatus(this.wire, this.label);

  final String wire;
  final String label;

  static FixedAssetVerificationStatus fromWire(String? raw) {
    for (final s in values) {
      if (s.wire == raw) return s;
    }
    return FixedAssetVerificationStatus.open;
  }

  Color get color {
    switch (this) {
      case FixedAssetVerificationStatus.open:
        return AppColors.info;
      case FixedAssetVerificationStatus.closed:
        return AppColors.success;
      case FixedAssetVerificationStatus.cancelled:
        return AppColors.mutedForeground;
    }
  }
}

/// Cómo terminó cada línea al cerrar (`resolution`).
String fixedAssetResolutionLabel(String? resolution) {
  switch (resolution) {
    case 'ok':
      return 'En orden';
    case 'pending':
      return 'Pendiente de búsqueda';
    case 'lost':
      return 'Perdido';
    case 'quantity_set':
      return 'Cantidad ajustada';
    case 'moved':
      return 'Trasladado';
    case 'new':
      return 'Nuevo';
    default:
      return resolution ?? '';
  }
}

/// El resumen que guarda el servidor al cerrar.
@immutable
class FixedAssetVerificationSummary {
  final int expectedCount;
  final int checkedCount;
  final int okCount;
  final int missingCount;
  final int missingUnits;
  final double missingValue;
  final int extraCount;
  final int misplacedCount;
  final int newCount;

  /// Cuántas líneas quedaron «perdido» y cuántas «pendiente de búsqueda».
  final int lostCount;
  final int pendingCount;
  final double foundValue;

  const FixedAssetVerificationSummary({
    this.expectedCount = 0,
    this.checkedCount = 0,
    this.okCount = 0,
    this.missingCount = 0,
    this.missingUnits = 0,
    this.missingValue = 0,
    this.extraCount = 0,
    this.misplacedCount = 0,
    this.newCount = 0,
    this.lostCount = 0,
    this.pendingCount = 0,
    this.foundValue = 0,
  });

  factory FixedAssetVerificationSummary.fromMap(Map<String, dynamic> map) {
    return FixedAssetVerificationSummary(
      expectedCount: _int(map['expected_count']) ?? 0,
      checkedCount: _int(map['checked_count']) ?? 0,
      okCount: _int(map['ok_count']) ?? 0,
      missingCount: _int(map['missing_count']) ?? 0,
      missingUnits: _int(map['missing_units']) ?? 0,
      missingValue: _double(map['missing_value']) ?? 0,
      extraCount: _int(map['extra_count']) ?? 0,
      misplacedCount: _int(map['misplaced_count']) ?? 0,
      newCount: _int(map['new_count']) ?? 0,
      lostCount: _int(map['lost_count']) ?? 0,
      pendingCount: _int(map['pending_count']) ?? 0,
      foundValue: _double(map['found_value']) ?? 0,
    );
  }
}

/// En qué pestaña cae una línea. Cada línea va en UNA sola, con esta
/// precedencia: nuevo → fuera de lugar → pendiente → con diferencia →
/// encontrado.
enum VerificationLineGroup {
  pending('Pendientes'),
  found('Encontrados'),
  difference('Con diferencia'),
  misplaced('Fuera de lugar'),
  isNew('Nuevos');

  const VerificationLineGroup(this.label);

  final String label;
}

/// Una línea: un activo dentro de la verificación.
@immutable
class FixedAssetVerificationLine {
  final String id;
  final String verificationId;
  final String assetId;
  final String assetCode;
  final String assetName;

  /// Valor unitario al momento de crear la línea.
  final double? unitValue;
  final String? registeredWarehouseId;
  final String? registeredWarehouseName;

  /// Estaba en la lista de la ubicación cuando se abrió la verificación.
  final bool expected;

  /// null cuando no era esperado.
  final int? expectedQty;

  /// null = sin revisar; 0 = «no está».
  final int? foundQty;
  final FixedAssetStatus? expectedStatus;

  /// null = no se anotó cambio de estado.
  final FixedAssetStatus? observedStatus;

  /// Se registró durante esta verificación.
  final bool isNew;
  final String? notes;
  final String? checkedByName;
  final DateTime? checkedAt;

  /// Se llena al cerrar: ok | pending | lost | quantity_set | moved | new.
  final String? resolution;
  final bool conditionApplied;
  final DateTime? createdAt;

  const FixedAssetVerificationLine({
    required this.id,
    required this.verificationId,
    required this.assetId,
    required this.assetCode,
    required this.assetName,
    this.unitValue,
    this.registeredWarehouseId,
    this.registeredWarehouseName,
    this.expected = true,
    this.expectedQty,
    this.foundQty,
    this.expectedStatus,
    this.observedStatus,
    this.isNew = false,
    this.notes,
    this.checkedByName,
    this.checkedAt,
    this.resolution,
    this.conditionApplied = false,
    this.createdAt,
  });

  factory FixedAssetVerificationLine.fromMap(Map<String, dynamic> map) {
    return FixedAssetVerificationLine(
      id: map['id']?.toString() ?? '',
      verificationId: map['verification_id']?.toString() ?? '',
      assetId: map['asset_id']?.toString() ?? '',
      assetCode: map['asset_code']?.toString() ?? '',
      assetName: map['asset_name']?.toString() ?? '',
      unitValue: _double(map['unit_value']),
      registeredWarehouseId: _text(map['registered_warehouse_id']),
      registeredWarehouseName: _text(map['registered_warehouse_name']),
      expected: _bool(map['expected']),
      expectedQty: _int(map['expected_qty']),
      foundQty: _int(map['found_qty']),
      expectedStatus: _status(map['expected_status']),
      observedStatus: _status(map['observed_status']),
      isNew: _bool(map['is_new']),
      notes: _text(map['notes']),
      checkedByName: _text(map['checked_by_name']),
      checkedAt: _date(map['checked_at']),
      resolution: _text(map['resolution']),
      conditionApplied: _bool(map['condition_applied']),
      createdAt: _date(map['created_at']),
    );
  }

  bool get isChecked => foundQty != null;

  /// Apareció acá sin estar en la lista (y no se registró en el momento).
  bool get isMisplaced => !expected && !isNew;

  /// Lo encontrado; sin revisar cuenta como 0.
  int get found => foundQty ?? 0;

  /// Unidades que faltan contra lo esperado. Sin revisar = falta todo.
  int get shortfall {
    if (!expected) return 0;
    final missing = (expectedQty ?? 0) - found;
    return missing > 0 ? missing : 0;
  }

  /// Unidades de más contra lo esperado (solo si se revisó).
  int get surplus {
    if (!expected || foundQty == null) return 0;
    final extra = foundQty! - (expectedQty ?? 0);
    return extra > 0 ? extra : 0;
  }

  /// Se anotó un estado distinto al que tenía el activo.
  bool get hasConditionChange =>
      observedStatus != null && observedStatus != expectedStatus;

  double get missingValue => shortfall * (unitValue ?? 0);

  VerificationLineGroup get group {
    if (isNew) return VerificationLineGroup.isNew;
    if (isMisplaced) return VerificationLineGroup.misplaced;
    if (!isChecked) return VerificationLineGroup.pending;
    if (foundQty != expectedQty || hasConditionChange) {
      return VerificationLineGroup.difference;
    }
    return VerificationLineGroup.found;
  }

  /// «Esperado 40 · Encontrado 38» (o lo que aplique).
  String get countsLabel {
    final parts = <String>[
      if (expected) 'Esperado ${expectedQty ?? 0}',
      if (foundQty != null)
        foundQty == 0 ? 'No está' : 'Encontrado $foundQty'
      else
        'Sin revisar',
    ];
    return parts.join(' · ');
  }
}

/// Una verificación (cabecera + líneas cuando vienen).
@immutable
class FixedAssetVerification {
  final String id;
  final String businessId;
  final int number;

  /// null = todas las ubicaciones.
  final String? warehouseId;
  final String warehouseName;
  final FixedAssetVerificationStatus status;
  final String? notes;
  final String? startedByName;
  final DateTime? startedAt;
  final String? closedByName;
  final DateTime? closedAt;
  final String? cancelReason;
  final FixedAssetVerificationSummary? summary;
  final List<FixedAssetVerificationLine> lines;

  /// `fn_fixed_asset_verification_start` devolvió una que ya estaba abierta.
  final bool resumed;

  /// Avance de la bandeja (lo arma el repositorio para las abiertas, sin
  /// traer las líneas completas).
  final VerificationProgress? listProgress;

  const FixedAssetVerification({
    required this.id,
    required this.businessId,
    required this.number,
    this.warehouseId,
    this.warehouseName = kAllLocationsLabel,
    this.status = FixedAssetVerificationStatus.open,
    this.notes,
    this.startedByName,
    this.startedAt,
    this.closedByName,
    this.closedAt,
    this.cancelReason,
    this.summary,
    this.lines = const [],
    this.resumed = false,
    this.listProgress,
  });

  factory FixedAssetVerification.fromMap(Map<String, dynamic> map) {
    final rawLines = map['lines'];
    final rawSummary = map['summary'];
    final warehouseId = _text(map['warehouse_id']);
    return FixedAssetVerification(
      id: map['id']?.toString() ?? '',
      businessId: map['business_id']?.toString() ?? '',
      number: _int(map['number']) ?? 0,
      warehouseId: warehouseId,
      warehouseName: _text(map['warehouse_name']) ??
          (warehouseId == null ? kAllLocationsLabel : 'Ubicación'),
      status: FixedAssetVerificationStatus.fromWire(map['status']?.toString()),
      notes: _text(map['notes']),
      startedByName: _text(map['started_by_name']),
      startedAt: _date(map['started_at']),
      closedByName: _text(map['closed_by_name']),
      closedAt: _date(map['closed_at']),
      cancelReason: _text(map['cancel_reason']),
      summary: rawSummary is Map
          ? FixedAssetVerificationSummary.fromMap(
              Map<String, dynamic>.from(rawSummary),
            )
          : null,
      lines: rawLines is List
          ? sortVerificationLines([
              for (final l in rawLines)
                if (l is Map)
                  FixedAssetVerificationLine.fromMap(
                    Map<String, dynamic>.from(l),
                  ),
            ])
          : const [],
      resumed: _bool(map['resumed']),
    );
  }

  bool get isOpen => status == FixedAssetVerificationStatus.open;
  bool get isAllLocations => warehouseId == null;

  String get title => 'Verificación #$number';

  /// «Verificación #3 · Cocina».
  String get fullTitle => '$title · $warehouseName';

  FixedAssetVerificationLine? lineFor(String assetId) {
    for (final l in lines) {
      if (l.assetId == assetId) return l;
    }
    return null;
  }

  VerificationProgress get progress =>
      listProgress ?? VerificationProgress.from(lines);

  FixedAssetVerification copyWith({
    List<FixedAssetVerificationLine>? lines,
    VerificationProgress? listProgress,
    bool? resumed,
  }) {
    return FixedAssetVerification(
      id: id,
      businessId: businessId,
      number: number,
      warehouseId: warehouseId,
      warehouseName: warehouseName,
      status: status,
      notes: notes,
      startedByName: startedByName,
      startedAt: startedAt,
      closedByName: closedByName,
      closedAt: closedAt,
      cancelReason: cancelReason,
      summary: summary,
      lines: lines ?? this.lines,
      resumed: resumed ?? this.resumed,
      listProgress: listProgress ?? this.listProgress,
    );
  }

  /// Reemplaza (o agrega) la línea de ese activo.
  FixedAssetVerification withLine(FixedAssetVerificationLine line) {
    final next = <FixedAssetVerificationLine>[
      for (final l in lines)
        if (l.assetId == line.assetId) line else l,
    ];
    if (!lines.any((l) => l.assetId == line.assetId)) next.add(line);
    return copyWith(lines: sortVerificationLines(next));
  }

  FixedAssetVerification withoutLine(String assetId) => copyWith(
        lines: [
          for (final l in lines)
            if (l.assetId != assetId) l,
        ],
      );
}

/// Orden de las líneas: por número de código (AF-00002 antes que AF-00010).
List<FixedAssetVerificationLine> sortVerificationLines(
  List<FixedAssetVerificationLine> lines,
) {
  int number(String code) =>
      int.tryParse(code.replaceAll(RegExp(r'\D'), '')) ?? 0;
  final sorted = [...lines];
  sorted.sort((a, b) {
    final n = number(a.assetCode).compareTo(number(b.assetCode));
    return n != 0
        ? n
        : a.assetCode.toLowerCase().compareTo(b.assetCode.toLowerCase());
  });
  return sorted;
}

/// Cuántas líneas hay en cada pestaña.
Map<VerificationLineGroup, int> countVerificationGroups(
  List<FixedAssetVerificationLine> lines,
) {
  final counts = {for (final g in VerificationLineGroup.values) g: 0};
  for (final l in lines) {
    counts[l.group] = counts[l.group]! + 1;
  }
  return counts;
}

/// Filtra por pestaña ([group] null = todas) y por texto (código o nombre).
List<FixedAssetVerificationLine> filterVerificationLines(
  List<FixedAssetVerificationLine> lines, {
  VerificationLineGroup? group,
  String query = '',
}) {
  final q = foldFixedAssetText(query.trim());
  return [
    for (final l in lines)
      if ((group == null || l.group == group) &&
          (q.isEmpty ||
              foldFixedAssetText('${l.assetCode} ${l.assetName}').contains(q)))
        l,
  ];
}

/// «18 de 30 revisados», más lo que apareció sin estar en la lista.
@immutable
class VerificationProgress {
  /// Líneas que estaban en la lista.
  final int expected;

  /// De esas, cuántas ya se revisaron.
  final int checked;
  final int misplaced;
  final int added;

  const VerificationProgress({
    this.expected = 0,
    this.checked = 0,
    this.misplaced = 0,
    this.added = 0,
  });

  factory VerificationProgress.from(List<FixedAssetVerificationLine> lines) {
    var expected = 0;
    var checked = 0;
    var misplaced = 0;
    var added = 0;
    for (final l in lines) {
      if (l.isNew) {
        added++;
      } else if (!l.expected) {
        misplaced++;
      } else {
        expected++;
        if (l.isChecked) checked++;
      }
    }
    return VerificationProgress(
      expected: expected,
      checked: checked,
      misplaced: misplaced,
      added: added,
    );
  }

  double get fraction => expected == 0 ? 1 : checked / expected;

  String get label => '$checked de $expected revisados';

  /// «2 fuera de lugar · 1 nuevo», o vacío.
  String get extrasLabel => [
        if (misplaced > 0) '$misplaced fuera de lugar',
        if (added > 0) '$added ${added == 1 ? 'nuevo' : 'nuevos'}',
      ].join(' · ');
}

// ── Cierre ─────────────────────────────────────────────────────────────────

/// Lo que hay que decidir al cerrar. Lo que cuadra no aparece.
@immutable
class VerificationClosePlan {
  /// Faltan unidades (incluye las que nunca se revisaron).
  final List<FixedAssetVerificationLine> shortfalls;

  /// Se encontraron más de las esperadas.
  final List<FixedAssetVerificationLine> surpluses;

  /// Aparecieron acá y están registradas en otra ubicación (o en ninguna).
  final List<FixedAssetVerificationLine> misplaced;

  /// Se anotó un estado distinto.
  final List<FixedAssetVerificationLine> conditionChanges;

  /// En una verificación de «todas las ubicaciones» no hay a dónde
  /// trasladar: los fuera de lugar se informan y no se deciden.
  final bool canMove;

  const VerificationClosePlan({
    this.shortfalls = const [],
    this.surpluses = const [],
    this.misplaced = const [],
    this.conditionChanges = const [],
    this.canMove = true,
  });

  factory VerificationClosePlan.from(FixedAssetVerification v) {
    final lines = sortVerificationLines(v.lines);
    return VerificationClosePlan(
      shortfalls: [
        for (final l in lines)
          if (l.shortfall > 0) l,
      ],
      surpluses: [
        for (final l in lines)
          if (l.surplus > 0) l,
      ],
      misplaced: [
        for (final l in lines)
          if (l.isMisplaced && l.found > 0) l,
      ],
      // Cambiar el estado de algo que no se encontró no tiene sentido: lo
      // que se ve es que falta, no cómo está.
      conditionChanges: [
        for (final l in lines)
          if (l.hasConditionChange && l.found > 0) l,
      ],
      canMove: !v.isAllLocations,
    );
  }

  bool get isEmpty =>
      shortfalls.isEmpty &&
      surpluses.isEmpty &&
      (misplaced.isEmpty || !canMove) &&
      conditionChanges.isEmpty;

  /// Valor de lo que falta (todas las líneas con faltante).
  double get missingValue =>
      shortfalls.fold(0, (sum, l) => sum + l.missingValue);
}

/// Lo que se eligió en el diálogo de cierre. Por defecto: nada se da por
/// perdido (queda «pendiente de búsqueda»), y sí se actualizan cantidades de
/// más, traslados y estados anotados — es lo que se vio con los ojos.
@immutable
class VerificationCloseChoices {
  final Set<String> markLost;
  final Set<String> setQuantity;
  final Set<String> moveHere;
  final Set<String> applyCondition;

  const VerificationCloseChoices({
    this.markLost = const {},
    this.setQuantity = const {},
    this.moveHere = const {},
    this.applyCondition = const {},
  });

  factory VerificationCloseChoices.defaults(VerificationClosePlan plan) {
    return VerificationCloseChoices(
      setQuantity: {for (final l in plan.surpluses) l.assetId},
      moveHere: plan.canMove ? {for (final l in plan.misplaced) l.assetId} : {},
      applyCondition: {for (final l in plan.conditionChanges) l.assetId},
    );
  }

  VerificationCloseChoices toggle(String action, String assetId, bool on) {
    Set<String> flip(Set<String> s) =>
        on ? {...s, assetId} : ({...s}..remove(assetId));
    switch (action) {
      case 'mark_lost':
        return VerificationCloseChoices(
          markLost: flip(markLost),
          setQuantity: setQuantity,
          moveHere: moveHere,
          applyCondition: applyCondition,
        );
      case 'set_quantity':
        return VerificationCloseChoices(
          markLost: markLost,
          setQuantity: flip(setQuantity),
          moveHere: moveHere,
          applyCondition: applyCondition,
        );
      case 'move_here':
        return VerificationCloseChoices(
          markLost: markLost,
          setQuantity: setQuantity,
          moveHere: flip(moveHere),
          applyCondition: applyCondition,
        );
      case 'apply_condition':
        return VerificationCloseChoices(
          markLost: markLost,
          setQuantity: setQuantity,
          moveHere: moveHere,
          applyCondition: flip(applyCondition),
        );
    }
    return this;
  }

  /// `p_decisions` de `fn_fixed_asset_verification_close`. Solo manda
  /// decisiones que el plan permite (un id suelto no se cuela).
  List<Map<String, String>> toDecisions(VerificationClosePlan plan) {
    Set<String> ids(List<FixedAssetVerificationLine> lines) =>
        {for (final l in lines) l.assetId};
    final shortfallIds = ids(plan.shortfalls);
    final surplusIds = ids(plan.surpluses);
    final misplacedIds = plan.canMove ? ids(plan.misplaced) : <String>{};
    final conditionIds = ids(plan.conditionChanges);
    return [
      for (final id in markLost)
        if (shortfallIds.contains(id)) {'asset_id': id, 'action': 'mark_lost'},
      for (final id in setQuantity)
        if (surplusIds.contains(id)) {'asset_id': id, 'action': 'set_quantity'},
      for (final id in moveHere)
        if (misplacedIds.contains(id)) {'asset_id': id, 'action': 'move_here'},
      for (final id in applyCondition)
        if (conditionIds.contains(id))
          {'asset_id': id, 'action': 'apply_condition'},
    ];
  }

  /// Valor de lo que se va a dar por perdido con estas decisiones.
  double lostValue(VerificationClosePlan plan) => plan.shortfalls
      .where((l) => markLost.contains(l.assetId))
      .fold(0, (sum, l) => sum + l.missingValue);
}
