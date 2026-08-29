// Validación de las líneas de una transferencia entre bodegas.
//
// Vive fuera del diálogo por una razón concreta: la versión anterior recorría
// TODOS los ítems de la bodega origen y comparaba `qty > stock`. Para un ítem
// no seleccionado eso es `0 > stock`, que con existencia negativa da cierto —
// así que un artículo cuadrado en negativo, sin relación con lo que se estaba
// moviendo, tumbaba la transferencia entera. La regla correcta es que solo se
// revisa lo que se va a transferir, y esa regla merece una prueba.

import '../state/inventory_state.dart';

/// Mensaje de error de la PRIMERA línea que no se puede transferir, o `null`
/// si todo lo seleccionado tiene existencia suficiente.
///
/// [quantities] va indexado por `item.id`; una cantidad ausente, cero o
/// negativa significa "esta línea no se transfiere" y no se valida.
String? validateTransferLines({
  required List<InventoryItemSummary> items,
  required Map<String, double> quantities,
}) {
  for (final item in items) {
    final qty = quantities[item.id] ?? 0;
    // Lo que no se mueve, no se revisa. Una existencia negativa en otro
    // artículo es un problema de ese artículo.
    if (qty <= 0) continue;

    if (item.stock <= 0) {
      return '${item.name}: no hay existencia en la bodega origen '
          '(${item.stock.toStringAsFixed(2)} ${item.unit}). Ajusta ese insumo '
          'antes de transferirlo.';
    }
    if (qty > item.stock) {
      return '${item.name}: cantidad (${qty.toStringAsFixed(2)}) '
          'supera el stock (${item.stock.toStringAsFixed(2)})';
    }
  }
  return null;
}
