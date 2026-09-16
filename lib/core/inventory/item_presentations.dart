/// Presentaciones de dos niveles («caja dentro de caja», Compras F5a).
///
/// Lata = 355 mL; Caja = 24 Lata → la caja trae 8,520 mL. Cada presentación
/// contiene la unidad BASE o una presentación que contiene la base (máximo dos
/// niveles), igual que valida `fn_inventory_item_presentations_save`
/// (20260915_0009). La de compra por defecto se aplana en `purchase_unit` /
/// `pack_size`, así que todo lo que ya convierte con un solo contenido sigue
/// igual.
///
/// Funciones puras: el formulario valida y muestra la etiqueta mientras se
/// escribe, sin ir a la base.
library;

import 'unit_conversion.dart';

const int kMaxItemPresentations = 5;

String _key(String value) => value.trim().toLowerCase();

/// Lo que se escribe en el formulario (o se lee de la base).
class PresentationDraft {
  final String unit;
  final double containsQty;

  /// null = la unidad base; si no, el nombre de otra presentación.
  final String? containsUnit;
  final bool isPurchaseDefault;

  const PresentationDraft({
    required this.unit,
    required this.containsQty,
    this.containsUnit,
    this.isPurchaseDefault = false,
  });

  factory PresentationDraft.fromMap(Map<String, dynamic> map) {
    final qty = map['contains_qty'];
    return PresentationDraft(
      unit: map['unit']?.toString() ?? '',
      containsQty: qty is num ? qty.toDouble() : double.tryParse('$qty') ?? 0,
      containsUnit: (map['contains_unit']?.toString().trim().isEmpty ?? true)
          ? null
          : map['contains_unit'].toString(),
      isPurchaseDefault: map['is_purchase_default'] == true,
    );
  }

  PresentationDraft copyWith({
    String? unit,
    double? containsQty,
    String? containsUnit,
    bool clearContainsUnit = false,
    bool? isPurchaseDefault,
  }) {
    return PresentationDraft(
      unit: unit ?? this.unit,
      containsQty: containsQty ?? this.containsQty,
      containsUnit: clearContainsUnit ? null : (containsUnit ?? this.containsUnit),
      isPurchaseDefault: isPurchaseDefault ?? this.isPurchaseDefault,
    );
  }

  /// Para `fn_inventory_item_presentations_save`.
  Map<String, dynamic> toJson() => {
        'unit': unit.trim(),
        'contains_qty': containsQty,
        'contains_unit': containsUnit?.trim(),
        'is_purchase_default': isPurchaseDefault,
      };
}

/// Una presentación con su contenido ya llevado a unidad base.
class ResolvedPresentation {
  final PresentationDraft draft;

  /// Unidades base por 1 de esta presentación. Null si no se pudo resolver.
  final double? baseQty;

  /// La presentación que contiene (null = la base).
  final String? parent;

  const ResolvedPresentation({required this.draft, this.baseQty, this.parent});

  String get unit => draft.unit.trim();
}

class PresentationsCheck {
  final List<ResolvedPresentation> items;

  /// Errores legibles, en el orden de la lista. Vacío = se puede guardar.
  final List<String> errors;

  const PresentationsCheck({required this.items, required this.errors});

  bool get isValid => errors.isEmpty;

  ResolvedPresentation? get purchaseDefault {
    for (final p in items) {
      if (p.draft.isPurchaseDefault) return p;
    }
    return null;
  }
}

/// Valida y resuelve igual que la base. [baseUnit] es la unidad de stock.
PresentationsCheck checkPresentations(
  List<PresentationDraft> drafts,
  String baseUnit,
) {
  final base = _key(baseUnit.isEmpty ? 'unidad' : baseUnit);
  final errors = <String>[];
  final byKey = <String, PresentationDraft>{};

  if (drafts.length > kMaxItemPresentations) {
    errors.add('Máximo $kMaxItemPresentations presentaciones.');
  }

  for (final d in drafts) {
    final key = _key(d.unit);
    if (key.isEmpty) {
      errors.add('Una presentación no tiene nombre.');
      continue;
    }
    if (sameUnit(key, base) || key == base) {
      errors.add('«${d.unit.trim()}» es la unidad base del insumo.');
      continue;
    }
    if (byKey.containsKey(key)) {
      errors.add('«${d.unit.trim()}» está repetida.');
      continue;
    }
    if (d.containsQty <= 0) {
      errors.add('«${d.unit.trim()}» necesita una cantidad mayor que 0.');
    }
    byKey[key] = d;
  }

  if (drafts.where((d) => d.isPurchaseDefault).length > 1) {
    errors.add('Solo una puede ser la de compra por defecto.');
  }

  String? parentOf(PresentationDraft d) {
    final c = d.containsUnit?.trim();
    if (c == null || c.isEmpty) return null;
    if (_key(c) == base || sameUnit(c, base)) return null;
    return c;
  }

  final items = <ResolvedPresentation>[];
  for (final d in drafts) {
    var parent = parentOf(d);
    double? baseQty;
    if (parent == null) {
      baseQty = d.containsQty > 0 ? d.containsQty : null;
    } else {
      final container = byKey[_key(parent)];
      if (container == null) {
        errors.add('«${d.unit.trim()}» contiene «$parent», que no está en la lista.');
      } else if (_key(container.unit) == _key(d.unit)) {
        errors.add('«${d.unit.trim()}» no puede contenerse a sí misma.');
      } else if (parentOf(container) != null) {
        errors.add('«${d.unit.trim()}» contiene «${container.unit.trim()}», que ya contiene otra '
            'presentación: máximo dos niveles.');
      } else {
        // El nombre como está escrito en SU fila («Lata»), no como se tecleó
        // en el contenedor («lata»). La base guarda lo mismo.
        parent = container.unit.trim();
        if (d.containsQty > 0 && container.containsQty > 0) {
          baseQty = d.containsQty * container.containsQty;
        }
      }
    }
    items.add(ResolvedPresentation(draft: d, baseQty: baseQty, parent: parent));
  }

  return PresentationsCheck(items: items, errors: errors);
}

/// Una cantidad base legible: 8520 mL → «8.52 L», 2500 g → «2.5 kg».
String humanizeBaseQty(double qty, String baseUnit) {
  final unit = baseUnit.trim().isEmpty ? 'unidad' : baseUnit.trim();
  final key = _key(unit);
  if ((key == 'ml' || key == 'mililitro' || key == 'mililitros') && qty >= 1000) {
    return '${formatUnitQty(qty / 1000)} L';
  }
  if ((key == 'g' || key == 'gr' || key == 'gramo' || key == 'gramos') && qty >= 1000) {
    return '${formatUnitQty(qty / 1000)} kg';
  }
  return '${formatUnitQty(qty)} ${unitShortLabel(unit)}';
}

/// «1 Caja · 24 Lata · 8.52 L»; para el primer nivel, «1 Lata · 355 mL».
String presentationChainLabel(ResolvedPresentation p, String baseUnit) {
  final parts = <String>['1 ${p.unit}'];
  if (p.parent != null) {
    parts.add('${formatUnitQty(p.draft.containsQty)} ${p.parent}');
  }
  if (p.baseQty != null) {
    parts.add(humanizeBaseQty(p.baseQty!, baseUnit));
  }
  return parts.join(' · ');
}
