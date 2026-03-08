import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../../../../data/repositories/recipes_repository.dart';
import '../../../../../../../data/utils/business_id_resolver.dart';
import '../state/recipes_state.dart';

final recipesRepositoryProvider = Provider<RecipesRepository>((ref) {
  return RecipesRepository(Supabase.instance.client);
});

final recipesViewModelProvider = ChangeNotifierProvider<RecipesViewModel>((ref) {
  return RecipesViewModel(ref.read(recipesRepositoryProvider));
});

class RecipesViewModel extends ChangeNotifier {
  final RecipesRepository _repository;

  RecipesState _state = const RecipesState();

  RecipesViewModel(this._repository);

  RecipesState get state => _state;

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
        error: 'Error cargando recetas: $e',
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
        error: 'Error refrescando recetas: $e',
      );
      notifyListeners();
    }
  }

  Future<void> saveRecipe({
    required String menuItemId,
    required double yieldQuantity,
    String? instructions,
    required List<RecipeDraftIngredient> ingredients,
  }) async {
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.saveRecipe(
        menuItemId: menuItemId,
        yieldQuantity: yieldQuantity,
        instructions: instructions,
        ingredients: ingredients,
      );
      _state = _state.copyWith(saving: false);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error guardando receta: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> deleteRecipe(String recipeId) async {
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.deleteRecipe(recipeId);
      _state = _state.copyWith(saving: false);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error eliminando receta: $e',
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

    final menuProducts = await _repository.getMenuProducts(businessId);
    final inventoryItems = await _repository.getInventoryItems(businessId);
    final recipes = await _repository.getRecipes(businessId);

    _state = _state.copyWith(
      loading: false,
      menuProducts: menuProducts,
      inventoryItems: inventoryItems,
      recipes: recipes,
      clearError: true,
    );
    notifyListeners();
  }
}
