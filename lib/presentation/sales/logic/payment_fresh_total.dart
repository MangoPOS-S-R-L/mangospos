import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';

/// Total de los productos abiertos del alcance que se va a cobrar.
///
/// Los botones de pago pasan este total antes de recargar la cuenta. Se
/// recalcula después de la recarga para incorporar tanto aumentos como
/// reducciones. Los abonos previos los descuenta el candado de cobro en
/// PaymentSplitViewModel; descontarlos aquí también los aplicaría dos veces.
/// Null impide cobrar una orden que cambió o una subcuenta ya cerrada.
double? freshPaymentScopeTotal({
  required String expectedOrderId,
  required Order? order,
  required Iterable<OrderItem> items,
  required Iterable<OrderCheck> checks,
  String? checkId,
  String? forcedOrigin,
}) {
  if (order == null ||
      order.id != expectedOrderId ||
      order.closedAt != null ||
      const {'paid', 'closed', 'void', 'cancelled'}.contains(order.status)) {
    return null;
  }

  final scopeChecks = checks
      .where((check) => check.orderId == expectedOrderId)
      .toList(growable: false);
  if (checkId != null &&
      !scopeChecks.any((check) => check.id == checkId && !check.isClosed)) {
    return null;
  }

  final closedCheckIds = scopeChecks
      .where((check) => check.isClosed)
      .map((check) => check.id)
      .toSet();
  final scopeItems = items
      .where((item) {
        if (item.orderId != expectedOrderId ||
            item.status == 'paid' ||
            item.status == 'void' ||
            closedCheckIds.contains(item.checkId)) {
          return false;
        }
        return checkId == null || item.checkId == checkId;
      })
      .toList(growable: false);
  if (scopeItems.isEmpty) return null;

  final total = summarizeOrderPricing(
    // El cargo de envío pertenece a la orden completa. Una subcuenta tiene
    // sus propios productos y no vuelve a cobrar el envío de toda la mesa.
    checkId == null ? order : order.copyWith(deliveryFee: 0),
    scopeItems,
    forcedOrigin: forcedOrigin,
  ).total;
  return total.isFinite && total >= 0 ? total : null;
}
