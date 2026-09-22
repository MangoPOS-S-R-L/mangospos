/// Motivo por el que se quita un producto de la cuenta, y qué se hace con el
/// inventario (catálogo `order_item_removal_reasons`, migración
/// 20260920_0002).
///
/// La marca [isWaste] la decide el dueño UNA vez, en frío, igual que en Toast
/// o Micros: el cajero solo escoge el motivo a las 2 de la mañana. Se puede
/// cambiar en el momento, pero el motivo ya trae la respuesta correcta.
class OrderItemRemovalReason {
  const OrderItemRemovalReason({
    required this.code,
    required this.label,
    required this.isWaste,
  });

  final String code;
  final String label;

  /// true = MERMA: el producto salió y no vuelve al inventario.
  /// false = se devuelve al inventario (no llegó a prepararse).
  final bool isWaste;

  /// Los mismos cinco que siembra la migración. Se usan cuando el servidor
  /// todavía no tiene el catálogo: sin esto, un negocio sin la migración se
  /// quedaría sin poder borrar nada.
  static const defaults = <OrderItemRemovalReason>[
    OrderItemRemovalReason(
      code: 'typo',
      label: 'Error de digitación',
      isWaste: false,
    ),
    OrderItemRemovalReason(
      code: 'changed',
      label: 'El cliente cambió de opinión',
      isWaste: false,
    ),
    OrderItemRemovalReason(
      code: 'table',
      label: 'Se cambió de mesa',
      isWaste: false,
    ),
    OrderItemRemovalReason(
      code: 'prepared',
      label: 'Ya preparado, se botó',
      isWaste: true,
    ),
    OrderItemRemovalReason(
      code: 'damaged',
      label: 'Producto en mal estado',
      isWaste: true,
    ),
  ];

  static OrderItemRemovalReason? fromRow(Map<String, dynamic> row) {
    final code = row['code']?.toString().trim() ?? '';
    final label = row['label']?.toString().trim() ?? '';
    if (code.isEmpty || label.isEmpty) return null;
    return OrderItemRemovalReason(
      code: code,
      label: label,
      isWaste: row['is_waste'] == true,
    );
  }
}

/// Lo que el cajero decidió al quitar el producto: el motivo, la nota
/// opcional y qué pasa con el inventario.
class OrderItemRemovalDecision {
  const OrderItemRemovalDecision({
    required this.reason,
    required this.isWaste,
    this.note,
  });

  final OrderItemRemovalReason reason;

  /// Puede diferir del motivo: el cajero lo cambia si ese caso fue distinto.
  final bool isWaste;
  final String? note;

  /// Lo que se guarda como motivo escrito y sale en el comprobante.
  String get text {
    final extra = note?.trim();
    return extra == null || extra.isEmpty
        ? reason.label
        : '${reason.label}: $extra';
  }

  String get inventoryLabel =>
      isWaste ? 'Merma: NO vuelve al inventario' : 'Devuelto al inventario';
}
