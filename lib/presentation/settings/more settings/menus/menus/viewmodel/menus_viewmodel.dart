import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../../../../data/models/menu.dart';
import '../../../../../../data/repositories/menu_repository.dart';
import '../state/menus_state.dart';

final menusVmProvider = NotifierProvider<MenusVm, MenusState>(MenusVm.new);

class MenusVm extends Notifier<MenusState> {
  final _repo = MenuRepository();
  final _sp = Supabase.instance.client;
  String? _businessId;

  @override
  MenusState build() => const MenusState();

  Future<void> load({required String businessId}) async {
    state = state.copyWith(data: const AsyncLoading());
    try {
      _businessId = await _normalizeBusinessId(businessId);
      final res = await _repo.list(_businessId!, search: state.search);
      state = state.copyWith(
        data: AsyncData(res),
        selectedId: res.isNotEmpty ? (state.selectedId ?? res.first.id) : null,
      );
    } catch (e, st) {
      state = state.copyWith(data: AsyncError(e, st));
    }
  }

  Future<void> setSearch(String q) async {
    state = state.copyWith(search: q);
    if (_businessId == null) return;
    try {
      final res = await _repo.list(_businessId!, search: q);
      state = state.copyWith(data: AsyncData(res));
    } catch (e, st) {
      state = state.copyWith(data: AsyncError(e, st));
    }
  }

  void select(String id) => state = state.copyWith(selectedId: id);

  Future<void> createMenu({
    required String name,
    String? description,
    String? schedule,
    bool isActive = true,
  }) async {
    final b = _ensureBusiness();
    final menu = Menu(
      id: const Uuid().v4(),
      businessId: b,
      name: name,
      description: description?.trim().isEmpty == true
          ? null
          : description?.trim(),
      schedule: schedule?.trim().isEmpty == true ? null : schedule?.trim(),
      isActive: isActive,
      createdAt: DateTime.now(),
      itemsCount: 0,
    );
    await _repo.create(menu);
    await load(businessId: b);
  }

  Future<void> updateMenu({
    required String id,
    required String name,
    String? description,
    String? schedule,
    required bool isActive,
  }) async {
    await _repo.update(id, {
      'name': name,
      'description': description?.trim().isEmpty == true
          ? null
          : description?.trim(),
      'schedule': schedule?.trim().isEmpty == true ? null : schedule?.trim(),
      'is_active': isActive,
    });
    await load(businessId: _businessId ?? 'auto');
  }

  Future<void> toggleActive(String id, bool v) async {
    await _repo.update(id, {'is_active': v});
    await load(businessId: _businessId ?? 'auto');
  }

  Future<void> remove(String id) async {
    await _repo.remove(id);
    await load(businessId: _businessId ?? 'auto');
  }

  String _ensureBusiness() {
    if (_businessId == null || _businessId == 'auto' || _businessId!.isEmpty) {
      throw StateError(
        'BusinessId no resuelto. Llama load(businessId) primero',
      );
    }
    return _businessId!;
  }

  Future<String> _normalizeBusinessId(String id) async {
    if (id.isNotEmpty && id != 'auto') return id;
    final uid = _sp.auth.currentUser?.id;
    if (uid == null) throw Exception('Sesión no iniciada');

    final ub = await _sp
        .from('user_businesses')
        .select('business_id')
        .eq('user_id', uid)
        .order('created_at')
        .limit(1)
        .maybeSingle();
    if (ub != null && ub['business_id'] != null) {
      return ub['business_id'] as String;
    }

    final mem = await _sp
        .from('memberships')
        .select('business_id')
        .eq('user_id', uid)
        .order('created_at')
        .limit(1)
        .maybeSingle();
    if (mem != null && mem['business_id'] != null) {
      return mem['business_id'] as String;
    }

    final own = await _sp
        .from('businesses')
        .select('id')
        .eq('owner_id', uid)
        .order('created_at')
        .limit(1)
        .maybeSingle();
    if (own != null && own['id'] != null) {
      return own['id'] as String;
    }

    throw Exception('No tienes un negocio asignado');
  }
}
