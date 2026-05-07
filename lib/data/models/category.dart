class Category {
  final String id;
  final String businessId;
  final String name;
  final int position;
  final bool isActive;
  final String? color; // Hex string e.g. '#FF0000'
  final DateTime? createdAt;

  const Category({
    required this.id,
    required this.businessId,
    required this.name,
    required this.position,
    required this.isActive,
    this.color,
    this.createdAt,
  });

  factory Category.fromMap(Map<String, dynamic> m) => Category(
        id: m['id'] as String,
        businessId: m['business_id'] as String,
        name: m['name'] as String,
        position: (m['position'] ?? 0) as int,
        isActive: (m['is_active'] ?? true) as bool,
        color: m['color'] as String?,
        createdAt: m['created_at'] == null ? null : DateTime.parse(m['created_at']),
      );

  Map<String, dynamic> toInsert() => {
        'id': id,
        'business_id': businessId,
        'name': name,
        'position': position,
        'is_active': isActive,
        'color': color,
      };

  Category copyWith({
    String? id,
    String? businessId,
    String? name,
    int? position,
    bool? isActive,
    Object? color = _sentinel,
    DateTime? createdAt,
  }) {
    return Category(
      id: id ?? this.id,
      businessId: businessId ?? this.businessId,
      name: name ?? this.name,
      position: position ?? this.position,
      isActive: isActive ?? this.isActive,
      // sentinel para diferenciar "no pasar" vs "pasar null explicito".
      color: identical(color, _sentinel) ? this.color : color as String?,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

const Object _sentinel = Object();
