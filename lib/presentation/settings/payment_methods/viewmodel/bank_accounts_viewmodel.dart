// lib/presentation/settings/payment_methods/viewmodel/bank_accounts_viewmodel.dart

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/models/bank_account.dart';
import 'package:mangopos/data/repositories/bank_accounts_repository.dart';
import 'package:mangopos/services/session/session_controller.dart';

@immutable
class BankAccountsState {
  const BankAccountsState({
    this.items = const [],
    this.isLoading = false,
    this.errorMessage,
  });

  final List<BankAccount> items;
  final bool isLoading;
  final String? errorMessage;

  BankAccountsState copyWith({
    List<BankAccount>? items,
    bool? isLoading,
    String? errorMessage,
  }) {
    return BankAccountsState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage,
    );
  }
}

final bankAccountsRepoProvider = Provider<BankAccountsRepository>((ref) {
  return BankAccountsRepository();
});

final bankAccountsVmProvider =
    NotifierProvider<BankAccountsVm, BankAccountsState>(BankAccountsVm.new);

class BankAccountsVm extends Notifier<BankAccountsState> {
  String? _businessId;
  BankAccountsRepository get _repo => ref.read(bankAccountsRepoProvider);

  @override
  BankAccountsState build() => const BankAccountsState();

  Future<void> load({required String businessId}) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      _businessId = await _resolveBusiness(businessId);
      final list = await _repo.list(_businessId!);
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
    required String bankName,
    required String accountNumber,
    required BankAccountType accountType,
    required String currency,
    String? accountHolder,
    String? alias,
  }) async {
    if (bankName.trim().isEmpty || accountNumber.trim().isEmpty) {
      state = state.copyWith(
        errorMessage: 'El banco y el número de cuenta son obligatorios.',
      );
      return false;
    }
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final b = await _ensureBusiness();
      final nextSort = state.items.isEmpty
          ? 10
          : (state.items
                    .map((a) => a.sortOrder)
                    .fold<int>(0, (m, v) => v > m ? v : m)) +
                10;
      final draft = BankAccount(
        id: const Uuid().v4(),
        businessId: b,
        bankName: bankName.trim(),
        accountNumber: accountNumber.trim(),
        accountHolder: accountHolder?.trim().isEmpty ?? true
            ? null
            : accountHolder!.trim(),
        accountType: accountType,
        currency: currency,
        alias: alias?.trim().isEmpty ?? true ? null : alias!.trim(),
        isActive: true,
        sortOrder: nextSort,
      );
      await _repo.create(draft);
      await load(businessId: b);
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
      return false;
    }
  }

  Future<bool> update({
    required String id,
    String? bankName,
    String? accountNumber,
    String? accountHolder,
    BankAccountType? accountType,
    String? currency,
    String? alias,
  }) async {
    final patch = <String, dynamic>{};
    if (bankName != null) patch['bank_name'] = bankName.trim();
    if (accountNumber != null) patch['account_number'] = accountNumber.trim();
    if (accountHolder != null) {
      patch['account_holder'] =
          accountHolder.trim().isEmpty ? null : accountHolder.trim();
    }
    if (accountType != null) patch['account_type'] = accountType.code;
    if (currency != null) patch['currency'] = currency;
    if (alias != null) {
      patch['alias'] = alias.trim().isEmpty ? null : alias.trim();
    }
    if (patch.isEmpty) return true;

    // Optimistic
    final updated = state.items.map((a) {
      if (a.id != id) return a;
      return a.copyWith(
        bankName: patch.containsKey('bank_name')
            ? patch['bank_name'] as String
            : null,
        accountNumber: patch.containsKey('account_number')
            ? patch['account_number'] as String
            : null,
        accountHolder: patch.containsKey('account_holder')
            ? patch['account_holder']
            : a.accountHolder,
        accountType: patch.containsKey('account_type')
            ? BankAccountTypeX.fromCode(patch['account_type'] as String)
            : null,
        currency: patch.containsKey('currency')
            ? patch['currency'] as String
            : null,
        alias: patch.containsKey('alias') ? patch['alias'] : a.alias,
      );
    }).toList(growable: false);
    state = state.copyWith(items: updated);

    try {
      await _repo.update(id, patch);
      return true;
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
      await refresh();
      return false;
    }
  }

  Future<void> toggleActive(String id, bool active) async {
    final updated = state.items
        .map((a) => a.id == id ? a.copyWith(isActive: active) : a)
        .toList(growable: false);
    state = state.copyWith(items: updated);
    try {
      await _repo.update(id, {'is_active': active});
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
      await refresh();
    }
  }

  Future<void> remove(String id) async {
    try {
      await _repo.remove(id);
      await refresh();
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  /// Optimistic reorder con persistencia en background. Mismo patrón
  /// que categorías y zonas — la UI no parpadea porque actualizamos
  /// state inmediato y solo llamamos load() en error path.
  Future<void> reorder(List<BankAccount> ordered) async {
    state = state.copyWith(items: ordered);
    try {
      await _repo.reorder(ordered);
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
      await refresh();
    }
  }

  // ─── helpers ───────────────────────────────────────────────────────────────

  Future<String> _resolveBusiness(String businessId) async {
    return BusinessResolver.ensure(
      businessId.isEmpty ? 'auto' : businessId,
    );
  }

  Future<String> _ensureBusiness() async {
    if (_businessId == null || _businessId!.isEmpty || _businessId == 'auto') {
      // Intentamos session primero, luego auto-resolve.
      final active = ref.read(sessionProvider).activeBusinessId;
      if (active != null && active.isNotEmpty) {
        _businessId = await BusinessResolver.ensure(active);
      } else {
        _businessId = await BusinessResolver.ensure('auto');
      }
    }
    return _businessId!;
  }
}

/// Provider auxiliar: solo cuentas activas, para el modal de cobro.
/// Carga lazy y cachea — el modal no necesita los inactivos.
final activeBankAccountsProvider =
    FutureProvider.family<List<BankAccount>, String>((ref, businessId) async {
  final repo = ref.read(bankAccountsRepoProvider);
  final bid = await BusinessResolver.ensure(
    businessId.isEmpty ? 'auto' : businessId,
  );
  return repo.listActive(bid);
});
