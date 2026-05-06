class Zone {
  final String id;
  final String name;
  final int sortIndex;
  final bool isActive;
  final String? businessId;

  Zone({
    required this.id,
    required this.name,
    required this.sortIndex,
    this.isActive = true,
    this.businessId,
  });

  factory Zone.fromMap(Map<String, dynamic> j) => Zone(
    id: j['id'] as String,
    name: j['name'] as String,
    sortIndex: (j['sort_index'] ?? 0) as int,
    isActive: (j['is_active'] ?? true) as bool,
    businessId: j['business_id'] as String?,
  );
}
