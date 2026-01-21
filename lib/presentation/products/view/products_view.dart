import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../viewmodel/products_viewmodel.dart';
import '../widgets/add_edit_product_dialog.dart';

class ProductsView extends ConsumerStatefulWidget {
  const ProductsView({super.key});

  @override
  ConsumerState<ProductsView> createState() => _ProductsViewState();
}

class _ProductsViewState extends ConsumerState<ProductsView> {
  @override
  void initState() {
    super.initState();
    // Initialize data
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(productsViewModelProvider).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = ref.watch(productsViewModelProvider);

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

                  // Toolbar
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
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
                      _buildDropdownButton('Todos', viewModel.categories),
                      const SizedBox(width: 16),
                      _buildDropdownButton('Todas', viewModel.menus),
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
                  if (viewModel.products.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32.0),
                      child: Center(child: Text('No hay productos')),
                    )
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: viewModel.products.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1, color: Color(0xFFE5E7EB)),
                      itemBuilder: (context, index) {
                        final product = viewModel.products[index];
                        final categoryName =
                            product['categories']?['name'] ?? '-';
                        // Assuming menus are linked differently or just placeholder for now
                        const menuName = '-';
                        final isActive = product['is_active'] == true;

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
                                child: Text(
                                  '\$${(product['price'] ?? 0).toStringAsFixed(2)}',
                                  style: const TextStyle(color: Colors.black54),
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
                                child: const Text(
                                  menuName,
                                  style: TextStyle(color: Colors.black54),
                                ),
                              ),
                              Expanded(
                                flex: 1,
                                child: Center(
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

  Widget _buildDropdownButton(String label, List<Map<String, dynamic>> items) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: null,
          hint: Text(
            '-- $label --',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
          ),
          icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
          items: items.map((item) {
            return DropdownMenuItem<String>(
              value: item['id'].toString(),
              child: Text(item['name'] ?? ''),
            );
          }).toList(),
          onChanged: (value) {
            // Filter logic could go here
          },
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
        onAdd:
            ({
              required name,
              required price,
              required categoryId,
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
              productType,
            }) {
              viewModel.addProduct(
                name: name,
                price: price,
                categoryId: categoryId,
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
                productType: productType,
              );
            },
        onUpdate:
            ({
              required id,
              required name,
              required price,
              required categoryId,
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
              productType,
            }) {
              viewModel.updateProduct(
                id: id,
                name: name,
                price: price,
                categoryId: categoryId,
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
                productType: productType,
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
