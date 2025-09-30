import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'; // kIsWeb
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/tax/state/taxes_state.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/tax/viewmodel/taxes_viewmodel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../viewmodel/menu_items_viewmodel.dart';
import '../../../../../../data/models/menu_item.dart';

class MenuItemsView extends ConsumerStatefulWidget {
  final String businessId; // puede ser 'auto'
  const MenuItemsView({super.key, required this.businessId});

  @override
  ConsumerState<MenuItemsView> createState() => _MenuItemsViewState();
}

class _MenuItemsViewState extends ConsumerState<MenuItemsView> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref
          .read(menuItemsVmProvider.notifier)
          .load(businessId: widget.businessId);
      await ref
          .read(taxesVmProvider.notifier)
          .load(businessId: widget.businessId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(menuItemsVmProvider);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: MangoColors.sidebarBg,
      appBar: AppBar(
        title: const Text('Elementos del menú'),
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: .4,
        actions: [
          IconButton(
            tooltip: 'Refrescar',
            onPressed: () async {
              await ref.read(menuItemsVmProvider.notifier).refresh();
              await ref.read(taxesVmProvider.notifier).refresh();
            },
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              foregroundColor: MangoColors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (_) => const _NewItemDialog(),
              );
              if (ok == true && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Elemento creado')),
                );
              }
            },
            icon: const Icon(Icons.add),
            label: const Text('Agregar elemento de menú'),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    onChanged: (v) =>
                        ref.read(menuItemsVmProvider.notifier).setSearch(v),
                    decoration: InputDecoration(
                      hintText: 'Busca tu elemento del menú aquí',
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      fillColor: MangoColors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: MangoColors.cardBorder),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: MangoColors.cardBorder),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                _FilterDropdown<String?>(
                  label: 'Menú',
                  value: _safeValue(
                    vm.filterMenuId,
                    vm.menusList.map((e) => e.id).toList(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('-- Todos --'),
                    ),
                    ...vm.menusList.map(
                      (m) => DropdownMenuItem(value: m.id, child: Text(m.name)),
                    ),
                  ],
                  onChanged: (v) =>
                      ref.read(menuItemsVmProvider.notifier).setFilterMenu(v),
                ),
                const SizedBox(width: 8),
                _FilterDropdown<String?>(
                  label: 'Categoría',
                  value: _safeValue(
                    vm.filterCategoryId,
                    vm.categoriesList.map((e) => e.id).toList(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('-- Todas --'),
                    ),
                    ...vm.categoriesList.map(
                      (c) => DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ),
                  ],
                  onChanged: (v) => ref
                      .read(menuItemsVmProvider.notifier)
                      .setFilterCategory(v),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: MangoColors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: MangoColors.cardBorder),
                ),
                child: vm.loading && vm.filtered.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : vm.error != null
                    ? Center(
                        child: Text(
                          'Error: ${vm.error}',
                          style: text.bodyMedium?.copyWith(color: Colors.red),
                        ),
                      )
                    : const _ItemsTable(),
              ),
            ),
            if (vm.loading) const SizedBox(height: 8),
            if (vm.loading)
              const LinearProgressIndicator(
                minHeight: 2,
                color: MangoColors.primaryOrange,
              ),
          ],
        ),
      ),
    );
  }

  String? _safeValue(String? value, List<String> ids) {
    if (value == null) return null;
    final count = ids.where((e) => e == value).length;
    return count == 1 ? value : null;
  }
}

