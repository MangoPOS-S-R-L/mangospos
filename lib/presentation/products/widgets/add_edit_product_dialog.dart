import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/tax/state/taxes_state.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/tax/viewmodel/taxes_viewmodel.dart';

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
    File? imageFile,
    Uint8List? imageBytes,
    List<String> taxIds,
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
    File? imageFile,
    Uint8List? imageBytes,
    List<String> taxIds,
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

  File? _pickedImageFile;
  Uint8List? _pickedImageBytes;
  final Set<String> _selectedTaxIds = <String>{};
  late List<Map<String, dynamic>> _categories;
  bool _isCreatingCategory = false;

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

    Future.microtask(() async {
      try {
        await ref.read(taxesVmProvider.notifier).load(businessId: 'auto');
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
            color: MangoColors.white,
            borderRadius: BorderRadius.circular(18),
            boxShadow: const [
              BoxShadow(
                color: Color(0x2A000000),
                blurRadius: 30,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
                child: Row(
                  children: [
                    Text(
                      isEdit
                          ? 'Editar Elemento de Menú'
                          : 'Agregar Elemento de Menú',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF282524),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 24),
                      color: const Color(0xFF716C69),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xFFEAE6E2)),
              Expanded(
                child: Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final isWide = constraints.maxWidth >= 900;
                        if (isWide) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _buildLeftColumn()),
                              const SizedBox(width: 20),
                              Expanded(child: _buildRightColumn(taxesState)),
                            ],
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildLeftColumn(),
                            const SizedBox(height: 18),
                            _buildRightColumn(taxesState),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
              const Divider(height: 1, color: Color(0xFFEAE6E2)),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFFE0DBD5)),
                        foregroundColor: const Color(0xFF2B2928),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('Cancelar'),
                    ),
                    const SizedBox(width: 14),
                    ElevatedButton(
                      onPressed: _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: MangoColors.primaryOrange,
                        foregroundColor: MangoColors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
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
        _fieldLabel('Nombre del Artículo', required: true),
        _buildTextField(
          controller: _nameController,
          hintText: 'Ej: Pollo al Horno',
          validator: (v) =>
              v?.trim().isEmpty == true ? 'Campo requerido' : null,
        ),
        const SizedBox(height: 14),
        _fieldLabel('Descripción'),
        _buildTextField(
          controller: _descController,
          hintText: 'Descripción del producto...',
          minLines: 4,
          maxLines: 4,
        ),
        const SizedBox(height: 14),
        _fieldLabel('Menú', required: true),
        _buildDropdown<String?>(
          value: _selectedMenuId,
          hint: 'Seleccionar menú',
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
        const SizedBox(height: 14),
        _fieldLabel('Categoría', required: true),
        Row(
          children: [
            Expanded(
              child: _buildDropdown<String?>(
                value: _selectedCategoryId,
                hint: 'Seleccionar categoría',
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
            const SizedBox(width: 12),
            SizedBox(
              width: 58,
              height: 58,
              child: OutlinedButton(
                onPressed: _isCreatingCategory ? null : _createCategoryInline,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFD9D3CD)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  foregroundColor: const Color(0xFF282524),
                ),
                child: _isCreatingCategory
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
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
            const SizedBox(width: 12),
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
        const SizedBox(height: 14),
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
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _fieldLabel('Código de Barras'),
                  _buildTextField(
                    controller: _barcodeController,
                    hintText: '123456789',
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _fieldLabel('Imagen del Producto'),
        _ImagePickerArea(
          bytes: _pickedImageBytes,
          file: _pickedImageFile,
          existingUrl: widget.product?['image_url']?.toString(),
          onTap: _pickImage,
        ),
        const SizedBox(height: 14),
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
        const SizedBox(height: 8),
        _switchRow(
          title: 'Disponible',
          value: _isActive,
          onChanged: (v) => setState(() => _isActive = v),
        ),
        const SizedBox(height: 8),
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
        const SizedBox(height: 10),
        _fieldLabel('Modo de impuesto'),
        _taxModeSelector(),
        const SizedBox(height: 6),
        Text(
          _taxMode == 'inclusive'
              ? 'El precio del producto ya incluye el impuesto aplicado en venta.'
              : 'El impuesto se suma sobre el precio del producto durante la venta.',
          style: const TextStyle(fontSize: 12, color: Color(0xFF7A746D)),
        ),
        if (taxesState.data.isLoading)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(color: MangoColors.primaryOrange),
          ),
        if (taxesState.data.hasError)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Error al cargar impuestos',
              style: TextStyle(color: Colors.red.shade700),
            ),
          ),
        if (!taxesState.data.isLoading && taxesState.list.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F5F2),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE1DBD6)),
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
      ],
    );
  }

  Widget _fieldLabel(String text, {bool required = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        required ? '$text *' : text,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: Color(0xFF2D2A29),
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
      style: const TextStyle(fontSize: 15, color: Color(0xFF3A3431)),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(color: Color(0xFF8A8078), fontSize: 15),
        filled: true,
        fillColor: enabled ? Colors.white : const Color(0xFFF1EEEB),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFD9D3CD)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFD9D3CD)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(
            color: MangoColors.primaryOrange,
            width: 2,
          ),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFE2DDD8)),
        ),
        contentPadding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: maxLines != null && maxLines > 1 ? 12 : 14,
        ),
      ),
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
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFD9D3CD)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          hint: Text(
            hint,
            style: const TextStyle(color: Color(0xFF8A8078), fontSize: 14),
          ),
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 24),
          items: items,
          onChanged: onChanged,
          style: const TextStyle(
            color: Color(0xFF2D2A29),
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
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Color(0xFF2D2A29),
          ),
        ),
        const Spacer(),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: MangoColors.white,
          activeTrackColor: MangoColors.primaryOrange,
          inactiveThumbColor: Colors.white,
          inactiveTrackColor: const Color(0xFFDFDAD5),
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
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Color(0xFF2D2A29),
            ),
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: MangoColors.white,
          activeTrackColor: MangoColors.primaryOrange,
          inactiveThumbColor: Colors.white,
          inactiveTrackColor: const Color(0xFFDFDAD5),
        ),
      ],
    );
  }

  Widget _taxModeSelector() {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F5F2),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE1DBD6)),
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
          const SizedBox(width: 8),
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
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _taxMode = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? MangoColors.primaryOrange
                : const Color(0x00000000),
            width: 1.5,
          ),
          boxShadow: selected
              ? const [
                  BoxShadow(
                    color: Color(0x0F000000),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ]
              : null,
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
                      ? MangoColors.primaryOrange
                      : const Color(0xFF9C948B),
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: selected
                        ? const Color(0xFF2D2A29)
                        : const Color(0xFF5F5A56),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 12, color: Color(0xFF7A746D)),
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
      _showValidationMessage('Selecciona el menú.');
      return;
    }
    if (_selectedCategoryId == null || _selectedCategoryId!.isEmpty) {
      _showValidationMessage('Selecciona la categoría.');
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
        imageFile: _pickedImageFile,
        imageBytes: _pickedImageBytes,
        taxIds: _selectedTaxIds.toList(),
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
        imageFile: _pickedImageFile,
        imageBytes: _pickedImageBytes,
        taxIds: _selectedTaxIds.toList(),
      );
    }
    Navigator.pop(context);
  }

  Future<void> _createCategoryInline() async {
    if (widget.onCreateCategory == null) {
      _showValidationMessage(
        'Crea nuevas categorías desde Ajustes > Menús > Categorías.',
      );
      return;
    }

    final controller = TextEditingController();
    final categoryName = await showDialog<String>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text(
            'Nueva categoría',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Color(0xFF2D2A29),
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Ej: Bebidas frías',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFD9D3CD)),
              ),
            ),
            onSubmitted: (value) => Navigator.pop(dialogCtx, value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange,
                foregroundColor: MangoColors.white,
              ),
              onPressed: () =>
                  Navigator.pop(dialogCtx, controller.text.trim()),
              child: const Text('Crear'),
            ),
          ],
        );
      },
    );

    if (!mounted || categoryName == null) return;
    if (categoryName.isEmpty) {
      _showValidationMessage('Escribe un nombre para la categoría.');
      return;
    }

    setState(() => _isCreatingCategory = true);
    try {
      final created = await widget.onCreateCategory!(categoryName);
      if (!mounted) return;

      final createdId = created['id']?.toString();
      if (createdId == null || createdId.isEmpty) {
        throw Exception('Respuesta inválida al crear categoría');
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
      _showValidationMessage('Categoría creada correctamente.');
    } catch (e) {
      if (!mounted) return;
      _showValidationMessage('No se pudo crear la categoría: $e');
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
      content = Image.network(
        existingUrl!,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) =>
            const Icon(Icons.broken_image, size: 50, color: Color(0xFF968C84)),
      );
    } else {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(
            Icons.add_photo_alternate_outlined,
            size: 64,
            color: Color(0xFF8F847C),
          ),
          SizedBox(height: 14),
          Text(
            'Click para subir imagen',
            style: TextStyle(
              color: Color(0xFF7F746D),
              fontSize: 20 / 1.2,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: double.infinity,
        height: 180,
        decoration: BoxDecoration(
          color: const Color(0xFFF8F5F2),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE1DBD6), width: 1.4),
        ),
        clipBehavior: Clip.antiAlias,
        child: content,
      ),
    );
  }
}
