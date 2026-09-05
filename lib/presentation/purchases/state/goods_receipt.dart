// El papel que produce una compra.
//
// Son DOS documentos con el mismo cuerpo (encabezado del negocio, suplidor,
// líneas y firmas) y distinto título:
//
//   - ORDEN DE COMPRA: lo que se compró. Nace al registrar la compra, antes
//     de que la mercancía entre, y declara el dinero de la factura del
//     suplidor (subtotal, ITBIS y descuento).
//   - RECEPCIÓN DE MERCANCÍA (conduce): lo que realmente llegó al almacén.
//     Es el soporte contable de la entrada de inventario.
//
// Comparten modelo a propósito: el ticket térmico, el PDF y el diálogo leen
// este mismo objeto, así que los dos papeles no pueden divergir de formato.
//
// La recepción se lee de `purchase_receptions` / `purchase_reception_lines`
// —donde la RPC dejó el SNAPSHOT de cada línea— y no del maestro de insumos:
// una reimpresión de marzo tiene que salir como salió en marzo, aunque el
// insumo se haya renombrado desde entonces.

import 'purchases_state.dart';

/// Cuál de los dos papeles de la compra es este documento.
enum PurchaseDocumentKind {
  /// Orden de compra / factura del suplidor: lo que se pidió y lo que cuesta.
  order,

  /// Conduce de recepción: lo que entró al almacén.
  reception,
}

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

  /// Cuál de los dos papeles es. Por omisión, conduce: es el que ya existía
  /// y el que emite la recepción en almacén.
  final PurchaseDocumentKind kind;

  /// Quién REALIZÓ el documento: el comprador que registró la orden. Va en la
  /// primera firma («Realizado por»). Vacío cuando no se puede resolver —el
  /// papel sale igual, con la raya en blanco para firmar a mano.
  final String issuedByName;

  /// Desglose del dinero tal como quedó guardado en la CABECERA de la orden.
  /// Solo lo lleva la orden de compra: el conduce declara mercancía, no
  /// impuestos. `null` = este documento no tiene desglose que imprimir.
  final double? subtotal;
  final double? taxTotal;
  final double? discountTotal;

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
    this.kind = PurchaseDocumentKind.reception,
    this.issuedByName = '',
    this.subtotal,
    this.taxTotal,
    this.discountTotal,
  });

  /// Orden de compra impresa, armada desde la factura guardada.
  ///
  /// Es el papel que se le entrega a quien va a recibir la mercancía: lo que
  /// se compró, a qué precio y cuánto se debe. Lleva el desglose de la
  /// cabecera —no la suma de las líneas— porque el descuento global vive ahí
  /// y el papel tiene que decir lo mismo que la factura del suplidor.
  factory GoodsReceipt.fromOrderDetail(
    PurchaseOrderDetail detail, {
    String issuedByName = '',
    String receivedByName = '',
  }) {
    final order = detail.order;
    return GoodsReceipt(
      id: order.id,
      number: order.orderNumber,
      date: order.createdAt,
      createdAt: order.createdAt,
      status: order.status,
      orderId: order.id,
      orderNumber: order.orderNumber,
      invoiceNumber: order.invoiceNumber,
      ncf: order.ncf,
      supplierName: order.supplierName,
      supplierRnc: '',
      warehouseName: order.warehouseName,
      receivedByName: receivedByName,
      notes: order.notes,
      lines: detail.lines
          .map(
            (line) => GoodsReceiptLine(
              code: line.sku,
              reference: line.description,
              description: line.itemName,
              // La orden guarda cantidades y costos en unidad BASE, igual que
              // el conduce: los dos papeles hablan en la misma unidad.
              quantity: line.quantityOrdered,
              unit: line.unit,
              unitCost: line.unitCost,
            ),
          )
          .toList(growable: false),
      kind: PurchaseDocumentKind.order,
      issuedByName: issuedByName,
      subtotal: detail.subtotal,
      taxTotal: detail.tax,
      discountTotal: detail.discount,
    );
  }

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
    String issuedByName = '',
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
      issuedByName: issuedByName,
      notes: notes,
      lines: lines,
      isReconstructed: true,
    );
  }

  /// Suma NETA de las líneas (sin impuestos). Es el total del conduce.
  double get total => lines.fold<double>(0, (sum, line) => sum + line.amount);

  double get totalUnits =>
      lines.fold<double>(0, (sum, line) => sum + line.quantity);

  bool get isOrder => kind == PurchaseDocumentKind.order;

  /// Título del papel, tal como sale impreso.
  String get documentTitle =>
      isOrder ? 'ORDEN DE COMPRA' : 'RECEPCION DE MERCANCIA';

  /// Título para 58mm, donde el papel solo da 32 columnas.
  String get shortTitle => isOrder ? 'ORDEN DE COMPRA' : 'RECEPCION';

  /// Segunda línea del título: qué es este papel dentro del negocio.
  String get documentSubtitle =>
      isOrder ? 'COMPROBANTE DE COMPRA' : 'CONDUCE DE ALMACEN';

  /// ¿Hay desglose fiscal que imprimir? Solo la orden lo trae.
  bool get hasAmountBreakdown => taxTotal != null || subtotal != null;

  /// Lo que hay que pagar. En la orden manda la cabecera (ahí vive el
  /// descuento global); en el conduce es la suma de lo que entró.
  double get grandTotal {
    if (!hasAmountBreakdown) return total;
    final base = subtotal ?? total;
    return base + (taxTotal ?? 0) - (discountTotal ?? 0);
  }

  /// Una recepción parcial deja mercancía pendiente en la orden: el conduce
  /// lo dice en la cara para que nadie archive el papel creyendo que la
  /// compra llegó completa.
  ///
  /// La ORDEN comparte esos estados ('partial' = recibida a medias) pero ahí
  /// no significa entrega parcial del documento, así que no se marca.
  bool get isPartial =>
      !isOrder && (status == 'partial' || status == 'short_closed');
}
