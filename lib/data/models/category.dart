class Category {
  final String id;
  final String businessId;
  final String name;
  final int position;
  final bool isActive;
  final DateTime? createdAt;

  const Category({
    required this.id,
    required this.businessId,
    required this.name,
    required this.position,
    required this.isActive,
    this.createdAt,
  });

  factory Category.fromMap(Map<String, dynamic> m) => Category(
        id: m['id'] as String,
        businessId: m['business_id'] as String,
        name: m['name'] as String,
        position: (m['position'] ?? 0) as int,
        isActive: (m['is_active'] ?? true) as bool,
        createdAt: m['created_at'] == null ? null : DateTime.parse(m['created_at']),
      );

  Map<String, dynamic> toInsert() => {
        'id': id,
        'business_id': businessId,
        'name': name,
        'position': position,
        'is_active': isActive,
      };
}
