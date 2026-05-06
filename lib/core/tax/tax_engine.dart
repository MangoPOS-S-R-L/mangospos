/// MangoPOS Tax Engine
///
/// Pure, deterministic tax calculation with support for:
/// - Multiple taxes (ITBIS, Ley, etc.)
/// - Inclusive / exclusive modes
/// - Per-origin activation (zone, manual, quick, delivery)
/// - Correct base preservation when taxes are toggled off
/// - Service fee (propina de ley) as a separate line item
library;

import 'dart:math' show max;

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

enum SaleOrigin { zone, manual, quick, delivery, unknown }

SaleOrigin parseSaleOrigin(String? raw) {
  switch (raw?.toLowerCase().trim()) {
    case 'table':
    case 'dine_in':
    case 'zone':
    case 'table_order':
      return SaleOrigin.zone;
    case 'manual':
    case 'manual_order':
      return SaleOrigin.manual;
    case 'quick':
    case 'quick_sale':
    case 'quick-sale':
      return SaleOrigin.quick;
    case 'delivery':
      return SaleOrigin.delivery;
    default:
      return SaleOrigin.unknown;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tax definition (mirrors the `taxes` table row)
// ─────────────────────────────────────────────────────────────────────────────

class TaxDef {
  final String name;

  /// Percentage rate, e.g. 18.0 for 18%.
  final double rate;
  final bool isActive;
  final bool isServiceFee;
  final bool applyOnZone;
  final bool applyOnManual;
  final bool applyOnQuick;
  final bool applyOnDelivery;
  /// PRD 6: si false, este tax NO aplica para items con is_takeout=true.
  /// Default true para taxes regulares; backfill en SQL setea a false para
  /// is_service_fee=true (preserva el skip hardcodeado).
  final bool applyOnTakeout;

  /// Si true: este impuesto se incluye en el cálculo del e-CF DGII
  /// (itbis_amount, taxable_amount, totalAmount declarado a DGII).
  /// Si false: se cobra al cliente pero NO se declara en el e-CF
  /// (uso típico: Propina Legal 10% que es a favor de empleados).
  ///
  /// Backfill SQL: default `true` para is_service_fee=false, `false` para
  /// is_service_fee=true. Cada negocio puede ajustar el toggle según su
  /// criterio contable (algunos contadores prefieren declarar la propina,
  /// otros la mantienen extra-fiscal).
  final bool includeInEcf;

  const TaxDef({
    required this.name,
    required this.rate,
    this.isActive = true,
    this.isServiceFee = false,
    this.applyOnZone = true,
    this.applyOnManual = true,
    this.applyOnQuick = true,
    this.applyOnDelivery = true,
    this.applyOnTakeout = true,
    this.includeInEcf = true,
  });

  factory TaxDef.fromMap(Map<String, dynamic> m) => TaxDef(
        name: m['name']?.toString() ?? '',
        rate: (m['rate'] as num?)?.toDouble() ?? 0,
        isActive: m['is_active'] as bool? ?? true,
        isServiceFee: m['is_service_fee'] as bool? ?? false,
        applyOnZone: m['apply_on_zone'] as bool? ?? true,
        applyOnManual: m['apply_on_manual'] as bool? ?? true,
        applyOnQuick: m['apply_on_quick'] as bool? ?? true,
        applyOnDelivery: m['apply_on_delivery'] as bool? ?? true,
        applyOnTakeout: m['apply_on_takeout'] as bool? ?? true,
        // Backfill default: ITBIS-like va al e-CF, propina-like no.
        // Si la columna no existe (DB vieja), usa el mismo default sensato.
        includeInEcf: (m['include_in_ecf'] as bool?) ??
            !((m['is_service_fee'] as bool?) ?? false),
      );

  double get rateDecimal => rate / 100.0;

  /// Whether this tax should be treated as a service-fee charge.
  ///
  /// PRD 1: eliminada la heurística por nombre/tasa. Sólo cuenta el flag
  /// explícito `is_service_fee` de la fila en `taxes`. Cualquier impuesto
  /// que deba comportarse como propina debe marcarse explícitamente en DB.
  bool get effectiveIsServiceFee => isServiceFee;

  /// Does this tax apply to the given [origin]?
  bool appliesTo(SaleOrigin origin) {
    if (!isActive) return false;
    switch (origin) {
      case SaleOrigin.zone:
        return applyOnZone;
      case SaleOrigin.manual:
        return applyOnManual;
      case SaleOrigin.quick:
        return applyOnQuick;
      case SaleOrigin.delivery:
        return applyOnDelivery;
      case SaleOrigin.unknown:
        return true; // default: apply
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Resolved tax rates for a given origin
// ─────────────────────────────────────────────────────────────────────────────

class ResolvedTaxRates {
  /// Sum of tax rates (pct) that apply to this origin, excluding service fee.
  final double effectiveTaxPct;

  /// Sum of ALL active tax rates (pct), including service fee.
  /// Used to extract the base from inclusive prices.
  final double fullTaxPct;

  /// Service fee rate (pct) if active for this origin, else 0.
  final double serviceFeePct;

  /// Whether service fee is active for this origin.
  final bool serviceFeeActive;

  const ResolvedTaxRates({
    required this.effectiveTaxPct,
    required this.fullTaxPct,
    required this.serviceFeePct,
    required this.serviceFeeActive,
  });

  double get effectiveTaxDecimal => effectiveTaxPct / 100.0;
  double get fullTaxDecimal => fullTaxPct / 100.0;
  double get serviceFeeDecimal => serviceFeePct / 100.0;

  static const zero = ResolvedTaxRates(
    effectiveTaxPct: 0,
    fullTaxPct: 0,
    serviceFeePct: 0,
    serviceFeeActive: false,
  );
}

/// Resolve which taxes apply for a given [origin] from the full [taxes] list.
ResolvedTaxRates resolveTaxRates(List<TaxDef> taxes, SaleOrigin origin) {
  double effectivePct = 0;
  double fullPct = 0;
  double serviceFeePct = 0;
  bool serviceFeeActive = false;

  for (final tx in taxes) {
    if (!tx.isActive || tx.rate <= 0) continue;

    fullPct += tx.rate;

    if (tx.effectiveIsServiceFee) {
      if (tx.appliesTo(origin)) {
        serviceFeePct = tx.rate;
        serviceFeeActive = true;
      }
      continue; // service fee is NOT included in effectiveTaxPct
    }

    if (tx.appliesTo(origin)) {
      effectivePct += tx.rate;
    }
  }

  return ResolvedTaxRates(
    effectiveTaxPct: effectivePct,
    fullTaxPct: fullPct,
    serviceFeePct: serviceFeePct,
    serviceFeeActive: serviceFeeActive,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Item-level tax result
// ─────────────────────────────────────────────────────────────────────────────

class ItemTaxResult {
  final double baseAmount;
  final double taxAmount;
  final double serviceFee;
  final double discounts;
  final double total;

  const ItemTaxResult({
    required this.baseAmount,
    required this.taxAmount,
    required this.serviceFee,
    required this.discounts,
    required this.total,
  });

  @override
  String toString() =>
      'ItemTaxResult(base=$baseAmount, tax=$taxAmount, sf=$serviceFee, disc=$discounts, total=$total)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Core calculation
// ─────────────────────────────────────────────────────────────────────────────

/// Money-safe rounding to 2 decimals.
double _r(double v) => double.parse(v.toStringAsFixed(2));

/// Calculate taxes for a single line item.
///
/// [grossAmount]     Menu price × qty + modifiers (the catalog amount).
/// [taxMode]         'inclusive' or 'exclusive'.
/// [effectiveTaxPct] Tax rate to APPLY (filtered by origin, excludes service fee).
/// [fullTaxPct]      ALL active tax rates INCLUDING service fee.
///                   Used only in inclusive mode to extract the base.
/// [serviceFeePct]   Service fee rate for this origin (0 if inactive).
/// [isTakeout]       Takeout items skip service fee.
/// [discounts]       Discount amount on this item.
ItemTaxResult calculateItemTax({
  required double grossAmount,
  required String taxMode,
  required double effectiveTaxPct,
  required double fullTaxPct,
  required double serviceFeePct,
  required bool isTakeout,
  double discounts = 0,
}) {
  final effectiveRate = effectiveTaxPct / 100.0;
  final fullRate = fullTaxPct / 100.0;
  final serviceRate = (isTakeout ? 0.0 : serviceFeePct) / 100.0;
  final disc = _r(max(discounts, 0));

  if (taxMode == 'inclusive') {
    return _calcInclusive(
      grossAmount: grossAmount,
      effectiveRate: effectiveRate,
      fullRate: fullRate,
      serviceRate: serviceRate,
      discounts: disc,
    );
  }

  return _calcExclusive(
    grossAmount: grossAmount,
    effectiveRate: effectiveRate,
    serviceRate: serviceRate,
    discounts: disc,
  );
}

/// Inclusive: the catalog price ALREADY includes all taxes.
///
/// Step 1: Extract base using the FULL rate (all taxes that were baked in).
/// Step 2: Apply only the effective tax rate to get the actual tax.
/// Step 3: When a tax is toggled off, the total DECREASES — the base stays.
ItemTaxResult _calcInclusive({
  required double grossAmount,
  required double effectiveRate,
  required double fullRate,
  required double serviceRate,
  required double discounts,
}) {
  // The divisor must use the FULL rate that was used to compose the price.
  // This ensures the base stays constant regardless of which taxes are active.
  final divisor = 1 + fullRate;
  final netGross = _r(max(grossAmount - discounts, 0));

  // Step 1: Calculate components using the full gross as reference to minimize drift
  final tax = _r(netGross * (effectiveRate / divisor));
  final service = _r(netGross * (serviceRate / divisor));

  // Step 2: The base amount ABSORBS the residue
  // This ensures that base + tax + service == netGross exactly.
  final base = _r(netGross - tax - service);

  // Step 3: Final total is the sum of these rounded components
  final total = _r(base + tax + service);

  return ItemTaxResult(
    baseAmount: base,
    taxAmount: tax,
    serviceFee: service,
    discounts: discounts,
    total: total,
  );
}

/// Exclusive: taxes are added on top of the base.
ItemTaxResult _calcExclusive({
  required double grossAmount,
  required double effectiveRate,
  required double serviceRate,
  required double discounts,
}) {
  final base = _r(grossAmount);
  final taxableBase = _r(max(base - discounts, 0));
  final tax = _r(taxableBase * effectiveRate);
  final service = _r(taxableBase * serviceRate);
  final total = _r(taxableBase + tax + service);

  return ItemTaxResult(
    baseAmount: base,
    taxAmount: tax,
    serviceFee: service,
    discounts: discounts,
    total: total,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Order-level aggregation
// ─────────────────────────────────────────────────────────────────────────────

class OrderTaxResult {
  final double subtotal;
  final double tax;
  final double serviceFee;
  final double discounts;
  final double total;

  const OrderTaxResult({
    required this.subtotal,
    required this.tax,
    required this.serviceFee,
    required this.discounts,
    required this.total,
  });

  static const zero = OrderTaxResult(
    subtotal: 0,
    tax: 0,
    serviceFee: 0,
    discounts: 0,
    total: 0,
  );
}

/// Aggregate item-level results into an order summary.
OrderTaxResult aggregateOrderTax(List<ItemTaxResult> items) {
  double subtotal = 0;
  double tax = 0;
  double serviceFee = 0;
  double discounts = 0;
  double total = 0;

  for (final item in items) {
    subtotal += item.baseAmount;
    tax += item.taxAmount;
    serviceFee += item.serviceFee;
    discounts += item.discounts;
    total += item.total;
  }

  return OrderTaxResult(
    subtotal: _r(subtotal),
    tax: _r(tax),
    serviceFee: _r(serviceFee),
    discounts: _r(discounts),
    total: _r(total),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Convenience: gross amount from item data
// ─────────────────────────────────────────────────────────────────────────────

/// Compute the catalog gross amount: (unitPrice × qty) + modifiers.
double catalogGrossAmount({
  required double unitPrice,
  required double quantity,
  required List<({double price, double qty})> modifiers,
}) {
  final q = quantity <= 0 ? 1.0 : quantity;
  final modsTotal =
      modifiers.fold<double>(0, (sum, m) => sum + (m.price * m.qty));
  return _r((unitPrice * q) + modsTotal);
}
