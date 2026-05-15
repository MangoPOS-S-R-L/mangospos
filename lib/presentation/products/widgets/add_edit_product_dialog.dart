import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_shadows.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/data/repositories/modifiers_repository.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/areas/viewmodel/print_areas_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/tax/state/taxes_state.dart';
import 'package:mangopos/presentation/settings/more settings/system settings/tax/viewmodel/taxes_viewmodel.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AddEditProductDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic>? product;
  final List<Map<String, dynamic>> categories;
  final List<Map<String, dynamic>> menus;
  final Future<Map<String, dynamic>> Function(String name)? onCreateCategory;
  final Function({
    required String name,
    required double price,
    required String? categoryId,
    String taxMode,
    String? sku,
    String? description,
    String? menuId,
    double? cost,
    String? barcode,
    bool hasVariants,
    bool isActive,
    String itemType,
    String? printAreaCode,
    File? imageFile,
    Uint8List? imageBytes,
    List<String> taxIds,
    bool isInventoryTracked,
    double initialStock,
  })
  onAdd;

  final Function({
    required String id,
    required String name,
    required double price,
    required String? categoryId,
    String taxMode,
    String? sku,
    required bool isActive,
    String? description,
    String? menuId,
    double? cost,
    String? barcode,
    bool hasVariants,
    String itemType,
    String? printAreaCode,
    File? imageFile,
    Uint8List? imageBytes,
    List<String> taxIds,
    bool? isInventoryTracked,
    double initialStock,
  })
  onUpdate;

  const AddEditProductDialog({
    super.key,
    this.product,
    required this.categories,
    required this.menus,
    this.onCreateCategory,
    required this.onAdd,
    required this.onUpdate,
  });

  @override
  ConsumerState<AddEditProductDialog> createState() =>
      _AddEditProductDialogState();
}

