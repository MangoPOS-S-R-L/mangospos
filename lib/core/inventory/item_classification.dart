/// Clases de insumo (`inventory_items.item_classification`).
///
/// El CHECK de la base (20260516_0003, ampliado en 20260930_0051) tiene que
/// aceptar los mismos códigos: si agregas uno aquí, amplía también el CHECK.
///
/// Antes cada pantalla tenía su propia copia de las etiquetas y, al sumar una
/// clase, las que nadie tocó la mostraban como «Simple».
abstract final class ItemClassification {
  static const simple = 'simple';
  static const rawMaterial = 'raw_material';
  static const finishedProduct = 'finished_product';
  static const combo = 'combo';
  static const service = 'service';

  /// Gastable / suministro: se compra y se CONSUME en la operación (papel
  /// higiénico, servilletas, cloro, fundas). No se vende. Sale del almacén
  /// como «Consumo interno».
  static const supply = 'supply';

  /// Menaje / utensilio: se reutiliza y se controla por cantidad (copas,
  /// platos, cubiertos, ollas, cuchillos). No se consume: sale por rotura o
  /// pérdida y se repone hasta el par (el mínimo). Nunca va en una receta —
  /// cada venta descontaría copas.
  static const smallware = 'smallware';

  /// Las que se muestran al elegir, en este orden.
  static const all = [
    simple,
    rawMaterial,
    finishedProduct,
    supply,
    smallware,
    combo,
    service,
  ];

  /// Lo que el negocio compra y NO vende: tiene su propio panel y no entra
  /// en el rendimiento de la comida.
  static bool isNonSale(String? value) => value == supply || value == smallware;

  static bool isKnown(String? value) => all.contains(value);
}

/// Etiqueta en español. [simpleLabel] cambia cómo se nombra la clase por
/// defecto (en la ficha de ajuste es «Insumo», en los filtros «Simple»).
String itemClassificationLabel(
  String? value, {
  String simpleLabel = 'Simple',
}) => switch (value) {
  ItemClassification.rawMaterial => 'Materia prima',
  ItemClassification.finishedProduct => 'Producto terminado',
  ItemClassification.combo => 'Combo',
  ItemClassification.service => 'Servicio',
  ItemClassification.supply => 'Gastable',
  ItemClassification.smallware => 'Menaje / utensilio',
  _ => simpleLabel,
};

/// Qué significa cada clase, para el formulario del insumo.
String itemClassificationHint(String? value) => switch (value) {
  ItemClassification.rawMaterial =>
    'Materia prima: entra por compras y sale al producir productos '
        'terminados o al venderse como insumo.',
  ItemClassification.finishedProduct =>
    'Producto terminado: se genera por órdenes de producción a partir de '
        'materias primas.',
  ItemClassification.combo =>
    'Combo: paquete compuesto por otros items. No requiere transformación '
        'física.',
  ItemClassification.service =>
    'Servicio: no afecta el stock físico (ej. delivery, instalación, '
        'asesoría).',
  ItemClassification.supply =>
    'Gastable: se compra y se usa en el negocio, no se vende (papel '
        'higiénico, servilletas, cloro, fundas). Sale del almacén como '
        '«Consumo interno».',
  ItemClassification.smallware =>
    'Menaje: se reutiliza y se cuenta por piezas (copas, platos, ollas, '
        'cuchillos). Sale por rotura o pérdida. El mínimo es el PAR: cuántas '
        'debe haber. No se puede usar en recetas.',
  _ =>
    'Item genérico — no participa en flujos de producción. Comportamiento '
        'legacy.',
};
