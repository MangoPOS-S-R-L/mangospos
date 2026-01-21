import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/tax/viewmodel/taxes_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/tax/state/taxes_state.dart';

class AddEditProductDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic>? product;
  final List<Map<String, dynamic>> categories;
  final List<Map<String, dynamic>> menus;
  final Function({
    required String name,
    required double price,
    required String? categoryId,
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
    String? productType,
  })
  onAdd;

  final Function({
    required String id,
    required String name,
    required double price,
    required String? categoryId,
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
    String? productType,
  })
  onUpdate;

  const AddEditProductDialog({
    super.key,
    this.product,
    required this.categories,
    required this.menus,
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
  String? _selectedProductType;
  bool _isActive = true;
  bool _hasVariants = false;

  // Image
  File? _pickedImageFile;
  Uint8List? _pickedImageBytes;

  // Taxes
  final Set<String> _selectedTaxIds = <String>{};

  @override
  void initState() {
    super.initState();
    final p = widget.product;
    _nameController = TextEditingController(text: p?['name'] ?? '');
    _descController = TextEditingController(text: p?['description'] ?? '');
    _priceController = TextEditingController(
      text: p?['price']?.toString() ?? '0',
    );
    _costController = TextEditingController(text: p?['cost']?.toString() ?? '');
    _skuController = TextEditingController(text: p?['sku'] ?? '');
    _barcodeController = TextEditingController(text: p?['barcode'] ?? '');

    _selectedCategoryId = p?['category_id']?.toString();
    _selectedMenuId = p?['menu_id']?.toString();
    _selectedProductType = p?['product_type'];
    _isActive = p?['is_active'] ?? true;
    _hasVariants = p?['has_variants'] ?? false;

    // Initialize taxes if editing (assuming we have tax_ids in product)
    // if (p != null && p['tax_ids'] != null) {
    //   _selectedTaxIds.addAll((p['tax_ids'] as List).map((e) => e.toString()));
    // }
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
  Widget build(BuildContext context) {
    final isEdit = widget.product != null;
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
                  Text(
                    isEdit ? 'Editar artículo' : 'Nuevo artículo',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 20,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
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
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTextField(
                        controller: _nameController,
                        label: 'Nombre del artículo',
                        validator: (v) =>
                            v?.isEmpty == true ? 'Requerido' : null,
                      ),
                      const SizedBox(height: 12),

                      _buildTextField(
                        controller: _descController,
                        label: 'Descripción (opcional)',
                        minLines: 2,
                        maxLines: 3,
                      ),
                      const SizedBox(height: 12),

                      Row(
                        children: [
                          Expanded(
                            child: _Dropdown<String?>(
                              label: 'Tipo de Producto',
                              value: _selectedProductType,
                              items: const [
                                DropdownMenuItem(
                                  value: null,
                                  child: Text('-- Seleccionar --'),
                                ),
                                DropdownMenuItem(
                                  value: 'Comida',
                                  child: Text('Comida'),
                                ),
                                DropdownMenuItem(
                                  value: 'Bebida',
                                  child: Text('Bebida'),
                                ),
                                DropdownMenuItem(
                                  value: 'Combo',
                                  child: Text('Combo'),
                                ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _selectedProductType = v),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _Dropdown<String?>(
                              label: 'Elegir menú',
                              value: _selectedMenuId,
                              items: [
                                const DropdownMenuItem(
                                  value: null,
                                  child: Text('--'),
                                ),
                                ...widget.menus.map(
                                  (m) => DropdownMenuItem(
                                    value: m['id'].toString(),
                                    child: Text(m['name'] ?? ''),
                                  ),
                                ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _selectedMenuId = v),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      Row(
                        children: [
                          Expanded(
                            child: _Dropdown<String?>(
                              label: 'Categoría',
                              value: _selectedCategoryId,
                              items: [
                                const DropdownMenuItem(
                                  value: null,
                                  child: Text('--'),
                                ),
                                ...widget.categories.map(
                                  (c) => DropdownMenuItem(
                                    value: c['id'].toString(),
                                    child: Text(c['name'] ?? ''),
                                  ),
                                ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _selectedCategoryId = v),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      Row(
                        children: [
                          Expanded(
                            child: _buildTextField(
                              controller: _priceController,
                              label: 'Precio',
                              prefixText: '\$ ',
                              enabled: !_hasVariants,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              validator: (v) {
                                if (!_hasVariants && (v == null || v.isEmpty)) {
                                  return 'Requerido';
                                }
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildTextField(
                              controller: _costController,
                              label: 'Costo (opcional)',
                              prefixText: '\$ ',
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      Row(
                        children: [
                          Expanded(
                            child: _buildTextField(
                              controller: _skuController,
                              label: 'Referencia (SKU) (opcional)',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildTextField(
                              controller: _barcodeController,
                              label: 'Código de barras (opcional)',
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
                            if (v) _priceController.clear();
                          });
                        },
                        title: const Text('Tiene variaciones'),
                        contentPadding: EdgeInsets.zero,
                        activeThumbColor: MangoColors.successGreen,
                      ),

                      SwitchListTile(
                        value: _isActive,
                        onChanged: (v) => setState(() => _isActive = v),
                        title: const Text('Disponible'),
                        contentPadding: EdgeInsets.zero,
                        activeThumbColor: MangoColors.successGreen,
                      ),
                      const SizedBox(height: 12),

                      Row(
                        children: [
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: MangoColors.white,
                              foregroundColor: MangoColors.darkGray,
                              side: const BorderSide(
                                color: MangoColors.cardBorder,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: _pickImage,
                            icon: const Icon(Icons.image),
                            label: const Text('Elegir imagen'),
                          ),
                          const SizedBox(width: 12),
                          _ImagePreview(
                            bytes: _pickedImageBytes,
                            file: _pickedImageFile,
                            existingUrl: widget.product?['image_url'],
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
                    onPressed: () => Navigator.pop(context),
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
                    onPressed: _submit,
                    child: Text(isEdit ? 'Actualizar' : 'Guardar'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    String? prefixText,
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
      decoration: InputDecoration(
        labelText: label,
        prefixText: prefixText,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: MangoColors.cardBorder),
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

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;

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
        productType: _selectedProductType,
      );
    } else {
      widget.onAdd(
        name: name,
        price: price,
        categoryId: _selectedCategoryId,
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
        productType: _selectedProductType,
      );
    }
    Navigator.pop(context);
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
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: MangoColors.cardBorder),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _ImagePreview extends StatelessWidget {
  final Uint8List? bytes;
  final File? file;
  final String? existingUrl;

  const _ImagePreview({this.bytes, this.file, this.existingUrl});

  @override
  Widget build(BuildContext context) {
    const size = 56.0;
    Widget child;

    if (bytes != null) {
      child = Image.memory(bytes!, fit: BoxFit.cover);
    } else if (file != null) {
      child = Image.file(file!, fit: BoxFit.cover);
    } else if (existingUrl != null && existingUrl!.isNotEmpty) {
      child = Image.network(
        existingUrl!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            const Icon(Icons.broken_image, color: MangoColors.muted),
      );
    } else {
      child = const Icon(Icons.image, color: MangoColors.muted);
    }

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
            decoration: const BoxDecoration(
              color: MangoColors.white,
              border: Border(bottom: BorderSide(color: MangoColors.cardBorder)),
              borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
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
                  activeThumbColor: MangoColors.successGreen,
                ),
              );
            }),
        ],
      ),
    );
  }
}
