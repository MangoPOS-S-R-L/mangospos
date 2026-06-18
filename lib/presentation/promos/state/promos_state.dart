import 'package:flutter/material.dart' show TimeOfDay;

class PromotionSummary {
  final String id;
  final String name;
  final String description;
  final String discountType;
  final double discountValue;
  final double minPurchase;
  final String appliesTo;
  final String promoType;
  final String targetScope;
  final List<String> targetIds;
  final List<int> daysOfWeek;
  final bool autoApply;
  final int priority;
  final bool stackable;
  final int? buyQuantity;
  final int? payQuantity;
  final int? rewardQuantity;
  final DateTime? startDate;
  final DateTime? endDate;
  // Happy hour: franja horaria diaria opcional (hora local). null en ambos =
  // aplica todo el día. Si endTime < startTime, la franja cruza la medianoche.
  final TimeOfDay? startTime;
  final TimeOfDay? endTime;
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
    required this.promoType,
    required this.targetScope,
    required this.targetIds,
    required this.daysOfWeek,
    required this.autoApply,
    required this.priority,
    required this.stackable,
    required this.buyQuantity,
    required this.payQuantity,
    required this.rewardQuantity,
    required this.startDate,
    required this.endDate,
    this.startTime,
    this.endTime,
    required this.isActive,
    required this.createdAt,
  });

  factory PromotionSummary.fromMap(Map<String, dynamic> map) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    int? toNullableInt(dynamic value) {
      if (value == null) return null;
      if (value is num) return value.toInt();
      return int.tryParse(value.toString());
    }

    DateTime? parseDate(dynamic value) {
      if (value == null) return null;
      return DateTime.tryParse(value.toString());
    }

    // Postgres devuelve `time` como "HH:mm:ss" (a veces "HH:mm"). Lo leemos
    // como hora de pared, sin conversión de zona horaria.
    TimeOfDay? parseTime(dynamic value) {
      final raw = value?.toString();
      if (raw == null || raw.isEmpty) return null;
      final parts = raw.split(':');
      if (parts.length < 2) return null;
      final hour = int.tryParse(parts[0]);
      final minute = int.tryParse(parts[1]);
      if (hour == null || minute == null) return null;
      if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
      return TimeOfDay(hour: hour, minute: minute);
    }

    List<String> parseStringList(dynamic value) {
      if (value is List) {
        return value
            .map((item) => item?.toString() ?? '')
            .where((item) => item.isNotEmpty)
            .toList(growable: false);
      }
      return const [];
    }

    List<int> parseIntList(dynamic value) {
      if (value is List) {
        return value
            .map((item) {
              if (item is num) return item.toInt();
              return int.tryParse(item?.toString() ?? '');
            })
            .whereType<int>()
            .toList(growable: false);
      }
      return const [];
    }

    final targetScope = map['target_scope']?.toString();
    final appliesTo = map['applies_to']?.toString() ?? 'all';

    return PromotionSummary(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Promoción',
      description: map['description']?.toString() ?? '',
      discountType: map['discount_type']?.toString() ?? 'percentage',
      discountValue: toDouble(map['discount_value']),
      minPurchase: toDouble(map['min_purchase']),
      appliesTo: appliesTo,
      promoType:
          map['promo_type']?.toString() ??
          map['discount_type']?.toString() ??
          'percentage',
      targetScope: (targetScope == null || targetScope.isEmpty)
          ? appliesTo
          : targetScope,
      targetIds: parseStringList(map['target_ids']),
      daysOfWeek: parseIntList(map['days_of_week']),
      autoApply: map['auto_apply'] != false,
      priority: toNullableInt(map['priority']) ?? 0,
      stackable: map['stackable'] == true,
      buyQuantity: toNullableInt(map['buy_quantity']),
      payQuantity: toNullableInt(map['pay_quantity']),
      rewardQuantity: toNullableInt(map['reward_quantity']),
      startDate: parseDate(map['start_date']),
      endDate: parseDate(map['end_date']),
      startTime: parseTime(map['start_time']),
      endTime: parseTime(map['end_time']),
      isActive: map['is_active'] != false,
      createdAt: parseDate(map['created_at']) ?? DateTime.now(),
    );
  }
}

class PromoProductSummary {
  final String id;
  final String name;
  final String? categoryId;
  final bool isActive;

  const PromoProductSummary({
    required this.id,
    required this.name,
    required this.categoryId,
    required this.isActive,
  });

  factory PromoProductSummary.fromMap(Map<String, dynamic> map) {
    return PromoProductSummary(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Producto',
      categoryId: map['category_id']?.toString(),
      isActive: map['is_active'] != false,
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
  final List<PromoProductSummary> products;
  final List<CouponSummary> coupons;
  final List<GiftCardSummary> giftCards;

  const PromosState({
    this.loading = false,
    this.saving = false,
    this.error,
    this.businessId,
    this.promotions = const [],
    this.products = const [],
    this.coupons = const [],
    this.giftCards = const [],
  });

  PromosState copyWith({
    bool? loading,
    bool? saving,
    String? error,
    String? businessId,
    List<PromotionSummary>? promotions,
    List<PromoProductSummary>? products,
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
      products: products ?? this.products,
      coupons: coupons ?? this.coupons,
      giftCards: giftCards ?? this.giftCards,
    );
  }
}
