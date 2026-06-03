// Carritos de venta rápida simultáneos — SOLO modo retail.
//
// En retail (colmado/tienda) el cajero atiende a varios clientes a la vez y
// necesita varias "ventas rápidas" abiertas en paralelo. Cada carrito es una
// sesión/orden `quick` independiente (ya soportadas server-side, igual que las
// mesas). Este provider mantiene SOLO el estado de UI de las pestañas (lista de
// carritos + cuál está activo). La creación/carga/persistencia de cada orden la
// orquesta `SalesViewModel` (que ya es dueño del `currentOrderProvider` y de la
// capa offline). El restaurante NO usa nada de esto.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Un carrito de venta rápida abierto en retail.
class RetailCart {
  /// Id local estable del carrito. Se usa también como `slotId` del snapshot
  /// offline (clave de persistencia por carrito).
  final String slotId;

  /// Id de la orden en el server (o `local-order-…` mientras está offline).
  final String? orderId;

  /// Número de pestaña ("Venta N"). Estable durante la vida del carrito.
  final int number;

  /// Nombre del cliente asignado (opcional). Si existe, es la etiqueta.
  final String? customerName;

  const RetailCart({
    required this.slotId,
    required this.number,
    this.orderId,
    this.customerName,
  });

  /// Etiqueta de la pestaña: cliente si se asignó, si no "Venta N".
  String get label {
    final name = customerName?.trim();
    return (name != null && name.isNotEmpty) ? name : 'Venta $number';
  }

  RetailCart copyWith({
    String? orderId,
    String? customerName,
    bool clearCustomer = false,
  }) =>
      RetailCart(
        slotId: slotId,
        number: number,
        orderId: orderId ?? this.orderId,
        customerName: clearCustomer ? null : (customerName ?? this.customerName),
      );

  Map<String, dynamic> toMap() => {
        'slot_id': slotId,
        'order_id': orderId,
        'number': number,
        'customer_name': customerName,
      };

  factory RetailCart.fromMap(Map<String, dynamic> map) => RetailCart(
        slotId: map['slot_id'] as String,
        orderId: map['order_id'] as String?,
        number: (map['number'] as num?)?.toInt() ?? 1,
        customerName: map['customer_name'] as String?,
      );
}

class RetailCartsState {
  final List<RetailCart> carts;
  final String? activeSlotId;

  const RetailCartsState({this.carts = const [], this.activeSlotId});

  RetailCart? get active {
    for (final c in carts) {
      if (c.slotId == activeSlotId) return c;
    }
    return null;
  }

  bool get isEmpty => carts.isEmpty;

  RetailCartsState copyWith({
    List<RetailCart>? carts,
    String? activeSlotId,
    bool clearActive = false,
  }) =>
      RetailCartsState(
        carts: carts ?? this.carts,
        activeSlotId: clearActive ? null : (activeSlotId ?? this.activeSlotId),
      );
}

class RetailCartsNotifier extends Notifier<RetailCartsState> {
  @override
  RetailCartsState build() => const RetailCartsState();

  int _nextNumber() {
    var max = 0;
    for (final c in state.carts) {
      if (c.number > max) max = c.number;
    }
    return max + 1;
  }

  /// Registra un carrito nuevo y lo deja activo. Devuelve el carrito creado.
  RetailCart addCart({required String slotId, String? orderId}) {
    final cart = RetailCart(
      slotId: slotId,
      number: _nextNumber(),
      orderId: orderId,
    );
    state = state.copyWith(
      carts: [...state.carts, cart],
      activeSlotId: slotId,
    );
    return cart;
  }

  void setActive(String slotId) {
    if (state.activeSlotId == slotId) return;
    state = state.copyWith(activeSlotId: slotId);
  }

  void setOrderId(String slotId, String orderId) {
    state = state.copyWith(carts: [
      for (final c in state.carts)
        c.slotId == slotId ? c.copyWith(orderId: orderId) : c,
    ]);
  }

  void setCustomerName(String slotId, String? name) {
    state = state.copyWith(carts: [
      for (final c in state.carts)
        c.slotId == slotId
            ? c.copyWith(customerName: name, clearCustomer: name == null)
            : c,
    ]);
  }

  /// Quita un carrito. Devuelve el slotId que debería quedar activo (otro
  /// carrito) o null si ya no queda ninguno.
  String? removeCart(String slotId) {
    final remaining =
        state.carts.where((c) => c.slotId != slotId).toList(growable: false);
    String? nextActive = state.activeSlotId;
    if (state.activeSlotId == slotId) {
      nextActive = remaining.isNotEmpty ? remaining.last.slotId : null;
    }
    state = RetailCartsState(carts: remaining, activeSlotId: nextActive);
    return nextActive;
  }

  void replaceAll(List<RetailCart> carts, String? activeSlotId) {
    state = RetailCartsState(carts: carts, activeSlotId: activeSlotId);
  }

  void clear() => state = const RetailCartsState();
}

final retailCartsProvider =
    NotifierProvider<RetailCartsNotifier, RetailCartsState>(
  RetailCartsNotifier.new,
);
