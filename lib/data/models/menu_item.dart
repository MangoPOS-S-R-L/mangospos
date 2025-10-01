enum SoldBy { unit, piece, weight, volume, package }

SoldBy _soldByFromString(String? s) {
  switch ((s ?? '').toLowerCase()) {
    case 'piece':
      return SoldBy.piece;
    case 'weight':
      return SoldBy.weight;
    case 'volume':
      return SoldBy.volume;
    case 'package':
      return SoldBy.package;
    default:
      return SoldBy.unit;
  }
}

String _soldByToString(SoldBy v) {
  switch (v) {
    case SoldBy.piece:
      return 'piece';
    case SoldBy.weight:
      return 'weight';
    case SoldBy.volume:
      return 'volume';
    case SoldBy.package:
      return 'package';
    case SoldBy.unit:
    default:
      return 'unit';
  }
}

class MenuItem {
  final String id;
  final String businessId;

  final String name;
  final String? description;
  final String? categoryId;

  final SoldBy soldBy; // 👈 NUEVO
  final double price;
  final double? cost; // 👈 NUEVO opcional
  final String? sku; // referencia
  final String? barcode; // 👈 NUEVO opcional

  final int prepMinutes;
  final bool hasVariants;
  final bool isActive;

  final String? imagePath;
  final String? imageUrl;

  final bool hasPrep;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  // extras de la vista
  final String? categoryName;
  final String? menuName;
  final String? menuId;

  const MenuItem({
    required this.id,
    required this.businessId,
    required this.name,
    this.description,
    this.categoryId,
    required this.soldBy,
    required this.price,
    this.cost,
    this.sku,
    this.barcode,
    required this.prepMinutes,
    required this.hasVariants,
    required this.isActive,
    this.imagePath,
    this.imageUrl,
    required this.hasPrep,
    this.createdAt,
    this.updatedAt,
    this.categoryName,
    this.menuName,
    this.menuId,
  });

  factory MenuItem.fromMap(Map<String, dynamic> m) {
    double toDouble(dynamic v) {
      if (v == null) return 0.0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0.0;
    }

    double? toDoubleOpt(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    int toInt(dynamic v) {
      if (v == null) return 0;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString()) ?? 0;
    }

    bool toBool(dynamic v) {
      if (v is bool) return v;
      final s = v?.toString().toLowerCase();
      return s == 'true' || s == 't' || s == '1';
    }

    DateTime? toDate(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      return DateTime.tryParse(v.toString());
    }

    return MenuItem(
      id: m['id'] as String,
      businessId: (m['business_id'] ?? m['businessId']) as String,
      name: m['name'] as String,
      description: m['description'] as String?,
      categoryId: m['category_id'] as String?,
      soldBy: _soldByFromString(m['sold_by'] as String?), // 👈
      price: toDouble(m['price']),
      cost: toDoubleOpt(m['cost']), // 👈
      sku: m['sku'] as String?,
      barcode: m['barcode'] as String?, // 👈
      prepMinutes: toInt(m['prep_minutes']),
      hasVariants: toBool(m['has_variants']),
      isActive: toBool(m['is_active']),
      imagePath: m['image_path'] as String?,
      imageUrl: m['image_url'] as String?,
      hasPrep: toBool(m['has_prep']),
      createdAt: toDate(m['created_at']),
      updatedAt: toDate(m['updated_at']),
      categoryName: m['category_name'] as String?,
      menuName: m['menu_name'] as String?,
      menuId: m['menu_id'] as String?,
    );
  }

  MenuItem copyWith({
    String? id,
    String? businessId,
    String? name,
    String? description,
    String? categoryId,
    SoldBy? soldBy,
    double? price,
    double? cost,
    String? sku,
    String? barcode,
    int? prepMinutes,
    bool? hasVariants,
    bool? isActive,
    String? imagePath,
    String? imageUrl,
    bool? hasPrep,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? categoryName,
    String? menuName,
    String? menuId,
  }) {
    return MenuItem(
      id: id ?? this.id,
      businessId: businessId ?? this.businessId,
      name: name ?? this.name,
      description: description ?? this.description,
      categoryId: categoryId ?? this.categoryId,
      soldBy: soldBy ?? this.soldBy,
      price: price ?? this.price,
      cost: cost ?? this.cost,
      sku: sku ?? this.sku,
      barcode: barcode ?? this.barcode,
      prepMinutes: prepMinutes ?? this.prepMinutes,
      hasVariants: hasVariants ?? this.hasVariants,
      isActive: isActive ?? this.isActive,
      imagePath: imagePath ?? this.imagePath,
      imageUrl: imageUrl ?? this.imageUrl,
      hasPrep: hasPrep ?? this.hasPrep,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      categoryName: categoryName ?? this.categoryName,
      menuName: menuName ?? this.menuName,
      menuId: menuId ?? this.menuId,
    );
  }

  /// util para repo
  Map<String, dynamic> toInsert() => {
    'name': name,
    'description': description,
    'category_id': categoryId,
    'sold_by': _soldByToString(soldBy), // 👈
    'price': price,
    'cost': cost,
    'sku': sku,
    'barcode': barcode,
    'prep_minutes': prepMinutes,
    'has_variants': hasVariants,
    'is_active': isActive,
    'image_path': imagePath,
    'image_url': imageUrl,
    'has_prep': hasPrep,
  }..removeWhere((k, v) => v == null);
}