class _FilterDropdown<T> extends StatelessWidget {
  final String label;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const _FilterDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          hint: Text(label),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _ItemsTable extends ConsumerWidget {
  const _ItemsTable();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(menuItemsVmProvider);
    final text = Theme.of(context).textTheme;

    if (vm.filtered.isEmpty) {
      return Center(child: Text('No hay elementos', style: text.bodyMedium));
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: vm.filtered.length + 1,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: MangoColors.cardBorder),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Row(
              children: [
                _th('ARTÍCULO', flex: 4),
                _th('PRECIO'),
                _th('CATEGORÍA'),
                _th('MENÚ'),
                _th('DISPONIBLE'),
                _th('ACCIÓN', alignEnd: true),
              ],
            ),
          );
        }

        final it = vm.filtered[i - 1];
        return InkWell(
          onTap: () => ref.read(menuItemsVmProvider.notifier).select(it.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Row(
                    children: [
                      _ItemThumb(item: it),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              it.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if ((it.description ?? '').isNotEmpty)
                              Text(
                                it.description!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall?.copyWith(
                                  color: MangoColors.muted,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                _td('\$${(it.price ?? 0).toStringAsFixed(2)}'),
                _td(it.categoryName ?? '-'),
                _td(it.menuName ?? '-'),
                _tdSwitch(
                  value: it.isActive ?? true,
                  onChanged: (v) => ref
                      .read(menuItemsVmProvider.notifier)
                      .toggleActive(it.id, v),
                ),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: 'Editar',
                        onPressed: () async {
                          final newName = await _prompt(context, 'Renombrar');
                          if (newName != null && newName.trim().isNotEmpty) {
                            await ref
                                .read(menuItemsVmProvider.notifier)
                                .rename(it.id, newName.trim());
                          }
                        },
                        icon: const Icon(
                          Icons.edit,
                          size: 18,
                          color: MangoColors.darkGray,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Eliminar',
                        onPressed: () async {
                          final ok = await _confirm(
                            context,
                            '¿Eliminar "${it.name}"?',
                          );
                          if (ok == true) {
                            await ref
                                .read(menuItemsVmProvider.notifier)
                                .remove(it.id);
                          }
                        },
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: Colors.red,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _th(String t, {int flex = 1, bool alignEnd = false}) => Expanded(
    flex: flex,
    child: Align(
      alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
      child: Text(
        t,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          color: MangoColors.darkGray,
        ),
      ),
    ),
  );

  Widget _td(String t, {int flex = 1}) => Expanded(
    flex: flex,
    child: Text(t, overflow: TextOverflow.ellipsis),
  );

  Widget _tdSwitch({
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => Expanded(
    child: Align(
      alignment: Alignment.centerLeft,
      child: Checkbox(
        value: value,
        onChanged: (v) => onChanged(v ?? value),
        activeColor: MangoColors.successGreen,
      ),
    ),
  );
}

/// Miniatura: usa imageUrl si está; si no, firma imagePath
class _ItemThumb extends StatelessWidget {
  final MenuItem item;
  const _ItemThumb({required this.item});

  @override
  Widget build(BuildContext context) {
    const size = 56.0;

    final direct = item.imageUrl?.trim();
    if (direct != null && direct.isNotEmpty) {
      return _ThumbBox(
        size: size,
        child: Image.network(
          direct,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) =>
              const Icon(Icons.broken_image, color: MangoColors.muted),
        ),
      );
    }

    return FutureBuilder<String?>(
      future: _signedUrlFromPath(item.imagePath),
      builder: (context, snap) {
        final url = snap.data;
        if (snap.connectionState == ConnectionState.waiting) {
          return _ThumbBox(
            size: size,
            child: const Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: MangoColors.primaryOrange,
                ),
              ),
            ),
          );
        }
        if (url == null || url.isEmpty) {
          return _ThumbBox(
            size: size,
            child: const Icon(
              Icons.image_not_supported,
              color: MangoColors.muted,
            ),
          );
        }
        return _ThumbBox(
          size: size,
          child: Image.network(
            url,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                const Icon(Icons.broken_image, color: MangoColors.muted),
          ),
        );
      },
    );
  }

  Future<String?> _signedUrlFromPath(String? imagePath) async {
    if (imagePath == null || imagePath.trim().isEmpty) return null;
    var key = imagePath.trim();
    if (key.startsWith('/')) key = key.substring(1);
    final storage = Supabase.instance.client.storage.from('menu-items');
    try {
      return await storage.createSignedUrl(key, 3600);
    } catch (_) {
      return storage.getPublicUrl(key);
    }
  }
}

class _ThumbBox extends StatelessWidget {
  final double size;
  final Widget child;
  const _ThumbBox({required this.size, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: size,
        height: size,
        color: MangoColors.bgLight,
        child: child,
      ),
    );
  }
}

/// -------- Diálogo flotante crear --------
class _NewItemDialog extends ConsumerStatefulWidget {
  const _NewItemDialog();

  @override
  ConsumerState<_NewItemDialog> createState() => _NewItemDialogState();
}

class _NewItemDialogState extends ConsumerState<_NewItemDialog> {
  final _name = TextEditingController();
  final _desc = TextEditingController();
  final _sku = TextEditingController();
  final _barcode = TextEditingController();
  final _price = TextEditingController(text: '0');
  final _cost = TextEditingController();

  String? _menuId;
  String? _categoryId;
  bool _isActive = true;
  bool _hasVariants = false;

  // Imagen
  File? _pickedImageFile; // mobile/desktop
  Uint8List? _pickedImageBytes; // web

  // Impuestos seleccionados
  final Set<String> _selectedTaxIds = <String>{};

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(menuItemsVmProvider);
    final taxesState = ref.watch(taxesVmProvider);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 700),
        decoration: BoxDecoration(
          color: MangoColors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: MangoColors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  const Text(
                    'Nuevo artículo',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 20,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close),
                    color: MangoColors.darkGray,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: MangoColors.cardBorder),

            // Content
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _name,
                      decoration: InputDecoration(
                        labelText: 'Nombre del artículo',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: MangoColors.cardBorder),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    TextField(
                      controller: _desc,
                      minLines: 2,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: 'Descripción (opcional)',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: MangoColors.cardBorder),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    Row(
                      children: [
                        Expanded(
                          child: _Dropdown<String?>(
                            label: 'Elegir menú',
                            value: _menuId,
                            items: [
                              const DropdownMenuItem(
                                value: null,
                                child: Text('--'),
                              ),
                              ...vm.menusList.map(
                                (m) => DropdownMenuItem(
                                  value: m.id,
                                  child: Text(m.name),
                                ),
                              ),
                            ],
                            onChanged: (v) => setState(() => _menuId = v),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _Dropdown<String?>(
                            label: 'Categoría',
                            value: _categoryId,
                            items: [
                              const DropdownMenuItem(
                                value: null,
                                child: Text('--'),
                              ),
                              ...vm.categoriesList.map(
                                (c) => DropdownMenuItem(
                                  value: c.id,
                                  child: Text(c.name),
                                ),
                              ),
                            ],
                            onChanged: (v) => setState(() => _categoryId = v),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _price,
                            enabled: !_hasVariants,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Precio',
                              prefixText: '\$ ',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: MangoColors.cardBorder,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _cost,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Costo (opcional)',
                              prefixText: '\$ ',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: MangoColors.cardBorder,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _sku,
                            decoration: InputDecoration(
                              labelText: 'Referencia (SKU) (opcional)',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: MangoColors.cardBorder,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _barcode,
                            decoration: InputDecoration(
                              labelText: 'Código de barras (opcional)',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: MangoColors.cardBorder,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    SwitchListTile(
                      value: _hasVariants,
                      onChanged: (v) {
                        setState(() {
                          _hasVariants = v;
                          if (v) _price.clear();
                        });
                      },
                      title: const Text('Tiene variaciones'),
                      contentPadding: EdgeInsets.zero,
                      activeColor: MangoColors.successGreen,
                    ),

                    SwitchListTile(
                      value: _isActive,
                      onChanged: (v) => setState(() => _isActive = v),
                      title: const Text('Disponible'),
                      contentPadding: EdgeInsets.zero,
                      activeColor: MangoColors.successGreen,
                    ),

                    const SizedBox(height: 12),

                    Row(
                      children: [
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: MangoColors.white,
                            foregroundColor: MangoColors.darkGray,
                            side: BorderSide(color: MangoColors.cardBorder),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () async {
                            final r = await FilePicker.platform.pickFiles(
                              type: FileType.image,
                              withData: kIsWeb,
                            );
                            if (r != null) {
                              if (kIsWeb) {
                                setState(() {
                                  _pickedImageBytes = r.files.single.bytes;
                                  _pickedImageFile = null;
                                });
                              } else {
                                final p = r.files.single.path;
                                if (p != null) {
                                  setState(() {
                                    _pickedImageFile = File(p);
                                    _pickedImageBytes = null;
                                  });
                                }
                              }
                            }
                          },
                          icon: const Icon(Icons.image),
                          label: const Text('Elegir imagen'),
                        ),
                        const SizedBox(width: 12),
                        _ImagePreview(
                          bytes: _pickedImageBytes,
                          file: _pickedImageFile,
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    _TaxesBlock(
                      state: taxesState,
                      initiallySelected: _selectedTaxIds,
                      onToggle: (taxId, enabled) {
                        setState(() {
                          if (enabled) {
                            _selectedTaxIds.add(taxId);
                          } else {
                            _selectedTaxIds.remove(taxId);
                          }
                        });
                      },
                    ),
                  ],
                ),
              ),
            ),

            // Footer
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: MangoColors.white,
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(16),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: MangoColors.darkGray,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: MangoColors.primaryOrange,
                      foregroundColor: MangoColors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () async {
                      final name = _name.text.trim();
                      if (name.isEmpty) return;

                      final price = double.tryParse(_price.text.trim()) ?? 0;
                      final cost = double.tryParse(_cost.text.trim());
                      final sku = _sku.text.trim().isEmpty
                          ? null
                          : _sku.text.trim();
                      final barcode = _barcode.text.trim().isEmpty
                          ? null
                          : _barcode.text.trim();

                      await ref
                          .read(menuItemsVmProvider.notifier)
                          .create(
                            name: name,
                            description: _desc.text.trim().isEmpty
                                ? null
                                : _desc.text.trim(),
                            categoryId: _categoryId,
                            menuId: _menuId,
                            price: _hasVariants ? 0 : price,
                            sku: sku,
                            hasVariants: _hasVariants,
                            isActive: _isActive,
                            imageFile: _pickedImageFile,
                            imageBytes: _pickedImageBytes,
                            taxIds: _selectedTaxIds.toList(),
                            cost: cost,
                            barcode: barcode,
                          );
                      if (mounted) Navigator.pop(context, true);
                    },
                    child: const Text('Guardar'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaxesBlock extends StatelessWidget {
  final TaxesState state;
  final Set<String> initiallySelected;
  final void Function(String taxId, bool enabled) onToggle;

  const _TaxesBlock({
    required this.state,
    required this.initiallySelected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final taxes = state.list;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: MangoColors.cardBorder),
        borderRadius: BorderRadius.circular(12),
        color: MangoColors.white,
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: MangoColors.white,
              border: Border(bottom: BorderSide(color: MangoColors.cardBorder)),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
            ),
            child: const Text(
              'Impuestos',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: MangoColors.darkGray,
              ),
            ),
          ),
          if (state.data.isLoading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(
                minHeight: 2,
                color: MangoColors.primaryOrange,
              ),
            )
          else if (state.data.hasError)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Error al cargar impuestos: ${state.data.error}',
                style: const TextStyle(color: Colors.red),
              ),
            )
          else if (taxes.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No hay impuestos configurados',
                style: TextStyle(color: MangoColors.muted),
              ),
            )
          else
            ...taxes.map((t) {
              final enabled = initiallySelected.contains(t.id);
              return Container(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: t != taxes.last
                        ? BorderSide(
                            color: MangoColors.cardBorder.withOpacity(0.5),
                          )
                        : BorderSide.none,
                  ),
                ),
                child: SwitchListTile(
                  value: enabled,
                  onChanged: (v) => onToggle(t.id, v),
                  title: Text('${t.name}, ${t.rate.toStringAsFixed(0)}%'),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  activeColor: MangoColors.successGreen,
                ),
              );
            }).toList(),
        ],
      ),
    );
  }
}

