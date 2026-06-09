// lib/presentation/settings/more settings/menus/menu items/viewmodel/menu_items_viewmodel.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/core/storage/image_upload_helper.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../state/menu_items_state.dart';
import '../../../../../../data/repositories/menu_item_repository.dart';
import '../../../../../../data/repositories/category_repository.dart';
import '../../../../../../data/repositories/menu_repository.dart';

final menuItemsVmProvider = NotifierProvider<MenuItemsVm, MenuItemsState>(
  MenuItemsVm.new,
);

class MenuItemsVm extends Notifier<MenuItemsState> {
  final _repo = MenuItemRepository();
  final _cats = CategoryRepository();
  final _menus = MenuRepository();

  late String _businessId;

  @override
  MenuItemsState build() => const MenuItemsState();

  Future<void> load({required String businessId}) async {
    _businessId = businessId;

    state = state.copyWith(
      data: const AsyncLoading(),
      categories: const AsyncLoading(),
      menus: const AsyncLoading(),
    );

    try {
      final itemsF = _repo.list(_businessId);
      final catsF = _cats.list(_businessId);
      final menusF = _menus.list(_businessId);

      final items = await itemsF;
      final cats = await catsF;
      final menus = await menusF;

      final uniqCats = {for (final c in cats) c.id: c}.values.toList();
      final uniqMenus = {for (final m in menus) m.id: m}.values.toList();

      state = state.copyWith(
        data: AsyncData(items),
        categories: AsyncData(uniqCats),
        menus: AsyncData(uniqMenus),
      );
    } catch (e, st) {
      state = state.copyWith(
        data: AsyncError(e, st),
        categories: const AsyncData([]),
        menus: const AsyncData([]),
      );
    }
  }

  Future<void> refresh() => load(businessId: _businessId);

  void setSearch(String q) => state = state.copyWith(search: q);

  void setFilterMenu(String? id) {
    final exists = id == null || state.menusList.any((m) => m.id == id);
    state = state.copyWith(filterMenuId: exists ? id : null);
  }

  void setFilterCategory(String? id) {
    final exists = id == null || state.categoriesList.any((c) => c.id == id);
    state = state.copyWith(filterCategoryId: exists ? id : null);
  }

  void select(String? id) => state = state.copyWith(selectedId: id);

  /// -------- CREATE ----------
  Future<void> create({
    required String name,
    String? description,
    String? categoryId,
    String? menuId,
    double price = 0,
    String? sku,
    bool hasVariants = false,
    bool isActive = true,

    // Imagen (web o device)
    File? imageFile,
    Uint8List? imageBytes,

    // nuevos
    List<String>? taxIds,
    double? cost,
    String? barcode,
    String? presentation,
  }) async {
    try {
      String? imagePath;
      String? imageUrl;

      // Subida de imagen (soporta web con bytes)
      if (imageFile != null || imageBytes != null) {
        // PRD 7 Fase 2.2: comprimir antes de subir.
        final rawBytes = imageBytes ?? await imageFile!.readAsBytes();
        final compressed = await ImageUploadHelper.compressForMenu(rawBytes);
        final ext = identical(compressed, rawBytes)
            ? _guessExt(imageFile?.path ?? 'upload.jpg')
            : 'jpg';
        final biz = await BusinessResolver.ensure(_businessId);
        final key = 'items/$biz/${const Uuid().v4()}.$ext';

        final storage = Supabase.instance.client.storage.from('menu-items');

        await storage.uploadBinary(
          key,
          compressed,
          fileOptions: const FileOptions(upsert: true),
        );

        imagePath = key;
        imageUrl = storage.getPublicUrl(key); // útil si el bucket es público
      }

      await _repo.create(
        businessId: _businessId,
        name: name,
        description: description,
        categoryId: categoryId,
        price: price,
        sku: sku,
        hasVariants: hasVariants,
        isActive: isActive,
        imagePath: imagePath,
        imageUrl: imageUrl,
        attachMenuId: menuId,
        hasPrep: false,
        // nuevos
        taxIds: taxIds,
        cost: cost,
        barcode: barcode,
        presentation: presentation,
      );

      await refresh();
    } catch (e, st) {
      state = state.copyWith(data: AsyncError(e, st));
      rethrow;
    }
  }

  Future<void> rename(String id, String newName) async {
    await _repo.update(id, {'name': newName});
    await refresh();
  }

  /// Etiqueta de presentación (Botella/Trago/Shot…). `null`/vacío la limpia.
  Future<void> setPresentation(String id, String? value) async {
    final v = value?.trim();
    await _repo.update(id, {'presentation': (v == null || v.isEmpty) ? null : v});
    await refresh();
  }

  /// Etiquetas de presentación distintas ya usadas (para autocompletar y
  /// mantenerlas consistentes). Ordenadas alfabéticamente.
  List<String> get presentationOptions {
    final set = <String>{};
    for (final it in state.list) {
      final p = it.presentation?.trim();
      if (p != null && p.isNotEmpty) set.add(p);
    }
    final list = set.toList()..sort();
    return list;
  }

  Future<void> updatePrice(String id, double price) async {
    await _repo.update(id, {'price': price});
    await refresh();
  }

  Future<void> toggleActive(String id, bool v) async {
    await _repo.toggleActive(id, v);
    await refresh();
  }

  Future<void> remove(String id) async {
    await _repo.remove(id);
    if (state.selectedId == id) {
      state = state.copyWith(clearSelected: true);
    }
    await refresh();
  }

  String _guessExt(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.png')) return 'png';
    if (p.endsWith('.webp')) return 'webp';
    if (p.endsWith('.jpeg')) return 'jpeg';
    if (p.endsWith('.jpg')) return 'jpg';
    return 'jpg';
  }
}
