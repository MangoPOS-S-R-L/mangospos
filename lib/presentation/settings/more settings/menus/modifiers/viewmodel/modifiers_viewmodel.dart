import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../../../../../data/repositories/modifiers_repository.dart';
import '../../../../../../../data/utils/business_id_resolver.dart';
import '../state/modifiers_state.dart';

final modifiersRepositoryProvider = Provider<ModifiersRepository>((ref) {
  return ModifiersRepository(Supabase.instance.client);
});

final modifiersViewModelProvider =
    ChangeNotifierProvider<ModifiersViewModel>((ref) {
      return ModifiersViewModel(ref.read(modifiersRepositoryProvider));
    });

class ModifiersViewModel extends ChangeNotifier {
  final ModifiersRepository _repository;

  ModifiersState _state = const ModifiersState();

  ModifiersViewModel(this._repository);

  ModifiersState get state => _state;

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
        error: 'Error cargando modificadores: $e',
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
        error: 'Error refrescando modificadores: $e',
      );
      notifyListeners();
    }
  }

  void selectGroup(String groupId) {
    _state = _state.copyWith(selectedGroupId: groupId);
    notifyListeners();
  }

  Future<void> createGroup({
    required String name,
    required int minSelect,
    required int maxSelect,
    required bool isActive,
  }) async {
    final businessId = _state.businessId;
    if (businessId == null) {
      throw Exception('No hay negocio activo.');
    }

    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      final id = const Uuid().v4();
      await _repository.createGroup(
        businessId: businessId,
        id: id,
        name: name,
        minSelect: minSelect,
        maxSelect: maxSelect,
        isActive: isActive,
      );
      _state = _state.copyWith(saving: false, selectedGroupId: id);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error creando grupo: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateGroup({
    required String id,
    required String name,
    required int minSelect,
    required int maxSelect,
    required bool isActive,
  }) async {
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.updateGroup(
        id: id,
        name: name,
        minSelect: minSelect,
        maxSelect: maxSelect,
        isActive: isActive,
      );
      _state = _state.copyWith(saving: false);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error actualizando grupo: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> deleteGroup(String id) async {
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.deleteGroup(id);
      final fallback = _state.groups
          .where((group) => group.id != id)
          .map((group) => group.id)
          .toList(growable: false);
      _state = _state.copyWith(
        saving: false,
        selectedGroupId: fallback.isEmpty ? null : fallback.first,
      );
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error eliminando grupo: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> createModifier({
    required String groupId,
    required String name,
    required double priceDelta,
    required bool isActive,
  }) async {
    final businessId = _state.businessId;
    if (businessId == null) {
      throw Exception('No hay negocio activo.');
    }

    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.createModifier(
        businessId: businessId,
        id: const Uuid().v4(),
        groupId: groupId,
        name: name,
        priceDelta: priceDelta,
        isActive: isActive,
      );
      _state = _state.copyWith(saving: false, selectedGroupId: groupId);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error creando modificador: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateModifier({
    required String id,
    required String groupId,
    required String name,
    required double priceDelta,
    required bool isActive,
  }) async {
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.updateModifier(
        id: id,
        groupId: groupId,
        name: name,
        priceDelta: priceDelta,
        isActive: isActive,
      );
      _state = _state.copyWith(saving: false, selectedGroupId: groupId);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error actualizando modificador: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> deleteModifier(String id) async {
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.deleteModifier(id);
      _state = _state.copyWith(saving: false);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error eliminando modificador: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> replaceAssignments({
    required String groupId,
    required List<String> menuItemIds,
  }) async {
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.replaceAssignments(
        groupId: groupId,
        menuItemIds: menuItemIds,
      );
      _state = _state.copyWith(saving: false, selectedGroupId: groupId);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error asignando productos: $e',
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

    final groups = await _repository.getGroups(businessId);
    final products = await _repository.getProducts(businessId);
    final modifiers = await _repository.getModifiers(businessId);
    final assignments = await _repository.getAssignments(businessId);

    final selectedGroupId = _resolveSelectedGroupId(groups);

    _state = _state.copyWith(
      loading: false,
      products: products,
      groups: groups,
      modifiers: modifiers,
      assignedProductIdsByGroup: assignments,
      selectedGroupId: selectedGroupId,
      clearError: true,
    );
    notifyListeners();
  }

  String? _resolveSelectedGroupId(List<ModifierGroupSummary> groups) {
    if (groups.isEmpty) return null;
    final current = _state.selectedGroupId;
    if (current == null || current.isEmpty) return groups.first.id;
    for (final group in groups) {
      if (group.id == current) return current;
    }
    return groups.first.id;
  }
}
