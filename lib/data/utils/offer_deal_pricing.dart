import '../models/sales_models.dart';

/// Snapshot de la oferta al venderla. No se deduce del nombre ni se vuelve a
/// consultar una promoción que pudo cambiar después de tomar la orden.
class OfferDealRule {
  const OfferDealRule(this.units, this.discount);
  final int units;
  final double discount;

  String get marker => '[DEAL_RULE:$units:${discount.toStringAsFixed(2)}]';

  double discountFor(double quantity) => double.parse(
    ((quantity / units + 0.0000001).floor() * discount).toStringAsFixed(2),
  );

  static OfferDealRule? fromNotes(String? notes) {
    final match = RegExp(
      r'^\[DEAL_RULE:(\d+):(\d+(?:\.\d+)?)\]$',
      multiLine: true,
    ).firstMatch(notes ?? '');
    if (match == null) return null;
    final units = int.tryParse(match.group(1)!);
    final discount = double.tryParse(match.group(2)!);
    if (units == null || units < 2 || discount == null || !discount.isFinite) {
      return null;
    }
    return OfferDealRule(units, discount);
  }

  /// Compatibilidad con ventas anteriores al snapshot. El catálogo genera
  /// esta etiqueta al vender (p. ej. «4x3 Presidente»). Solo se acepta cuando
  /// describe paquetes completos y su beneficio coincide con el descuento
  /// guardado, usando el precio de ESTA venta, nunca el precio actual.
  static OfferDealRule? fromLegacySale(OrderItem item) {
    if (!_isDeal(item) ||
        (item.notes ?? '').contains('[CORTESIA:') ||
        !item.quantity.isFinite ||
        item.quantity <= 0 ||
        item.quantity != item.quantity.truncateToDouble() ||
        !item.unitPrice.isFinite ||
        item.unitPrice <= 0 ||
        !item.discounts.isFinite) {
      return null;
    }
    final label = RegExp(
      r'^\s*([0-9]+)[xX×]([0-9]+)\s+',
    ).firstMatch(item.productName);
    if (label == null) return null;
    final units = int.tryParse(label.group(1)!);
    final paid = int.tryParse(label.group(2)!);
    if (units == null ||
        units < 2 ||
        units > 2147483647 ||
        paid == null ||
        paid < 1 ||
        paid >= units ||
        item.quantity < units ||
        item.quantity % units != 0) {
      return null;
    }
    final discount = double.parse(
      (item.unitPrice * (units - paid)).toStringAsFixed(2),
    );
    if (!discount.isFinite ||
        (item.discounts - item.quantity / units * discount).abs() > 0.01) {
      return null;
    }
    return OfferDealRule(units, discount);
  }
}

class OfferRuleUnavailable implements Exception {
  const OfferRuleUnavailable();
  static const message =
      'No se pudo recuperar la regla de esta oferta. '
      'Puedes retirar la oferta completa; para quitar unidades, '
      'un administrador debe revisar la venta original.';
  @override
  String toString() => message;
}

OrderItem recoverLegacyOfferRule(OrderItem item) {
  if (OfferDealRule.fromNotes(item.notes) != null) return item;
  final rule = OfferDealRule.fromLegacySale(item);
  if (rule == null) return item;
  return item.copyWith(
    notes: [
      if (item.notes?.isNotEmpty == true) item.notes!,
      rule.marker,
    ].join('\n'),
  );
}

bool _isDeal(OrderItem item) =>
    RegExp(r'^\[DEAL:[^\]]*\]$', multiLine: true).hasMatch(item.notes ?? '');

/// Descuento de ESA línea tras reducirla. Las ofertas se recalculan por
/// paquetes completos; cortesías y descuentos comunes se prorratean.
/// Sin snapshot (cliente antiguo), el backend resuelve la regla al editar.
double discountAtQuantity(OrderItem item, double quantity) {
  final courtesy = (item.notes ?? '').contains('[CORTESIA:');
  final rule = courtesy
      ? null
      : OfferDealRule.fromNotes(item.notes) ??
            OfferDealRule.fromLegacySale(item);
  if (_isDeal(item) && rule != null) return rule.discountFor(quantity);
  if (item.quantity <= 0) return 0;
  return double.parse(
    (item.discounts * quantity / item.quantity).toStringAsFixed(2),
  );
}

/// El modal representa varias filas como una. Nunca reparte el descuento de
/// una oferta entre filas que se van a borrar: cada paquete conserva el suyo.
double groupLineDiscount({
  required OrderItem item,
  required double quantity,
  required double groupDiscount,
  required double groupGross,
  bool managedOfferDiscount = true,
}) {
  if (_isDeal(item) && managedOfferDiscount) {
    return discountAtQuantity(item, quantity);
  }
  if (groupGross <= 0) return 0;
  return groupDiscount * (item.subtotal + item.tax) / groupGross;
}

double discountForGroupQuantity(List<OrderItem> items, double quantity) {
  var remaining = quantity;
  var discount = 0.0;
  for (var index = 0; index < items.length; index++) {
    final item = items[index];
    final qty = index == items.length - 1
        ? remaining
        : remaining.clamp(0, item.quantity).toDouble();
    discount += discountAtQuantity(item, qty);
    remaining = (remaining - qty).clamp(0, double.infinity).toDouble();
  }
  return discount;
}

/// Conserva la regla de cada fila al copiar las notas visibles del grupo.
String? preserveOfferRule(String? notes, OrderItem original) {
  final lines = (notes ?? '')
      .split('\n')
      .where((line) => !line.trim().startsWith('[DEAL_RULE:'))
      .where((line) => !line.trim().startsWith('[DEAL:'))
      .where((line) => line.trim().isNotEmpty)
      .toList();
  for (final line in (original.notes ?? '').split('\n')) {
    if (line.trim().startsWith('[DEAL:')) lines.add(line.trim());
  }
  final rule = OfferDealRule.fromNotes(original.notes);
  if (rule != null) lines.add(rule.marker);
  return lines.isEmpty ? null : lines.join('\n');
}
