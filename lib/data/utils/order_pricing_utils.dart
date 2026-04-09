import '../models/sales_models.dart';

double _roundMoney(double value) => double.parse(value.toStringAsFixed(2));
double _normalizeRate(double value) => value > 1 ? (value / 100.0) : value;
double _positiveMoney(double value) =>
    value.clamp(0, double.infinity).toDouble();
const double _defaultItbisRate = 0.18;

double _catalogGrossAmount(OrderItem item) {
  final qty = item.quantity <= 0 ? 1.0 : item.quantity;
  final modifiersTotal = item.modifiers.fold<double>(
    0.0,
    (sum, modifier) => sum + (modifier.price * modifier.qty),
  );
  return _roundMoney((item.unitPrice * qty) + modifiersTotal);
}

double resolveOrderServiceRate(Order? order) {
  if (order == null) return 0;

  final subtotal = order.subtotal;
  final serviceFee = order.serviceFee;
  if (subtotal > 0 && serviceFee > 0) {
    return serviceFee / subtotal;
  }

  return 0;
}

bool isServiceIncludedInItemTotal(Order? order, OrderItem item) {
  final serviceRate = resolveOrderServiceRate(order);
  if (serviceRate <= 0 || item.isTakeout || item.taxMode != 'inclusive') {
    return false;
  }
  
  // Si la tasa original (ej: 28%) ya cubre tanto el ITBIS (ej: 18%) 
  // como el servicio (ej: 10%), entonces el servicio está incluido.
  final rate = _normalizeRate(item.taxRate);
  final originalRate = _normalizeRate(item.originalTaxRate ?? item.taxRate);
  if (originalRate >= (rate + serviceRate - 0.01)) {
    return true;
  }

  if ((rate - _defaultItbisRate).abs() < 0.01 && serviceRate > 0.05) {
    // Looks like ONLY ITBIS, no service fee in the rate.
    return false;
  }
  
  return true;
}

bool _looksLikeCombinedServiceTax(
  Order? order,
  OrderItem item,
  double rawTaxRate,
) {
  final serviceRate = resolveOrderServiceRate(order);
  return serviceRate > 0 &&
      !item.isTakeout &&
      (rawTaxRate - serviceRate - _defaultItbisRate).abs() <= 0.001;
}

double _resolveEffectiveTaxRate(Order? order, OrderItem item) {
  final rawTaxRate = _normalizeRate(item.taxRate);
  if (_looksLikeCombinedServiceTax(order, item, rawTaxRate)) {
    return _defaultItbisRate;
  }

  return rawTaxRate;
}

double _resolveExclusiveTaxAmount(
  Order? order,
  OrderItem item,
  double taxRate,
) {
  final subtotal = _roundMoney(
    item.subtotal > 0 ? item.subtotal : _catalogGrossAmount(item),
  );
  if (subtotal <= 0 || item.isTakeout) {
    return _roundMoney(item.tax);
  }

  // Si la tasa efectiva es 0 (impuesto desactivado para este origin),
  // el tax debe ser 0 sin importar lo que tenga el DB.
  if (taxRate <= 0) return 0;

  final rawTaxRate = _normalizeRate(item.taxRate);
  final expectedTax = _roundMoney(subtotal * taxRate);
  if (_looksLikeCombinedServiceTax(order, item, rawTaxRate)) {
    return expectedTax;
  }

  return _roundMoney(item.tax);
}

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

