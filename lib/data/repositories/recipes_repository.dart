import 'package:supabase_flutter/supabase_flutter.dart';

import '../../presentation/settings/more settings/menus/recipes/state/recipes_state.dart';

class RecipesRepository {
  final SupabaseClient _client;

  RecipesRepository(this._client);

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<List<RecipeMenuProduct>> getMenuProducts(String businessId) async {
    final response = await _client
        .from('menu_items')
        .select('id, name, is_active')
        .eq('business_id', businessId)
        .order('name');

    return List<Map<String, dynamic>>.from(
      response,
    ).map(RecipeMenuProduct.fromMap).toList(growable: false);
  }

  Future<List<RecipeInventoryItem>> getInventoryItems(String businessId) async {
    final response = await _client
        .from('inventory_items')
        .select('id, name, sku, unit, cost, is_active, purchase_unit, pack_size')
        .eq('business_id', businessId)
        .eq('is_active', true)
        .order('name');

    return List<Map<String, dynamic>>.from(
      response,
    ).map(RecipeInventoryItem.fromMap).toList(growable: false);
  }

  Future<List<RecipeSummary>> getRecipes(String businessId) async {
    final recipesResponse = await _client
        .from('recipes')
        .select(
          'id, menu_item_id, yield_quantity, instructions, created_at, menu_items!inner(id, name, business_id, is_active)',
        )
        .eq('menu_items.business_id', businessId)
        .order('created_at', ascending: false);

    final recipesRaw = List<Map<String, dynamic>>.from(recipesResponse);
    if (recipesRaw.isEmpty) return const [];

    final recipeIds = recipesRaw
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toList(growable: false);

    final ingredientsResponse = await _client
        .from('recipe_ingredients')
        .select('id, recipe_id, inventory_item_id, quantity, unit')
        .inFilter('recipe_id', recipeIds);

    final ingredientsRaw = List<Map<String, dynamic>>.from(ingredientsResponse);
    final inventoryIds = ingredientsRaw
        .map((row) => row['inventory_item_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final inventoryById = <String, RecipeInventoryItem>{};
    if (inventoryIds.isNotEmpty) {
      final inventoryResponse = await _client
          .from('inventory_items')
          .select(
            'id, name, sku, unit, cost, is_active, purchase_unit, pack_size',
          )
          .inFilter('id', inventoryIds);

      for (final row in List<Map<String, dynamic>>.from(inventoryResponse)) {
        final item = RecipeInventoryItem.fromMap(row);
        inventoryById[item.id] = item;
      }
    }

    final ingredientsByRecipe = <String, List<RecipeIngredientEntry>>{};
    for (final row in ingredientsRaw) {
      final recipeId = row['recipe_id']?.toString();
      if (recipeId == null || recipeId.isEmpty) continue;
      final inventoryItemId = row['inventory_item_id']?.toString() ?? '';
      final inventoryItem = inventoryById[inventoryItemId];
      ingredientsByRecipe.putIfAbsent(recipeId, () => <RecipeIngredientEntry>[]);
      ingredientsByRecipe[recipeId]!.add(
        RecipeIngredientEntry(
          id: row['id']?.toString() ?? '',
          inventoryItemId: inventoryItemId,
          inventoryItemName: inventoryItem?.name ?? 'Insumo',
          inventoryItemSku: inventoryItem?.sku ?? '',
          quantity: _toDouble(row['quantity']),
          unit: row['unit']?.toString() ?? inventoryItem?.unit ?? 'unidad',
          unitCost: inventoryItem?.cost ?? 0,
        ),
      );
    }

    return recipesRaw.map((row) {
      final menuItem = Map<String, dynamic>.from(
        row['menu_items'] as Map<String, dynamic>,
      );
      final recipeId = row['id']?.toString() ?? '';
      return RecipeSummary(
        id: recipeId,
        menuItemId: row['menu_item_id']?.toString() ?? '',
        menuItemName: menuItem['name']?.toString() ?? 'Producto',
        menuItemIsActive: menuItem['is_active'] != false,
        yieldQuantity: _toDouble(row['yield_quantity']),
        instructions: row['instructions']?.toString() ?? '',
        createdAt:
            DateTime.tryParse(row['created_at']?.toString() ?? '') ??
            DateTime.now(),
        ingredients: ingredientsByRecipe[recipeId] ?? const [],
      );
    }).toList(growable: false);
  }

  Future<void> saveRecipe({
    required String menuItemId,
    required double yieldQuantity,
    String? instructions,
    required List<RecipeDraftIngredient> ingredients,
  }) async {
    if (ingredients.isEmpty) {
      throw Exception('Debes agregar al menos un ingrediente.');
    }

    final existing = await _client
        .from('recipes')
        .select('id')
        .eq('menu_item_id', menuItemId)
        .limit(1)
        .maybeSingle();

    String recipeId;
    if (existing == null) {
      final created = await _client
          .from('recipes')
          .insert({
            'menu_item_id': menuItemId,
            'yield_quantity': yieldQuantity,
            'instructions': instructions,
          }..removeWhere((key, value) => value == null || value == ''))
          .select('id')
          .single();
      recipeId = created['id']?.toString() ?? '';
    } else {
      recipeId = existing['id']?.toString() ?? '';
      await _client
          .from('recipes')
          .update({
            'yield_quantity': yieldQuantity,
            'instructions': instructions,
          }..removeWhere((key, value) => value == null || value == ''))
          .eq('id', recipeId);
      await _client.from('recipe_ingredients').delete().eq('recipe_id', recipeId);
    }

    if (recipeId.isEmpty) {
      throw Exception('No se pudo guardar la receta.');
    }

    await _client.from('recipe_ingredients').insert(
      ingredients
          .map(
            (ingredient) => {
              'recipe_id': recipeId,
              'inventory_item_id': ingredient.inventoryItemId,
              'quantity': ingredient.quantity,
              'unit': ingredient.unit,
            },
          )
          .toList(growable: false),
    );
  }

  Future<void> deleteRecipe(String recipeId) async {
    await _client.from('recipes').delete().eq('id', recipeId);
  }
}
