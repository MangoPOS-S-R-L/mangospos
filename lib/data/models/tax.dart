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
  /// PRD 6: si false, este impuesto NO se aplica a items con
  /// is_takeout=true. Default true para taxes regulares (ITBIS); para
  /// service fees el backfill setea a false (preserva el skip
  /// hardcodeado pre-migración).
  final bool applyOnTakeout;
  final bool isServiceFee;
  /// Si true: el impuesto se incluye en el cálculo del e-CF DGII
  /// (itbis_amount, taxable_amount). Si false: se cobra al cliente
  /// pero NO se declara en el e-CF (uso típico: Propina Legal 10%).
  /// Default sensato: true para ITBIS-like, false para is_service_fee=true.
  final bool includeInEcf;

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
    this.applyOnTakeout = true,
    this.isServiceFee = false,
    this.includeInEcf = true,
  });

  factory Tax.fromMap(Map<String, dynamic> m) {
    final isServiceFee = (m['is_service_fee'] as bool?) ?? false;
    return Tax(
      id: m['id'] as String,
      businessId: m['business_id'] as String,
      name: m['name'] as String,
      rate: (m['rate'] is num) ? (m['rate'] as num).toDouble() : double.parse(m['rate'].toString()),
      isActive: (m['is_active'] as bool?) ?? true,
      applyOnZone: (m['apply_on_zone'] as bool?) ?? true,
      applyOnManual: (m['apply_on_manual'] as bool?) ?? true,
      applyOnQuick: (m['apply_on_quick'] as bool?) ?? true,
      applyOnDelivery: (m['apply_on_delivery'] as bool?) ?? true,
      applyOnTakeout: (m['apply_on_takeout'] as bool?) ?? true,
      isServiceFee: isServiceFee,
      includeInEcf: (m['include_in_ecf'] as bool?) ?? !isServiceFee,
    );
  }
}

