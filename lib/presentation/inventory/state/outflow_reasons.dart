// Motivos de una MERMA / salida, como los clasifica el sistema.
//
// Es el mismo criterio que usa el servidor en `fn_inventory_yield_analysis`
// (20260930_0050): el motivo guardado si es de salida; si no, «quitado de la
// cuenta» cuando la merma la generó un producto ya preparado que se sacó de
// una orden; si no, el prefijo de la nota que la app guarda siempre
// («Vencido — …»); si no, «sin motivo». Mantener los dos lados iguales: el
// filtro de Salidas y el reporte de Rendimiento tienen que contar lo mismo.
//
// Única diferencia a propósito (20260930_0051): «Consumo interno» es una
// SALIDA aquí —sale del almacén y se lista en Salidas con su chip— pero el
// rendimiento la cuenta como CONSUMO, no como merma: el papel que se usó no
// se perdió.

import 'package:flutter/material.dart';

import 'adjust_reasons.dart';
import 'inventory_state.dart';

@immutable
class OutflowReason {
  const OutflowReason(this.code, this.label, this.icon);

  final String code;
  final String label;
  final IconData icon;
}

/// Motivo de una merma generada al quitar de la cuenta un producto que ya
/// se había preparado (20260920_0002).
const kOrderRemovalReason = 'order_removal';

/// Merma vieja o cargada sin motivo reconocible.
const kUnspecifiedReason = 'unspecified';

/// Áreas que se proponen para un consumo interno. Es texto libre: estas son
/// solo las que casi todo restaurante tiene.
const kSuggestedDestinations = [
  'Baños',
  'Cocina',
  'Bar',
  'Salón',
  'Oficina',
  'Limpieza',
];

/// Los motivos, en el orden en que se muestran.
final List<OutflowReason> kOutflowReasons = [
  for (final r in kAdjustReasons.where((r) => r.isExit))
    OutflowReason(r.code, r.label, r.icon),
  const OutflowReason(
    kOrderRemovalReason,
    'Quitado de la cuenta',
    Icons.remove_shopping_cart_outlined,
  ),
  const OutflowReason(
    kUnspecifiedReason,
    'Sin motivo',
    Icons.help_outline_rounded,
  ),
];

/// Motivos de catálogo que cuentan como SALIDA (los mismos del servidor).
final Set<String> kExitReasonCodes = {
  for (final r in kAdjustReasons.where((r) => r.isExit)) r.code,
};

OutflowReason outflowReasonByCode(String code) {
  for (final r in kOutflowReasons) {
    if (r.code == code) return r;
  }
  return kOutflowReasons.last;
}

/// Clasifica una merma. [reasonCode] es `inventory_movements.reason_code`.
String outflowReasonCodeOf({
  String? reasonCode,
  String? referenceType,
  String? notes,
}) {
  if (reasonCode != null && kExitReasonCodes.contains(reasonCode)) {
    return reasonCode;
  }
  if (referenceType == 'order_item_removal') return kOrderRemovalReason;
  final text = (notes ?? '').trim();
  final dash = text.indexOf(' — ');
  final head = dash >= 0 ? text.substring(0, dash) : text;
  for (final r in kAdjustReasons.where((r) => r.isExit)) {
    if (r.label == head) return r.code;
  }
  return kUnspecifiedReason;
}

extension OutflowReasonOfMovement on InventoryMovementEntry {
  /// ¿Es una salida REGISTRADA como merma? Toda merma (`waste`) y los
  /// ajustes que restan con motivo de salida (los del ajuste de Insumos que
  /// imprimen conduce). Un conteo o una corrección no lo son.
  bool get isRegisteredOutflow =>
      movementType == 'waste' ||
      (movementType == 'adjustment' &&
          quantity < 0 &&
          reasonCode != null &&
          kExitReasonCodes.contains(reasonCode));

  /// Código del motivo, con el mismo criterio que el servidor.
  String get outflowReason => outflowReasonCodeOf(
    reasonCode: reasonCode,
    referenceType: referenceType,
    notes: notes,
  );
}
