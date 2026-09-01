import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/breakpoints.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart' as mango_bp;
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/tax/viewmodel/taxes_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import '../viewmodel/products_viewmodel.dart';
import '../widgets/add_edit_product_dialog.dart';
import '../widgets/import_catalog_dialog.dart';
import 'package:cached_network_image/cached_network_image.dart';

class ProductsView extends ConsumerStatefulWidget {
  const ProductsView({super.key});

  @override
  ConsumerState<ProductsView> createState() => _ProductsViewState();
}

class _ProductsViewState extends ConsumerState<ProductsView> {
  String? _lastBusinessId;
  // Controller del campo de búsqueda. Lo manejamos manualmente para poder
  // limpiarlo con el botón X (sin recrear el widget) y para sincronizar
  // con clearAllFilters() del viewmodel.
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Initialize data
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final businessId = ref.read(sessionProvider).activeBusinessId;
      final vm = ref.read(productsViewModelProvider);
      // Reset filtros al ENTRAR a la pantalla. Sin esto, el viewmodel
      // (singleton via riverpod) conserva searchQuery/category/menu de
      // la sesion anterior — el cajero salia con "a" en el buscador,
      // volvia, y veia solo productos con "a" sin entender por que.
      vm.clearAllFilters();
      vm.init(businessId: businessId);
      ref.read(taxesVmProvider.notifier).load(businessId: 'auto');
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    // Editar y eliminar productos son permisos propios: hasta acá bastaba
    // `productos.acceso` para borrar cualquier ítem del menú.
    final sessionCtrl = ref.watch(sessionProvider.notifier);
    final canEditProducts = sessionCtrl.hasPermission('productos.editar');
    final canDeleteProducts = sessionCtrl.hasPermission('productos.eliminar');
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
          : Padding(
              // Header fijo arriba; la tabla/lista vive en un Expanded con su
              // propio scroll virtualizado (ListView perezoso). Antes todo iba
              // en un SingleChildScrollView con shrinkWrap, que construía
              // TODAS las filas de golpe.
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
                  // PRD 6 \u00a7 4.3 \u2014 header se apila vertical en compact para
                  // que el t\u00edtulo y el CTA "Agregar" no compitan por ancho
                  // y se trunquen.
                  _ProductsHeader(
                    onRefresh: () =>
                        viewModel.init(businessId: session.activeBusinessId),
                    onAdd: () => _showAddEditDialog(context, viewModel),
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

                  // Toolbar responsive: en m\u00f3vil apila vertical (b\u00fasqueda
                  // full-width + fila con los dos dropdowns); en desktop
                  // mantiene la fila horizontal original. Sincroniza el
                  // controller con el viewmodel para que clearAllFilters()
                  // tambi\u00e9n limpie el texto visible.
                  _buildToolbar(context, viewModel),
                  const SizedBox(height: AppSpacing.xxl),

                  Expanded(
                    child: _ProductsTable(
                      products: products,
                      viewModel: viewModel,
                      onEdit: (product) => _showAddEditDialog(
                        context,
                        viewModel,
                        product: product,
                      ),
                      onDelete: (id) => _confirmDelete(context, viewModel, id),
                      canEdit: canEditProducts,
                      canDelete: canDeleteProducts,
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildToolbar(BuildContext context, ProductsViewModel viewModel) {
    final compact = Breakpoints.isCompact(context);

    final searchField = _buildSearchField(viewModel);
    final categoryDropdown = _buildDropdownButton(
      label: 'Todas',
      items: viewModel.categories,
      value: viewModel.selectedCategoryFilterId,
      onChanged: viewModel.setCategoryFilter,
    );
    final menuDropdown = _buildDropdownButton(
      label: 'Todos',
      items: viewModel.menus,
      value: viewModel.selectedMenuFilterId,
      onChanged: viewModel.setMenuFilter,
    );
    final printAreaDropdown = _buildDropdownButton(
      label: 'Todas',
      items: viewModel.availablePrintAreas,
      value: viewModel.selectedPrintAreaFilterId,
      onChanged: viewModel.setPrintAreaFilter,
    );
    final clearButton = TextButton.icon(
      onPressed: () => _clearFilters(viewModel),
      icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
      label: const Text('Limpiar filtros'),
      style: TextButton.styleFrom(
        foregroundColor: AppColors.destructive,
      ),
    );

    if (compact) {
      // Móvil: apilamos vertical. Búsqueda full-width arriba; los tres
      // dropdowns expandidos en una segunda fila para que cada uno tenga
      // espacio suficiente y no se trunque el texto.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          searchField,
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(child: categoryDropdown),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: menuDropdown),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: printAreaDropdown),
            ],
          ),
          if (viewModel.hasActiveFilters) ...[
            const SizedBox(height: AppSpacing.xs),
            Align(
              alignment: Alignment.centerRight,
              child: clearButton,
            ),
          ],
        ],
      );
    }

    // Desktop/tablet: layout horizontal original. Si hay filtros activos
    // mostramos el botón al final de la fila.
    return Row(
      children: [
        Expanded(child: searchField),
        const SizedBox(width: AppSpacing.lg),
        categoryDropdown,
        const SizedBox(width: AppSpacing.lg),
        menuDropdown,
        const SizedBox(width: AppSpacing.lg),
        printAreaDropdown,
        if (viewModel.hasActiveFilters) ...[
          const SizedBox(width: AppSpacing.lg),
          clearButton,
        ],
      ],
    );
  }

  Widget _buildSearchField(ProductsViewModel viewModel) {
    // Sincronizamos el controller cuando el viewmodel se reseteó por
    // fuera (ej. cambio de business). Sin esto, el texto en el TextField
    // quedaría desincronizado del searchQuery real.
    if (_searchController.text != viewModel.searchQuery) {
      _searchController.value = TextEditingValue(
        text: viewModel.searchQuery,
        selection: TextSelection.collapsed(
          offset: viewModel.searchQuery.length,
        ),
      );
    }
    return TextField(
      controller: _searchController,
      onChanged: viewModel.setSearchQuery,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Buscar por nombre, SKU o código de barras',
        prefixIcon: Icon(
          Icons.search,
          color: AppColors.mutedForeground,
        ),
        suffixIcon: viewModel.searchQuery.isNotEmpty
            ? IconButton(
                icon: Icon(
                  Icons.close,
                  color: AppColors.mutedForeground,
                  size: 20,
                ),
                tooltip: 'Limpiar búsqueda',
                onPressed: () {
                  _searchController.clear();
                  viewModel.setSearchQuery('');
                },
              )
            : null,
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
            width: 1.5,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 0,
          horizontal: AppSpacing.lg,
        ),
      ),
    );
  }

  void _clearFilters(ProductsViewModel viewModel) {
    _searchController.clear();
    viewModel.clearAllFilters();
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
        existingPresentations: viewModel.presentationOptions,
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
              printAreaCode,
              presentation,
              printAreaIds,
              imageFile,
              imageBytes,
              taxIds = const [],
              isInventoryTracked = false,
              initialStock = 0,
              initialStockByWarehouse,
              allowNegativeSale = false,
              baseUnit,
              purchaseUnit,
              packSize,
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
                presentation: presentation,
                printAreaIds: printAreaIds,
                imageFile: imageFile,
                imageBytes: imageBytes,
                taxIds: taxIds,
                isInventoryTracked: isInventoryTracked,
                initialStock: initialStock,
                initialStockByWarehouse: initialStockByWarehouse,
                allowNegativeSale: allowNegativeSale,
                baseUnit: baseUnit,
                purchaseUnit: purchaseUnit,
                packSize: packSize,
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
              printAreaCode,
              presentation,
              printAreaIds,
              imageFile,
              imageBytes,
              taxIds = const [],
              isInventoryTracked,
              initialStock = 0,
              initialStockByWarehouse,
              allowNegativeSale,
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
                presentation: presentation,
                printAreaIds: printAreaIds,
                imageFile: imageFile,
                imageBytes: imageBytes,
                taxIds: taxIds,
                isInventoryTracked: isInventoryTracked,
                initialStock: initialStock,
                initialStockByWarehouse: initialStockByWarehouse,
                allowNegativeSale: allowNegativeSale,
              );
            },
      ),
    );
  }

  /// Traduce el error del borrado.
  ///
  /// Desde `20260902_0006` hay una foreign key de `order_items.product_id`
  /// hacia `menu_items`, así que borrar un producto con ventas falla con
  /// 23503. Es a propósito: antes el DELETE pasaba y el histórico quedaba
  /// apuntando a un producto inexistente, con los reportes perdiendo esas
  /// ventas en silencio. El mensaje tiene que decir qué hacer en su lugar.
  static String _mensajeBorrado(Object e) {
    final texto = e.toString();
    final esFk = texto.contains('23503') ||
        texto.contains('order_items_product_id_fkey') ||
        texto.toLowerCase().contains('foreign key');
    if (esFk) {
      return 'Este producto tiene ventas registradas, así que no se puede '
          'eliminar sin romper el histórico. Desactivalo en su ficha '
          '(quitar "Activo") y deja de aparecer en la caja.';
    }
    return 'No se pudo eliminar el producto: $e';
  }

  void _confirmDelete(
    BuildContext context,
    ProductsViewModel viewModel,
    String id,
  ) {
    final pageContext = context;
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
            onPressed: () async {
              // Cerramos el diálogo ANTES del await para no quedarnos con la
              // modal trabada si el delete tarda. Usamos el `context` de la
              // página (no el del builder) para que sobreviva al pop.
              Navigator.pop(context);
              try {
                await viewModel.deleteProduct(id);
                AppToast.success(pageContext, 'Producto eliminado.');
              } catch (e) {
                AppToast.error(pageContext, _mensajeBorrado(e));
              }
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }
}

