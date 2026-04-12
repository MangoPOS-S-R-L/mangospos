import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/tax/viewmodel/taxes_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import '../viewmodel/products_viewmodel.dart';
import '../widgets/add_edit_product_dialog.dart';

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
      ref.read(productsViewModelProvider).init();
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
          ref.read(productsViewModelProvider).init();
          ref.read(taxesVmProvider.notifier).load(businessId: 'auto');
        }
      });
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: viewModel.isLoading
          ? Center(
              child: CircularProgressIndicator(
                color: AppColors.primary,
              ),
            )
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
                            onPressed: () => viewModel.init(),
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
                                borderRadius:
                                    BorderRadius.circular(AppRadius.button),
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
                        color: AppColors.destructive.withValues(alpha:0.06),
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(
                          color: AppColors.destructive.withValues(alpha:0.2),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              size: 18, color: AppColors.destructive),
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
                            hintText: 'Busca tu elemento del men\u00fa aqu\u00ed',
                            prefixIcon: Icon(
                              Icons.search,
                              color: AppColors.mutedForeground,
                            ),
                            border: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(AppRadius.button),
                              borderSide: BorderSide(color: AppColors.border),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(AppRadius.button),
                              borderSide: BorderSide(color: AppColors.border),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(AppRadius.button),
                              borderSide: BorderSide(
                                  color: AppColors.primary, width: 1.5),
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

                  // Table Header
                  Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.md,
                      horizontal: AppSpacing.lg,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      border: Border(
                        bottom: BorderSide(color: AppColors.border),
                      ),
                    ),
                    child: Row(
                      children: const [
                        Expanded(
                          flex: 3,
                          child: Text(
                            'ART\u00cdCULO',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: AppColors.mutedForeground,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 1,
                          child: Text(
                            'PRECIO',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: AppColors.mutedForeground,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 1,
                          child: Text(
                            'CATEGOR\u00cdA',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: AppColors.mutedForeground,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 1,
                          child: Text(
                            'MEN\u00da',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: AppColors.mutedForeground,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 1,
                          child: Center(
                            child: Text(
                              'DISPONIBLE',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 1,
                          child: Text(
                            'ACCI\u00d3N',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: AppColors.mutedForeground,
                            ),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Table Body
                  if (products.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.xxxl),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(Icons.inventory_2_outlined,
                                size: 48,
                                color: AppColors.mutedForeground
                                    .withValues(alpha:0.5)),
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
                            product['categories']?['name'] ?? '-';
                        final links =
                            product['menu_item_links'] as List<dynamic>? ?? [];
                        String? firstMenu;
                        if (links.isNotEmpty) {
                          final firstLink = links.first as Map<String, dynamic>;
                          final menu =
                              firstLink['menus'] as Map<String, dynamic>?;
                          firstMenu = menu?['name']?.toString();
                        }
                        final menuName = firstMenu ?? '-';
                        final isActive = product['is_active'] == true;
                        final taxMode =
                            product['tax_mode']?.toString() == 'inclusive'
                            ? 'Incluido'
                            : 'Excluido';
                        final taxModeColor =
                            product['tax_mode']?.toString() == 'inclusive'
                            ? AppColors.info
                            : AppColors.primary;

                        return Padding(
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
                                            AppRadius.button),
                                        color: AppColors.muted,
                                        image: product['image_url'] != null
                                            ? DecorationImage(
                                                image: NetworkImage(
                                                  product['image_url'],
                                                ),
                                                fit: BoxFit.cover,
                                              )
                                            : null,
                                      ),
                                      child: product['image_url'] == null
                                          ? Icon(
                                              Icons.image,
                                              size: 20,
                                              color:
                                                  AppColors.mutedForeground,
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: AppSpacing.md),
                                    Expanded(
                                      child: Text(
                                        product['name'] ?? 'Sin nombre',
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
                                      '\$${(product['price'] ?? 0).toStringAsFixed(2)}',
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
                                        color: taxModeColor.withValues(alpha:0.10),
                                        borderRadius: BorderRadius.circular(
                                            AppRadius.badge),
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
                                  style: TextStyle(
                                      color: AppColors.mutedForeground),
                                ),
                              ),
                              Expanded(
                                flex: 1,
                                child: Text(
                                  menuName,
                                  style: TextStyle(
                                      color: AppColors.mutedForeground),
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
                                    borderRadius: BorderRadius.circular(
                                        AppRadius.sm),
                                    child: Container(
                                      width: 20,
                                      height: 20,
                                      decoration: BoxDecoration(
                                        color: isActive
                                            ? AppColors.success
                                            : AppColors.mutedForeground,
                                        borderRadius: BorderRadius.circular(
                                            AppRadius.sm),
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
                                      onPressed: () => _showAddEditDialog(
                                        context,
                                        viewModel,
                                        product: product,
                                      ),
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
                                      onPressed: () => _confirmDelete(
                                        context,
                                        viewModel,
                                        product['id'],
                                      ),
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
            DropdownMenuItem<String>(
              value: null,
              child: Text('-- $label --'),
            ),
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
            style: TextButton.styleFrom(
              foregroundColor: AppColors.destructive,
            ),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }
}
