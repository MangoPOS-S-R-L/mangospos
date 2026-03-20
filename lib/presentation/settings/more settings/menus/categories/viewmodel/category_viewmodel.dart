import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/data/models/category.dart' as model;
import 'package:mangopos/data/repositories/category_repository.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../state/category_state.dart';

final categoriesVmProvider =
    NotifierProvider<CategoriesVm, CategoriesState>(CategoriesVm.new);

class CategoriesVm extends Notifier<CategoriesState> {
  final _repo = CategoryRepository();
  final _sp = Supabase.instance.client;

  String? _businessId; // queda cacheado al primer load

  @override
  CategoriesState build() => const CategoriesState();

  /// Carga categorías. Acepta 'auto' y lo resuelve a un business_id real.
  Future<void> load({required String businessId}) async {
    state = state.copyWith(data: const AsyncValue.loading());
    try {
      _businessId = await _normalizeBusinessId(businessId);
      final res = await _repo.list(_businessId!);
      state = state.copyWith(data: AsyncValue.data(res));
    } catch (e, st) {
      state = state.copyWith(data: AsyncValue.error(e, st));
    }
  }

  // ----------------- Acciones CRUD -----------------
  Future<void> create({required String name, int position = 0}) async {
    _ensureBusiness();
    final cat = model.Category(
      id: const Uuid().v4(),
      businessId: _businessId!,
      name: name,
      position: position,
      isActive: true,
    );
    await _repo.create(cat);
    await load(businessId: _businessId!);
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

  // ----------------- Helpers -----------------
  void _ensureBusiness() {
    if (_businessId == null || _businessId!.isEmpty || _businessId == 'auto') {
      throw StateError('BusinessId no resuelto. Llama primero a load(businessId: ...)');
    }
  }

  /// Resuelve 'auto' -> business_id válido del usuario.
  /// No usamos helper externo: consultamos tablas existentes.
  Future<String> _normalizeBusinessId(String id) async {
    if (id.isNotEmpty && id != 'auto') return id;

    final activeBusinessId = ref.read(sessionProvider).activeBusinessId;
    if (activeBusinessId != null && activeBusinessId.isNotEmpty) {
      return activeBusinessId;
    }

    final uid = _sp.auth.currentUser?.id;
    if (uid == null) {
      throw Exception('Sesión no iniciada');
    }

    // 1) user_businesses (preferido)
    final ub = await _sp
        .from('user_businesses')
        .select('business_id')
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (ub != null && ub['business_id'] != null) {
      return ub['business_id'] as String;
    }

    // 2) memberships
    final mem = await _sp
        .from('memberships')
        .select('business_id')
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (mem != null && mem['business_id'] != null) {
      return mem['business_id'] as String;
    }

    // 3) negocios donde es owner (fallback)
    final own = await _sp
        .from('businesses')
        .select('id')
        .eq('owner_id', uid)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (own != null && own['id'] != null) {
      return own['id'] as String;
    }

    throw Exception('No tienes un negocio asignado');
  }
}
