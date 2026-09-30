/// Tarjetas de sellos («cada N compras, 1 gratis»). Ver mig 20260930_0053.
library;

double _toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

int _toInt(dynamic value) => _toDouble(value).floor();

/// La regla en palabras de caja: «Compra 5, la 6ª gratis» (por compra) o
/// «Cada 10 unidades, 1 gratis» (por unidad).
String loyaltyRuleLabel(int stampsRequired, String countMode) {
  return countMode == 'unit'
      ? 'Cada $stampsRequired unidades, 1 gratis'
      : 'Compra $stampsRequired, la ${stampsRequired + 1}ª gratis';
}

/// Programa configurado por el negocio: qué productos suman sellos y cuántos
/// sellos hacen falta para 1 unidad gratis.
class LoyaltyStampProgram {
  const LoyaltyStampProgram({
    required this.id,
    required this.businessId,
    required this.name,
    required this.targetScope,
    required this.targetIds,
    required this.stampsRequired,
    required this.countMode,
    required this.startsAt,
    required this.isActive,
  });

  final String id;
  final String businessId;
  final String name;

  /// 'product' (productos específicos) o 'category' (todo lo de la categoría).
  final String targetScope;
  final List<String> targetIds;
  final int stampsRequired;

  /// 'visit': una marca por compra con productos de la tarjeta (como se
  /// sella el cartón). 'unit': una marca por unidad.
  final String countMode;

  /// Las compras cuentan desde aquí.
  final DateTime startsAt;
  final bool isActive;

  bool get byCategory => targetScope == 'category';
  String get ruleLabel => loyaltyRuleLabel(stampsRequired, countMode);

  factory LoyaltyStampProgram.fromMap(Map<String, dynamic> map) {
    final rawTargets = map['target_ids'];
    return LoyaltyStampProgram(
      id: map['id'].toString(),
      businessId: map['business_id'].toString(),
      name: (map['name'] ?? '').toString(),
      targetScope: (map['target_scope'] ?? 'product').toString(),
      targetIds: rawTargets is List
          ? rawTargets.map((e) => e.toString()).toList(growable: false)
          : const [],
      stampsRequired: _toInt(map['stamps_required']),
      countMode: (map['count_mode'] ?? 'visit').toString(),
      startsAt:
          DateTime.tryParse(map['starts_at']?.toString() ?? '')?.toLocal() ??
          DateTime.now(),
      isActive: map['is_active'] != false,
    );
  }
}

/// La tarjeta de UN cliente en UN programa, calculada por el servidor
/// (`fn_loyalty_customer_cards`) a partir de sus ventas cobradas.
class LoyaltyCard {
  const LoyaltyCard({
    required this.programId,
    required this.name,
    required this.stampsRequired,
    required this.targetScope,
    required this.countMode,
    required this.earned,
    required this.adjustments,
    required this.redeemed,
    required this.reserved,
    required this.balance,
    required this.availableRewards,
    required this.progress,
    required this.eligibleProductIds,
  });

  final String programId;
  final String name;
  final int stampsRequired;
  final String targetScope;

  /// 'visit' (una marca por compra) o 'unit' (una por unidad).
  final String countMode;

  /// Compras (o unidades, según [countMode]) cobradas con productos del
  /// programa.
  final int earned;

  /// Ajustes manuales (tarjeta física, correcciones).
  final int adjustments;

  /// Sellos de premios ya cobrados.
  final int redeemed;

  /// Sellos de premios puestos en una cuenta todavía abierta.
  final int reserved;

  /// Sellos disponibles = earned + adjustments − redeemed − reserved.
  final int balance;
  final int availableRewards;

  /// Marcas en la tarjeta actual (0..stampsRequired-1).
  final int progress;
  final Set<String> eligibleProductIds;

  bool get perVisit => countMode != 'unit';
  String get ruleLabel => loyaltyRuleLabel(stampsRequired, countMode);

  factory LoyaltyCard.fromMap(Map<String, dynamic> map) {
    final rawIds = map['eligible_product_ids'];
    return LoyaltyCard(
      programId: map['program_id'].toString(),
      name: (map['name'] ?? '').toString(),
      stampsRequired: _toInt(map['stamps_required']),
      targetScope: (map['target_scope'] ?? 'product').toString(),
      countMode: (map['count_mode'] ?? 'visit').toString(),
      earned: _toInt(map['earned']),
      adjustments: _toInt(map['adjustments']),
      redeemed: _toInt(map['redeemed']),
      reserved: _toInt(map['reserved']),
      balance: _toInt(map['balance']),
      availableRewards: _toInt(map['available_rewards']),
      progress: _toInt(map['progress']),
      eligibleProductIds: rawIds is List
          ? rawIds.map((e) => e.toString()).toSet()
          : const <String>{},
    );
  }
}

/// Ajuste manual de sellos, para el historial de la ficha del cliente.
class LoyaltyAdjustment {
  const LoyaltyAdjustment({
    required this.id,
    required this.stamps,
    required this.reason,
    required this.createdAt,
  });

  final String id;
  final int stamps;
  final String reason;
  final DateTime createdAt;

  factory LoyaltyAdjustment.fromMap(Map<String, dynamic> map) {
    return LoyaltyAdjustment(
      id: map['id'].toString(),
      stamps: _toInt(map['stamps']),
      reason: (map['reason'] ?? '').toString(),
      createdAt:
          DateTime.tryParse(map['created_at']?.toString() ?? '')?.toLocal() ??
          DateTime.now(),
    );
  }
}

/// Producto o categoría para el selector de la configuración.
class LoyaltyTargetOption {
  const LoyaltyTargetOption({
    required this.id,
    required this.name,
    this.categoryId,
  });

  final String id;
  final String name;
  final String? categoryId;
}
