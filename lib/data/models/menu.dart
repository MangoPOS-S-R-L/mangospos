import 'package:flutter/foundation.dart' show immutable;

@immutable
class Menu {
  final String id;
  final String businessId;
  final String name;
  final String? description;
  final String? schedule;
  final bool isActive;
  final DateTime createdAt;
  final int? itemsCount; // viene desde la vista v_menus_with_counts

  const Menu({
    required this.id,
    required this.businessId,
    required this.name,
    this.description,
    this.schedule,
    required this.isActive,
    required this.createdAt,
    this.itemsCount,
  });

  factory Menu.fromMap(Map<String, dynamic> m) => Menu(
    id: m['id'] as String,
    businessId: m['business_id'] as String,
    name: m['name'] as String,
    description: m['description']?.toString(),
    schedule: m['schedule']?.toString(),
    isActive: m['is_active'] as bool? ?? true,
    createdAt:
        DateTime.tryParse(m['created_at']?.toString() ?? '') ?? DateTime.now(),
    itemsCount: m['items_count'] as int?,
  );

  Map<String, dynamic> toInsert({bool includeExtended = true}) => {
    'id': id,
    'business_id': businessId,
    'name': name,
    if (includeExtended) 'description': description,
    if (includeExtended) 'schedule': schedule,
    'is_active': isActive,
  };
}
