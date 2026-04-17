import 'package:mangopos/core/tax/tax_engine.dart';

import '../models/sales_models.dart';

double _r(double v) => double.parse(v.toStringAsFixed(2));

// ─────────────────────────────────────────────────────────────────────────────
// Resolve service rate from order-level DB values
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
  // ── Strategy: trust DB values, only recalculate service fee ──
  //
  // The DB trigger fn_compute_item_totals already computes subtotal, tax,
  // and total correctly (including modifiers). Recalculating in Flutter
  // causes drift because:
  //   1. Modifiers may not be loaded (zones_repository, reprint)
  //   2. Rounding accumulates differently than the DB
  //   3. Service fee is NOT in item.tax (it's at order level)
  //
  // So we trust item.subtotal, item.tax, item.total from DB, and only
  // compute service fee locally (since it's not stored per item).

  final dbSubtotal = _r(item.subtotal > 0 ? item.subtotal : _itemGross(item));
  final dbTax = _r(item.tax);
  final dbDiscounts = _r(item.discounts);

  // Service fee: computed from order-level rate applied to this item's subtotal
  final serviceRate = resolveOrderServiceRate(order);
  final serviceFee =
      (serviceRate > 0 && !item.isTakeout) ? _r(dbSubtotal * serviceRate) : 0.0;

  // For the "total" field we use the catalog display price (what the customer
  // pays). For inclusive items this is unitPrice × qty + modifiers; for
  // exclusive it's subtotal - discounts.  Using item.total from DB can be
  // wrong because the DB decomposes inclusive prices into subtotal+tax which
  // doesn't equal the catalog price after rounding.
  final displayTotal = itemDisplayTotal(order, item);

  return OrderItemPricingSummary(
    subtotal: dbSubtotal,
    tax: dbTax,
    discounts: dbDiscounts,
    serviceFee: serviceFee,
    extraServiceFee: 0,
    total: displayTotal,
  );
}

bool isServiceIncludedInItemTotal(Order? order, OrderItem item) {
  return item.taxMode == 'inclusive' && resolveOrderServiceRate(order) > 0;
}

double itemServiceFee(Order? order, OrderItem item) {
  return summarizeItemPricing(order, item).serviceFee;
}

double itemDisplayTotal(Order? order, OrderItem item) {
  // For ALL items: display price = unitPrice × qty + modifiers - discounts.
  // Always recalculate from unitPrice × qty because DB item.total may be
  // stale after equal splits (qty changed but trigger not re-fired).
  final qty = item.quantity <= 0 ? 1.0 : item.quantity;
  final modsTotal = item.modifiers.fold<double>(
      0, (sum, m) => sum + (m.price * m.qty));
  final calculatedGross = _r((item.unitPrice * qty) + modsTotal);

  if (item.taxMode == 'inclusive') {
    // For inclusive: the display price = catalog gross = base × (1 + fullRate).
    // When modifiers are not loaded (zones_repository), calculatedGross
    // misses modifier prices. Reconstruct from DB subtotal × (1 + originalTaxRate).
    if (item.modifiers.isEmpty && item.subtotal > 0) {
      final originalRate = (item.originalTaxRate ?? item.taxRate) / 100.0;
      final reconstructedGross = _r(item.subtotal * (1 + originalRate));
      // Only use reconstruction if it's significantly larger than calculated gross,
      // avoiding 0.01 drift from rounded subtotal bases.
      if (reconstructedGross > calculatedGross + 0.015) {
        return _r((reconstructedGross - item.discounts).clamp(0, double.infinity));
      }
    }
    return _r((calculatedGross - item.discounts).clamp(0, double.infinity));
  }
  // Exclusive: show base price without tax (tax is shown separately).
  // When modifiers are not loaded, DB subtotal already includes them.
  final gross = (item.modifiers.isEmpty && item.subtotal > calculatedGross)
      ? item.subtotal
      : calculatedGross;
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

  const OrderPricingSummary({
    required this.subtotal,
    required this.tax,
    required this.discounts,
    required this.serviceFee,
    required this.extraServiceFee,
    required this.total,
  });
}

