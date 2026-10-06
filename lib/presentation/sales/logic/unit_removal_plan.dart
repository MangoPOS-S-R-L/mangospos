// Reparto de las unidades que se quitan de un producto agrupado en la cuenta.
//
// El carrito junta en UNA fila todas las líneas del mismo producto: rondas
// distintas y, en «TODAS», subcuentas distintas. Antes, «Eliminar» sobre
// «6 × Presidente» borraba las seis líneas aunque el cajero quisiera quitar
// una — y como al cajero el «−» no le baja de lo ya enviado, era su única
// salida. Si ese producto era todo lo de la mesa, la cuenta quedaba vacía y
// se liberaba al salir. Esto decide exactamente qué líneas pierden unidades.

import '../../../data/models/sales_models.dart';

const double _eps = 0.0001;

/// Lo que le pasa a una línea de la cuenta al quitarle unidades.
class UnitRemovalStep {
  const UnitRemovalStep({required this.item, required this.nextQuantity});

  final OrderItem item;

  /// Con cuánto queda la línea. 0 = la línea se borra.
  final double nextQuantity;

  bool get deletesRow => nextQuantity <= _eps;

  double get removedQuantity => item.quantity - nextQuantity;
}

/// `true` si las [rows] se pueden quitar de a una unidad: más de una en total
/// y todas enteras. Una línea de 1.5 lb no se parte por unidades.
bool canRemoveByUnits(List<OrderItem> rows) {
  final total = rows.fold<double>(0, (sum, row) => sum + row.quantity);
  if (total < 2 - _eps) return false;
  return rows.every(
    (row) => (row.quantity - row.quantity.roundToDouble()).abs() < _eps,
  );
}

/// Reparte [quantity] unidades a quitar entre [rows] y devuelve SOLO las
/// líneas que cambian.
///
/// Mismo reparto que el «−» del modal (`onSaveBatch` en table_order_screen):
/// las primeras líneas quedan completas y se recorta desde la ÚLTIMA. Así
/// quitar una unidad con «−» o con «Eliminar» toca la misma línea. Si
/// [quantity] cubre todo, todas las líneas se borran.
List<UnitRemovalStep> planUnitRemoval(List<OrderItem> rows, double quantity) {
  var pending = quantity;
  final steps = <UnitRemovalStep>[];
  for (final row in rows.reversed) {
    if (pending <= _eps) break;
    if (row.quantity <= _eps) continue;
    final take = pending >= row.quantity - _eps ? row.quantity : pending;
    final next = row.quantity - take;
    steps.add(
      UnitRemovalStep(item: row, nextQuantity: next <= _eps ? 0 : next),
    );
    pending -= take;
  }
  return steps.reversed.toList(growable: false);
}

/// Aviso para el diálogo cuando las [rows] están repartidas en VARIAS
/// subcuentas: de cuál sale lo que se quita. `null` si todo está en una sola,
/// porque ahí no hay nada que avisar.
///
/// [checkName] traduce el `check_id` de una línea al nombre que el cajero ve
/// en pantalla («C2», «Juan»…).
String? describeRemovalAcrossChecks(
  List<OrderItem> rows,
  double quantity, {
  required String Function(String? checkId) checkName,
}) {
  final checkIds = rows.map((row) => row.checkId).toSet();
  if (checkIds.length < 2) return null;

  final removedByCheck = <String?, double>{};
  for (final step in planUnitRemoval(rows, quantity)) {
    final checkId = step.item.checkId;
    removedByCheck[checkId] =
        (removedByCheck[checkId] ?? 0) + step.removedQuantity;
  }
  if (removedByCheck.isEmpty) return null;

  final parts = [
    for (final entry in removedByCheck.entries)
      '${checkName(entry.key)}: ${_qtyLabel(entry.value)}',
  ];
  return 'Este producto está en varias subcuentas. '
      'Se quita de ${parts.join(' · ')}.';
}

String _qtyLabel(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
