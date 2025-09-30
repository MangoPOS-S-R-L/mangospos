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

  // MenusVm
Future<void> load({required String businessId}) async {
  state = state.copyWith(data: const AsyncLoading());
  try {
    _businessId = await _normalizeBusinessId(businessId);
    final res = await _repo.list(_businessId!, search: state.search);
    state = state.copyWith(data: AsyncData(res));
    // 👇 solo setea si no hay uno seleccionado aún
    if (res.isNotEmpty && state.selectedId == null) {
      state = state.copyWith(selectedId: res.first.id);
    }
  } catch (e, st) {
    state = state.copyWith(data: AsyncError(e, st));
  }
}


  void setSearch(String q) async {
    state = state.copyWith(search: q);
    if (_businessId != null) {
      final res = await _repo.list(_businessId!, search: q);
      state = state.copyWith(data: AsyncData(res));
    }
  }

  void select(String id) => state = state.copyWith(selectedId: id);

  Future<void> create({required String name}) async {
    final b = _ensureBusiness();
    final menu = Menu(
      id: const Uuid().v4(),
      businessId: b,
      name: name,
      isActive: true,
      createdAt: DateTime.now(),
    );
    await _repo.create(menu);
    await load(businessId: b);
  }

  Future<void> rename(String id, String name) async {
    await _repo.update(id, {'name': name});
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

  // Helpers
  String _ensureBusiness() {
    if (_businessId == null || _businessId == 'auto' || _businessId!.isEmpty) {
      throw StateError('BusinessId no resuelto. Llama load(businessId) primero');
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
    if (ub != null && ub['business_id'] != null) return ub['business_id'] as String;

    final mem = await _sp
        .from('memberships')
        .select('business_id')
        .eq('user_id', uid)
        .order('created_at')
        .limit(1)
        .maybeSingle();
    if (mem != null && mem['business_id'] != null) return mem['business_id'] as String;

    final own = await _sp
        .from('businesses')
        .select('id')
        .eq('owner_id', uid)
        .order('created_at')
        .limit(1)
        .maybeSingle();
    if (own != null && own['id'] != null) return own['id'] as String;

    throw Exception('No tienes un negocio asignado');
  }
}