class _ProductsHeader extends ConsumerWidget {
  final VoidCallback onRefresh;
  final VoidCallback onAdd;

  const _ProductsHeader({required this.onRefresh, required this.onAdd});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `productos.acceso` gatea la ruta; crear es un permiso aparte. Antes
    // cualquiera que abriera Productos podía dar de alta ítems de menú.
    final canCreate =
        ref.watch(sessionProvider.notifier).hasPermission('productos.crear');
    final compact = Breakpoints.isCompact(context);

    final title = Text(
      'Elementos del menú',
      style: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.bold,
        color: AppColors.foreground,
      ),
    );

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onRefresh,
          icon: Icon(Icons.refresh, color: AppColors.mutedForeground),
          tooltip: 'Actualizar',
        ),
        const SizedBox(width: AppSpacing.sm),
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: AppColors.mutedForeground),
          tooltip: 'M\u00e1s opciones',
          onSelected: (value) async {
            final viewModel = ref.read(productsViewModelProvider);
            if (value == 'import') {
              final imported = await showDialog<bool>(
                context: context,
                builder: (_) => const ImportCatalogDialog(),
              );
              if (imported == true) {
                await viewModel.init();
              }
            } else if (value == 'export') {
              await viewModel.exportProductsToExcel();
              if (context.mounted && viewModel.error != null) {
                AppToast.info(context, viewModel.error!);
              }
            } else if (value == 'template') {
              await viewModel.downloadTemplate();
              if (context.mounted && viewModel.error != null) {
                AppToast.info(context, viewModel.error!);
              }
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'import',
              child: Row(
                children: [
                  Icon(Icons.upload_file, size: 20),
                  SizedBox(width: 8),
                  Text('Importar (Excel/CSV)'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'export',
              child: Row(
                children: [
                  Icon(Icons.download, size: 20),
                  SizedBox(width: 8),
                  Text('Exportar a Excel'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'template',
              child: Row(
                children: [
                  Icon(Icons.description, size: 20),
                  SizedBox(width: 8),
                  Text('Descargar plantilla'),
                ],
              ),
            ),
          ],
        ),
        if (canCreate) const SizedBox(width: AppSpacing.md),
        if (canCreate)
        ElevatedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 18),
          label: Text(
            compact ? 'Agregar' : 'Agregar elemento de menú',
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: AppColors.card,
            elevation: 0,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl,
              vertical: AppSpacing.lg,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.button),
            ),
          ),
        ),
      ],
    );

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          title,
          const SizedBox(height: AppSpacing.md),
          Align(alignment: Alignment.centerRight, child: actions),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [title, actions],
    );
  }
}

