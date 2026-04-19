import 'package:mangopos/core/tax/tax_engine.dart';

import '../models/sales_models.dart';

double _r(double v) => double.parse(v.toStringAsFixed(2));

// ─────────────────────────────────────────────────────────────────────────────
// Resolve service rate from order-level DB values
// ─────────────────────────────────────────────────────────────────────────────

double resolveOrderServiceRate(Order? order) {
  if (order == null) return 0.10; // Default 10%
  final subtotal = order.subtotal;
  final serviceFee = order.serviceFee;
  if (subtotal > 0 && serviceFee > 0) {
    return serviceFee / subtotal;
  }
  return 0.10; // Default 10%
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
  final dbSubtotal = _r(item.subtotal > 0 ? item.subtotal : _itemGross(item));
  final dbTax = _r(item.tax);
  final dbDiscounts = _r(item.discounts);

  final displayTotal = itemDisplayTotal(order, item);

  if (item.taxMode == 'inclusive') {
    final origin = parseSaleOrigin(forcedOrigin ?? 'zone');
    final orderServicePct = resolveOrderServiceRate(order) * 100.0;
    
    double effectiveTaxPct = item.taxRate;
    double fullTaxPct = item.originalTaxRate ?? (effectiveTaxPct + (item.isTakeout ? 0.0 : orderServicePct));
    
    // Si el ITBIS llegó como 28% camuflado, lo corregimos a 18% para el desglose
    if (effectiveTaxPct >= 27.9) {
       effectiveTaxPct = 18.0;
       fullTaxPct = 28.0;
    }

    // Calculamos SIEMPRE con la tasa completa (28%) para extraer la base real (39.06)
    final serviceFeePct = (fullTaxPct - effectiveTaxPct).abs() > 0.01 
        ? (fullTaxPct - effectiveTaxPct) 
        : (item.isTakeout ? 0.0 : orderServicePct);

    final inclusiveResult = calculateItemTax(
      grossAmount: _r(displayTotal + dbDiscounts),
      taxMode: 'inclusive',
      effectiveTaxPct: effectiveTaxPct,
      fullTaxPct: fullTaxPct,
      serviceFeePct: serviceFeePct,
      isTakeout: item.isTakeout,
      discounts: dbDiscounts,
    );

    // Ahora decidimos si mostramos/cobramos la ley según el origen
    bool shouldShowServiceFee = !item.isTakeout && origin != SaleOrigin.quick && origin != SaleOrigin.delivery;
    
    final finalServiceFee = shouldShowServiceFee ? inclusiveResult.serviceFee : 0.0;
    final finalTotal = _r(inclusiveResult.baseAmount + inclusiveResult.taxAmount + finalServiceFee);

    return OrderItemPricingSummary(
      subtotal: _r(inclusiveResult.baseAmount),
      tax: _r(inclusiveResult.taxAmount),
      discounts: dbDiscounts,
      serviceFee: _r(finalServiceFee),
      extraServiceFee: 0,
      total: finalTotal,
    );
  }

  final serviceRate = resolveOrderServiceRate(order);
  final serviceFee =
      (serviceRate > 0 && !item.isTakeout) ? _r(dbSubtotal * serviceRate) : 0.0;

  return OrderItemPricingSummary(
    subtotal: dbSubtotal,
    tax: dbTax,
    discounts: dbDiscounts,
    serviceFee: serviceFee,
    extraServiceFee: 0,
    total: _r(dbSubtotal + dbTax + serviceFee - dbDiscounts),
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

List<({String label, double amount})> buildOrderTaxBreakdown(
  Order? order,
  Iterable<OrderItem> items, {
  String? forcedOrigin,
  Iterable<({String label, double amount})> configuredBreakdown = const [],
}) {
  final summary = summarizeOrderPricing(order, items, forcedOrigin: forcedOrigin);
  final breakdown = <({String label, double amount})>[];

  summary.taxDetails.forEach((rate, amount) {
    if (amount > 0.004) {
      final displayRate = (rate == 28.0) ? 18.0 : rate;
      final pct = displayRate % 1 == 0 ? displayRate.toInt() : displayRate;
      breakdown.add((label: 'ITBIS ($pct%)', amount: amount));
    }
  });

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

  // Universal total formula: Base + Taxes + Service Fee.
  // Discounts are already included in the base/tax/service components of each item
  // so we don't subtract them again here.
  final finalTotal = _r(subtotal + tax + serviceFee + extraServiceFee);

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
