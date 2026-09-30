// Activos fijos: el equipo y el mobiliario, UNO POR UNO (20260930_0052).
//
// No es inventario: un horno no se consume ni entra en el costo de venta. Es
// un registro paralelo de qué hay, dónde está y quién responde por él. Por
// eso modelos propios y ningún cruce con los insumos. Sin depreciación
// (decisión del dueño).
//
// Acá viven los modelos, los filtros y los indicadores de la pantalla como
// funciones puras: la vista solo los pinta.

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Las que la app propone. Es texto libre: cada negocio nombra lo suyo.
const kFixedAssetCategorySuggestions = <String>[
  'Equipo de cocina',
  'Refrigeración',
  'Mobiliario',
  'Electrónica',
  'Climatización',
  'Vehículo',
  'Otro',
];

/// Estados de un activo. `retired` = dado de baja (con fecha y motivo).
enum FixedAssetStatus {
  active('active', 'En uso', Icons.check_circle_outline_rounded),
  needsRepair('needs_repair', 'Necesita reparación', Icons.build_outlined),
  inRepair('in_repair', 'En reparación', Icons.handyman_outlined),
  damaged('damaged', 'Dañado', Icons.report_gmailerrorred_outlined),
  lost('lost', 'Perdido', Icons.help_outline_rounded),
  retired('retired', 'Dado de baja', Icons.do_not_disturb_on_outlined);

  const FixedAssetStatus(this.wire, this.label, this.icon);

  final String wire;
  final String label;
  final IconData icon;

  static FixedAssetStatus fromWire(String? raw) {
    for (final s in values) {
      if (s.wire == raw) return s;
    }
    return FixedAssetStatus.active;
  }

  Color get color {
    switch (this) {
      case FixedAssetStatus.active:
        return AppColors.success;
      case FixedAssetStatus.needsRepair:
        return AppColors.warning;
      case FixedAssetStatus.inRepair:
        return AppColors.info;
      case FixedAssetStatus.damaged:
        return AppColors.destructive;
      case FixedAssetStatus.lost:
        return AppColors.reserved;
      case FixedAssetStatus.retired:
        return AppColors.mutedForeground;
    }
  }

  bool get isRetired => this == FixedAssetStatus.retired;

  /// Los que se eligen en «Cambiar estado». La baja tiene su propio botón
  /// (pide motivo) y no se ofrece ahí.
  static const selectable = <FixedAssetStatus>[
    FixedAssetStatus.active,
    FixedAssetStatus.needsRepair,
    FixedAssetStatus.inRepair,
    FixedAssetStatus.damaged,
    FixedAssetStatus.lost,
  ];
}

/// Qué pasó en una fila de la historia.
enum FixedAssetEventType {
  created('created', 'Alta', Icons.add_circle_outline_rounded),
  updated('updated', 'Datos editados', Icons.edit_outlined),
  relocated('relocated', 'Traslado', Icons.swap_horiz_rounded),
  reassigned('reassigned', 'Cambio de responsable', Icons.person_outline),
  statusChanged('status_changed', 'Cambio de estado', Icons.flag_outlined),
  retired('retired', 'Baja', Icons.do_not_disturb_on_outlined),
  reactivated('reactivated', 'Reactivado', Icons.restart_alt_rounded);

  const FixedAssetEventType(this.wire, this.label, this.icon);

  final String wire;
  final String label;
  final IconData icon;

  static FixedAssetEventType fromWire(String? raw) {
    for (final e in values) {
      if (e.wire == raw) return e;
    }
    return FixedAssetEventType.updated;
  }
}

/// Nombre legible de los campos que puede cambiar la edición (la columna
/// `changes` de la historia).
const kFixedAssetFieldLabels = <String, String>{
  'name': 'Nombre',
  'category': 'Categoría',
  'brand': 'Marca',
  'model': 'Modelo',
  'serial_number': 'Serie',
  'purchase_date': 'Fecha de compra',
  'purchase_cost': 'Costo',
  'supplier_name': 'Proveedor',
  'warranty_until': 'Garantía hasta',
  'notes': 'Notas',
};

