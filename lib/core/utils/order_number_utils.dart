/// Número corto y legible de una orden, para tickets y pantallas.
///
/// El problema que resuelve: por todo el código se hacía
/// `order.id.substring(0, 8)`. Para una orden del servidor (un uuid) eso da
/// algo útil y distinto en cada orden. Para una orden creada OFFLINE, cuyo id
/// es `local-order-<uuid>`, los primeros 8 caracteres son **siempre**
/// `local-or` — así que TODAS las órdenes offline se imprimían y se listaban
/// con el mismo número:
///
///     ORDEN: #LOCAL-OR
///     FAC-LOCAL-OR
///
/// El cajero no podía distinguir una de otra en el ticket ni en el historial.
///
/// El KDS ya lo había resuelto por su cuenta (`HubKitchenProjector._shortNumber`,
/// que usa las últimas 4 del id); esto lleva el mismo criterio al resto.
library;

/// Prefijos que la app le pone a los ids creados sin conexión. Todos empiezan
/// igual, que es justo lo que rompía el `substring(0, 8)`.
const _localPrefixes = <String>[
  'local-order-',
  'local-session-',
  'local-cash-session-',
  'offline-op-',
];

/// Número corto para mostrar/imprimir.
///
/// - Id normal del servidor (uuid): los primeros 8, **igual que siempre**. Esto
///   es a propósito: cambiarlo alteraría el número impreso en todos los tickets
///   ya emitidos y rompería la correspondencia con lo que el cajero ve en el
///   sistema.
/// - Id local (`local-order-…`): las últimas 4 del uuid, que sí distinguen una
///   orden de otra. Mismo criterio que el KDS.
/// - Id más corto que 8: se devuelve entero en vez de reventar. Antes esto era
///   un `RangeError` que tumbaba la impresión de la factura.
String shortOrderNumber(String orderId) {
  final id = orderId.trim();
  if (id.isEmpty) return '';

  for (final prefix in _localPrefixes) {
    if (id.startsWith(prefix)) {
      final resto = id.substring(prefix.length).replaceAll('-', '');
      if (resto.isEmpty) return id.toUpperCase();
      return resto.length <= 4
          ? resto.toUpperCase()
          : resto.substring(resto.length - 4).toUpperCase();
    }
  }

  return id.length <= 8 ? id.toUpperCase() : id.substring(0, 8).toUpperCase();
}
