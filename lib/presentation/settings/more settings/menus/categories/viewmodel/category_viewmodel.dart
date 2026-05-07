import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/offline/offline_catalog_service.dart';
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

  /// Cambia el color de una categoría. [hexColor] = `#RRGGBB` o `null`
  /// para limpiar. Optimistic: actualiza el state local primero (no
  /// flash) y luego persiste. También sincroniza el cache offline para
  /// que ventas/zona muestre el color nuevo sin refresh manual.
  Future<void> updateColor(String id, String? hexColor) async {
    final current = state.list;
    final updated = current
        .map((c) => c.id == id ? c.copyWith(color: hexColor) : c)
        .toList(growable: false);
    state = state.copyWith(data: AsyncValue.data(updated));
    try {
      await _repo.update(id, {'color': hexColor});
      await _syncOfflineCatalogCategories(updated);
    } catch (e) {
      await load(businessId: _businessId ?? 'auto');
      rethrow;
    }
  }

  Future<void> remove(String id) async {
    await _repo.remove(id);
    await load(businessId: _businessId ?? 'auto');
  }

  /// Aplica un nuevo orden a las categorías. Optimistic: actualiza el
  /// state local inmediato con la lista ya reorganizada (el UI no
  /// "pestañea" porque evitamos el AsyncValue.loading que `load()`
  /// metería). El repo persiste cada `position` con step de 10 en
  /// background. Si falla, recargamos para volver al orden real
  /// persistido (esa recarga sí parpadea — error path).
  ///
  /// También sincroniza el cache offline del menu browser (ventas/zona)
  /// para que el nuevo orden se refleje sin tener que esperar un
  /// refresh manual del catálogo.
  Future<void> reorder(List<model.Category> ordered) async {
    state = state.copyWith(data: AsyncValue.data(ordered));
    try {
      await _repo.reorder(ordered);
      await _syncOfflineCatalogCategories(ordered);
    } catch (e) {
      await load(businessId: _businessId ?? 'auto');
      rethrow;
    }
  }

  /// Reescribe la sección `categories` del snapshot offline con el orden
  /// nuevo. El menu browser de ventas/zona lee de este cache primero, así
  /// que sin este sync el reorder no se refleja hasta que el usuario
  /// fuerce un refresh del catálogo.
  ///
  /// Filtra inactivas — el cache solo lleva categorías visibles para el
  /// punto de venta (matchea el filtro `is_active = true` de la query
  /// que hidrata el snapshot).
  Future<void> _syncOfflineCatalogCategories(
    List<model.Category> ordered,
  ) async {
    final bid = _businessId;
    if (bid == null || bid.isEmpty || bid == 'auto') return;
    try {
      final activeMaps = ordered
          .where((c) => c.isActive)
          .map((c) => {'id': c.id, 'name': c.name, 'color': c.color})
          .toList(growable: false);
      await OfflineCatalogService().saveSnapshot(
        businessId: bid,
        categories: activeMaps,
      );
    } catch (e) {
      // No crítico — la próxima refresh manual del catálogo lo corrige.
      debugPrint('CategoriesVm: error sincronizando cache offline: $e');
    }
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
