import 'package:equatable/equatable.dart';

/// 🍳 Item de cocina (KDS)
class KitchenItem extends Equatable {
  final String id;
  final String orderId;
  final String orderNumber;
  final String productName;
  final double quantity;
  final String? notes;
  final String status; // 'pending', 'preparing', 'ready', 'served'
  final String? tableName;
  final String? waiterName;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? readyAt;
  final List<KitchenModifier> modifiers;
  final bool isTakeout;

  /// Código del área de producción (`print_area_code` del order_item).
  /// Null si el menu_item no tiene área asignada todavía. Usado por el
  /// filtro "Todos / Cocina / Bar / ..." del KDS.
  final String? areaCode;

  /// Nombre legible del área (`print_areas.name`). Null si la área
  /// no existe en la BD o si el item no tiene área asignada.
  final String? areaName;

  /// Momento en que el ítem se envió a cocina. Los ítems enviados juntos
  /// comparten este valor y forman una RONDA (comanda) en el KDS. Null =
  /// ítem legacy sin marca (cae en la ronda "legacy" de su orden).
  final DateTime? kitchenSentAt;

  const KitchenItem({
    required this.id,
    required this.orderId,
    required this.orderNumber,
    required this.productName,
    required this.quantity,
    this.notes,
    required this.status,
    this.tableName,
    this.waiterName,
    required this.createdAt,
    this.startedAt,
    this.readyAt,
    this.modifiers = const [],
    this.isTakeout = false,
    this.areaCode,
    this.areaName,
    this.kitchenSentAt,
  });

  factory KitchenItem.fromMap(Map<String, dynamic> map) {
    String? trimOrNull(dynamic raw) {
      final s = raw?.toString().trim();
      return (s == null || s.isEmpty) ? null : s;
    }

    return KitchenItem(
      id: map['id'] ?? '',
      orderId: map['order_id'] ?? '',
      orderNumber: map['order_number'] ?? '',
      productName: map['product_name'] ?? '',
      quantity: (map['quantity'] ?? 1).toDouble(),
      notes: map['notes'],
      status: map['status'] ?? 'pending',
      tableName: map['table_name'],
      waiterName: map['waiter_name'],
      createdAt: DateTime.tryParse(map['created_at'] ?? '') ?? DateTime.now(),
      startedAt: map['started_at'] != null
          ? DateTime.tryParse(map['started_at'])
          : null,
      readyAt: map['ready_at'] != null
          ? DateTime.tryParse(map['ready_at'])
          : null,
      modifiers: [],
      isTakeout: map['is_takeout'] == true,
      areaCode: trimOrNull(map['area_code']),
      areaName: trimOrNull(map['area_name']),
      kitchenSentAt: map['kitchen_sent_at'] != null
          ? DateTime.tryParse(map['kitchen_sent_at'].toString())
          : null,
    );
  }

  KitchenItem copyWith({
    String? id,
    String? orderId,
    String? orderNumber,
    String? productName,
    double? quantity,
    String? notes,
    String? status,
    String? tableName,
    String? waiterName,
    DateTime? createdAt,
    DateTime? startedAt,
    DateTime? readyAt,
    List<KitchenModifier>? modifiers,
    bool? isTakeout,
    String? areaCode,
    String? areaName,
    DateTime? kitchenSentAt,
  }) {
    return KitchenItem(
      id: id ?? this.id,
      orderId: orderId ?? this.orderId,
      orderNumber: orderNumber ?? this.orderNumber,
      productName: productName ?? this.productName,
      quantity: quantity ?? this.quantity,
      notes: notes ?? this.notes,
      status: status ?? this.status,
      tableName: tableName ?? this.tableName,
      waiterName: waiterName ?? this.waiterName,
      createdAt: createdAt ?? this.createdAt,
      startedAt: startedAt ?? this.startedAt,
      readyAt: readyAt ?? this.readyAt,
      modifiers: modifiers ?? this.modifiers,
      isTakeout: isTakeout ?? this.isTakeout,
      areaCode: areaCode ?? this.areaCode,
      areaName: areaName ?? this.areaName,
      kitchenSentAt: kitchenSentAt ?? this.kitchenSentAt,
    );
  }

  bool get isPending => status == 'pending';
  bool get isPreparing => status == 'preparing';
  bool get isReady => status == 'ready';
  bool get isServed => status == 'served';

  /// Tiempo transcurrido desde creación
  Duration get elapsedTime => DateTime.now().difference(createdAt);

  /// Tiempo en preparación
  Duration? get preparingTime {
    if (startedAt == null) return null;
    final endTime = readyAt ?? DateTime.now();
    return endTime.difference(startedAt!);
  }

  @override
  List<Object?> get props => [
    id,
    orderId,
    orderNumber,
    productName,
    quantity,
    notes,
    status,
    tableName,
    waiterName,
    createdAt,
    startedAt,
    readyAt,
    modifiers,
    isTakeout,
    areaCode,
    areaName,
    kitchenSentAt,
  ];
}

/// 🔧 Modificador de item de cocina
class KitchenModifier extends Equatable {
  final String id;
  final String name;
  final double quantity;

  const KitchenModifier({
    required this.id,
    required this.name,
    required this.quantity,
  });

  factory KitchenModifier.fromMap(Map<String, dynamic> map) {
    return KitchenModifier(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      quantity: (map['quantity'] ?? 1).toDouble(),
    );
  }

  @override
  List<Object?> get props => [id, name, quantity];
}

/// 🗂️ Área de producción configurada (`print_areas` table).
/// Usado por el dropdown de filtro del KDS. El `code` es lo que viaja
/// como `print_area_code` en order_items; el `name` es lo legible.
class KitchenArea extends Equatable {
  final String id;
  final String code;
  final String name;

  const KitchenArea({
    required this.id,
    required this.code,
    required this.name,
  });

  @override
  List<Object?> get props => [id, code, name];
}

/// 📦 Orden agrupada para KDS
class KitchenOrder extends Equatable {
  final String orderId;
  final String orderNumber;
  final String? tableName;
  final String? waiterName;
  final DateTime createdAt;
  final List<KitchenItem> items;

  /// Identifica la RONDA (comanda) dentro de una orden. Una orden con dos
  /// envíos a cocina produce dos `KitchenOrder` con el mismo `orderId` pero
  /// distinto `roundKey`, y por tanto dos tarjetas separadas en el KDS.
  final String roundKey;

  const KitchenOrder({
    required this.orderId,
    required this.orderNumber,
    this.tableName,
    this.waiterName,
    required this.createdAt,
    required this.items,
    this.roundKey = '',
  });

  /// Items pendientes
  List<KitchenItem> get pendingItems =>
      items.where((i) => i.isPending).toList();

  /// Items en preparación
  List<KitchenItem> get preparingItems =>
      items.where((i) => i.isPreparing).toList();

  /// Items listos
  List<KitchenItem> get readyItems => items.where((i) => i.isReady).toList();

  /// Todos los items están listos
  bool get allReady => items.every((i) => i.isReady || i.isServed);

  /// Tiempo transcurrido desde creación
  Duration get elapsedTime => DateTime.now().difference(createdAt);

  @override
  List<Object?> get props => [
    orderId,
    orderNumber,
    tableName,
    waiterName,
    createdAt,
    items,
    roundKey,
  ];
}
