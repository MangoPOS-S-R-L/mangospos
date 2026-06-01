import '../../../data/models/kitchen_models.dart';

/// Proyector de estado de cocina (F3c): reconstruye la lista de
/// [KitchenOrder] que ve el KDS a partir del op-log del Hub (las ops que los
/// terminales generaron sin internet). Es la pieza que el diseño llama
/// "los clientes materializan el estado desde el feed": el Hub solo guarda
/// y difunde ops; el KDS las dobla en órdenes de cocina con esta función
/// PURA (sin I/O → testeable).
///
/// Semántica (explícita y acotada — documentada porque define qué ve cocina):
///   - `add_item`            → registra un item en su orden (aún NO visible
///                             en cocina; vive en el "borrador").
///   - `send_to_kitchen` /
///     `confirm_local_order` → marca los items actuales de esa orden como
///                             `pending` (visibles en el KDS). Es el momento
///                             en que la comanda "entra a cocina".
///   - `update_item_quantity`/`update_item_notes`/`toggle_item_takeout`
///                           → actualizan el item.
///   - `delete_item`         → quita el item.
///   - `kds_item_status`     → cambia el estado (preparing/ready/served);
///                             `served` lo saca del KDS. (Op nueva para los
///                             cambios de estado del KDS sin red — su replay
///                             se agrega al activar F3c.)
///   - `void_order` / `mark_order_takeout` → anula / marca takeout la orden.
///
/// LÍMITE conocido (baseline): solo reconstruye órdenes CREADAS durante la
/// ventana offline (sus add_item están en el op-log). Las comandas que ya
/// estaban en cocina ANTES de caer internet no están en el op-log; mostrarlas
/// requeriría capturar un snapshot base al entrar a modo hub (paso de
/// activación pendiente). El caso principal —ver comandas NUEVAS sin red— sí
/// queda cubierto.
class HubKitchenProjector {
  /// Dobla [ops] (en orden seq) en órdenes de cocina visibles.
  static List<KitchenOrder> project(List<Map<String, dynamic>> ops) {
    final sorted = [...ops]..sort((a, b) =>
        ((a['seq'] as num?)?.toInt() ?? 0)
            .compareTo((b['seq'] as num?)?.toInt() ?? 0));

    final orders = <String, _OrderAcc>{};

    for (final op in sorted) {
      final type = op['type']?.toString();
      final orderId = op['order_id']?.toString() ?? '';
      if (orderId.isEmpty && type != 'kds_item_status') continue;

      switch (type) {
        case 'add_item':
          final acc = orders.putIfAbsent(orderId, () => _OrderAcc(orderId));
          final itemId = op['item_id']?.toString() ?? '';
          if (itemId.isEmpty) break;
          acc.items[itemId] = _ItemAcc(
            id: itemId,
            orderId: orderId,
            productName: op['product_name']?.toString() ?? 'Producto',
            quantity: (op['qty'] as num?)?.toDouble() ??
                (op['quantity'] as num?)?.toDouble() ??
                1,
            notes: op['notes']?.toString(),
            isTakeout: op['takeout'] == true || op['is_takeout'] == true,
            createdAt: _stamp(op),
          );
          break;
        case 'delete_item':
          final acc = orders[orderId];
          acc?.items.remove(op['item_id']?.toString());
          break;
        case 'update_item_quantity':
          final it = orders[orderId]?.items[op['item_id']?.toString()];
          if (it != null) {
            it.quantity = (op['quantity'] as num?)?.toDouble() ??
                (op['qty'] as num?)?.toDouble() ??
                it.quantity;
          }
          break;
        case 'update_item_notes':
          final it = orders[orderId]?.items[op['item_id']?.toString()];
          if (it != null) it.notes = op['notes']?.toString();
          break;
        case 'toggle_item_takeout':
          final it = orders[orderId]?.items[op['item_id']?.toString()];
          if (it != null) it.isTakeout = op['is_takeout'] == true;
          break;
        case 'send_to_kitchen':
        case 'confirm_local_order':
          final acc = orders.putIfAbsent(orderId, () => _OrderAcc(orderId));
          acc.sent = true;
          acc.sentAt ??= _stamp(op);
          break;
        case 'mark_order_takeout':
          final acc = orders[orderId];
          if (acc != null) {
            for (final it in acc.items.values) {
              it.isTakeout = true;
            }
          }
          break;
        case 'void_order':
          orders.remove(orderId);
          break;
        case 'kds_item_status':
          final targetOrder = orderId.isEmpty ? null : orders[orderId];
          final itemId = op['item_id']?.toString();
          final status = op['status']?.toString() ?? 'preparing';
          // Si no tenemos el order_id, buscamos el item en cualquier orden.
          final accs = targetOrder != null ? [targetOrder] : orders.values;
          for (final acc in accs) {
            final it = acc.items[itemId];
            if (it != null) {
              it.status = status;
              if (status == 'preparing') it.startedAt ??= _stamp(op);
              if (status == 'ready') it.readyAt ??= _stamp(op);
              break;
            }
          }
          break;
      }
    }

    // Solo órdenes enviadas a cocina, con items no servidos.
    final result = <KitchenOrder>[];
    for (final acc in orders.values) {
      if (!acc.sent) continue;
      final items = acc.items.values
          .where((i) => i.status != 'served')
          .map((i) => i.toModel())
          .toList(growable: false);
      if (items.isEmpty) continue;
      result.add(KitchenOrder(
        orderId: acc.orderId,
        orderNumber: _shortNumber(acc.orderId),
        createdAt: acc.sentAt ?? items.first.createdAt,
        items: items,
      ));
    }
    result.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return result;
  }

  static DateTime _stamp(Map<String, dynamic> op) {
    final raw = op['hub_received_at']?.toString() ??
        op['queued_at']?.toString() ??
        '';
    return DateTime.tryParse(raw) ?? DateTime.now();
  }

  /// Número de comanda legible offline: las órdenes locales no tienen número
  /// de server, así que usamos las últimas 4 del id local.
  static String _shortNumber(String orderId) {
    final clean = orderId.replaceAll('-', '');
    return clean.length <= 4
        ? clean.toUpperCase()
        : clean.substring(clean.length - 4).toUpperCase();
  }
}

class _OrderAcc {
  _OrderAcc(this.orderId);
  final String orderId;
  bool sent = false;
  DateTime? sentAt;
  final Map<String, _ItemAcc> items = {};
}

class _ItemAcc {
  _ItemAcc({
    required this.id,
    required this.orderId,
    required this.productName,
    required this.quantity,
    required this.createdAt,
    this.notes,
    this.isTakeout = false,
  });

  final String id;
  final String orderId;
  String productName;
  double quantity;
  String? notes;
  bool isTakeout;
  DateTime createdAt;
  String status = 'pending';
  DateTime? startedAt;
  DateTime? readyAt;

  KitchenItem toModel() => KitchenItem(
        id: id,
        orderId: orderId,
        orderNumber: '',
        productName: productName,
        quantity: quantity,
        notes: notes,
        status: status,
        createdAt: createdAt,
        startedAt: startedAt,
        readyAt: readyAt,
        isTakeout: isTakeout,
      );
}
