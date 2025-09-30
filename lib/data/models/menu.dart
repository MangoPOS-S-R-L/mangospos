import 'package:meta/meta.dart';

@immutable
class Menu {
  final String id;
  final String businessId;
  final String name;
  final bool isActive;
  final DateTime createdAt;
  final int? itemsCount; // viene desde la vista v_menus_with_counts

  const Menu({
    required this.id,
    required this.businessId,
    required this.name,
    required this.isActive,
    required this.createdAt,
    this.itemsCount,
  });

  factory Menu.fromMap(Map<String, dynamic> m) => Menu(
        id: m['id'] as String,
        businessId: m['business_id'] as String,
        name: m['name'] as String,
        isActive: m['is_active'] as bool? ?? true,
        createdAt: DateTime.parse(m['created_at'] as String),
        itemsCount: m['items_count'] as int?,
  );

  Map<String, dynamic> toInsert() => {
        'id': id,
        'business_id': businessId,
        'name': name,
        'is_active': isActive,
      };
}
