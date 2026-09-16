/// Pedido sugerido: de la proyección (`fn_purchase_projection`, 20260915_0004)
/// a una orden de compra por suplidor.
///
/// La base calcula CUÁNTO hace falta en unidad base. Aquí se decide lo que el
/// comprador ve y toca: empaques completos (D7), costo por unidad de compra,
/// cambio de suplidor por línea, total contra el pedido mínimo del suplidor y
/// el mensaje para mandarle el pedido. Funciones puras: la pantalla recalcula
/// en cada tecla sin ir a la base.
library;

import 'purchase_quantity.dart';
import 'unit_conversion.dart';

const double _eps = 1e-9;

double _num(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0;
}

double? _opt(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

String? _str(dynamic v) {
  final s = v?.toString().trim();
  return (s == null || s.isEmpty) ? null : s;
}

/// Una fila de `fn_purchase_projection`. Cantidades y costo en unidad BASE.
class ProjectionLine {
  final String itemId;
  final String itemName;
  final String? sku;
  final String unit;
  final String classification;
  final double stock;
  final double inTransit;
  final double onOrder;
  final double consumption;
  final int windowDays;
  final double dailyConsumption;
  final double minStock;

  /// El mínimo es el del almacén elegido (si no, el del insumo).
  final bool minStockFromWarehouse;
  final int leadTimeDays;
  final bool leadTimeIsDefault;
  final double target;
  final double suggestedBase;

  /// Días que alcanza lo que hay + lo que viene. Null sin consumo.
  final double? daysOfSupply;
  final double suggestedMinStock;
  final String? supplierId;
  final String? supplierName;

  /// 'preferido' | 'vinculo' | 'ultima_compra' | null.
  final String? supplierSource;
  final String purchaseUnit;
  final double packSize;

  /// Mínimo de compra del suplidor, en unidades de compra.
  final double? minOrderQty;
  final double? unitCostBase;

  /// 'ultima_compra' | 'lista' | 'insumo' | null.
  final String? costSource;

  const ProjectionLine({
    required this.itemId,
    required this.itemName,
    this.sku,
    this.unit = 'unidad',
    this.classification = 'simple',
    this.stock = 0,
    this.inTransit = 0,
    this.onOrder = 0,
    this.consumption = 0,
    this.windowDays = 30,
    this.dailyConsumption = 0,
    this.minStock = 0,
    this.minStockFromWarehouse = false,
    this.leadTimeDays = kDefaultSupplierLeadTimeDays,
    this.leadTimeIsDefault = true,
    this.target = 0,
    this.suggestedBase = 0,
    this.daysOfSupply,
    this.suggestedMinStock = 0,
    this.supplierId,
    this.supplierName,
    this.supplierSource,
    this.purchaseUnit = '',
    this.packSize = 1,
    this.minOrderQty,
    this.unitCostBase,
    this.costSource,
  });

  factory ProjectionLine.fromMap(Map<String, dynamic> map) {
    final pack = _opt(map['pack_size']);
    return ProjectionLine(
      itemId: map['item_id']?.toString() ?? '',
      itemName: _str(map['item_name']) ?? 'Insumo',
      sku: _str(map['sku']),
      unit: _str(map['unit']) ?? 'unidad',
      classification: _str(map['item_classification']) ?? 'simple',
      stock: _num(map['stock']),
      inTransit: _num(map['in_transit']),
      onOrder: _num(map['on_order']),
      consumption: _num(map['consumption']),
      windowDays: (_opt(map['window_days']) ?? 30).round(),
      dailyConsumption: _num(map['daily_consumption']),
      minStock: _num(map['min_stock']),
      minStockFromWarehouse: map['min_stock_source'] == 'almacen',
      leadTimeDays:
          (_opt(map['lead_time_days']) ?? kDefaultSupplierLeadTimeDays).round(),
      leadTimeIsDefault: map['lead_time_is_default'] != false,
      target: _num(map['target']),
      suggestedBase: _num(map['suggested_base']),
      daysOfSupply: _opt(map['days_of_supply']),
      suggestedMinStock: _num(map['suggested_min_stock']),
      supplierId: _str(map['supplier_id']),
      supplierName: _str(map['supplier_name']),
      supplierSource: _str(map['supplier_source']),
      purchaseUnit: _str(map['purchase_unit']) ?? '',
      packSize: (pack == null || pack <= 0) ? 1 : pack,
      minOrderQty: _opt(map['min_order_qty']),
      unitCostBase: _opt(map['unit_cost_base']),
      costSource: _str(map['cost_source']),
    );
  }

  bool get hasPack => (packSize - 1).abs() > _eps;

  bool get baseIsCountable {
    final family = unitFamily(unit);
    return family != UnitFamily.weight && family != UnitFamily.volume;
  }

  /// Unidad en la que el comprador escribe la cantidad: la de compra si hay
  /// empaque, si no la base.
  String get orderUnit {
    if (!hasPack) return unit;
    return purchaseUnit.isNotEmpty ? purchaseUnit : 'empaque';
  }

  /// Lo sugerido redondeado a empaques completos y al mínimo del suplidor.
  PurchaseRounding get rounded => roundUpToPurchase(
        suggestedBase: suggestedBase,
        packSize: packSize,
        minOrderPacks: minOrderQty,
        baseIsCountable: baseIsCountable,
      );
}

/// Lo que la pantalla necesita del suplidor (se lee con `select *`: las
/// columnas de términos pueden no existir en una base vieja).
class SuggestedOrderSupplier {
  final String id;
  final String name;
  final String? phone;
  final String? whatsapp;
  final int? leadTimeDays;
  final double? minOrderAmount;
  final bool isActive;

  const SuggestedOrderSupplier({
    required this.id,
    required this.name,
    this.phone,
    this.whatsapp,
    this.leadTimeDays,
    this.minOrderAmount,
    this.isActive = true,
  });

  factory SuggestedOrderSupplier.fromMap(Map<String, dynamic> map) {
    return SuggestedOrderSupplier(
      id: map['id']?.toString() ?? '',
      name: _str(map['name']) ?? 'Suplidor',
      phone: _str(map['phone']),
      whatsapp: _str(map['whatsapp']),
      leadTimeDays: _opt(map['lead_time_days'])?.round(),
      minOrderAmount: _opt(map['min_order_amount']),
      isActive: map['is_active'] != false,
    );
  }

  /// Número para escribirle: el de WhatsApp y, si no hay, el teléfono.
  String? get chatPhone => whatsapp ?? phone;
}

/// Lo que el comprador cambió en una línea. Null = lo que propone el sistema.
class LineEdit {
  /// Cantidad en la unidad de pedido (cajas si hay empaque).
  final double? packs;

  /// Costo por unidad de pedido (por caja si hay empaque).
  final double? costPerOrderUnit;
  final String? supplierId;
  final bool? selected;

  const LineEdit({
    this.packs,
    this.costPerOrderUnit,
    this.supplierId,
    this.selected,
  });

  LineEdit copyWith({
    double? packs,
    double? costPerOrderUnit,
    String? supplierId,
    bool? selected,
  }) {
    return LineEdit(
      packs: packs ?? this.packs,
      costPerOrderUnit: costPerOrderUnit ?? this.costPerOrderUnit,
      supplierId: supplierId ?? this.supplierId,
      selected: selected ?? this.selected,
    );
  }
}

/// Una línea ya decidida: cuánto se pide y a qué costo.
class OrderLineDraft {
  final ProjectionLine line;
  final bool selected;

  /// En unidad de pedido (cajas si hay empaque).
  final double packs;

  /// En unidad base: lo que va a la orden.
  final double baseQuantity;
  final double unitCostBase;

  /// Lo que se pide de más sobre lo sugerido, en unidad base.
  final double surplusBase;

  /// El mínimo de compra del suplidor subió la cantidad (solo sin edición).
  final bool raisedToMinimum;

  const OrderLineDraft({
    required this.line,
    required this.selected,
    required this.packs,
    required this.baseQuantity,
    required this.unitCostBase,
    required this.surplusBase,
    this.raisedToMinimum = false,
  });

  double get costPerOrderUnit =>
      line.hasPack ? unitCostBase * line.packSize : unitCostBase;

  double get subtotal => baseQuantity * unitCostBase;

  bool get willOrder => selected && baseQuantity > _eps;
}

OrderLineDraft resolveOrderLine(ProjectionLine line, LineEdit? edit) {
  final rounded = line.rounded;
  final pack = line.hasPack ? line.packSize : 1.0;
  final packs = edit?.packs ?? rounded.packs;
  final base = packs <= 0 ? 0.0 : packs * pack;
  final editedCost = edit?.costPerOrderUnit;
  final cost = editedCost != null ? editedCost / pack : (line.unitCostBase ?? 0);
  final surplus = base - line.suggestedBase;
  return OrderLineDraft(
    line: line,
    selected: edit?.selected ?? rounded.baseQuantity > _eps,
    packs: packs < 0 ? 0 : packs,
    baseQuantity: base,
    unitCostBase: cost < 0 ? 0 : cost,
    surplusBase: surplus > _eps ? surplus : 0,
    raisedToMinimum: edit?.packs == null && rounded.raisedToMinimum,
  );
}

/// La orden de un suplidor (o el grupo «sin suplidor», que no se puede crear).
class SupplierOrderDraft {
  final String? supplierId;
  final String supplierName;
  final SuggestedOrderSupplier? supplier;
  final List<OrderLineDraft> lines;
  final int leadTimeDays;

  /// El suplidor no tiene tiempo de entrega cargado: se usó el de por defecto.
  final bool leadTimeIsDefault;

  const SupplierOrderDraft({
    required this.supplierId,
    required this.supplierName,
    required this.lines,
    required this.leadTimeDays,
    required this.leadTimeIsDefault,
    this.supplier,
  });

  Iterable<OrderLineDraft> get orderLines => lines.where((l) => l.willOrder);

  int get orderLineCount => orderLines.length;

  double get subtotal =>
      orderLines.fold<double>(0, (sum, l) => sum + l.subtotal);

  double? get minOrderAmount => supplier?.minOrderAmount;

  /// Cuánto falta para el pedido mínimo del suplidor. Es un aviso: no bloquea.
  double get missingForMinimum {
    final minimum = minOrderAmount;
    if (minimum == null || minimum <= 0 || orderLineCount == 0) return 0;
    final missing = minimum - subtotal;
    return missing > 0.005 ? missing : 0;
  }

  bool get canCreate => supplierId != null && orderLineCount > 0;

  DateTime expectedDate(DateTime today) =>
      DateTime(today.year, today.month, today.day)
          .add(Duration(days: leadTimeDays));
}

/// Agrupa las líneas por suplidor (el de la edición manda sobre el resuelto).
/// Orden: por nombre de suplidor; «sin suplidor» al final.
List<SupplierOrderDraft> buildSupplierOrders({
  required List<ProjectionLine> lines,
  Map<String, LineEdit> edits = const {},
  Map<String, SuggestedOrderSupplier> suppliers = const {},
  int defaultLeadTimeDays = kDefaultSupplierLeadTimeDays,
}) {
  final groups = <String?, List<OrderLineDraft>>{};
  for (final line in lines) {
    final edit = edits[line.itemId];
    final supplierId = edit?.supplierId ?? line.supplierId;
    groups.putIfAbsent(supplierId, () => []).add(resolveOrderLine(line, edit));
  }

  final result = <SupplierOrderDraft>[];
  groups.forEach((id, drafts) {
    final supplier = id == null ? null : suppliers[id];
    String? nameFromLines;
    int? leadFromLines;
    for (final d in drafts) {
      if (id == null || d.line.supplierId != id) continue;
      nameFromLines ??= d.line.supplierName;
      if (!d.line.leadTimeIsDefault) leadFromLines ??= d.line.leadTimeDays;
    }
    final lead = supplier?.leadTimeDays ?? leadFromLines;
    result.add(
      SupplierOrderDraft(
        supplierId: id,
        supplierName: id == null
            ? 'Sin suplidor'
            : (supplier?.name ?? nameFromLines ?? 'Suplidor'),
        supplier: supplier,
        lines: drafts,
        leadTimeDays: lead ?? defaultLeadTimeDays,
        leadTimeIsDefault: lead == null,
      ),
    );
  });

  result.sort((a, b) {
    if (a.supplierId == null) return b.supplierId == null ? 0 : 1;
    if (b.supplierId == null) return -1;
    return a.supplierName.toLowerCase().compareTo(b.supplierName.toLowerCase());
  });
  return result;
}

String _date(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

/// Texto del pedido para mandárselo al suplidor. Sin costos: al suplidor se le
/// pide mercancía, el precio lo pone su factura.
String supplierOrderMessage({
  required SupplierOrderDraft order,
  String? businessName,
  String? orderNumber,
  DateTime? expectedDate,
}) {
  final b = StringBuffer()
    ..write('Hola, ${order.supplierName}. ')
    ..write(businessName == null || businessName.trim().isEmpty
        ? 'Le enviamos este pedido'
        : 'Pedido de ${businessName.trim()}')
    ..writeln(orderNumber == null ? ':' : ' ($orderNumber):');
  for (final l in order.orderLines) {
    final line = l.line;
    b.write('• ${formatUnitQty(l.packs)} ${line.orderUnit} — ${line.itemName}');
    if (line.hasPack) {
      b.write(' (${formatUnitQty(l.baseQuantity)} ${line.unit})');
    }
    b.writeln();
  }
  if (expectedDate != null) {
    b.writeln('Para el ${_date(expectedDate)}.');
  }
  b.write('Gracias.');
  return b.toString();
}

/// Enlace de WhatsApp con el pedido escrito. Null si el número no sirve. Un
/// número de 10 dígitos se toma como del plan norteamericano (809/829/849).
Uri? whatsappOrderLink(String? phone, String text) {
  final digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
  if (digits.length < 8) return null;
  final full = digits.length == 10 ? '1$digits' : digits;
  return Uri.parse('https://wa.me/$full?text=${Uri.encodeComponent(text)}');
}
