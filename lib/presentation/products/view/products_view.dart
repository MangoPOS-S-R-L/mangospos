import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
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
      backgroundColor: Colors.white,
      body: viewModel.isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  const Text(
                    'Gestión de productos',
                    style: TextStyle(fontSize: 18, color: Colors.black54),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Elementos del menú',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF111827),
                        ),
                      ),
                      Row(
                        children: [
                          IconButton(
                            onPressed: () => viewModel.init(),
                            icon: const Icon(
                              Icons.refresh,
                              color: Colors.black54,
                            ),
                          ),
                          const SizedBox(width: 16),
                          ElevatedButton.icon(
                            onPressed: () =>
                                _showAddEditDialog(context, viewModel),
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('Agregar elemento de menú'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(
                                0xFFF97316,
                              ), // Orange
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 16,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (viewModel.error != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFFECACA)),
                      ),
                      child: Text(
                        viewModel.error!,
                        style: const TextStyle(color: Color(0xFF991B1B)),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Toolbar
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          onChanged: viewModel.setSearchQuery,
                          decoration: InputDecoration(
                            hintText: 'Busca tu elemento del menú aquí',
                            prefixIcon: const Icon(
                              Icons.search,
                              color: Colors.grey,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 0,
                              horizontal: 16,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      _buildDropdownButton(
                        label: 'Todas',
                        items: viewModel.categories,
                        value: viewModel.selectedCategoryFilterId,
                        onChanged: viewModel.setCategoryFilter,
                      ),
                      const SizedBox(width: 16),
                      _buildDropdownButton(
                        label: 'Todos',
                        items: viewModel.menus,
                        value: viewModel.selectedMenuFilterId,
                        onChanged: viewModel.setMenuFilter,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Table Header
                  Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 16,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border(
                        bottom: BorderSide(color: Colors.grey.shade200),
                      ),
                    ),
                    child: Row(
                      children: const [
                        Expanded(
                          flex: 3,
                          child: Text(
                            'ARTÍCULO',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: Colors.black87,
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
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 1,
                          child: Text(
                            'CATEGORÍA',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 1,
                          child: Text(
                            'MENÚ',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: Colors.black87,
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
                                color: Colors.black87,
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 1,
                          child: Text(
                            'ACCIÓN',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: Colors.black87,
                            ),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Table Body
                  if (products.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32.0),
                      child: Center(
                        child: Text('No hay productos para los filtros actuales'),
                      ),
                    )
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: products.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1, color: Color(0xFFE5E7EB)),
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
                            ? const Color(0xFF2563EB)
                            : MangoColors.primaryOrange;

                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 16,
                            horizontal: 16,
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
                                        borderRadius: BorderRadius.circular(8),
                                        color: Colors.grey.shade200,
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
                                          ? const Icon(
                                              Icons.image,
                                              size: 20,
                                              color: Colors.grey,
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        product['name'] ?? 'Sin nombre',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w500,
                                          color: Colors.black87,
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
                                      style: const TextStyle(
                                        color: Colors.black54,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: taxModeColor.withValues(
                                          alpha: 0.10,
                                        ),
                                        borderRadius: BorderRadius.circular(999),
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
                                  style: const TextStyle(color: Colors.black54),
                                ),
                              ),
                              Expanded(
                                flex: 1,
                                child: Text(
                                  menuName,
                                  style: const TextStyle(color: Colors.black54),
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
                                    borderRadius: BorderRadius.circular(4),
                                    child: Container(
                                      width: 20,
                                      height: 20,
                                      decoration: BoxDecoration(
                                        color: isActive
                                            ? const Color(0xFF10B981)
                                            : Colors.grey,
                                        borderRadius: BorderRadius.circular(4),
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
                                      icon: const Icon(
                                        Icons.edit,
                                        size: 18,
                                        color: Colors.black54,
                                      ),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                    const SizedBox(width: 16),
                                    IconButton(
                                      onPressed: () => _confirmDelete(
                                        context,
                                        viewModel,
                                        product['id'],
                                      ),
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        size: 18,
                                        color: Color(0xFFEF4444),
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
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          hint: Text(
            '-- $label --',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
          ),
          icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
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
        title: const Text('Eliminar Producto'),
        content: const Text(
          '¿Estás seguro de que deseas eliminar este producto?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () {
              viewModel.deleteProduct(id);
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }
}
