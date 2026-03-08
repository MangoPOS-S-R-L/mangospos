import 'package:supabase_flutter/supabase_flutter.dart';

import '../../presentation/promos/state/promos_state.dart';
import '../datasources/queries/promos_queries.dart';

class PromosRepository {
  final SupabaseClient _client;

  PromosRepository(this._client);

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<List<PromotionSummary>> getPromotions(String businessId) async {
    final response = await _client
        .from(PromosQueries.tablePromotions)
        .select(
          'id, name, description, discount_type, discount_value, min_purchase, applies_to, start_date, end_date, is_active, created_at',
        )
        .eq('business_id', businessId)
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(
      response,
    ).map(PromotionSummary.fromMap).toList(growable: false);
  }

  Future<List<CouponSummary>> getCoupons(String businessId) async {
    final response = await _client
        .from(PromosQueries.tableCoupons)
        .select(
          'id, code, promotion_id, discount_type, discount_value, usage_limit, times_used, min_purchase, valid_from, valid_until, is_active, created_at',
        )
        .eq('business_id', businessId)
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(
      response,
    ).map(CouponSummary.fromMap).toList(growable: false);
  }

  Future<List<GiftCardSummary>> getGiftCards(String businessId) async {
    final response = await _client
        .from(PromosQueries.tableGiftCards)
        .select(
          'id, code, initial_balance, current_balance, expires_at, is_active, created_at',
        )
        .eq('business_id', businessId)
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(
      response,
    ).map(GiftCardSummary.fromMap).toList(growable: false);
  }

  Future<void> createPromotion({
    required String businessId,
    required String name,
    String? description,
    required String discountType,
    required double discountValue,
    required double minPurchase,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    await _client.from(PromosQueries.tablePromotions).insert({
      'business_id': businessId,
      'name': name,
      'description': description,
      'discount_type': discountType,
      'discount_value': discountValue,
      'min_purchase': minPurchase,
      'applies_to': 'all',
      'start_date': startDate.toUtc().toIso8601String(),
      'end_date': endDate.toUtc().toIso8601String(),
      'is_active': true,
    }..removeWhere((key, value) => value == null || value == ''));
  }

  Future<void> createCoupon({
    required String businessId,
    required String code,
    required String discountType,
    required double discountValue,
    int? usageLimit,
    required double minPurchase,
    required DateTime validFrom,
    required DateTime validUntil,
  }) async {
    await _client.from(PromosQueries.tableCoupons).insert({
      'business_id': businessId,
      'code': code,
      'discount_type': discountType,
      'discount_value': discountValue,
      'usage_limit': usageLimit,
      'min_purchase': minPurchase,
      'valid_from': validFrom.toUtc().toIso8601String(),
      'valid_until': validUntil.toUtc().toIso8601String(),
      'is_active': true,
    }..removeWhere((key, value) => value == null || value == ''));
  }

  Future<void> createGiftCard({
    required String businessId,
    required String code,
    required double initialBalance,
    DateTime? expiresAt,
  }) async {
    await _client.from(PromosQueries.tableGiftCards).insert({
      'business_id': businessId,
      'code': code,
      'initial_balance': initialBalance,
      'current_balance': initialBalance,
      'expires_at': expiresAt?.toIso8601String().split('T').first,
      'is_active': true,
    }..removeWhere((key, value) => value == null || value == ''));
  }

  Future<Map<String, double>> getTotals(String businessId) async {
    final giftCards = await getGiftCards(businessId);
    double activeGiftBalance = 0;
    for (final card in giftCards) {
      if (card.isActive) {
        activeGiftBalance += _toDouble(card.currentBalance);
      }
    }

    return {
      'active_promotions': getPromotionsCount(await getPromotions(businessId)),
      'active_coupons': getCouponsCount(await getCoupons(businessId)),
      'gift_balance': activeGiftBalance,
    };
  }

  double getPromotionsCount(List<PromotionSummary> promotions) =>
      promotions.where((item) => item.isActive).length.toDouble();

  double getCouponsCount(List<CouponSummary> coupons) =>
      coupons.where((item) => item.isActive).length.toDouble();
}