class _ProductsTable extends StatelessWidget {
  const _ProductsTable({
    required this.products,
    required this.viewModel,
    required this.onEdit,
    required this.onDelete,
    required this.canEdit,
    required this.canDelete,
  });

  final List<Map<String, dynamic>> products;
  final ProductsViewModel viewModel;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<String> onDelete;

  /// `productos.editar` — habilita editar y el toggle de disponibilidad.
  final bool canEdit;

  /// `productos.eliminar` — habilita el borrado.
  final bool canDelete;

  @override
  Widget build(BuildContext context) {
    // Phone (<600dp) usa cards apiladas en vez de tabla horizontal —
    // las 6 columnas no caben en portrait.
    final isPhone = mango_bp.ResponsiveHelper.useCompactShell(context);
    if (isPhone) {
      return _ProductsCardList(
        products: products,
        viewModel: viewModel,
        onEdit: onEdit,
        onDelete: onDelete,
        canEdit: canEdit,
        canDelete: canDelete,
      );
    }
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
                Expanded(flex: 1, child: _TableHeaderCell('AREA PROD.')),
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
            Expanded(
              child: ListView.separated(
                shrinkWrap: false,
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
                final productionAreaName = _resolveProductionAreaName(
                  product: product,
                  printAreasByProduct: viewModel.printAreasByProduct,
                );
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
                                        onError: (_, _) {},
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
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    product['name']?.toString() ?? 'Sin nombre',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.foreground,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (_extractStock(product) != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      'Stock: ${_extractStock(product)!.label}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: _extractStock(product)!
                                            .isLow
                                            ? const Color(0xFFC2410C)
                                            : AppColors.mutedForeground,
                                      ),
                                    ),
                                  ],
                                ],
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
                        child: Text(
                          productionAreaName,
                          style: TextStyle(color: AppColors.mutedForeground),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Expanded(
                        flex: 1,
                        child: Center(
                          child: _AvailabilityIndicator(
                            state: _extractAvailability(product),
                            onTap: !canEdit
                                ? null
                                : () => viewModel.toggleAvailability(
                                      product['id'].toString(),
                                      isActive,
                                    ),
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 1,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (canEdit)
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
                            if (canEdit && canDelete)
                              const SizedBox(width: AppSpacing.lg),
                            if (canDelete)
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

/// Resuelve el label de "Área de producción" para un producto. Prefiere las
/// asignaciones N:M de `menu_item_print_areas` (cargadas en el viewmodel);
/// si no hay, cae al legacy `print_area_code` del menu_item. Si tampoco,
/// devuelve "-".
String _resolveProductionAreaName({
  required Map<String, dynamic> product,
  required Map<String, List<Map<String, dynamic>>> printAreasByProduct,
}) {
  final productId = product['id']?.toString() ?? '';
  if (productId.isNotEmpty) {
    final areas = printAreasByProduct[productId];
    if (areas != null && areas.isNotEmpty) {
      final names = areas
          .map((a) => a['name']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      if (names.isNotEmpty) return names.join(', ');
    }
  }
  final legacyCode = product['print_area_code']?.toString();
  if (legacyCode != null && legacyCode.isNotEmpty) return legacyCode;
  return '-';
}

/// Resumen de stock disponible para mostrar en la lista de productos.
/// Devuelve null si el producto no es inventariable o no tiene receta 1:1
/// (esos no se muestran).
class _StockSummary {
  final String label;
  final bool isLow;
  const _StockSummary({required this.label, required this.isLow});
}

/// Estado de disponibilidad de un producto en el catálogo. Hay 3 casos:
///   - Activo: is_active = true. Verde, clickable para apagar manualmente.
///   - Auto-agotado: is_active = false AND auto_disabled = true. Naranja.
///     El sistema lo apagó porque stock = 0; se reactivará automáticamente
///     al recibir stock. Tap = forzar reactivación manual (clearing flag).
///   - Inactivo manual: is_active = false AND auto_disabled = false. Gris.
///     El admin lo apagó. No se reactiva solo. Tap = reactivar manualmente.
enum _Availability { active, autoSoldOut, inactive }

_Availability _extractAvailability(Map<String, dynamic> product) {
  final isActive = product['is_active'] == true;
  if (isActive) return _Availability.active;
  final autoDisabled = product['auto_disabled'] == true;
  return autoDisabled ? _Availability.autoSoldOut : _Availability.inactive;
}

class _AvailabilityIndicator extends StatelessWidget {
  final _Availability state;
  /// `null` sin `productos.editar`: el indicador queda de solo lectura.
  final VoidCallback? onTap;
  final bool compact;

  const _AvailabilityIndicator({
    required this.state,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final (label, bg, fg, icon, tooltip) = switch (state) {
      _Availability.active => (
          'Disponible',
          AppColors.success.withValues(alpha: 0.12),
          AppColors.success,
          Icons.check_circle,
          'Producto activo. Tócalo para deshabilitarlo manualmente.',
        ),
      _Availability.autoSoldOut => (
          'Auto-agotado',
          const Color(0xFFFFEDD5),
          const Color(0xFFC2410C),
          Icons.inventory_2_outlined,
          'Apagado automáticamente porque el stock llegó a 0. '
              'Se reactivará solo cuando regrese stock. '
              'Tócalo para reactivarlo manualmente ahora.',
        ),
      _Availability.inactive => (
          'Inactivo',
          const Color(0xFFE5E7EB),
          const Color(0xFF6B7280),
          Icons.do_not_disturb_on_outlined,
          'Apagado manualmente. No se reactiva por sí solo. '
              'Tócalo para reactivarlo.',
        ),
    };
    final pill = Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 12 : 14, color: fg),
          SizedBox(width: compact ? 4 : 5),
          Text(
            label,
            style: TextStyle(
              fontSize: compact ? 10 : 11,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ],
      ),
    );
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: pill,
      ),
    );
  }
}

_StockSummary? _extractStock(Map<String, dynamic> product) {
  final tracked = product['is_inventory_tracked'] == true;
  if (!tracked) return null;
  final stockRaw = product['stock'];
  if (stockRaw == null) return null;
  final stock = stockRaw is Map<String, dynamic>
      ? stockRaw
      : Map<String, dynamic>.from(stockRaw as Map);
  final units = stock['available_units'];
  if (units == null) return null;
  final num n = units is num ? units : (num.tryParse(units.toString()) ?? 0);
  final unit = stock['unit']?.toString() ?? '';
  final unitSuffix = unit.isEmpty ? '' : ' $unit';
  final value = n.toDouble();
  final isInt = value == value.truncate();
  final formatted = isInt ? value.toInt().toString() : value.toStringAsFixed(2);
  return _StockSummary(
    label: '$formatted$unitSuffix',
    isLow: value <= 0,
  );
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

// =============================================================================
// Vista compacta de productos en móvil: cards apiladas en vez de tabla.
// Reusa los mismos callbacks (onEdit/onDelete) y `viewModel` que la tabla
// desktop. La acción de toggle disponible usa el mismo método del VM.
// =============================================================================

class _ProductsCardList extends StatelessWidget {
  const _ProductsCardList({
    required this.products,
    required this.viewModel,
    required this.onEdit,
    required this.onDelete,
    required this.canEdit,
    required this.canDelete,
  });

  final List<Map<String, dynamic>> products;
  final ProductsViewModel viewModel;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<String> onDelete;
  final bool canEdit;
  final bool canDelete;

  @override
  Widget build(BuildContext context) {
    if (products.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.border),
        ),
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
      );
    }
    return ListView.separated(
      shrinkWrap: false,
      itemCount: products.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final product = products[index];
        return _ProductCardMobile(
          product: product,
          viewModel: viewModel,
          onEdit: () => onEdit(product),
          onDelete: () => onDelete(product['id'].toString()),
          canEdit: canEdit,
          canDelete: canDelete,
        );
      },
    );
  }
}

