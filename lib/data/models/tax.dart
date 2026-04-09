// lib/data/models/tax.dart
class Tax {
  final String id;
  final String businessId;
  final String name;
  final double rate; // 0..100
  final bool isActive;
  final bool applyOnZone;
  final bool applyOnManual;
  final bool applyOnQuick;
  final bool applyOnDelivery;
  final bool isServiceFee;

  const Tax({
    required this.id,
    required this.businessId,
    required this.name,
    required this.rate,
    required this.isActive,
    this.applyOnZone = true,
    this.applyOnManual = true,
    this.applyOnQuick = true,
    this.applyOnDelivery = true,
    this.isServiceFee = false,
  });

  factory Tax.fromMap(Map<String, dynamic> m) => Tax(
        id: m['id'] as String,
        businessId: m['business_id'] as String,
        name: m['name'] as String,
        rate: (m['rate'] is num) ? (m['rate'] as num).toDouble() : double.parse(m['rate'].toString()),
        isActive: (m['is_active'] as bool?) ?? true,
        applyOnZone: (m['apply_on_zone'] as bool?) ?? true,
        applyOnManual: (m['apply_on_manual'] as bool?) ?? true,
        applyOnQuick: (m['apply_on_quick'] as bool?) ?? true,
        applyOnDelivery: (m['apply_on_delivery'] as bool?) ?? true,
        isServiceFee: (m['is_service_fee'] as bool?) ?? false,
      );
}