class _AddEditProductDialogState extends ConsumerState<AddEditProductDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _descController;
  late TextEditingController _priceController;
  late TextEditingController _costController;
  late TextEditingController _skuController;
  late TextEditingController _barcodeController;

  String? _selectedCategoryId;
  String? _selectedMenuId;
  String _taxMode = 'exclusive';
  bool _isActive = true;
  bool _hasVariants = false;
  String _itemType = 'standard';
  /// `null` = el admin no eligió area todavía. Send-to-kitchen bloquea
  /// con error claro si esto se queda asi.
  String? _printAreaCode;

  /// Si true, el producto consume stock al venderse. Al activarlo en un
  /// producto nuevo o existente sin tracking previo, se pide stock inicial
  /// que se registra como movimiento `purchase` en la bodega principal.
  bool _isInventoryTracked = false;
  bool _wasInventoryTrackedInitially = false;
  late TextEditingController _initialStockController;

  File? _pickedImageFile;
  Uint8List? _pickedImageBytes;
  final Set<String> _selectedTaxIds = <String>{};
  late List<Map<String, dynamic>> _categories;
  bool _isCreatingCategory = false;

  // Modificadores asignados al producto (orden personalizado).
  late final ModifiersRepository _modifiersRepo = ModifiersRepository(
    Supabase.instance.client,
  );
  List<Map<String, dynamic>> _orderedGroups = const [];
  bool _loadingGroups = false;
  bool _savingGroupsOrder = false;

  @override
  void initState() {
    super.initState();
    final p = widget.product;
    _categories = List<Map<String, dynamic>>.from(widget.categories);
    _nameController = TextEditingController(text: p?['name'] ?? '');
    _descController = TextEditingController(text: p?['description'] ?? '');
    _priceController = TextEditingController(
      text: p?['price']?.toString() ?? '0',
    );
    _costController = TextEditingController(text: p?['cost']?.toString() ?? '');
    _skuController = TextEditingController(text: p?['sku'] ?? '');
    _barcodeController = TextEditingController(text: p?['barcode'] ?? '');

    _selectedCategoryId = p?['category_id']?.toString();

    // Extract menuId from menu_item_links if not directly on product
    if (p?['menu_id'] != null) {
      _selectedMenuId = p!['menu_id'].toString();
    } else {
      final links = p?['menu_item_links'] as List<dynamic>?;
      if (links != null && links.isNotEmpty) {
        final firstLink = links.first as Map<String, dynamic>;
        _selectedMenuId = firstLink['menu_id']?.toString();
      }
    }

    _taxMode = (p?['tax_mode']?.toString() == 'inclusive')
        ? 'inclusive'
        : 'exclusive';
    _isActive = p?['is_active'] ?? true;
    _hasVariants = p?['has_variants'] ?? false;
    _itemType = p?['item_type']?.toString() ?? 'standard';
    _printAreaCode = p?['print_area_code']?.toString();
    _isInventoryTracked = p?['is_inventory_tracked'] == true;
    _wasInventoryTrackedInitially = _isInventoryTracked;
    _initialStockController = TextEditingController(text: '0');

    Future.microtask(() async {
      try {
        await ref.read(taxesVmProvider.notifier).load(businessId: 'auto');
      } catch (_) {}
      // Cargar areas configuradas del negocio para el dropdown dinámico.
      try {
        await ref
            .read(printingAreasViewModelProvider.notifier)
            .load(businessId: 'auto');
      } catch (_) {}
    });

    if (p != null) {
      final taxLinks = p['menu_item_taxes'];
      if (taxLinks is List) {
        for (final link in taxLinks) {
          if (link is Map<String, dynamic>) {
            final taxId = link['tax_id']?.toString();
            if (taxId != null && taxId.isNotEmpty) {
              _selectedTaxIds.add(taxId);
            }
          }
        }
      }

      // Cargar grupos asignados (con su orden actual) solo en edición.
      final productId = p['id']?.toString();
      if (productId != null && productId.isNotEmpty) {
        _loadingGroups = true;
        Future.microtask(() async {
          try {
            final groups =
                await _modifiersRepo.getGroupsForMenuItem(productId);
            if (!mounted) return;
            setState(() {
              _orderedGroups = groups;
              _loadingGroups = false;
            });
          } catch (_) {
            if (!mounted) return;
            setState(() => _loadingGroups = false);
          }
        });
      }
    }
  }

  Future<void> _persistGroupOrder() async {
    final productId = widget.product?['id']?.toString();
    if (productId == null || productId.isEmpty) return;
    final ids = _orderedGroups
        .map((g) => g['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (ids.isEmpty) return;
    setState(() => _savingGroupsOrder = true);
    try {
      await _modifiersRepo.reorderModifierGroupsForMenuItem(
        menuItemId: productId,
        orderedGroupIds: ids,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Orden de modificadores actualizado.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al guardar orden: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _savingGroupsOrder = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _priceController.dispose();
    _costController.dispose();
    _skuController.dispose();
    _barcodeController.dispose();
    _initialStockController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AddEditProductDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.categories != widget.categories) {
      _categories = List<Map<String, dynamic>>.from(widget.categories);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.product != null;
    final taxesState = ref.watch(taxesVmProvider);
    final size = MediaQuery.of(context).size;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: size.width > 900 ? 20 : 8,
        vertical: size.height > 700 ? 14 : 8,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 1040,
          maxHeight: size.height * 0.9,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            boxShadow: AppShadows.cardInteractive,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xxl, AppSpacing.lg, AppSpacing.md, AppSpacing.sm),
                child: Row(
                  children: [
                    Text(
                      isEdit
                          ? 'Editar Elemento de Men\u00fa'
                          : 'Agregar Elemento de Men\u00fa',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppColors.foreground,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 24),
                      color: AppColors.mutedForeground,
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: AppColors.border),
              Expanded(
                child: Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.xxl, AppSpacing.lg, AppSpacing.xxl, AppSpacing.lg),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final isWide = constraints.maxWidth >= 900;
                        if (isWide) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _buildLeftColumn()),
                              const SizedBox(width: AppSpacing.xl),
                              Expanded(child: _buildRightColumn(taxesState)),
                            ],
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildLeftColumn(),
                            const SizedBox(height: AppSpacing.lg),
                            _buildRightColumn(taxesState),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
              Divider(height: 1, color: AppColors.border),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xxl, AppSpacing.md, AppSpacing.xxl, AppSpacing.lg),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: AppColors.border),
                        foregroundColor: AppColors.foreground,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xxl,
                          vertical: AppSpacing.md,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.button),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('Cancelar'),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    ElevatedButton(
                      onPressed: _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: AppColors.card,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xxl,
                          vertical: AppSpacing.md,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.button),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: Text(
                        isEdit ? 'Actualizar Producto' : 'Agregar Producto',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLeftColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel('Nombre del Art\u00edculo', required: true),
        _buildTextField(
          controller: _nameController,
          hintText: 'Ej: Pollo al Horno',
          validator: (v) =>
              v?.trim().isEmpty == true ? 'Campo requerido' : null,
        ),
        const SizedBox(height: AppSpacing.lg),
        _fieldLabel('Descripci\u00f3n'),
        _buildTextField(
          controller: _descController,
          hintText: 'Descripci\u00f3n del producto...',
          minLines: 4,
          maxLines: 4,
        ),
        const SizedBox(height: AppSpacing.lg),
        _fieldLabel('Men\u00fa', required: true),
        _buildDropdown<String?>(
          value: _selectedMenuId,
          hint: 'Seleccionar men\u00fa',
          items: widget.menus
              .map(
                (m) => DropdownMenuItem<String?>(
                  value: m['id'].toString(),
                  child: Text(m['name']?.toString() ?? ''),
                ),
              )
              .toList(),
          onChanged: (v) => setState(() => _selectedMenuId = v),
        ),
        const SizedBox(height: AppSpacing.lg),
        _fieldLabel('Categor\u00eda', required: true),
        Row(
          children: [
            Expanded(
              child: _buildDropdown<String?>(
                value: _selectedCategoryId,
                hint: 'Seleccionar categor\u00eda',
                items: _categories
                    .map(
                      (c) => DropdownMenuItem<String?>(
                        value: c['id'].toString(),
                        child: Text(c['name']?.toString() ?? ''),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _selectedCategoryId = v),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            SizedBox(
              width: 58,
              height: 58,
              child: OutlinedButton(
                onPressed: _isCreatingCategory ? null : _createCategoryInline,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: AppColors.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.button),
                  ),
                  foregroundColor: AppColors.foreground,
                ),
                child: _isCreatingCategory
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.primary,
                        ),
                      )
                    : const Icon(Icons.add, size: 24),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRightColumn(TaxesState taxesState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _fieldLabel('Precio', required: true),
                  _buildTextField(
                    controller: _priceController,
                    hintText: '0',
                    enabled: !_hasVariants,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: (v) {
                      if (_hasVariants) return null;
                      if (v == null || v.trim().isEmpty) {
                        return 'Campo requerido';
                      }
                      return null;
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _fieldLabel('Costo'),
                  _buildTextField(
                    controller: _costController,
                    hintText: '0',
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _fieldLabel('Referencia/SKU'),
                  _buildTextField(
                    controller: _skuController,
                    hintText: 'SKU-001',
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _fieldLabel('C\u00f3digo de Barras'),
                  _buildTextField(
                    controller: _barcodeController,
                    hintText: '123456789',
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        _fieldLabel('Imagen del Producto'),
        _ImagePickerArea(
          bytes: _pickedImageBytes,
          file: _pickedImageFile,
          existingUrl: widget.product?['image_url']?.toString(),
          onTap: _pickImage,
        ),
        const SizedBox(height: AppSpacing.lg),
        _fieldLabel('Tipo de elemento'),
        _buildDropdown<String>(
          value: _itemType,
          hint: 'Tipo de elemento',
          items: const [
            DropdownMenuItem(value: 'standard', child: Text('Producto normal')),
            DropdownMenuItem(value: 'combo', child: Text('Combo')),
            DropdownMenuItem(
              value: 'extra_only',
              child: Text('Extra / add-on'),
            ),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() => _itemType = value);
          },
        ),
        const SizedBox(height: AppSpacing.lg),
        _fieldLabel('Área de impresión'),
        _buildPrintAreaSelector(),
        const SizedBox(height: AppSpacing.lg),
        _switchRow(
          title: 'Tiene Variaciones',
          value: _hasVariants,
          onChanged: (v) {
            setState(() {
              _hasVariants = v;
              if (v) _priceController.clear();
            });
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        _switchRow(
          title: 'Disponible',
          value: _isActive,
          onChanged: (v) => setState(() => _isActive = v),
        ),
        const SizedBox(height: AppSpacing.sm),
        _switchRow(
          title: 'Inventariable',
          value: _isInventoryTracked,
          onChanged: (v) => setState(() => _isInventoryTracked = v),
        ),
        if (_isInventoryTracked && !_wasInventoryTrackedInitially) ...[
          const SizedBox(height: AppSpacing.xs),
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.25),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Stock inicial',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Se registrará como entrada en la bodega principal. '
                  'Puedes dejarlo en 0 y agregar stock luego desde Inventario.',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.mutedForeground,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextFormField(
                  controller: _initialStockController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Cantidad',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        _switchRow(
          title: 'Impuestos',
          value: _selectedTaxIds.isNotEmpty,
          onChanged: (v) {
            setState(() {
              if (!v) {
                _selectedTaxIds.clear();
              }
            });
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        _fieldLabel('Modo de impuesto'),
        _taxModeSelector(),
        const SizedBox(height: AppSpacing.sm),
        Text(
          _taxMode == 'inclusive'
              ? 'El precio del producto ya incluye el impuesto aplicado en venta.'
              : 'El impuesto se suma sobre el precio del producto durante la venta.',
          style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
        ),
        if (taxesState.data.isLoading)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: LinearProgressIndicator(color: AppColors.primary),
          ),
        if (taxesState.data.hasError)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Text(
              'Error al cargar impuestos',
              style: TextStyle(color: AppColors.destructive),
            ),
          ),
        if (!taxesState.data.isLoading && taxesState.list.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: AppSpacing.sm),
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            decoration: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: taxesState.list.map((tax) {
                final selected = _selectedTaxIds.contains(tax.id);
                return _taxSwitchRow(
                  title: '${tax.name} (${tax.rate.toStringAsFixed(0)}%)',
                  value: selected,
                  onChanged: (v) {
                    setState(() {
                      if (v) {
                        _selectedTaxIds.add(tax.id);
                      } else {
                        _selectedTaxIds.remove(tax.id);
                      }
                    });
                  },
                );
              }).toList(),
            ),
          ),
        if (widget.product != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _modifierGroupsSection(),
        ],
      ],
    );
  }

  Widget _modifierGroupsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _fieldLabel('Modificadores y orden'),
            const Spacer(),
            if (_savingGroupsOrder)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        Text(
          'Arrastra para cambiar el orden en que se muestran al cobrar.',
          style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_loadingGroups)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: LinearProgressIndicator(color: AppColors.primary),
          )
        else if (_orderedGroups.isEmpty)
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              'Este producto no tiene grupos de modificadores asignados. '
              'Asigna grupos desde Ajustes → Menús → Modificadores.',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.mutedForeground,
              ),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: AppColors.border),
            ),
            child: ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: _orderedGroups.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex -= 1;
                  final item = _orderedGroups.removeAt(oldIndex);
                  _orderedGroups = List<Map<String, dynamic>>.from(
                    _orderedGroups,
                  )..insert(newIndex, item);
                });
                _persistGroupOrder();
              },
              itemBuilder: (context, index) {
                final group = _orderedGroups[index];
                final name = group['name']?.toString() ?? '';
                final isActive = group['is_active'] == true;
                return ListTile(
                  key: ValueKey(group['id']),
                  dense: true,
                  leading: Text(
                    '${index + 1}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                  title: Text(
                    name,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: isActive
                          ? AppColors.foreground
                          : AppColors.mutedForeground,
                    ),
                  ),
                  subtitle: !isActive
                      ? const Text(
                          'Inactivo',
                          style: TextStyle(fontSize: 11),
                        )
                      : null,
                  trailing: ReorderableDragStartListener(
                    index: index,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: Icon(
                        Icons.drag_indicator,
                        color: const Color(0xFF6B7280),
                        size: 22,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _fieldLabel(String text, {bool required = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(
        required ? '$text *' : text,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: AppColors.foreground,
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hintText,
    int? minLines,
    int? maxLines = 1,
    TextInputType? keyboardType,
    bool enabled = true,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      minLines: minLines,
      maxLines: maxLines,
      keyboardType: keyboardType,
      validator: validator,
      style: TextStyle(fontSize: 15, color: AppColors.foreground),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: TextStyle(color: AppColors.mutedForeground, fontSize: 15),
        filled: true,
        fillColor: enabled ? AppColors.card : AppColors.muted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
          borderSide: BorderSide(
            color: AppColors.primary,
            width: 2,
          ),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
          borderSide: BorderSide(color: AppColors.border),
        ),
        contentPadding: EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: maxLines != null && maxLines > 1 ? AppSpacing.md : AppSpacing.md,
        ),
      ),
    );
  }

  /// Dropdown dinámico de áreas de impresión configuradas para el negocio.
  ///
  /// - Si aún se está cargando: muestra spinner.
  /// - Si no hay áreas activas: muestra mensaje + dirige al admin a Ajustes
  ///   → Impresoras → Áreas para crearlas (sin defaults hardcodeados).
  /// - Si hay áreas: dropdown con `code → name` de cada area activa. El
  ///   admin puede dejar el campo vacío y el producto queda sin enrutar
  ///   (send-to-kitchen lo bloquea con error claro).
  Widget _buildPrintAreaSelector() {
    final areasState = ref.watch(printingAreasViewModelProvider);
    final activeAreas = areasState.items
        .where((area) => area.isActive)
        .toList(growable: false);

    if (areasState.isLoading && activeAreas.isEmpty) {
      return Container(
        height: 58,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.button),
          border: Border.all(color: AppColors.border),
        ),
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              'Cargando áreas...',
              style: TextStyle(color: AppColors.mutedForeground, fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (activeAreas.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.button),
          border: Border.all(color: AppColors.border),
          color: AppColors.accent,
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: AppColors.mutedForeground),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                'No hay áreas de impresión configuradas. Ve a Ajustes → '
                'Impresoras → Áreas para crearlas.',
                style: TextStyle(
                  color: AppColors.mutedForeground,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Si el código guardado en el producto no coincide con ninguna area
    // activa (e.g. area renombrada/desactivada después), forzamos null para
    // que el dropdown no crashee y el admin reasigne explícitamente.
    final hasCurrentValue =
        _printAreaCode != null &&
        activeAreas.any((a) => a.code == _printAreaCode);
    final dropdownValue = hasCurrentValue ? _printAreaCode : null;

    return _buildDropdown<String>(
      value: dropdownValue,
      hint: 'Selecciona un área',
      items: activeAreas
          .map(
            (area) => DropdownMenuItem<String>(
              value: area.code,
              child: Text(area.name),
            ),
          )
          .toList(growable: false),
      onChanged: (value) {
        if (value == null) return;
        setState(() => _printAreaCode = value);
      },
    );
  }

  Widget _buildDropdown<T>({
    required T? value,
    required String hint,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          hint: Text(
            hint,
            style: TextStyle(color: AppColors.mutedForeground, fontSize: 14),
          ),
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 24),
          items: items,
          onChanged: onChanged,
          style: TextStyle(
            color: AppColors.foreground,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _switchRow({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.foreground,
          ),
        ),
        const Spacer(),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: AppColors.card,
          activeTrackColor: AppColors.primary,
          inactiveThumbColor: Colors.white,
          inactiveTrackColor: AppColors.border,
        ),
      ],
    );
  }

  Widget _taxSwitchRow({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.foreground,
            ),
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: AppColors.card,
          activeTrackColor: AppColors.primary,
          inactiveThumbColor: Colors.white,
          inactiveTrackColor: AppColors.border,
        ),
      ],
    );
  }

  Widget _taxModeSelector() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: _taxModeOption(
              value: 'exclusive',
              title: 'Exclusivo',
              subtitle: 'Se suma al vender',
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: _taxModeOption(
              value: 'inclusive',
              title: 'Inclusivo',
              subtitle: 'Ya viene incluido',
            ),
          ),
        ],
      ),
    );
  }

  Widget _taxModeOption({
    required String value,
    required String title,
    required String subtitle,
  }) {
    final selected = _taxMode == value;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      onTap: () => setState(() => _taxMode = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: selected ? AppColors.card : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
            color: selected ? AppColors.primary : Colors.transparent,
            width: 1.5,
          ),
          boxShadow: selected ? AppShadows.soft : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  size: 18,
                  color: selected
                      ? AppColors.primary
                      : AppColors.mutedForeground,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: selected
                        ? AppColors.foreground
                        : AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              subtitle,
              style: TextStyle(
                  fontSize: 12, color: AppColors.mutedForeground),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImage() async {
    try {
      final r = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
        allowMultiple: false,
        withData: kIsWeb,
      );

      if (r == null || r.files.isEmpty) return;

      if (kIsWeb) {
        final bytes = r.files.single.bytes;
        if (bytes != null && bytes.isNotEmpty) {
          setState(() {
            _pickedImageBytes = bytes;
            _pickedImageFile = null;
          });
        }
      } else {
        final path = r.files.single.path;
        if (path != null && path.isNotEmpty) {
          setState(() {
            _pickedImageFile = File(path);
            _pickedImageBytes = null;
          });
        }
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
    }
  }

  void _showValidationMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;

    if (_selectedMenuId == null || _selectedMenuId!.isEmpty) {
      _showValidationMessage('Selecciona el men\u00fa.');
      return;
    }
    if (_selectedCategoryId == null || _selectedCategoryId!.isEmpty) {
      _showValidationMessage('Selecciona la categor\u00eda.');
      return;
    }

    final name = _nameController.text.trim();
    final price = double.tryParse(_priceController.text.trim()) ?? 0;
    final cost = double.tryParse(_costController.text.trim());
    final sku = _skuController.text.trim().isEmpty
        ? null
        : _skuController.text.trim();
    final barcode = _barcodeController.text.trim().isEmpty
        ? null
        : _barcodeController.text.trim();
    final desc = _descController.text.trim().isEmpty
        ? null
        : _descController.text.trim();

    // Stock inicial: solo aplica cuando se activa tracking en esta sesión.
    final initialStock =
        _isInventoryTracked && !_wasInventoryTrackedInitially
            ? (double.tryParse(
                  _initialStockController.text.trim().replaceAll(',', '.'),
                ) ??
                0)
            : 0.0;
    // Solo enviar el flag en update si cambió respecto al valor original
    // (para no disparar la RPC innecesariamente en cada save).
    final inventoryFlagChanged =
        _isInventoryTracked != _wasInventoryTrackedInitially;

    if (widget.product != null) {
      widget.onUpdate(
        id: widget.product!['id'],
        name: name,
        price: price,
        categoryId: _selectedCategoryId,
        taxMode: _taxMode,
        sku: sku,
        isActive: _isActive,
        description: desc,
        menuId: _selectedMenuId,
        cost: cost,
        barcode: barcode,
        hasVariants: _hasVariants,
        itemType: _itemType,
        printAreaCode: _printAreaCode,
        imageFile: _pickedImageFile,
        imageBytes: _pickedImageBytes,
        taxIds: _selectedTaxIds.toList(),
        isInventoryTracked: inventoryFlagChanged ? _isInventoryTracked : null,
        initialStock: initialStock,
      );
    } else {
      widget.onAdd(
        name: name,
        price: price,
        categoryId: _selectedCategoryId,
        taxMode: _taxMode,
        sku: sku,
        description: desc,
        menuId: _selectedMenuId,
        cost: cost,
        barcode: barcode,
        hasVariants: _hasVariants,
        isActive: _isActive,
        itemType: _itemType,
        printAreaCode: _printAreaCode,
        imageFile: _pickedImageFile,
        imageBytes: _pickedImageBytes,
        taxIds: _selectedTaxIds.toList(),
        isInventoryTracked: _isInventoryTracked,
        initialStock: initialStock,
      );
    }
    Navigator.pop(context);
  }

  Future<void> _createCategoryInline() async {
    if (widget.onCreateCategory == null) {
      _showValidationMessage(
        'Crea nuevas categor\u00edas desde Ajustes > Men\u00fas > Categor\u00edas.',
      );
      return;
    }

    final controller = TextEditingController();
    final categoryName = await showDialog<String>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          title: Text(
            'Nueva categor\u00eda',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Ej: Bebidas fr\u00edas',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                borderSide: BorderSide(color: AppColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                borderSide: BorderSide(color: AppColors.primary, width: 1.5),
              ),
            ),
            onSubmitted: (value) => Navigator.pop(dialogCtx, value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.mutedForeground,
              ),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.card,
              ),
              onPressed: () => Navigator.pop(dialogCtx, controller.text.trim()),
              child: const Text('Crear'),
            ),
          ],
        );
      },
    );

    if (!mounted || categoryName == null) return;
    if (categoryName.isEmpty) {
      _showValidationMessage('Escribe un nombre para la categor\u00eda.');
      return;
    }

    setState(() => _isCreatingCategory = true);
    try {
      final created = await widget.onCreateCategory!(categoryName);
      if (!mounted) return;

      final createdId = created['id']?.toString();
      if (createdId == null || createdId.isEmpty) {
        throw Exception('Respuesta inv\u00e1lida al crear categor\u00eda');
      }

      final alreadyExists = _categories.any(
        (c) => c['id']?.toString() == createdId,
      );
      if (!alreadyExists) {
        _categories = [..._categories, created];
        _categories.sort((a, b) {
          final aName = a['name']?.toString().toLowerCase() ?? '';
          final bName = b['name']?.toString().toLowerCase() ?? '';
          return aName.compareTo(bName);
        });
      }

      setState(() => _selectedCategoryId = createdId);
      _showValidationMessage('Categor\u00eda creada correctamente.');
    } catch (e) {
      if (!mounted) return;
      _showValidationMessage('No se pudo crear la categor\u00eda: $e');
    } finally {
      if (mounted) {
        setState(() => _isCreatingCategory = false);
      }
    }
  }
}

class _ImagePickerArea extends StatelessWidget {
  final Uint8List? bytes;
  final File? file;
  final String? existingUrl;
  final VoidCallback onTap;

  const _ImagePickerArea({
    required this.bytes,
    required this.file,
    required this.existingUrl,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (bytes != null) {
      content = Image.memory(bytes!, fit: BoxFit.cover);
    } else if (file != null) {
      content = Image.file(file!, fit: BoxFit.cover);
    } else if (existingUrl != null && existingUrl!.isNotEmpty) {
      content = CachedNetworkImage(
        imageUrl: existingUrl!.replaceAll('sqdwjjewdqzxglvqerqt.supabase.co', 'supabase.mangopos.do'),
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) =>
            Icon(Icons.broken_image, size: 50, color: AppColors.mutedForeground),
      );
    } else {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.add_photo_alternate_outlined,
            size: 64,
            color: AppColors.mutedForeground,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Click para subir imagen',
            style: TextStyle(
              color: AppColors.mutedForeground,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        width: double.infinity,
        height: 180,
        decoration: BoxDecoration(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.border, width: 1.4),
        ),
        clipBehavior: Clip.antiAlias,
        child: content,
      ),
    );
  }
}