/// Builds a per-tax breakdown for display.
///
/// Tries to use [configuredBreakdown] (from viewmodel's getTaxBreakdown).
/// Falls back to deriving from the order summary.
List<({String label, double amount})> buildOrderTaxBreakdown(
  Order? order,
  Iterable<OrderItem> items, {
  Iterable<({String label, double amount})> configuredBreakdown = const [],
}) {
  final summary = summarizeOrderPricing(order, items);
  final targetTaxTotal = _r(summary.tax + summary.serviceFee);

  final normalizedConfigured = configuredBreakdown
      .map((entry) => (label: entry.label, amount: _r(entry.amount)))
      .where((entry) => entry.amount > 0.004)
      .toList(growable: false);

  if (normalizedConfigured.isNotEmpty) {
    final configuredSum = _r(
      normalizedConfigured.fold<double>(0, (sum, entry) => sum + entry.amount),
    );
    final diff = _r(targetTaxTotal - configuredSum);

    if (diff.abs() <= 0.01) {
      final reconciled = normalizedConfigured.toList(growable: true);
      if (diff.abs() > 0.0001) {
        final last = reconciled.removeLast();
        reconciled.add((label: last.label, amount: _r(last.amount + diff)));
      }
      return reconciled;
    }
  }

  // Fallback: derive from summary values
  final fallback = <({String label, double amount})>[];
  if (summary.tax > 0.004) {
    final taxPct = summary.subtotal > 0
        ? ((summary.tax / summary.subtotal) * 100)
        : 0.0;
    final taxPctLabel = taxPct > 0
        ? ' (${taxPct.toStringAsFixed(taxPct % 1 == 0 ? 0 : 2)}%)'
        : '';
    fallback.add((label: 'ITBIS$taxPctLabel', amount: _r(summary.tax)));
  }
  if (summary.serviceFee > 0.004) {
    final servicePct = summary.subtotal > 0
        ? ((summary.serviceFee / summary.subtotal) * 100)
        : 0.0;
    final servicePctLabel = servicePct > 0
        ? ' (${servicePct.toStringAsFixed(servicePct % 1 == 0 ? 0 : 2)}%)'
        : '';
    fallback.add((
      label: 'Propina Ley$servicePctLabel',
      amount: _r(summary.serviceFee),
    ));
  }
  return fallback;
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

  final Map<double, double> taxGroups = {};
  double serviceBase = 0;

  for (final item in items) {
    if (item.status == 'void') continue;
    final s = summarizeItemPricing(order, item);
    
    subtotal += s.subtotal;
    discounts += s.discounts;
    extraServiceFee += s.extraServiceFee;
    
    // Accumulate taxable base by rate to calculate tax on the sum (prevents rounding drift)
    final rate = item.taxRate.toDouble();
    taxGroups[rate] = (taxGroups[rate] ?? 0) + s.subtotal;
    
    // Accumulate base for service fee (non-takeout items only)
    if (!item.isTakeout) {
      serviceBase += s.subtotal;
    }
  }

  // Calculate taxes from aggregated bases
  taxGroups.forEach((rate, base) {
    if (rate > 0) {
      tax += _r(base * (rate / 100.0));
    }
  });

  // Calculate service fee from aggregated base
  final serviceRate = resolveOrderServiceRate(order);
  if (serviceRate > 0) {
    serviceFee = _r(serviceBase * serviceRate); 
  }

  // Universal total formula: Base + Taxes + Service Fee - Discounts.
  final finalTotal = _r(subtotal + tax + serviceFee + extraServiceFee - discounts);

  return OrderPricingSummary(
    subtotal: _r(subtotal),
    tax: _r(tax),
    discounts: _r(discounts),
    serviceFee: _r(serviceFee),
    extraServiceFee: _r(extraServiceFee),
    total: finalTotal,
  );
}