class _ImagePreview extends StatelessWidget {
  final Uint8List? bytes; // web
  final File? file; // mobile/desktop
  const _ImagePreview({this.bytes, this.file});

  @override
  Widget build(BuildContext context) {
    const size = 56.0;
    Widget child;
    if (kIsWeb) {
      child = (bytes == null)
          ? const Icon(Icons.image, color: MangoColors.muted)
          : Image.memory(bytes!, fit: BoxFit.cover);
    } else {
      child = (file == null)
          ? const Icon(Icons.image, color: MangoColors.muted)
          : Image.file(file!, fit: BoxFit.cover);
    }

    return Expanded(
      child: Align(
        alignment: Alignment.centerLeft,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: size,
            height: size,
            color: MangoColors.bgLight,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  final String label;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const _Dropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final count = items.where((it) => it.value == value).length;
    final safeValue = (items.isEmpty || value == null || count != 1)
        ? null
        : value;

    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: MangoColors.cardBorder),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: safeValue,
          isExpanded: true,
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

// Helpers de diálogo
Future<String?> _prompt(BuildContext ctx, String title) async {
  final c = TextEditingController();
  return showDialog<String>(
    context: ctx,
    builder: (d) => AlertDialog(
      backgroundColor: MangoColors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: MangoColors.darkGray,
        ),
      ),
      content: TextField(
        controller: c,
        autofocus: true,
        onSubmitted: (v) => Navigator.pop(d, v),
        decoration: InputDecoration(
          hintText: 'Escribe aquí',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: MangoColors.cardBorder),
          ),
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: MangoColors.darkGray,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: () => Navigator.pop(d),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: MangoColors.primaryOrange,
            foregroundColor: MangoColors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: () => Navigator.pop(d, c.text),
          child: const Text('Guardar'),
        ),
      ],
    ),
  );
}

Future<bool?> _confirm(BuildContext ctx, String title) async {
  return showDialog<bool>(
    context: ctx,
    builder: (d) => AlertDialog(
      backgroundColor: MangoColors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: MangoColors.darkGray,
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: MangoColors.darkGray,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: () => Navigator.pop(d, false),
          child: const Text('No'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: MangoColors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: () => Navigator.pop(d, true),
          child: const Text('Sí, eliminar'),
        ),
      ],
    ),
  );
}
