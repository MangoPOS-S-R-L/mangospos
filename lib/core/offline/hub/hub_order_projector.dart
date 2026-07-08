/// Proyector de SALÓN/ÓRDENES del Hub (H3). Reconstruye —desde el op-log del
/// Hub— qué mesas están ocupadas y el detalle de cada orden, para que el grid
/// del salón de CUALQUIER caja lea del Hub (`GET /hub/salon`, `GET /hub/order`)
/// en vez de `v_zone_table_status` de Supabase. Es la pieza que hace VISIBLE
/// entre cajas la mesa que abrió el mesero sin depender de la nube.
///
/// Es PURA (sin I/O → testeable), como [HubKitchenProjector]. El transporte
/// (endpoints + WS) y el enriquecimiento de las ops con `table_id` es H4.
///
/// Vocabulario de ops (mismo modelo de acciones de la app; en modo hub se
/// enriquecen con `table_id`/`origin` al enrutarlas al Hub):
///   - `open_table`            → asocia order_id ↔ table_id (la caja abrió una
///                               mesa). El Hub aprende el mapeo aquí.
///   - `add_item`              → agrega un ítem a su orden (si trae `table_id`
///                               y aún no se conocía, también asocia la mesa).
///   - `delete_item`           → quita el ítem.
///   - `update_item_quantity` / `update_item_notes` / `toggle_item_takeout`
///                             → actualizan el ítem.
///   - `move_item_to_check`    → cambia el ítem de subcuenta.
///   - `mark_order_takeout`    → marca toda la orden para llevar.
///   - `send_to_kitchen` / `confirm_local_order` → marca la orden enviada.
///   - `void_order`            → anula la orden (libera la mesa).
///   - `process_payment`       → cobro. Si es full-order (check_id nulo) o
///                               `close_order == true`, cierra la orden
///                               (libera la mesa). Los cobros por-subcuenta
///                               dejan la mesa ocupada hasta el cierre total.
///
/// LÍMITE (baseline): solo reconstruye órdenes CREADAS durante la ventana hub
/// (sus ops están en el op-log). Las mesas abiertas ANTES de entrar a modo hub
/// requieren un snapshot base al arrancar el Hub (paso de activación, H3/H4).
class HubOrderProjector {
  /// Detalle de una orden a partir de [ops] (order_id o table_id). Null si no
  /// hay una orden abierta que coincida.
  static HubOrderState? projectOrder(
    List<Map<String, dynamic>> ops, {
    String? orderId,
    String? tableId,
  }) {
    final byOrder = _fold(ops);
    for (final acc in byOrder.values) {
      final matchesOrder = orderId != null && acc.orderId == orderId;
      final matchesTable = tableId != null && acc.tableId == tableId;
      if (matchesOrder || matchesTable) {
        if (acc.voided) return null;
        return acc.toOrderState();
      }
    }
    return null;
  }

  /// Estado del salón: una entrada por mesa OCUPADA (orden abierta con ítems,
  /// no anulada ni totalmente pagada). Es el equivalente LAN de
  /// `v_zone_table_status` para el grid.
  static List<HubTableState> projectSalon(List<Map<String, dynamic>> ops) {
    final byOrder = _fold(ops);
    final result = <HubTableState>[];
    for (final acc in byOrder.values) {
      if (acc.tableId == null) continue; // solo mesas (no venta rápida/manual)
      if (acc.voided || acc.closed) continue;
      final liveItems = acc.items.values.toList(growable: false);
      if (liveItems.isEmpty) continue;
      result.add(HubTableState(
        tableId: acc.tableId!,
        orderId: acc.orderId,
        itemsCount: liveItems.length,
        total: acc.total,
        sentToKitchen: acc.sent,
      ));
    }
    return result;
  }

