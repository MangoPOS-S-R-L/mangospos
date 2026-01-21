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
  });

  factory KitchenItem.fromMap(Map<String, dynamic> map) {
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

/// 📦 Orden agrupada para KDS
class KitchenOrder extends Equatable {
  final String orderId;
  final String orderNumber;
  final String? tableName;
  final String? waiterName;
  final DateTime createdAt;
  final List<KitchenItem> items;

  const KitchenOrder({
    required this.orderId,
    required this.orderNumber,
    this.tableName,
    this.waiterName,
    required this.createdAt,
    required this.items,
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
  ];
}
