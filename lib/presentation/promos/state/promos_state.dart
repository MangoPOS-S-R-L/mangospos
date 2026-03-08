class PromotionSummary {
  final String id;
  final String name;
  final String description;
  final String discountType;
  final double discountValue;
  final double minPurchase;
  final String appliesTo;
  final DateTime? startDate;
  final DateTime? endDate;
  final bool isActive;
  final DateTime createdAt;

  const PromotionSummary({
    required this.id,
    required this.name,
    required this.description,
    required this.discountType,
    required this.discountValue,
    required this.minPurchase,
    required this.appliesTo,
    required this.startDate,
    required this.endDate,
    required this.isActive,
    required this.createdAt,
  });

  factory PromotionSummary.fromMap(Map<String, dynamic> map) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    DateTime? parseDate(dynamic value) {
      if (value == null) return null;
      return DateTime.tryParse(value.toString());
    }

    return PromotionSummary(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Promoción',
      description: map['description']?.toString() ?? '',
      discountType: map['discount_type']?.toString() ?? 'percentage',
      discountValue: toDouble(map['discount_value']),
      minPurchase: toDouble(map['min_purchase']),
      appliesTo: map['applies_to']?.toString() ?? 'all',
      startDate: parseDate(map['start_date']),
      endDate: parseDate(map['end_date']),
      isActive: map['is_active'] != false,
      createdAt: parseDate(map['created_at']) ?? DateTime.now(),
    );
  }
}

class CouponSummary {
  final String id;
  final String code;
  final String discountType;
  final double discountValue;
  final int? usageLimit;
  final int timesUsed;
  final double minPurchase;
  final DateTime? validFrom;
  final DateTime? validUntil;
  final bool isActive;
  final DateTime createdAt;

  const CouponSummary({
    required this.id,
    required this.code,
    required this.discountType,
    required this.discountValue,
    required this.usageLimit,
    required this.timesUsed,
    required this.minPurchase,
    required this.validFrom,
    required this.validUntil,
    required this.isActive,
    required this.createdAt,
  });

  factory CouponSummary.fromMap(Map<String, dynamic> map) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    int toInt(dynamic value) {
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    DateTime? parseDate(dynamic value) {
      if (value == null) return null;
      return DateTime.tryParse(value.toString());
    }

    return CouponSummary(
      id: map['id']?.toString() ?? '',
      code: map['code']?.toString() ?? '',
      discountType: map['discount_type']?.toString() ?? 'percentage',
      discountValue: toDouble(map['discount_value']),
      usageLimit: map['usage_limit'] == null ? null : toInt(map['usage_limit']),
      timesUsed: toInt(map['times_used']),
      minPurchase: toDouble(map['min_purchase']),
      validFrom: parseDate(map['valid_from']),
      validUntil: parseDate(map['valid_until']),
      isActive: map['is_active'] != false,
      createdAt: parseDate(map['created_at']) ?? DateTime.now(),
    );
  }
}

class GiftCardSummary {
  final String id;
  final String code;
  final double initialBalance;
  final double currentBalance;
  final DateTime? expiresAt;
  final bool isActive;
  final DateTime createdAt;

  const GiftCardSummary({
    required this.id,
    required this.code,
    required this.initialBalance,
    required this.currentBalance,
    required this.expiresAt,
    required this.isActive,
    required this.createdAt,
  });

  factory GiftCardSummary.fromMap(Map<String, dynamic> map) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    DateTime? parseDate(dynamic value) {
      if (value == null) return null;
      return DateTime.tryParse(value.toString());
    }

    return GiftCardSummary(
      id: map['id']?.toString() ?? '',
      code: map['code']?.toString() ?? '',
      initialBalance: toDouble(map['initial_balance']),
      currentBalance: toDouble(map['current_balance']),
      expiresAt: parseDate(map['expires_at']),
      isActive: map['is_active'] != false,
      createdAt: parseDate(map['created_at']) ?? DateTime.now(),
    );
  }
}

class PromosState {
  final bool loading;
  final bool saving;
  final String? error;
  final String? businessId;
  final List<PromotionSummary> promotions;
  final List<CouponSummary> coupons;
  final List<GiftCardSummary> giftCards;

  const PromosState({
    this.loading = false,
    this.saving = false,
    this.error,
    this.businessId,
    this.promotions = const [],
    this.coupons = const [],
    this.giftCards = const [],
  });

  PromosState copyWith({
    bool? loading,
    bool? saving,
    String? error,
    String? businessId,
    List<PromotionSummary>? promotions,
    List<CouponSummary>? coupons,
    List<GiftCardSummary>? giftCards,
    bool clearError = false,
  }) {
    return PromosState(
      loading: loading ?? this.loading,
      saving: saving ?? this.saving,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
      promotions: promotions ?? this.promotions,
      coupons: coupons ?? this.coupons,
      giftCards: giftCards ?? this.giftCards,
    );
  }
}