OrderItemPricingSummary summarizeItemPricing(Order? order, OrderItem item) {
  final serviceRate = resolveOrderServiceRate(order);
  final taxRate = _resolveEffectiveTaxRate(order, item);
  final serviceIncluded = isServiceIncludedInItemTotal(order, item);
  final catalogGrossAmount = _catalogGrossAmount(item);
  final isFractionalQty =
      (item.quantity - item.quantity.roundToDouble()).abs() > 0.001;
  final storedGrossAmount = _positiveMoney(item.total + item.discounts);
  final isInclusive = item.taxMode == 'inclusive' || serviceIncluded;

  // For inclusive items, the catalogGrossAmount (Menu Price) is the authoritative Gross base.
  // Using storedGrossAmount (item.total + disc) often re-grosses the discount if the total wasn't yet updated in DB.
  final effectiveGrossAmount = isInclusive
      ? (isFractionalQty ? catalogGrossAmount : (catalogGrossAmount > 0 ? catalogGrossAmount : storedGrossAmount))
      : (storedGrossAmount >= catalogGrossAmount ? storedGrossAmount : catalogGrossAmount);

  if (isInclusive) {
    final extractRate = (item.originalTaxRate ?? item.taxRate) / 100.0;
    final applyRate = taxRate; // already decimal from _resolveEffectiveTaxRate
    
    // Si la tasa de extracción original (ej: 28%) ya es mayor o igual a la suma 
    // de impuestos (ej: 18%) + servicio (ej: 10%), no añadimos el servicio al divisor 
    // porque ya está implícito en el extractRate.
    final extraServiceForDivisor = (serviceIncluded && extractRate < (applyRate + serviceRate - 0.001))
        ? serviceRate
        : 0.0;
    final divisor = 1 + extractRate + extraServiceForDivisor;

    // If it's inclusive, the discount also reduces tax and subtotal proportionally.
    final netGross = _positiveMoney(effectiveGrossAmount - item.discounts);


    // 1. Desescalar para obtener el subtotal base 
    // Usamos el divisor original (Catalog Rate) para encontrar la base "neta" del producto.
    final finalSubtotal = _roundMoney(netGross / divisor);
    
    // 2. Calcular impuestos y servicios sobre esa base neta usando la tasa REAL (Apply Rate)
    // Esto permite que si applyRate es 0 (impuesto desactivado para este área), 
    // el impuesto sea 0 sin "absorber" ese ahorro en el subtotal.
    final finalTax = _roundMoney(finalSubtotal * applyRate);
    final finalService = serviceIncluded ? _roundMoney(finalSubtotal * serviceRate) : 0.0;
    
    // 3. El total es la suma de las partes reales. 
    // Si applyRate < extractRate, el total será menor que el netGross original.
    final finalTotal = finalSubtotal + finalTax + finalService;

    return OrderItemPricingSummary(
      subtotal: finalSubtotal,
      tax: finalTax,
      discounts: _roundMoney(item.discounts),
      serviceFee: finalService,
      extraServiceFee: 0,
      total: _roundMoney(finalTotal),
    );
  }


  final expectedSubtotal = _roundMoney(catalogGrossAmount);
  final dbSubtotal = _roundMoney(item.subtotal);
  final useExpectedSubtotal =
      isFractionalQty &&
      dbSubtotal > 0 &&
      (dbSubtotal - expectedSubtotal).abs() > 0.01;
  final subtotal = _roundMoney(
    useExpectedSubtotal
        ? expectedSubtotal
        : (dbSubtotal > 0 ? dbSubtotal : expectedSubtotal),
  );
  final tax = useExpectedSubtotal && dbSubtotal > 0
      ? _roundMoney(_positiveMoney(item.tax) * (subtotal / dbSubtotal))
      : _resolveExclusiveTaxAmount(order, item, taxRate);
  final serviceFee = (serviceRate <= 0 || item.isTakeout)
      ? 0.0
      : _roundMoney(subtotal * serviceRate);
  final extraServiceFee = serviceIncluded ? 0.0 : serviceFee;
  final baseTotal = item.taxMode == 'inclusive'
      ? _roundMoney(
          item.discounts > 0
              ? _positiveMoney(effectiveGrossAmount - item.discounts)
              : effectiveGrossAmount,
        )
      : _roundMoney(subtotal + tax - item.discounts);
  final total = _roundMoney(baseTotal + extraServiceFee);

  return OrderItemPricingSummary(
    subtotal: subtotal,
    tax: tax,
    discounts: _roundMoney(item.discounts),
    serviceFee: _roundMoney(serviceFee),
    extraServiceFee: _roundMoney(extraServiceFee),
    total: total,
  );
}

double itemServiceFee(Order? order, OrderItem item) {
  return summarizeItemPricing(order, item).serviceFee;
}

double itemDisplayTotal(Order? order, OrderItem item) {
  return summarizeItemPricing(order, item).total;
}

double itemDisplayUnitPrice(Order? order, OrderItem item) {
  final qty = item.quantity <= 0 ? 1.0 : item.quantity;
  return _roundMoney(itemDisplayTotal(order, item) / qty);
}

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
  var subtotal = 0.0;
  var tax = 0.0;
  var discounts = 0.0;
  var serviceFee = 0.0;
  var extraServiceFee = 0.0;
  var total = 0.0;

  for (final item in items) {
    final itemSummary = summarizeItemPricing(order, item);

    subtotal += itemSummary.subtotal;
    tax += itemSummary.tax;
    discounts += itemSummary.discounts;
    serviceFee += itemSummary.serviceFee;
    extraServiceFee += itemSummary.extraServiceFee;
    total += itemSummary.total;
  }

  return OrderPricingSummary(
    subtotal: _roundMoney(subtotal),
    tax: _roundMoney(tax),
    discounts: _roundMoney(discounts),
    serviceFee: _roundMoney(serviceFee),
    extraServiceFee: _roundMoney(extraServiceFee),
    total: _roundMoney(total),
  );
}