  static Map<String, _OrderAcc> _fold(List<Map<String, dynamic>> ops) {
    final sorted = [...ops]..sort((a, b) =>
        ((a['seq'] as num?)?.toInt() ?? 0)
            .compareTo((b['seq'] as num?)?.toInt() ?? 0));

    final orders = <String, _OrderAcc>{};
    _OrderAcc accFor(String orderId, Map<String, dynamic> op) {
      final acc = orders.putIfAbsent(orderId, () => _OrderAcc(orderId));
      final tableId = op['table_id']?.toString();
      if (acc.tableId == null && tableId != null && tableId.isNotEmpty) {
        acc.tableId = tableId;
      }
      return acc;
    }

    for (final op in sorted) {
      final type = op['type']?.toString();
      final orderId = op['order_id']?.toString() ?? '';
      if (orderId.isEmpty) continue;

      switch (type) {
        case 'open_table':
          accFor(orderId, op);
          break;
        case 'add_item':
          final acc = accFor(orderId, op);
          final itemId = op['item_id']?.toString() ?? '';
          if (itemId.isEmpty) break;
          acc.items[itemId] = _ItemAcc(
            id: itemId,
            productName: op['product_name']?.toString() ?? 'Producto',
            quantity: (op['qty'] as num?)?.toDouble() ??
                (op['quantity'] as num?)?.toDouble() ??
                1,
            unitPrice: (op['product_price'] as num?)?.toDouble() ??
                (op['unit_price'] as num?)?.toDouble() ??
                0,
            checkPos: op['check_pos']?.toString(),
            notes: op['notes']?.toString(),
            takeout: op['takeout'] == true || op['is_takeout'] == true,
          );
          break;
        case 'delete_item':
          orders[orderId]?.items.remove(op['item_id']?.toString());
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
          if (it != null) it.takeout = op['is_takeout'] == true;
          break;
        case 'move_item_to_check':
          final it = orders[orderId]?.items[op['item_id']?.toString()];
          if (it != null) it.checkPos = op['check_pos']?.toString();
          break;
        case 'mark_order_takeout':
          final acc = orders[orderId];
          if (acc != null) {
            for (final it in acc.items.values) {
              it.takeout = true;
            }
          }
          break;
        case 'send_to_kitchen':
        case 'confirm_local_order':
          accFor(orderId, op).sent = true;
          break;
        case 'void_order':
          orders[orderId]?.voided = true;
          break;
        case 'process_payment':
          final acc = orders[orderId];
          if (acc == null) break;
          final checkId = op['check_id']?.toString();
          final closeOrder = op['close_order'] == true;
          // Full-order (sin check) o cierre explícito → cierra/libera la mesa.
          if (checkId == null || checkId.isEmpty || closeOrder) {
            acc.closed = true;
          }
          break;
      }
    }
    return orders;
  }
}

class HubTableState {
  const HubTableState({
    required this.tableId,
    required this.orderId,
    required this.itemsCount,
    required this.total,
    required this.sentToKitchen,
  });

  final String tableId;
  final String orderId;
  final int itemsCount;
  final double total;
  final bool sentToKitchen;

  Map<String, dynamic> toJson() => {
        'table_id': tableId,
        'order_id': orderId,
        'items_count': itemsCount,
        'total': total,
        'sent_to_kitchen': sentToKitchen,
      };
}

class HubOrderItemState {
  const HubOrderItemState({
    required this.id,
    required this.productName,
    required this.quantity,
    required this.unitPrice,
    this.checkPos,
    this.notes,
    this.takeout = false,
  });

  final String id;
  final String productName;
  final double quantity;
  final double unitPrice;
  final String? checkPos;
  final String? notes;
  final bool takeout;

  Map<String, dynamic> toJson() => {
        'id': id,
        'product_name': productName,
        'quantity': quantity,
        'unit_price': unitPrice,
        if (checkPos != null) 'check_pos': checkPos,
        if (notes != null) 'notes': notes,
        'takeout': takeout,
      };
}

class HubOrderState {
  const HubOrderState({
    required this.orderId,
    required this.tableId,
    required this.items,
    required this.total,
    required this.sentToKitchen,
  });

  final String orderId;
  final String? tableId;
  final List<HubOrderItemState> items;
  final double total;
  final bool sentToKitchen;

  Map<String, dynamic> toJson() => {
        'order_id': orderId,
        if (tableId != null) 'table_id': tableId,
        'items': items.map((i) => i.toJson()).toList(growable: false),
        'total': total,
        'sent_to_kitchen': sentToKitchen,
      };
}

class _OrderAcc {
  _OrderAcc(this.orderId);
  final String orderId;
  String? tableId;
  bool sent = false;
  bool voided = false;
  bool closed = false;
  final Map<String, _ItemAcc> items = {};

  double get total {
    var t = 0.0;
    for (final it in items.values) {
      t += it.quantity * it.unitPrice;
    }
    return t;
  }

  HubOrderState toOrderState() => HubOrderState(
        orderId: orderId,
        tableId: tableId,
        items: items.values
            .map((i) => i.toState())
            .toList(growable: false),
        total: total,
        sentToKitchen: sent,
      );
}

class _ItemAcc {
  _ItemAcc({
    required this.id,
    required this.productName,
    required this.quantity,
    required this.unitPrice,
    this.checkPos,
    this.notes,
    this.takeout = false,
  });

  final String id;
  String productName;
  double quantity;
  double unitPrice;
  String? checkPos;
  String? notes;
  bool takeout;

  HubOrderItemState toState() => HubOrderItemState(
        id: id,
        productName: productName,
        quantity: quantity,
        unitPrice: unitPrice,
        checkPos: checkPos,
        notes: notes,
        takeout: takeout,
      );
}
