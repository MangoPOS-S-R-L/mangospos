import '../../../../../../../core/inventory/unit_conversion.dart';
import 'modifiers_state.dart';

/// Una fila tal como la escribió el usuario en el formulario: texto crudo,
/// cantidad SIEMPRE en positivo y el signo aparte en [deducts].
class ModifierIngredientInput {
  final String? inventoryItemId;
  final String quantityText;
  final String unitText;

  /// `true` descuenta del inventario (queso extra); `false` lo resta de lo que
  /// la receta base del producto iba a descontar (sin queso, cambio de pan).
  final bool deducts;

  const ModifierIngredientInput({
    required this.inventoryItemId,
    required this.quantityText,
    required this.unitText,
    this.deducts = true,
  });
}

/// Convierte lo capturado en el formulario a las líneas que se guardan.
///
/// Reglas, todas heredadas del formulario de recetas menos la última:
///   1. las filas sin insumo o con cantidad 0/ilegible se ignoran (son filas
///      recién agregadas que nunca se llenaron);
///   2. la cantidad se convierte a la UNIDAD BASE del insumo — se puede
///      capturar en oz, en libras o en la unidad de compra (1 botella);
///   3. la coma decimal vale tanto como el punto (teclado dominicano);
///   4. un insumo NO se repite: la tabla tiene índice único
///      (modifier_id, inventory_item_id) y dos filas del mismo insumo
///      reventarían el guardado — gana la primera;
///   5. el signo se aplica al final: `deducts == false` guarda negativo.
List<ModifierIngredientDraft> buildModifierIngredientDrafts({
  required List<ModifierIngredientInput> rows,
  required List<ModifierInventoryItem> inventoryItems,
}) {
  ModifierInventoryItem? itemById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final item in inventoryItems) {
      if (item.id == id) return item;
    }
    return null;
  }

  final drafts = <ModifierIngredientDraft>[];
  final seen = <String>{};

  for (final row in rows) {
    final id = row.inventoryItemId;
    if (id == null || id.isEmpty) continue;

    final qty = double.tryParse(row.quantityText.trim().replaceAll(',', '.'));
    if (qty == null || qty == 0) continue;
    if (!seen.add(id)) continue;

    final item = itemById(id);
    final baseUnit = (item?.unit.trim().isNotEmpty ?? false)
        ? item!.unit.trim()
        : 'unidad';
    final fromUnit =
        row.unitText.trim().isEmpty ? baseUnit : row.unitText.trim();

    final baseQty = toBaseQuantity(
      quantity: qty.abs(),
      fromUnit: fromUnit,
      baseUnit: baseUnit,
      purchaseUnit: item?.purchaseUnit,
      packSize: item?.packSize ?? 1,
    );

    drafts.add(
      ModifierIngredientDraft(
        inventoryItemId: id,
        quantity: row.deducts ? baseQty : -baseQty,
        unit: baseUnit,
      ),
    );
  }

  return drafts;
}
