// Conduce de recepción de mercancía en almacén.
//
// El documento que produce una recepción: quién entregó, qué entró, en qué
// cantidad y a qué costo. Es el soporte contable de la entrada de inventario,
// así que se lee de `purchase_receptions` / `purchase_reception_lines` —donde
// la RPC dejó el SNAPSHOT de cada línea— y no del maestro de insumos: una
// reimpresión de marzo tiene que salir como salió en marzo, aunque el insumo
// se haya renombrado desde entonces.

class GoodsReceiptLine {
  /// Código del insumo (SKU) tal como estaba al recibir.
  final String code;

  /// Referencia del suplidor: la descripción que viajó en la línea de la OC.
  /// Vacía en recepciones libres.
  final String reference;

  /// Nombre del insumo al momento de recibir.
  final String description;

  /// Cantidad recibida, en unidad BASE (el ledger completo opera en base).
  final double quantity;

  final String unit;

  /// Costo unitario realmente recibido.
  final double unitCost;

  const GoodsReceiptLine({
    required this.code,
    required this.reference,
    required this.description,
    required this.quantity,
    required this.unit,
    required this.unitCost,
  });

  double get amount => quantity * unitCost;

  factory GoodsReceiptLine.fromMap(Map<String, dynamic> map) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    // El snapshot manda. Solo si la fila es anterior a la migración
    // 20260828_0001 (sin snapshot) se cae al maestro vinculado, que es lo
    // único que queda.
    final item = map['inventory_items'];
    String fallback(String key) =>
        item is Map ? (item[key]?.toString() ?? '') : '';

    final name = (map['item_name']?.toString().trim().isNotEmpty ?? false)
        ? map['item_name'].toString()
        : (fallback('name').isNotEmpty ? fallback('name') : 'Artículo');

    return GoodsReceiptLine(
      code: (map['item_sku']?.toString().trim().isNotEmpty ?? false)
          ? map['item_sku'].toString()
          : fallback('sku'),
      reference: map['description']?.toString() ?? '',
      description: name,
      quantity: toDouble(map['quantity_received']),
      unit: (map['item_unit']?.toString().trim().isNotEmpty ?? false)
          ? map['item_unit'].toString()
          : (fallback('unit').isNotEmpty ? fallback('unit') : 'unidad'),
      unitCost: toDouble(map['actual_unit_cost']),
    );
  }
}

class GoodsReceipt {
  final String id;

  /// Número del conduce (RM-00001). Vacío solo en recepciones creadas antes
  /// de que existiera la numeración.
  final String number;

  /// Fecha contable de la recepción (`reception_date`, sin hora).
  final DateTime date;

  /// Instante real en que se registró. `date` es una fecha pelada: si el
  /// conduce imprimiera la hora desde ahí, todos saldrían a las 12:00 AM.
  final DateTime createdAt;

  /// 'complete' | 'partial' | 'short_closed' | 'draft' | 'cancelled'.
  final String status;

  final String? orderId;

  /// Número de la orden de compra que se está recibiendo. Vacío = recepción
  /// libre (mercancía que entró sin OC previa).
  final String orderNumber;

  /// Número de factura del suplidor y su NCF, cuando la compra los trae.
  final String invoiceNumber;
  final String ncf;

  final String supplierName;
  final String supplierRnc;
  final String warehouseName;
  final String receivedByName;
  final String notes;

  final List<GoodsReceiptLine> lines;

  /// El documento NO sale de una recepción registrada: se armó con lo que la
  /// orden dice que se recibió. Pasa con las compras recibidas antes de que
  /// existiera el conduce. Se imprime igual —el contable necesita el papel—
  /// pero marcado, porque un documento reconstruido no puede pasar por uno
  /// firmado el día de la entrega.
  final bool isReconstructed;

  const GoodsReceipt({
    required this.id,
    required this.number,
    required this.date,
    required this.createdAt,
    required this.status,
    required this.orderId,
    required this.orderNumber,
    required this.invoiceNumber,
    required this.ncf,
    required this.supplierName,
    required this.supplierRnc,
    required this.warehouseName,
    required this.receivedByName,
    required this.notes,
    required this.lines,
    this.isReconstructed = false,
  });

  /// Conduce armado desde la ORDEN, para compras que se recibieron antes de
  /// que el sistema emitiera documento (o por la ruta vieja, que solo movía
  /// stock). Toma lo que cada línea tiene como recibido; sin número, porque
  /// un correlativo se asigna al recibir y este documento no lo vivió.
  factory GoodsReceipt.reconstructedFromOrder({
    required String orderId,
    required String orderNumber,
    required String invoiceNumber,
    required String ncf,
    required String supplierName,
    required String warehouseName,
    required DateTime date,
    required String status,
    required List<GoodsReceiptLine> lines,
    String supplierRnc = '',
    String notes = '',
  }) {
    return GoodsReceipt(
      id: orderId,
      number: '',
      date: date,
      createdAt: date,
      status: status,
      orderId: orderId,
      orderNumber: orderNumber,
      invoiceNumber: invoiceNumber,
      ncf: ncf,
      supplierName: supplierName,
      supplierRnc: supplierRnc,
      warehouseName: warehouseName,
      receivedByName: '',
      notes: notes,
      lines: lines,
      isReconstructed: true,
    );
  }

  double get total => lines.fold<double>(0, (sum, line) => sum + line.amount);

  double get totalUnits =>
      lines.fold<double>(0, (sum, line) => sum + line.quantity);

  /// Una recepción parcial deja mercancía pendiente en la orden: el conduce
  /// lo dice en la cara para que nadie archive el papel creyendo que la
  /// compra llegó completa.
  bool get isPartial => status == 'partial' || status == 'short_closed';
}