double? _toDoubleOrNull(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

String? _textOrNull(dynamic v) {
  final s = v?.toString().trim();
  return (s == null || s.isEmpty) ? null : s;
}

DateTime? _dateOrNull(dynamic v) {
  final s = v?.toString();
  if (s == null || s.isEmpty) return null;
  return DateTime.tryParse(s);
}

String _fullName(dynamic embedded) {
  if (embedded is! Map) return '';
  return [
    embedded['first_name']?.toString().trim() ?? '',
    embedded['last_name']?.toString().trim() ?? '',
  ].where((p) => p.isNotEmpty).join(' ');
}

/// Una ficha. Llega igual del SELECT de PostgREST (con `warehouses(name)` y
/// `employees(first_name, last_name)` embebidos) que de los RPC, que
/// devuelven la misma forma.
@immutable
class FixedAsset {
  final String id;
  final String businessId;
  final String code;
  final String name;
  final String? category;
  final String? brand;
  final String? model;
  final String? serialNumber;
  final DateTime? purchaseDate;
  final double? purchaseCost;
  final String? supplierName;
  final DateTime? warrantyUntil;
  final String? warehouseId;
  final String warehouseName;
  final String? locationNote;
  final String? assignedEmployeeId;
  final String employeeName;
  final FixedAssetStatus status;
  final DateTime? retiredAt;
  final String? retiredReason;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const FixedAsset({
    required this.id,
    required this.businessId,
    required this.code,
    required this.name,
    this.category,
    this.brand,
    this.model,
    this.serialNumber,
    this.purchaseDate,
    this.purchaseCost,
    this.supplierName,
    this.warrantyUntil,
    this.warehouseId,
    this.warehouseName = '',
    this.locationNote,
    this.assignedEmployeeId,
    this.employeeName = '',
    this.status = FixedAssetStatus.active,
    this.retiredAt,
    this.retiredReason,
    this.notes,
    this.createdAt,
    this.updatedAt,
  });

  factory FixedAsset.fromMap(Map<String, dynamic> map) {
    final wh = map['warehouses'];
    return FixedAsset(
      id: map['id']?.toString() ?? '',
      businessId: map['business_id']?.toString() ?? '',
      code: map['code']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      category: _textOrNull(map['category']),
      brand: _textOrNull(map['brand']),
      model: _textOrNull(map['model']),
      serialNumber: _textOrNull(map['serial_number']),
      purchaseDate: _dateOrNull(map['purchase_date']),
      purchaseCost: _toDoubleOrNull(map['purchase_cost']),
      supplierName: _textOrNull(map['supplier_name']),
      warrantyUntil: _dateOrNull(map['warranty_until']),
      warehouseId: _textOrNull(map['warehouse_id']),
      warehouseName: wh is Map ? (wh['name']?.toString().trim() ?? '') : '',
      locationNote: _textOrNull(map['location_note']),
      assignedEmployeeId: _textOrNull(map['assigned_employee_id']),
      employeeName: _fullName(map['employees']),
      status: FixedAssetStatus.fromWire(map['status']?.toString()),
      retiredAt: _dateOrNull(map['retired_at']),
      retiredReason: _textOrNull(map['retired_reason']),
      notes: _textOrNull(map['notes']),
      createdAt: _dateOrNull(map['created_at']),
      updatedAt: _dateOrNull(map['updated_at']),
    );
  }

  /// «Marca · Modelo», o lo que haya.
  String get brandModel =>
      [brand, model].whereType<String>().where((s) => s.isNotEmpty).join(' · ');

  bool get hasLocation =>
      (warehouseId != null && warehouseName.isNotEmpty) ||
      (locationNote ?? '').isNotEmpty;

  /// Dónde está, para una línea: «Cocina · junto a la plancha».
  String get locationLabel {
    final parts = [
      if (warehouseName.isNotEmpty) warehouseName,
      if ((locationNote ?? '').isNotEmpty) locationNote!,
    ];
    return parts.isEmpty ? 'Sin ubicación' : parts.join(' · ');
  }

  /// Nombre del grupo en el inventario impreso: la bodega (la nota de
  /// ubicación va en la fila, no parte el grupo).
  String get locationGroup =>
      warehouseName.isNotEmpty ? warehouseName : 'Sin ubicación';

  String get responsibleLabel =>
      employeeName.isNotEmpty ? employeeName : 'Sin responsable';

  /// ¿La garantía sigue vigente a [today]?
  bool warrantyActive(DateTime today) {
    final w = warrantyUntil;
    if (w == null) return false;
    final d = DateTime(today.year, today.month, today.day);
    return !DateTime(w.year, w.month, w.day).isBefore(d);
  }
}

/// Una fila de la historia.
@immutable
class FixedAssetMovement {
  final String id;
  final String assetId;
  final FixedAssetEventType eventType;
  final String? fromWarehouseName;
  final String? toWarehouseName;
  final String? fromLocationNote;
  final String? toLocationNote;
  final String? fromEmployeeName;
  final String? toEmployeeName;
  final FixedAssetStatus? fromStatus;
  final FixedAssetStatus? toStatus;

  /// Solo en `updated`: campo → (antes, después).
  final Map<String, ({String? from, String? to})> changes;
  final String? notes;
  final String? createdByName;
  final DateTime? createdAt;

  const FixedAssetMovement({
    required this.id,
    required this.assetId,
    required this.eventType,
    this.fromWarehouseName,
    this.toWarehouseName,
    this.fromLocationNote,
    this.toLocationNote,
    this.fromEmployeeName,
    this.toEmployeeName,
    this.fromStatus,
    this.toStatus,
    this.changes = const {},
    this.notes,
    this.createdByName,
    this.createdAt,
  });

  factory FixedAssetMovement.fromMap(Map<String, dynamic> map) {
    FixedAssetStatus? status(dynamic raw) {
      final s = _textOrNull(raw);
      return s == null ? null : FixedAssetStatus.fromWire(s);
    }

    final rawChanges = map['changes'];
    final changes = <String, ({String? from, String? to})>{};
    if (rawChanges is Map) {
      rawChanges.forEach((key, value) {
        if (value is Map) {
          changes[key.toString()] = (
            from: _textOrNull(value['from']),
            to: _textOrNull(value['to']),
          );
        }
      });
    }

    return FixedAssetMovement(
      id: map['id']?.toString() ?? '',
      assetId: map['asset_id']?.toString() ?? '',
      eventType: FixedAssetEventType.fromWire(map['event_type']?.toString()),
      fromWarehouseName: _textOrNull(map['from_warehouse_name']),
      toWarehouseName: _textOrNull(map['to_warehouse_name']),
      fromLocationNote: _textOrNull(map['from_location_note']),
      toLocationNote: _textOrNull(map['to_location_note']),
      fromEmployeeName: _textOrNull(map['from_employee_name']),
      toEmployeeName: _textOrNull(map['to_employee_name']),
      fromStatus: status(map['from_status']),
      toStatus: status(map['to_status']),
      changes: changes,
      notes: _textOrNull(map['notes']),
      createdByName: _textOrNull(map['created_by_name']),
      createdAt: _dateOrNull(map['created_at']),
    );
  }

  static String _place(String? warehouse, String? note) {
    final parts = [
      if ((warehouse ?? '').isNotEmpty) warehouse!,
      if ((note ?? '').isNotEmpty) note!,
    ];
    return parts.isEmpty ? 'sin ubicación' : parts.join(' · ');
  }

  /// Una línea que cuenta qué pasó: «De Cocina a Principal · Pasillo».
  String get description {
    switch (eventType) {
      case FixedAssetEventType.created:
        final where = _place(toWarehouseName, toLocationNote);
        final who = toEmployeeName;
        return who == null
            ? 'Registrado en $where'
            : 'Registrado en $where, a cargo de $who';
      case FixedAssetEventType.updated:
        if (changes.isEmpty) return 'Se editaron los datos';
        final campos = changes.keys
            .map((k) => kFixedAssetFieldLabels[k] ?? k)
            .join(', ');
        return 'Cambió: $campos';
      case FixedAssetEventType.relocated:
        return 'De ${_place(fromWarehouseName, fromLocationNote)} a '
            '${_place(toWarehouseName, toLocationNote)}';
      case FixedAssetEventType.reassigned:
        final antes = fromEmployeeName ?? 'sin responsable';
        final ahora = toEmployeeName ?? 'sin responsable';
        return 'De $antes a $ahora';
      case FixedAssetEventType.statusChanged:
      case FixedAssetEventType.retired:
      case FixedAssetEventType.reactivated:
        final antes = fromStatus?.label ?? '—';
        final ahora = toStatus?.label ?? '—';
        return '$antes → $ahora';
    }
  }
}

/// Bodega o empleado para los selectores.
@immutable
class FixedAssetOption {
  final String id;
  final String name;

  const FixedAssetOption(this.id, this.name);

  @override
  bool operator ==(Object other) =>
      other is FixedAssetOption && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

// ── Búsqueda y filtros ─────────────────────────────────────────────────────

/// Minúsculas y sin tildes: «refrigeracion» encuentra «Refrigeración».
String foldFixedAssetText(String input) {
  const map = {
    'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a',
    'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
    'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
    'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o',
    'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
    'ñ': 'n',
  };
  final lower = input.toLowerCase();
  final buffer = StringBuffer();
  for (final ch in lower.split('')) {
    buffer.write(map[ch] ?? ch);
  }
  return buffer.toString();
}

/// Valor del filtro de ubicación que significa «sin bodega asignada».
const kFixedAssetNoWarehouse = '__sin_bodega__';

@immutable
class FixedAssetsFilter {
  final String query;

  /// null = todas.
  final String? category;

  /// null = todas; [kFixedAssetNoWarehouse] = las que no tienen bodega.
  final String? warehouseId;

  /// null = todos los estados.
  final FixedAssetStatus? status;

  /// Los dados de baja se esconden por defecto: son historia, no operación.
  final bool showRetired;

  const FixedAssetsFilter({
    this.query = '',
    this.category,
    this.warehouseId,
    this.status,
    this.showRetired = false,
  });

  bool get isFiltering =>
      query.trim().isNotEmpty ||
      category != null ||
      warehouseId != null ||
      status != null;

  FixedAssetsFilter copyWith({
    String? query,
    String? category,
    bool clearCategory = false,
    String? warehouseId,
    bool clearWarehouse = false,
    FixedAssetStatus? status,
    bool clearStatus = false,
    bool? showRetired,
  }) {
    return FixedAssetsFilter(
      query: query ?? this.query,
      category: clearCategory ? null : (category ?? this.category),
      warehouseId: clearWarehouse ? null : (warehouseId ?? this.warehouseId),
      status: clearStatus ? null : (status ?? this.status),
      showRetired: showRetired ?? this.showRetired,
    );
  }

  bool matches(FixedAsset a) {
    // Pedir explícitamente «Dado de baja» los muestra aunque el interruptor
    // esté apagado: si no, el filtro devolvería siempre vacío.
    if (a.status.isRetired &&
        !showRetired &&
        status != FixedAssetStatus.retired) {
      return false;
    }
    if (status != null && a.status != status) return false;
    if (category != null &&
        foldFixedAssetText(a.category ?? '') != foldFixedAssetText(category!)) {
      return false;
    }
    final wh = warehouseId;
    if (wh != null) {
      if (wh == kFixedAssetNoWarehouse) {
        if (a.warehouseId != null) return false;
      } else if (a.warehouseId != wh) {
        return false;
      }
    }
    final q = foldFixedAssetText(query.trim());
    if (q.isNotEmpty) {
      final haystack = foldFixedAssetText(
        [
          a.name,
          a.code,
          a.serialNumber ?? '',
          a.brand ?? '',
          a.model ?? '',
        ].join(' '),
      );
      // Cada palabra tiene que estar: «horno rational» encuentra al horno
      // Rational aunque el orden sea otro.
      for (final word in q.split(RegExp(r'\s+'))) {
        if (word.isNotEmpty && !haystack.contains(word)) return false;
      }
    }
    return true;
  }

  List<FixedAsset> apply(List<FixedAsset> assets) =>
      assets.where(matches).toList(growable: false);
}

/// Categorías para el filtro: las sugeridas que se usan + las propias del
/// negocio, sin repetir (sin importar mayúsculas ni tildes).
List<String> fixedAssetCategoriesIn(List<FixedAsset> assets) {
  final seen = <String>{};
  final result = <String>[];
  for (final a in assets) {
    final c = a.category?.trim();
    if (c == null || c.isEmpty) continue;
    if (seen.add(foldFixedAssetText(c))) result.add(c);
  }
  result.sort(
    (a, b) => foldFixedAssetText(a).compareTo(foldFixedAssetText(b)),
  );
  return result;
}

/// Orden de la lista: por código (AF-00002 antes que AF-00010, y AF-100000
/// después de AF-99999).
List<FixedAsset> sortFixedAssetsByCode(List<FixedAsset> assets) {
  int number(String code) =>
      int.tryParse(code.replaceAll(RegExp(r'\D'), '')) ?? 0;
  final sorted = [...assets];
  sorted.sort((a, b) {
    final n = number(a.code).compareTo(number(b.code));
    return n != 0 ? n : a.code.compareTo(b.code);
  });
  return sorted;
}

// ── Indicadores ────────────────────────────────────────────────────────────

/// Los cuatro números de arriba. Se calculan sobre el registro COMPLETO del
/// negocio, no sobre lo filtrado: son la foto del patrimonio.
@immutable
class FixedAssetsKpis {
  /// Todo lo que no está dado de baja.
  final int registered;
  final int inUse;

  /// Suma del costo de compra de lo vigente (sin bajas). Sin depreciación.
  final double purchaseValue;

  /// Vigentes sin costo cargado: el valor total se queda corto por ellos.
  final int withoutCost;
  final int needsRepair;
  final int inRepair;
  final int damaged;
  final int lost;
  final int retired;

  const FixedAssetsKpis({
    this.registered = 0,
    this.inUse = 0,
    this.purchaseValue = 0,
    this.withoutCost = 0,
    this.needsRepair = 0,
    this.inRepair = 0,
    this.damaged = 0,
    this.lost = 0,
    this.retired = 0,
  });

  int get repairTotal => needsRepair + inRepair;

  factory FixedAssetsKpis.from(List<FixedAsset> assets) {
    var registered = 0;
    var inUse = 0;
    var value = 0.0;
    var withoutCost = 0;
    var needsRepair = 0;
    var inRepair = 0;
    var damaged = 0;
    var lost = 0;
    var retired = 0;
    for (final a in assets) {
      switch (a.status) {
        case FixedAssetStatus.retired:
          retired++;
          continue;
        case FixedAssetStatus.active:
          inUse++;
        case FixedAssetStatus.needsRepair:
          needsRepair++;
        case FixedAssetStatus.inRepair:
          inRepair++;
        case FixedAssetStatus.damaged:
          damaged++;
        case FixedAssetStatus.lost:
          lost++;
      }
      registered++;
      final cost = a.purchaseCost;
      if (cost == null) {
        withoutCost++;
      } else {
        value += cost;
      }
    }
    return FixedAssetsKpis(
      registered: registered,
      inUse: inUse,
      purchaseValue: value,
      withoutCost: withoutCost,
      needsRepair: needsRepair,
      inRepair: inRepair,
      damaged: damaged,
      lost: lost,
      retired: retired,
    );
  }
}

// ── Formulario ─────────────────────────────────────────────────────────────

/// Monto escrito a mano. Acepta las dos costumbres: «1,250.50» y «1250,50»
/// (también «1.250,50»). Una coma seguida de EXACTAMENTE tres dígitos es de
/// miles («85,000» son ochenta y cinco mil, no 85): así se escribe en RD y
/// leerla como decimal guardaría un costo mil veces menor.
/// Devuelve null si el texto no es un número; vacío también es null.
double? parseFixedAssetAmount(String raw) {
  var s = raw.trim().replaceAll(' ', '');
  s = s.replaceAll(RegExp(r'^[A-Za-z]*\$'), '');
  if (s.isEmpty) return null;
  final lastComma = s.lastIndexOf(',');
  final lastDot = s.lastIndexOf('.');
  if (lastComma >= 0 && lastDot >= 0) {
    // Las dos: la que va de último es la decimal.
    if (lastComma > lastDot) {
      s = s.replaceAll('.', '').replaceAll(',', '.');
    } else {
      s = s.replaceAll(',', '');
    }
  } else if (lastComma >= 0) {
    final thousands = RegExp(r'^\d{1,3}(,\d{3})+$');
    s = thousands.hasMatch(s) ? s.replaceAll(',', '') : s.replaceAll(',', '.');
  } else if ('.'.allMatches(s).length > 1) {
    // «1.250.000»: varios puntos solo pueden ser de miles.
    s = s.replaceAll('.', '');
  }
  if (!RegExp(r'^-?\d+(\.\d+)?$').hasMatch(s)) return null;
  return double.tryParse(s);
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Lo que se captura en el formulario. En la EDICIÓN la ubicación, el
/// responsable y el estado no viajan: tienen su propio RPC y su propio
/// evento en la historia.
@immutable
class FixedAssetDraft {
  final String name;
  final String? category;
  final String? brand;
  final String? model;
  final String? serialNumber;
  final DateTime? purchaseDate;
  final double? purchaseCost;
  final String? supplierName;
  final DateTime? warrantyUntil;
  final String? warehouseId;
  final String? locationNote;
  final String? assignedEmployeeId;
  final String? notes;

  const FixedAssetDraft({
    required this.name,
    this.category,
    this.brand,
    this.model,
    this.serialNumber,
    this.purchaseDate,
    this.purchaseCost,
    this.supplierName,
    this.warrantyUntil,
    this.warehouseId,
    this.locationNote,
    this.assignedEmployeeId,
    this.notes,
  });

  static String? _clean(String? v) {
    final s = v?.trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  /// Los datos de la ficha (lo que edita `fn_fixed_asset_update`). Las
  /// claves van SIEMPRE, con null para borrar: la edición manda la ficha
  /// completa.
  Map<String, dynamic> dataJson() => {
        'name': name.trim(),
        'category': _clean(category),
        'brand': _clean(brand),
        'model': _clean(model),
        'serial_number': _clean(serialNumber),
        'purchase_date': purchaseDate == null ? null : _isoDate(purchaseDate!),
        'purchase_cost': purchaseCost,
        'supplier_name': _clean(supplierName),
        'warranty_until':
            warrantyUntil == null ? null : _isoDate(warrantyUntil!),
        'notes': _clean(notes),
      };

  /// Payload del alta: los datos + dónde queda y quién responde.
  Map<String, dynamic> createJson({String? clientRequestId}) => {
        ...dataJson(),
        'warehouse_id': warehouseId,
        'location_note': _clean(locationNote),
        'assigned_employee_id': assignedEmployeeId,
        'client_request_id': ?clientRequestId,
      };
}

// ── Errores ────────────────────────────────────────────────────────────────

/// Los RPC levantan códigos, no frases. Traducirlos acá evita que el
/// usuario vea `FIXED_ASSET_DENIED` y no sepa qué hacer. `null` si el error
/// no es uno de los del módulo (la vista usa entonces el genérico).
String? fixedAssetErrorMessage(Object error) {
  final texto = error.toString();
  if (texto.contains('FIXED_ASSET_DENIED') ||
      texto.contains('NOT_AUTHORIZED')) {
    return 'No tienes permiso para modificar activos fijos en este negocio.';
  }
  if (texto.contains('FIXED_ASSET_NOT_FOUND')) {
    return 'Ese activo ya no existe. Actualiza la lista.';
  }
  if (texto.contains('FIXED_ASSET_NAME_REQUIRED')) {
    return 'El activo necesita un nombre.';
  }
  if (texto.contains('FIXED_ASSET_INVALID_COST')) {
    return 'El costo no puede ser negativo.';
  }
  if (texto.contains('FIXED_ASSET_RETIRE_REASON_REQUIRED')) {
    return 'Escribe el motivo de la baja.';
  }
  if (texto.contains('FIXED_ASSET_RETIRED')) {
    return 'Este activo está dado de baja. Reactívalo antes de moverlo.';
  }
  if (texto.contains('FIXED_ASSET_INVALID_STATUS')) {
    return 'Ese estado no es válido para este activo.';
  }
  if (texto.contains('WAREHOUSE_NOT_IN_BUSINESS')) {
    return 'La bodega elegida no es de este negocio.';
  }
  if (texto.contains('EMPLOYEE_NOT_IN_BUSINESS')) {
    return 'El responsable elegido no es empleado de este negocio.';
  }
  return null;
}
