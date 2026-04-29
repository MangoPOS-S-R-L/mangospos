import 'package:mangopos/core/tax/tax_engine.dart';

import '../models/order_item_tax_line.dart';
import '../models/sales_models.dart';

double _r(double v) => double.parse(v.toStringAsFixed(2));

// ─────────────────────────────────────────────────────────────────────────────
// Resolve service rate from order-level DB values
// ─────────────────────────────────────────────────────────────────────────────

/// Devuelve la tasa efectiva de service fee de una orden (0..1).
///
/// **PRD 2:** el motor backend consolida la propina dentro de `oi.tax` y
/// deja `order.serviceFee = 0` siempre. Esa es la fuente de verdad.
/// El default ANTES era `0.10` (10%) y eso era la causa de la propina
/// fantasma post-PRD-2: cualquier orden donde `order.serviceFee = 0` (es
/// decir, todas las nuevas) recibía un 10% adicional aplicado por
/// `summarizeItemPricing` por sobre el `oi.tax` que ya incluía propina,
/// duplicando el cargo en el total.
///
/// El default ahora es **0**. Sólo se devuelve una tasa > 0 cuando la
/// orden tiene `serviceFee > 0` persistido (caso de órdenes históricas
/// pre-PRD-2 que sí tenían el concepto separado).
double resolveOrderServiceRate(Order? order) {
  if (order == null) return 0.0;
  final subtotal = order.subtotal;
  final serviceFee = order.serviceFee;
  if (subtotal > 0 && serviceFee > 0) {
    return serviceFee / subtotal;
  }
  return 0.0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Item-level pricing
// ─────────────────────────────────────────────────────────────────────────────

class OrderItemPricingSummary {
  final double subtotal;
  final double tax;
  final double discounts;
  final double serviceFee;
  final double extraServiceFee;
  final double total;

  const OrderItemPricingSummary({
    required this.subtotal,
    required this.tax,
    required this.discounts,
    required this.serviceFee,
    required this.extraServiceFee,
    required this.total,
  });
}

/// Compute the catalog gross amount for an [OrderItem].
double _itemGross(OrderItem item) {
  return catalogGrossAmount(
    unitPrice: item.unitPrice,
    quantity: item.quantity,
    modifiers: item.modifiers
        .map((m) => (price: m.price, qty: m.qty))
        .toList(growable: false),
  );
}

OrderItemPricingSummary summarizeItemPricing(Order? order, OrderItem item, {String? forcedOrigin}) {
  // PRD 2.5: modelo unificado. oi.tax ya incluye TODOS los impuestos aplicables
  // (ITBIS + Ley + cualquier otro), filtrados por apply_on_<origin> en el motor
  // backend. Ya no hay distinción tax vs service_fee a nivel item.
  //
  // Para items inclusive: el trigger backend fn_compute_item_totals extrae
  // oi.subtotal y oi.tax usando la rate consolidada (ej. 28%). Confiamos en
  // esos valores y NO recalculamos en el frontend.
  //
  // Para items con modifiers en draft: oi.subtotal puede no incluir modifiers
  // hasta que el motor backend recalcule. Usamos el gross calculado como
  // fallback en ese caso (solo para exclusive — para inclusive el gross
  // incluye tax y rompería la math).
  final grossWithModifiers = _itemGross(item);
  final dbDiscounts = _r(item.discounts);
  final fullRate = (item.originalTaxRate ?? item.taxRate) / 100.0;

  // Detectar si los modifiers en draft aún no fueron procesados por el
  // backend (oi.subtotal/oi.tax persistidos no incluyen el modifier nuevo).
  // En ese caso recomputamos en frontend para que el total mostrado en
  // draft coincida con el confirmado y no haya cambio de precio sorpresa
  // al enviar a cocina.
  final persistedGross = item.taxMode == 'inclusive'
      ? _r(item.subtotal + item.tax)
      : _r(item.subtotal);
  final modifiersOutOfSync = item.modifiers.isNotEmpty &&
      grossWithModifiers > persistedGross + 0.01;

  final double dbSubtotal;
  final double dbTax;
  if (modifiersOutOfSync) {
    if (item.taxMode == 'inclusive') {
      dbSubtotal = fullRate > 0
          ? _r(grossWithModifiers / (1 + fullRate))
          : _r(grossWithModifiers);
      dbTax = _r(grossWithModifiers - dbSubtotal);
    } else {
      dbSubtotal = _r(grossWithModifiers);
      dbTax = _r(dbSubtotal * fullRate);
    }
  } else {
    dbTax = _r(item.tax);
    if (item.taxMode == 'inclusive') {
      // Inclusive: confiar en oi.subtotal (ya extraído por trigger backend con
      // tasa consolidada). Si está en 0 (optimistic), fallback a extraer del
      // gross usando tax_rate.
      if (item.subtotal > 0) {
        dbSubtotal = _r(item.subtotal);
      } else {
        dbSubtotal = fullRate > 0
            ? _r(grossWithModifiers / (1 + fullRate))
            : _r(grossWithModifiers);
      }
    } else {
      // Exclusive: oi.subtotal es la base (sin tax).
      dbSubtotal = _r(item.subtotal > 0 ? item.subtotal : grossWithModifiers);
    }
  }

  // Compatibilidad legacy: order.serviceFee > 0 solo aparece en órdenes
  // históricas pre-PRD-2.5. Para esas, mantenemos el cálculo proporcional
  // para no romper su display. Para órdenes nuevas (post-PRD-2.5),
  // order.serviceFee = 0 y este path no aplica.
  final orderServiceFee = order?.serviceFee ?? 0;
  final orderSubtotal = order?.subtotal ?? 0;
  final legacyServiceFee = (orderServiceFee > 0.004 && orderSubtotal > 0)
      ? _r((orderServiceFee / orderSubtotal) * dbSubtotal)
      : 0.0;

  return OrderItemPricingSummary(
    subtotal: dbSubtotal,
    tax: dbTax,
    discounts: dbDiscounts,
    serviceFee: legacyServiceFee,
    extraServiceFee: 0,
    total: _r(dbSubtotal + dbTax + legacyServiceFee - dbDiscounts),
  );
}

double itemDisplayTotal(Order? order, OrderItem item) {
  final catalogGross = _itemGross(item);
  if (item.taxMode == 'inclusive') {
    return _r((catalogGross - item.discounts).clamp(0, double.infinity));
  }
  final gross = (item.modifiers.isEmpty && item.subtotal > catalogGross)
      ? item.subtotal
      : catalogGross;
  return _r((gross - item.discounts).clamp(0, double.infinity));
}

double itemDisplayUnitPrice(Order? order, OrderItem item) {
  final qty = item.quantity <= 0 ? 1.0 : item.quantity;
  return _r(itemDisplayTotal(order, item) / qty);
}

/// Total base de la línea (sin impuestos), usado en tickets/facturas para que
/// la suma de líneas coincida con el SUBTOTAL y el desglose de impuestos
/// aparezca solo en el footer (evita doble visualización en items inclusive).
double itemDisplayBaseTotal(Order? order, OrderItem item) {
  return summarizeItemPricing(order, item).subtotal;
}

double itemDisplayBaseUnitPrice(Order? order, OrderItem item) {
  final qty = item.quantity <= 0 ? 1.0 : item.quantity;
  return _r(itemDisplayBaseTotal(order, item) / qty);
}

// ─────────────────────────────────────────────────────────────────────────────
// Order-level pricing
// ─────────────────────────────────────────────────────────────────────────────

class OrderPricingSummary {
  final double subtotal;
  final double tax;
  final double discounts;
  final double serviceFee;
  final double extraServiceFee;
  final double total;
  final Map<double, double> taxDetails;

  const OrderPricingSummary({
    required this.subtotal,
    required this.tax,
    required this.discounts,
    required this.serviceFee,
    required this.extraServiceFee,
    required this.total,
    this.taxDetails = const {},
  });
}

/// Construye el desglose de impuestos a partir de las `order_item_tax_lines`
/// (PRD 2 §6.1). Agrupa por `tax_id` (estable, sobrevive renombres del
/// impuesto), suma los `amount` y usa el `taxName`/`taxRate` del primer
/// snapshot del grupo para el label.
///
/// Contrato del retorno (3 estados):
///   - `[]` (lista vacía) → la orden post-PRD-2 está validada y NO tiene
///     impuestos. Cierra el bug de Agua Dasany: items legítimamente exentos
///     no deben caer al fallback heurístico viejo (que cobraría 10% por
///     default). El caller debe respetar este vacío.
///   - `[(...)]` (lista con elementos) → desglose desde snapshot, usar tal
///     cual.
///   - `null` → orden pre-PRD-2 (tiene `oi.tax > 0` pero no hay tax_lines).
///     El caller debe caer al path heurístico de [buildOrderTaxBreakdown].
///
/// Nota sobre PRD 3 / reportes agregados: si en el futuro se agrupan tax_lines
/// de **varias órdenes** que cubran un cambio de nombre del impuesto, el
/// snapshot del primer grupo deja de ser confiable como label. Para ese caso
/// (PRD 3) hay que hacer JOIN con `taxes` y usar el nombre vigente. Acá estamos
/// en el contexto de UNA orden, así que todos los snapshots del mismo `tax_id`
/// son coherentes por construcción.
List<({String label, double amount})>? buildBreakdownFromTaxLines(
  Iterable<OrderItem> items,
) {
  final activeItems = items.where((i) => i.status != 'void');

  // Items que el motor backend ya marcó como tributantes (oi.tax > 0).
  final taxedItems = activeItems.where((i) => i.tax.abs() > 0.005).toList();

  if (taxedItems.isEmpty) {
    // Todos los items son legítimamente exentos. Devolver lista vacía
    // explícita evita el fallback heurístico viejo que cobraría propina
    // fantasma con su default de 10% (caso Agua Dasany pre-PRD-2).
    return const [];
  }

  // Si hay items con tax > 0 pero ninguno tiene tax_lines, esa orden es
  // pre-PRD-2 (creada antes del deploy de F2.2). Devolver null para que el
  // caller use el path heurístico, que sí funciona para ese caso histórico.
  final hasAnyLines = taxedItems.any((i) => i.taxLines.isNotEmpty);
  if (!hasAnyLines) return null;

  final allLines = <OrderItemTaxLine>[
    for (final item in activeItems) ...item.taxLines,
  ];

  if (allLines.isEmpty) return const [];

  // Agrupar por tax_id. Guardamos también name/rate del primer snapshot.
  final byTaxId = <String, ({String name, double rate, double amount})>{};
  for (final line in allLines) {
    final existing = byTaxId[line.taxId];
    if (existing == null) {
      byTaxId[line.taxId] = (
        name: line.taxName,
        rate: line.taxRate,
        amount: line.amount,
      );
    } else {
      byTaxId[line.taxId] = (
        name: existing.name,
        rate: existing.rate,
        amount: existing.amount + line.amount,
      );
    }
  }

  final breakdown = <({String label, double amount})>[];
  // Orden estable: por nombre alfabético para que el ticket no varíe entre
  // refrescos. Si el operador prefiere otro orden, se hace en una pasada
  // posterior (ej: ITBIS primero, propina último).
  final sortedKeys = byTaxId.keys.toList()
    ..sort((a, b) => byTaxId[a]!.name.compareTo(byTaxId[b]!.name));

  for (final taxId in sortedKeys) {
    final entry = byTaxId[taxId]!;
    final amount = _r(entry.amount);
    if (amount <= 0.004) continue;
    final pct = entry.rate % 1 == 0 ? entry.rate.toInt() : entry.rate;
    breakdown.add((label: '${entry.name} ($pct%)', amount: amount));
  }

  return breakdown;
}

List<({String label, double amount})> buildOrderTaxBreakdown(
  Order? order,
  Iterable<OrderItem> items, {
  String? forcedOrigin,
  Iterable<({String label, double amount})> configuredBreakdown = const [],
}) {
  // PRD 2: si los items vienen con tax_lines (post-deploy F2.2), usamos
  // el desglose desde snapshot. Sino, fallback al path heurístico viejo
  // que sirve para órdenes históricas pre-PRD-2.
  final fromLines = buildBreakdownFromTaxLines(items);
  if (fromLines != null) return fromLines;

  final summary = summarizeOrderPricing(order, items, forcedOrigin: forcedOrigin);
  final breakdown = <({String label, double amount})>[];

  // Agrupamos primero por displayRate para que ítems con taxRate "camuflado"
  // (28 = 18 ITBIS + 10 propina) y sin camuflar (18 puro) caigan en la misma
  // línea de "ITBIS (18%)" en vez de duplicar el renglón.
  final Map<double, double> itbisByDisplayRate = <double, double>{};
  summary.taxDetails.forEach((rate, amount) {
    if (amount <= 0.004) return;
    final displayRate = (rate == 28.0) ? 18.0 : rate;
    itbisByDisplayRate[displayRate] =
        (itbisByDisplayRate[displayRate] ?? 0) + amount;
  });

  final sortedDisplayRates = itbisByDisplayRate.keys.toList()..sort();
  for (final displayRate in sortedDisplayRates) {
    final amount = _r(itbisByDisplayRate[displayRate] ?? 0);
    if (amount <= 0.004) continue;
    final pct = displayRate % 1 == 0 ? displayRate.toInt() : displayRate;
    breakdown.add((label: 'ITBIS ($pct%)', amount: amount));
  }

  if (summary.serviceFee > 0.004) {
    final rate = (resolveOrderServiceRate(order) * 100).roundToDouble();
    final displayRate = rate > 0 ? rate : 10.0;
    final pct = displayRate % 1 == 0 ? displayRate.toInt() : displayRate;
    breakdown.add((label: 'Propina Ley ($pct%)', amount: summary.serviceFee));
  }

  return breakdown;
}

OrderPricingSummary summarizeOrderPricing(
  Order? order,
  Iterable<OrderItem> items, {
  String? forcedOrigin,
}) {
  double subtotal = 0;
  double tax = 0;
  double discounts = 0;
  double serviceFee = 0;
  double extraServiceFee = 0;

  final Map<double, double> taxGroups = {};

  for (final item in items) {
    if (item.status == 'void') continue;
    final s = summarizeItemPricing(order, item, forcedOrigin: forcedOrigin);
    
    subtotal += s.subtotal;
    tax += s.tax;
    serviceFee += s.serviceFee;
    discounts += s.discounts;
    extraServiceFee += s.extraServiceFee;
    
    final rate = item.taxRate.toDouble();
    if (rate > 0) {
      taxGroups[rate] = (taxGroups[rate] ?? 0) + s.tax;
    }
  }

  // PRD 2.5: Total = Base + Taxes + Service Fee - Discounts.
  // (El comentario anterior decía que discounts ya estaban en base/tax/service
  // pero eso era falso después del refactor de summarizeItemPricing — los
  // descuentos solo se restan en el total per-item. A nivel orden hay que
  // restar explícitamente. Sin esto, cart muestra Total inconsistente con
  // la línea "Descuento" que renderea OrderSummaryPanel/cart.)
  final finalTotal = _r(subtotal + tax + serviceFee + extraServiceFee - discounts);

  return OrderPricingSummary(
    subtotal: _r(subtotal),
    tax: _r(tax),
    discounts: _r(discounts),
    serviceFee: _r(serviceFee),
    extraServiceFee: _r(extraServiceFee),
    total: finalTotal,
    taxDetails: taxGroups.map((key, value) => MapEntry(key, _r(value))),
  );
}
