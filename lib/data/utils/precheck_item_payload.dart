import '../models/sales_models.dart';
import 'order_pricing_utils.dart';

/// Contrato de la vista previa: `price` es unitario y `lineTotal` es el
/// importe completo, con impuestos y descuento ya aplicados. Nunca se vuelve
/// a multiplicar `lineTotal` por las unidades.
List<Map<String, dynamic>> buildPrecheckItemPayload(
  Order? order,
  Iterable<OrderItem> items, {
  String? forcedOrigin,
}) => items
    .map((item) {
      final total = summarizeItemPricing(
        order,
        item,
        forcedOrigin: forcedOrigin,
      ).total;
      return <String, dynamic>{
        'quantity': item.quantity,
        'name': item.productName,
        'price': item.quantity > 0 ? total / item.quantity : 0.0,
        'lineTotal': total,
        'amountIncludesTaxAndDiscount': true,
      };
    })
    .toList(growable: false);
