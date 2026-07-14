import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/promos_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/promos_state.dart';

final promosRepositoryProvider = Provider<PromosRepository>((ref) {
  return PromosRepository(Supabase.instance.client);
});

final promosViewModelProvider = ChangeNotifierProvider<PromosViewModel>((ref) {
  return PromosViewModel(ref.read(promosRepositoryProvider));
});

class PromosViewModel extends ChangeNotifier {
  final PromosRepository _repository;

  PromosState _state = const PromosState();

  PromosViewModel(this._repository);

  PromosState get state => _state;

  Future<void> init({bool force = false}) async {
    if (_state.loading && !force) return;

    _state = _state.copyWith(loading: true, clearError: true);
    notifyListeners();

    try {
      final businessId = await resolveBusinessIdOrNull(
        Supabase.instance.client,
        'auto',
      );
      if (businessId == null) {
        throw Exception('No se pudo resolver el negocio actual');
      }

      _state = _state.copyWith(businessId: businessId);
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error cargando promociones: $e',
      );
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    _state = _state.copyWith(loading: true, clearError: true);
    notifyListeners();

    try {
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error refrescando promociones: $e',
      );
      notifyListeners();
    }
  }

  Future<void> createPromotion({
    required String name,
    String? description,
    required String discountType,
    required String promoType,
    required double discountValue,
    required double minPurchase,
    required String appliesTo,
    required String targetScope,
    required List<String> targetIds,
    required List<int> daysOfWeek,
    required bool autoApply,
    required bool stackable,
    required int priority,
    int? buyQuantity,
    int? payQuantity,
    int? rewardQuantity,
    required DateTime startDate,
    required DateTime endDate,
    TimeOfDay? startTime,
    TimeOfDay? endTime,
  }) async {
    final businessId = _state.businessId;
    if (businessId == null) {
      throw Exception('No hay negocio activo.');
    }

    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.createPromotion(
        businessId: businessId,
        name: name,
        description: description,
        discountType: discountType,
        promoType: promoType,
        discountValue: discountValue,
        minPurchase: minPurchase,
        appliesTo: appliesTo,
        targetScope: targetScope,
        targetIds: targetIds,
        daysOfWeek: daysOfWeek,
        autoApply: autoApply,
        stackable: stackable,
        priority: priority,
        buyQuantity: buyQuantity,
        payQuantity: payQuantity,
        rewardQuantity: rewardQuantity,
        startDate: startDate,
        endDate: endDate,
        startTime: startTime,
        endTime: endTime,
      );
      _state = _state.copyWith(saving: false);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error creando promoción: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updatePromotion({
    required String id,
    required String name,
    String? description,
    required String discountType,
    required String promoType,
    required double discountValue,
    required double minPurchase,
    required String appliesTo,
    required String targetScope,
    required List<String> targetIds,
    required List<int> daysOfWeek,
    required bool autoApply,
    required bool stackable,
    required int priority,
    int? buyQuantity,
    int? payQuantity,
    int? rewardQuantity,
    required DateTime startDate,
    required DateTime endDate,
    TimeOfDay? startTime,
    TimeOfDay? endTime,
    required bool isActive,
  }) async {
    final businessId = _state.businessId;
    if (businessId == null) {
      throw Exception('No hay negocio activo.');
    }

    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.updatePromotion(
        id: id,
        name: name,
        description: description,
        discountType: discountType,
        promoType: promoType,
        discountValue: discountValue,
        minPurchase: minPurchase,
        appliesTo: appliesTo,
        targetScope: targetScope,
        targetIds: targetIds,
        daysOfWeek: daysOfWeek,
        autoApply: autoApply,
        stackable: stackable,
        priority: priority,
        buyQuantity: buyQuantity,
        payQuantity: payQuantity,
        rewardQuantity: rewardQuantity,
        startDate: startDate,
        endDate: endDate,
        startTime: startTime,
        endTime: endTime,
        isActive: isActive,
      );
      _state = _state.copyWith(saving: false);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error actualizando promoción: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> createCoupon({
    required String code,
    required String discountType,
    required double discountValue,
    int? usageLimit,
    required double minPurchase,
    required DateTime validFrom,
    required DateTime validUntil,
  }) async {
    final businessId = _state.businessId;
    if (businessId == null) {
      throw Exception('No hay negocio activo.');
    }

    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.createCoupon(
        businessId: businessId,
        code: code,
        discountType: discountType,
        discountValue: discountValue,
        usageLimit: usageLimit,
        minPurchase: minPurchase,
        validFrom: validFrom,
        validUntil: validUntil,
      );
      _state = _state.copyWith(saving: false);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(saving: false, error: 'Error creando cupón: $e');
      notifyListeners();
      rethrow;
    }
  }

  Future<void> createGiftCard({
    required String code,
    required double initialBalance,
    DateTime? expiresAt,
  }) async {
    final businessId = _state.businessId;
    if (businessId == null) {
      throw Exception('No hay negocio activo.');
    }

    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.createGiftCard(
        businessId: businessId,
        code: code,
        initialBalance: initialBalance,
        expiresAt: expiresAt,
      );
      _state = _state.copyWith(saving: false);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error creando gift card: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _reload() async {
    final businessId = _state.businessId;
    if (businessId == null) {
      throw Exception('No hay negocio activo.');
    }

    final promotions = await _repository.getPromotions(businessId);
    final products = await _repository.getProducts(businessId);
    final coupons = await _repository.getCoupons(businessId);
    final giftCards = await _repository.getGiftCards(businessId);

    _state = _state.copyWith(
      loading: false,
      promotions: promotions,
      products: products,
      coupons: coupons,
      giftCards: giftCards,
      clearError: true,
    );
    notifyListeners();
  }
}
