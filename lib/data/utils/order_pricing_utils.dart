import 'package:mangopos/core/tax/tax_engine.dart';

import '../models/sales_models.dart';

double _r(double v) => double.parse(v.toStringAsFixed(2));

// ─────────────────────────────────────────────────────────────────────────────
// Resolve service rate from order-level DB values (legacy compatibility)
// ─────────────────────────────────────────────────────────────────────────────

double resolveOrderServiceRate(Order? order) {
  if (order == null) return 0;
  final subtotal = order.subtotal;
  final serviceFee = order.serviceFee;
  if (subtotal > 0 && serviceFee > 0) {
    return serviceFee / subtotal;
  }
  return 0;
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

OrderItemPricingSummary summarizeItemPricing(Order? order, OrderItem item) {
  final serviceRate = resolveOrderServiceRate(order);
  final serviceRatePct = serviceRate * 100.0;
  var effectiveTaxPct = item.taxRate;
  final fullTaxPct = item.originalTaxRate ?? item.taxRate;
  final gross = _itemGross(item);

  // Guard against double-counting: if the item's taxRate already includes the
  // service fee (e.g. taxRate=28 = ITBIS 18% + Ley 10%), adding serviceFeePct
  // on top would count the 10% twice.
  // Detection: effectiveTax + service > fullTax means service is already baked in.
  double actualServicePct = item.isTakeout ? 0 : serviceRatePct;
  if (actualServicePct > 0 &&
      (effectiveTaxPct + actualServicePct - fullTaxPct) > 0.01) {
    // Service fee is already inside effectiveTaxPct — strip it out.
    effectiveTaxPct = _r(effectiveTaxPct - actualServicePct);
    if (effectiveTaxPct < 0) effectiveTaxPct = 0;
  }

  final result = calculateItemTax(
    grossAmount: gross,
    taxMode: item.taxMode,
    effectiveTaxPct: effectiveTaxPct,
    fullTaxPct: item.taxMode == 'inclusive' ? fullTaxPct : 0,
    serviceFeePct: actualServicePct,
    isTakeout: item.isTakeout,
    discounts: item.discounts,
  );

  // For exclusive items, service fee is an "extra" line (not in the item total
  // from DB). For inclusive items, it's already extracted from the gross.
  final isExtraService =
      item.taxMode != 'inclusive' && result.serviceFee > 0;

  return OrderItemPricingSummary(
    subtotal: result.baseAmount,
    tax: result.taxAmount,
    discounts: result.discounts,
    serviceFee: result.serviceFee,
    extraServiceFee: isExtraService ? result.serviceFee : 0,
    total: result.total,
  );
}

bool isServiceIncludedInItemTotal(Order? order, OrderItem item) {
  return item.taxMode == 'inclusive' && resolveOrderServiceRate(order) > 0;
}

double itemServiceFee(Order? order, OrderItem item) {
  return summarizeItemPricing(order, item).serviceFee;
}

double itemDisplayTotal(Order? order, OrderItem item) {
  if (item.taxMode == 'inclusive') {
    // For inclusive items, the catalog/menu price IS the display price.
    // Recomposing base+tax causes drift when order.serviceFee is stale.
    final gross = _itemGross(item);
    return _r((gross - item.discounts).clamp(0, double.infinity));
  }
  return summarizeItemPricing(order, item).total;
}

double itemDisplayUnitPrice(Order? order, OrderItem item) {
  final qty = item.quantity <= 0 ? 1.0 : item.quantity;
  return _r(itemDisplayTotal(order, item) / qty);
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

  const OrderPricingSummary({
    required this.subtotal,
    required this.tax,
    required this.discounts,
    required this.serviceFee,
    required this.extraServiceFee,
    required this.total,
  });
}

OrderPricingSummary summarizeOrderPricing(
  Order? order,
  Iterable<OrderItem> items,
) {
  double subtotal = 0;
  double tax = 0;
  double discounts = 0;
  double serviceFee = 0;
  double extraServiceFee = 0;
  double total = 0;

  for (final item in items) {
    if (item.status == 'void') continue;
    final s = summarizeItemPricing(order, item);
    subtotal += s.subtotal;
    tax += s.tax;
    discounts += s.discounts;
    serviceFee += s.serviceFee;
    extraServiceFee += s.extraServiceFee;
    total += s.total;
  }

  return OrderPricingSummary(
    subtotal: _r(subtotal),
    tax: _r(tax),
    discounts: _r(discounts),
    serviceFee: _r(serviceFee),
    extraServiceFee: _r(extraServiceFee),
    total: _r(total),
  );
}