class _ProductCardMobile extends StatelessWidget {
  const _ProductCardMobile({
    required this.product,
    required this.viewModel,
    required this.onEdit,
    required this.onDelete,
    required this.canEdit,
    required this.canDelete,
  });

  final Map<String, dynamic> product;
  final ProductsViewModel viewModel;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  /// `productos.editar` / `productos.eliminar` del usuario en sesión.
  final bool canEdit;
  final bool canDelete;

  static List<dynamic> _asList(dynamic value) =>
      value is List ? value : const [];
  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return const <String, dynamic>{};
  }

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
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
    final productionAreaName = _resolveProductionAreaName(
      product: product,
      printAreasByProduct: viewModel.printAreasByProduct,
    );
    final isActive = product['is_active'] == true;
    final inclusive = product['tax_mode']?.toString() == 'inclusive';
    final taxLabel = inclusive ? 'Imp. Incluido' : 'Imp. Excluido';
    final taxColor = inclusive ? AppColors.info : AppColors.primary;
    final imageUrl = product['image_url']?.toString();
    final productName = product['name']?.toString() ?? 'Sin nombre';

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        onTap: canEdit ? onEdit : null,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadius.button),
                      color: AppColors.muted,
                      image: imageUrl != null && imageUrl.isNotEmpty
                          ? DecorationImage(
                              image: CachedNetworkImageProvider(
                                imageUrl.replaceAll(
                                  'sqdwjjewdqzxglvqerqt.supabase.co',
                                  'supabase.mangopos.do',
                                ),
                              ),
                              fit: BoxFit.cover,
                              onError: (_, _) {},
                            )
                          : null,
                    ),
                    child: imageUrl == null || imageUrl.isEmpty
                        ? Icon(
                            Icons.image,
                            size: 22,
                            color: AppColors.mutedForeground,
                          )
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          productName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: AppColors.foreground,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              '\$${_toDouble(product['price']).toStringAsFixed(2)}',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: AppColors.foreground,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: taxColor.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(
                                  AppRadius.badge,
                                ),
                              ),
                              child: Text(
                                taxLabel,
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.3,
                                  color: taxColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Estado de disponibilidad: activo / auto-agotado / inactivo
                  _AvailabilityIndicator(
                    state: _extractAvailability(product),
                    compact: true,
                    onTap: !canEdit
                        ? null
                        : () => viewModel.toggleAvailability(
                      product['id'].toString(),
                      isActive,
                    ),
                  ),
                ],
              ),
              if (_extractStock(product) != null) ...[
                const SizedBox(height: 8),
                Builder(
                  builder: (_) {
                    final s = _extractStock(product)!;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: (s.isLow
                                ? const Color(0xFFC2410C)
                                : AppColors.success)
                            .withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.inventory_2_outlined,
                            size: 14,
                            color: s.isLow
                                ? const Color(0xFFC2410C)
                                : AppColors.success,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Stock: ${s.label}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: s.isLow
                                  ? const Color(0xFFC2410C)
                                  : AppColors.success,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _MobileMetaCol(
                      label: 'Categoría',
                      value: categoryName,
                    ),
                  ),
                  Expanded(
                    child: _MobileMetaCol(
                      label: 'Menú',
                      value: menuName,
                    ),
                  ),
                  Expanded(
                    child: _MobileMetaCol(
                      label: 'Área prod.',
                      value: productionAreaName,
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(
                      Icons.more_horiz,
                      color: AppColors.mutedForeground,
                    ),
                    tooltip: 'Acciones',
                    onSelected: (v) {
                      if (v == 'edit') onEdit();
                      if (v == 'delete') onDelete();
                    },
                    itemBuilder: (_) => [
                      if (canEdit)
                        PopupMenuItem<String>(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(Icons.edit, size: 18,
                                  color: AppColors.mutedForeground),
                              const SizedBox(width: 10),
                              const Text('Editar producto'),
                            ],
                          ),
                        ),
                      if (canDelete)
                        PopupMenuItem<String>(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete_outline,
                                  size: 18, color: AppColors.destructive),
                              const SizedBox(width: 10),
                              Text(
                                'Eliminar',
                                style: TextStyle(color: AppColors.destructive),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileMetaCol extends StatelessWidget {
  const _MobileMetaCol({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: AppColors.mutedForeground,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.foreground,
          ),
        ),
      ],
    );
  }
}
