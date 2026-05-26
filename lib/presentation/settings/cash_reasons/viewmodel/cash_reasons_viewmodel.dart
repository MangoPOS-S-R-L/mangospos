// lib/presentation/settings/cash_reasons/viewmodel/cash_reasons_viewmodel.dart
//
// VM para el CRUD de razones de movimientos de caja (cash_transaction_reasons).
// Reutiliza CashierRepository en lugar de crear uno paralelo, porque la
// tabla pertenece al módulo de caja.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';

@immutable
class CashReason {
  const CashReason({
    required this.id,
    required this.code,
    required this.label,
    required this.appliesTo,
    required this.requiresPin,
    required this.isActive,
  });

  final String id;
  final String code;
  final String label;
  // null = aplica a cualquier tipo. Sino: 'deposit', 'withdrawal', 'expense'.
  final String? appliesTo;
  final bool requiresPin;
  final bool isActive;

  String get appliesToDisplay {
    switch (appliesTo) {
      case 'deposit':
        return 'Ingreso';
      case 'withdrawal':
        return 'Retiro';
      case 'expense':
        return 'Gasto';
      default:
        return 'Universal';
    }
  }

  factory CashReason.fromMap(Map<String, dynamic> m) {
    return CashReason(
      id: m['id'] as String,
      code: m['code'] as String,
      label: m['label'] as String,
      appliesTo: m['applies_to'] as String?,
      requiresPin: m['requires_pin'] == true,
      isActive: m['is_active'] == true,
    );
  }
}

@immutable
class CashReasonsState {
  const CashReasonsState({
    this.items = const [],
    this.isLoading = false,
    this.errorMessage,
  });

  final List<CashReason> items;
  final bool isLoading;
  final String? errorMessage;

  CashReasonsState copyWith({
    List<CashReason>? items,
    bool? isLoading,
    String? errorMessage,
  }) {
    return CashReasonsState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage,
    );
  }
}

final cashReasonsVmProvider =
    NotifierProvider<CashReasonsVm, CashReasonsState>(CashReasonsVm.new);

class CashReasonsVm extends Notifier<CashReasonsState> {
  String? _businessId;

  @override
  CashReasonsState build() => const CashReasonsState();

  Future<void> load({required String businessId}) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      _businessId = await _resolveBusiness(businessId);
      final repo = ref.read(cashierRepositoryProvider);
      final rows = await repo.listAllCashReasons(_businessId!);
      final list = rows.map(CashReason.fromMap).toList(growable: false);
      state = state.copyWith(items: list, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
    }
  }

  Future<void> refresh() async {
    final b = await _ensureBusiness();
    await load(businessId: b);
  }

  Future<bool> create({
    required String code,
    required String label,
    String? appliesTo,
    bool requiresPin = false,
  }) async {
    final trimmedCode = code.trim();
    final trimmedLabel = label.trim();
    if (trimmedCode.isEmpty || trimmedLabel.isEmpty) {
      state = state.copyWith(
        errorMessage: 'El código y la etiqueta son obligatorios.',
      );
      return false;
    }
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final b = await _ensureBusiness();
      await ref.read(cashierRepositoryProvider).createCashReason(
            businessId: b,
            code: trimmedCode,
            label: trimmedLabel,
            appliesTo: appliesTo,
            requiresPin: requiresPin,
          );
      await load(businessId: b);
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: _humanizeError(e),
      );
      return false;
    }
  }

  Future<bool> update({
    required String id,
    String? label,
    String? appliesTo,
    bool clearAppliesTo = false,
    bool? requiresPin,
  }) async {
    final patch = <String, dynamic>{};
    if (label != null) patch['label'] = label.trim();
    if (clearAppliesTo) {
      patch['applies_to'] = null;
    } else if (appliesTo != null) {
      patch['applies_to'] = appliesTo;
    }
    if (requiresPin != null) patch['requires_pin'] = requiresPin;
    if (patch.isEmpty) return true;

    // Optimistic
    final updated = state.items.map((r) {
      if (r.id != id) return r;
      return CashReason(
        id: r.id,
        code: r.code,
        label: patch.containsKey('label') ? patch['label'] as String : r.label,
        appliesTo: patch.containsKey('applies_to')
            ? patch['applies_to'] as String?
            : r.appliesTo,
        requiresPin: patch.containsKey('requires_pin')
            ? patch['requires_pin'] as bool
            : r.requiresPin,
        isActive: r.isActive,
      );
    }).toList(growable: false);
    state = state.copyWith(items: updated);

    try {
      await ref.read(cashierRepositoryProvider).updateCashReason(id, patch);
      return true;
    } catch (e) {
      state = state.copyWith(errorMessage: _humanizeError(e));
      await refresh();
      return false;
    }
  }

  Future<void> toggleActive(String id, bool active) async {
    final updated = state.items.map((r) {
      if (r.id != id) return r;
      return CashReason(
        id: r.id,
        code: r.code,
        label: r.label,
        appliesTo: r.appliesTo,
        requiresPin: r.requiresPin,
        isActive: active,
      );
    }).toList(growable: false);
    state = state.copyWith(items: updated);
    try {
      await ref
          .read(cashierRepositoryProvider)
          .updateCashReason(id, {'is_active': active});
    } catch (e) {
      state = state.copyWith(errorMessage: _humanizeError(e));
      await refresh();
    }
  }

  Future<void> remove(String id) async {
    try {
      await ref.read(cashierRepositoryProvider).deleteCashReason(id);
      await refresh();
    } catch (e) {
      state = state.copyWith(errorMessage: _humanizeError(e));
    }
  }

  Future<String> _resolveBusiness(String businessId) async {
    return BusinessResolver.ensure(
      businessId.isEmpty ? 'auto' : businessId,
    );
  }

  Future<String> _ensureBusiness() async {
    if (_businessId == null || _businessId!.isEmpty || _businessId == 'auto') {
      final active = ref.read(sessionProvider).activeBusinessId;
      if (active != null && active.isNotEmpty) {
        _businessId = await BusinessResolver.ensure(active);
      } else {
        _businessId = await BusinessResolver.ensure('auto');
      }
    }
    return _businessId!;
  }

  String _humanizeError(Object e) {
    final msg = e.toString();
    if (msg.contains('duplicate key') ||
        msg.contains('unique') ||
        msg.contains('cash_transaction_reasons_business_id_code_key')) {
      return 'Ya existe una razón con ese código en este negocio.';
    }
    return msg;
  }
}
