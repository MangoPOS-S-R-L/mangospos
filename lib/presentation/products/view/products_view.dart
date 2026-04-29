import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/tax/viewmodel/taxes_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import '../viewmodel/products_viewmodel.dart';
import '../widgets/add_edit_product_dialog.dart';
import 'package:cached_network_image/cached_network_image.dart';

class ProductsView extends ConsumerStatefulWidget {
  const ProductsView({super.key});

  @override
  ConsumerState<ProductsView> createState() => _ProductsViewState();
}

class _ProductsViewState extends ConsumerState<ProductsView> {
  String? _lastBusinessId;

  @override
  void initState() {
    super.initState();
    // Initialize data
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final businessId = ref.read(sessionProvider).activeBusinessId;
      ref.read(productsViewModelProvider).init(businessId: businessId);
      ref.read(taxesVmProvider.notifier).load(businessId: 'auto');
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final viewModel = ref.watch(productsViewModelProvider);
    final products = viewModel.filteredProducts;

    if (session.activeBusinessId != null &&
        session.activeBusinessId != _lastBusinessId) {
      _lastBusinessId = session.activeBusinessId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref
              .read(productsViewModelProvider)
              .init(businessId: session.activeBusinessId);
          ref.read(taxesVmProvider.notifier).load(businessId: 'auto');
        }
      });
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: viewModel.isLoading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.xxl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Text(
                    'Gesti\u00f3n de productos',
                    style: TextStyle(
                      fontSize: 18,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Elementos del men\u00fa',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: AppColors.foreground,
                        ),
                      ),
                      Row(
                        children: [
                          IconButton(
                            onPressed: () => viewModel.init(
                              businessId: session.activeBusinessId,
                            ),
                            icon: Icon(
                              Icons.refresh,
                              color: AppColors.mutedForeground,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.lg),
                          ElevatedButton.icon(
                            onPressed: () =>
                                _showAddEditDialog(context, viewModel),
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('Agregar elemento de men\u00fa'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: AppColors.card,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.xl,
                                vertical: AppSpacing.lg,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadius.button,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  if (viewModel.error != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: AppColors.destructive.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(
                          color: AppColors.destructive.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 18,
                            color: AppColors.destructive,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              viewModel.error!,
                              style: TextStyle(color: AppColors.destructive),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                  ],

                  // Toolbar
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          onChanged: viewModel.setSearchQuery,
                          decoration: InputDecoration(
                            hintText:
                                'Busca tu elemento del men\u00fa aqu\u00ed',
                            prefixIcon: Icon(
                              Icons.search,
                              color: AppColors.mutedForeground,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadius.button,
                              ),
                              borderSide: BorderSide(color: AppColors.border),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadius.button,
                              ),
                              borderSide: BorderSide(color: AppColors.border),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadius.button,
                              ),
                              borderSide: BorderSide(
                                color: AppColors.primary,
                                width: 1.5,
                              ),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 0,
                              horizontal: AppSpacing.lg,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.lg),
                      _buildDropdownButton(
                        label: 'Todas',
                        items: viewModel.categories,
                        value: viewModel.selectedCategoryFilterId,
                        onChanged: viewModel.setCategoryFilter,
                      ),
                      const SizedBox(width: AppSpacing.lg),
                      _buildDropdownButton(
                        label: 'Todos',
                        items: viewModel.menus,
                        value: viewModel.selectedMenuFilterId,
                        onChanged: viewModel.setMenuFilter,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xxl),

                  _ProductsTable(
                    products: products,
                    viewModel: viewModel,
                    onEdit: (product) => _showAddEditDialog(
                      context,
                      viewModel,
                      product: product,
                    ),
                    onDelete: (id) => _confirmDelete(context, viewModel, id),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildDropdownButton({
    required String label,
    required List<Map<String, dynamic>> items,
    required String? value,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          hint: Text(
            '-- $label --',
            style: TextStyle(color: AppColors.mutedForeground, fontSize: 14),
          ),
          icon: Icon(Icons.arrow_drop_down, color: AppColors.mutedForeground),
          items: [
            DropdownMenuItem<String>(value: null, child: Text('-- $label --')),
            ...items.map((item) {
              return DropdownMenuItem<String>(
                value: item['id'].toString(),
                child: Text(item['name'] ?? ''),
              );
            }),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  void _showAddEditDialog(
    BuildContext context,
    ProductsViewModel viewModel, {
    Map<String, dynamic>? product,
  }) {
    showDialog(
      context: context,
      builder: (context) => AddEditProductDialog(
        product: product,
        categories: viewModel.categories,
        menus: viewModel.menus,
        onCreateCategory: (name) => viewModel.createCategory(name: name),
        onAdd:
            ({
              required name,
              required price,
              required categoryId,
              taxMode = 'exclusive',
              sku,
              description,
              menuId,
              cost,
              barcode,
              hasVariants = false,
              isActive = true,
              itemType = 'standard',
              printAreaCode = 'kitchen_hot',
              imageFile,
              imageBytes,
              taxIds = const [],
            }) {
              viewModel.addProduct(
                name: name,
                price: price,
                categoryId: categoryId,
                taxMode: taxMode,
                sku: sku,
                description: description,
                menuId: menuId,
                cost: cost,
                barcode: barcode,
                hasVariants: hasVariants,
                isActive: isActive,
                itemType: itemType,
                printAreaCode: printAreaCode,
                imageFile: imageFile,
                imageBytes: imageBytes,
                taxIds: taxIds,
              );
            },
        onUpdate:
            ({
              required id,
              required name,
              required price,
              required categoryId,
              taxMode = 'exclusive',
              sku,
              required isActive,
              description,
              menuId,
              cost,
              barcode,
              hasVariants = false,
              itemType = 'standard',
              printAreaCode = 'kitchen_hot',
              imageFile,
              imageBytes,
              taxIds = const [],
            }) {
              viewModel.updateProduct(
                id: id,
                name: name,
                price: price,
                categoryId: categoryId,
                taxMode: taxMode,
                sku: sku,
                isActive: isActive,
                description: description,
                menuId: menuId,
                cost: cost,
                barcode: barcode,
                hasVariants: hasVariants,
                itemType: itemType,
                printAreaCode: printAreaCode,
                imageFile: imageFile,
                imageBytes: imageBytes,
                taxIds: taxIds,
              );
            },
      ),
    );
  }

  void _confirmDelete(
    BuildContext context,
    ProductsViewModel viewModel,
    String id,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: Text(
          'Eliminar Producto',
          style: TextStyle(color: AppColors.foreground),
        ),
        content: Text(
          '\u00bfEst\u00e1s seguro de que deseas eliminar este producto?',
          style: TextStyle(color: AppColors.mutedForeground),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.mutedForeground,
            ),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () {
              viewModel.deleteProduct(id);
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }
}

class _ProductsTable extends StatelessWidget {
  const _ProductsTable({
    required this.products,
    required this.viewModel,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> products;
  final ProductsViewModel viewModel;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(
              vertical: AppSpacing.md,
              horizontal: AppSpacing.lg,
            ),
            child: Row(
              children: const [
                Expanded(flex: 3, child: _TableHeaderCell('ARTICULO')),
                Expanded(flex: 1, child: _TableHeaderCell('PRECIO')),
                Expanded(flex: 1, child: _TableHeaderCell('CATEGORIA')),
                Expanded(flex: 1, child: _TableHeaderCell('MENU')),
                Expanded(
                  flex: 1,
                  child: Center(child: _TableHeaderCell('DISPONIBLE')),
                ),
                Expanded(
                  flex: 1,
                  child: _TableHeaderCell('ACCION', textAlign: TextAlign.right),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.border),
          if (products.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.xxxl),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.inventory_2_outlined,
                      size: 48,
                      color: AppColors.mutedForeground.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'No hay productos para los filtros actuales',
                      style: TextStyle(
                        color: AppColors.mutedForeground,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: products.length,
              separatorBuilder: (context, index) =>
                  Divider(height: 1, color: AppColors.border),
              itemBuilder: (context, index) {
                final product = products[index];
                final categoryName =
                    _asMap(product['categories'])['name']?.toString() ?? '-';
                final links = _asList(product['menu_item_links']);
                final menuNames = links
                    .map(_asMap)
                    .map((link) => _asMap(link['menus'])['name']?.toString())
                    .whereType<String>()
                    .where((name) => name.trim().isNotEmpty)
                    .toSet()
                    .toList(growable: false);
                final menuName = menuNames.isEmpty ? '-' : menuNames.join(', ');
                final isActive = product['is_active'] == true;
                final taxMode = product['tax_mode']?.toString() == 'inclusive'
                    ? 'Incluido'
                    : 'Excluido';
                final taxModeColor =
                    product['tax_mode']?.toString() == 'inclusive'
                    ? AppColors.info
                    : AppColors.primary;
                final imageUrl = product['image_url']?.toString();

                return Container(
                  color: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    vertical: AppSpacing.lg,
                    horizontal: AppSpacing.lg,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(
                                  AppRadius.button,
                                ),
                                color: AppColors.muted,
                                image: imageUrl != null && imageUrl.isNotEmpty
                                    ? DecorationImage(
                                        image: CachedNetworkImageProvider(imageUrl.replaceAll('sqdwjjewdqzxglvqerqt.supabase.co', 'supabase.mangopos.do')),
                                        fit: BoxFit.cover,
                                      )
                                    : null,
                              ),
                              child: imageUrl == null || imageUrl.isEmpty
                                  ? Icon(
                                      Icons.image,
                                      size: 20,
                                      color: AppColors.mutedForeground,
                                    )
                                  : null,
                            ),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Text(
                                product['name']?.toString() ?? 'Sin nombre',
                                style: TextStyle(
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.foreground,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 1,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '\$${_toDouble(product['price']).toStringAsFixed(2)}',
                              style: TextStyle(
                                color: AppColors.mutedForeground,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.sm,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: taxModeColor.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(
                                  AppRadius.badge,
                                ),
                              ),
                              child: Text(
                                'Imp. $taxMode',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: taxModeColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 1,
                        child: Text(
                          categoryName,
                          style: TextStyle(color: AppColors.mutedForeground),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Expanded(
                        flex: 1,
                        child: Text(
                          menuName,
                          style: TextStyle(color: AppColors.mutedForeground),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Expanded(
                        flex: 1,
                        child: Center(
                          child: InkWell(
                            onTap: () => viewModel.toggleAvailability(
                              product['id'].toString(),
                              isActive,
                            ),
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                            child: Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: isActive
                                    ? AppColors.success
                                    : AppColors.mutedForeground,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.sm,
                                ),
                              ),
                              child: const Icon(
                                Icons.check,
                                size: 14,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 1,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            IconButton(
                              onPressed: () => onEdit(product),
                              icon: Icon(
                                Icons.edit,
                                size: 18,
                                color: AppColors.mutedForeground,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                            const SizedBox(width: AppSpacing.lg),
                            IconButton(
                              onPressed: () =>
                                  onDelete(product['id'].toString()),
                              icon: Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: AppColors.destructive,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  static List<dynamic> _asList(dynamic value) {
    return value is List ? value : const [];
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return const <String, dynamic>{};
  }

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class _TableHeaderCell extends StatelessWidget {
  const _TableHeaderCell(this.text, {this.textAlign = TextAlign.left});

  final String text;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 12,
        color: AppColors.mutedForeground,
      ),
      textAlign: textAlign,
    );
  }
}
