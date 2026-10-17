import 'package:equatable/equatable.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';

import 'payment_fresh_total.dart';

class PrecheckChangedException implements Exception {
  const PrecheckChangedException();

  @override
  String toString() =>
      'La cuenta cambió mientras se preparaba la precuenta. '
      'Revisa los productos y vuelve a tocar Pre-Cuenta.';
}

/// Cuenta que se preparó para una precuenta, mientras se esperan metadatos
/// y se elige la impresora. Validar [matches] antes de despacharla impide
/// imprimir esa copia si el contenido de la cuenta cambió durante la espera.
/// No reserva el precio para un cobro posterior: ese cobro recarga su cuenta.
class PrecheckSnapshot extends Equatable {
  final Order order;
  final List<OrderItem> items;
  final OrderPricingSummary summary;
  final String? checkId;
  final String? origin;
  final String? customerName;

  const PrecheckSnapshot._({
    required this.order,
    required this.items,
    required this.summary,
    required this.checkId,
    required this.origin,
    required this.customerName,
  });

  /// Null indica que se navegó a otra cuenta, el alcance ya se cerró o no
  /// quedan productos abiertos. El envío se cobra sólo en la orden completa.
  static PrecheckSnapshot? capture(
    CurrentOrderState state, {
    required String expectedOrderId,
    required String? checkId,
  }) {
    if (state.selectedCheckId != checkId) return null;
    final total = freshPaymentScopeTotal(
      expectedOrderId: expectedOrderId,
      order: state.order,
      items: state.items,
      checks: state.checks,
      checkId: checkId,
      forcedOrigin: state.origin,
    );
    if (total == null) return null;

    final sourceOrder = state.order!;
    final order = checkId == null
        ? sourceOrder
        : sourceOrder.copyWith(deliveryFee: 0);
    final closedCheckIds = state.checks
        .where((check) => check.orderId == expectedOrderId && check.isClosed)
        .map((check) => check.id)
        .toSet();
    final items = List<OrderItem>.unmodifiable(
      state.items
          .where(
            (item) =>
                item.orderId == expectedOrderId &&
                item.status != 'paid' &&
                item.status != 'void' &&
                !closedCheckIds.contains(item.checkId) &&
                (checkId == null || item.checkId == checkId),
          )
          .map(
            (item) => item.copyWith(
              modifiers: List.unmodifiable(item.modifiers),
              taxLines: List.unmodifiable(item.taxLines),
            ),
          ),
    );

    return PrecheckSnapshot._(
      order: order,
      items: items,
      summary: summarizeOrderPricing(order, items, forcedOrigin: state.origin),
      checkId: checkId,
      origin: state.origin,
      customerName: state.customerName,
    );
  }

  bool matches(CurrentOrderState live) {
    final current = capture(live, expectedOrderId: order.id, checkId: checkId);
    return current != null && this == current;
  }

  // La cocina puede pasar de preparing a ready durante la preparación de
  // la precuenta. Ese avance y su versión no cambian lo que se imprime.
  // Paid/void sí invalidan el alcance porque capture los excluye arriba.
  List<OrderItem> get _comparableItems {
    final comparable = items.map((item) {
      final modifiers = item.modifiers.toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      final taxLines = item.taxLines.toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      return item.copyWith(
        status: 'open',
        version: 0,
        modifiers: modifiers,
        taxLines: taxLines,
      );
    }).toList()..sort((a, b) => a.id.compareTo(b.id));
    return comparable;
  }

  @override
  List<Object?> get props => [
    order.copyWith(status: 'open', version: 0),
    order.origin,
    checkId,
    origin,
    customerName,
    _comparableItems,
  ];
}
