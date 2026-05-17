// PRD 5 F4.2 — Bulk asignación de productos por categoría a áreas de impresión.
//
// Pantalla con 3 zonas:
//   1. Selector de área destino (dropdown arriba).
//   2. Lista de categorías (ExpansionTile). Cada una:
//      - Checkbox "Seleccionar todos los productos de esta categoría".
//      - Lista de productos con checkbox individual. El producto muestra
//        a qué área pertenece hoy (badge gris).
//   3. Botón flotante: "Asignar X productos al área Y" — habilitado cuando
//      hay items seleccionados Y un área destino elegida. Confirma + ejecuta
//      bulk update.
//
// Después del bulk, la lista se recarga y el contador vuelve a 0.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/areas/viewmodel/print_areas_viewmodel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PrintingProductsView extends ConsumerStatefulWidget {
  const PrintingProductsView({super.key, this.businessId = 'auto'});

  final String businessId;

  @override
  ConsumerState<PrintingProductsView> createState() =>
      _PrintingProductsViewState();
}

class _PrintingProductsViewState extends ConsumerState<PrintingProductsView> {
  bool _loading = true;
  String? _errorMessage;
  String? _resolvedBusinessId;

  List<Map<String, dynamic>> _categories = const [];
  List<Map<String, dynamic>> _items = const [];
  List<PrintArea> _areas = const [];

  String? _selectedAreaCode;
  final Set<String> _selectedItemIds = <String>{};

  late final PrintingRepository _repo;

  @override
  void initState() {
    super.initState();
    _repo = PrintingRepository(Supabase.instance.client);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final businessId = await BusinessResolver.ensure(
        widget.businessId.isEmpty ? 'auto' : widget.businessId,
      );
      _resolvedBusinessId = businessId;

      final results = await Future.wait([
        _repo.getCategoriesForBusiness(businessId),
        _repo.getMenuItemsMinimal(businessId),
        _repo.getPrintAreas(businessId),
      ]);

      _categories = results[0] as List<Map<String, dynamic>>;
      _items = results[1] as List<Map<String, dynamic>>;
      _areas = results[2] as List<PrintArea>;

      // Si solo hay una área, seleccionarla por defecto.
      _selectedAreaCode ??= _areas.length == 1 ? _areas.first.code : null;

      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _errorMessage = 'No se pudieron cargar los productos. $e';
      });
    }
  }

  List<Map<String, dynamic>> _itemsForCategory(String? categoryId) {
    return _items
        .where((i) => i['category_id'] == categoryId)
        .toList(growable: false);
  }

  bool _categorySelectsAll(String? categoryId) {
    final cat = _itemsForCategory(categoryId);
    if (cat.isEmpty) return false;
    return cat.every((i) => _selectedItemIds.contains(i['id'] as String));
  }

  void _toggleCategory(String? categoryId, bool selectAll) {
    final cat = _itemsForCategory(categoryId);
    setState(() {
      for (final item in cat) {
        final id = item['id'] as String;
        if (selectAll) {
          _selectedItemIds.add(id);
        } else {
          _selectedItemIds.remove(id);
        }
      }
    });
  }

  void _toggleItem(String itemId, bool selected) {
    setState(() {
      if (selected) {
        _selectedItemIds.add(itemId);
      } else {
        _selectedItemIds.remove(itemId);
      }
    });
  }

  Future<void> _applyBulk() async {
    if (_selectedAreaCode == null || _selectedItemIds.isEmpty) return;
    final areaName = _areas
        .firstWhere(
          (a) => a.code == _selectedAreaCode,
          orElse: () => PrintArea(
            id: '',
            businessId: '',
            name: _selectedAreaCode!,
            code: _selectedAreaCode!,
            isActive: true,
          ),
        )
        .name;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Asignar productos'),
        content: Text(
          '${_selectedItemIds.length} producto(s) van a quedar asignados '
          'al área "$areaName". ¿Confirmar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Asignar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _repo.bulkUpdateMenuItemsPrintArea(
        itemIds: _selectedItemIds.toList(),
        areaCode: _selectedAreaCode!,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_selectedItemIds.length} producto(s) asignados a "$areaName".',
          ),
        ),
      );
      _selectedItemIds.clear();
      await _bootstrap();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo asignar: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Regresar',
          onPressed: () => Navigator.of(context).canPop()
              ? Navigator.of(context).pop()
              : context.go(AppRoutes.printingBase),
        ),
        title: const Text('Productos por área de impresión'),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(child: Text(_errorMessage!));
    }
    if (_areas.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No hay áreas creadas todavía. Crea una área primero en '
            '"Áreas" para poder asignar productos.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No hay productos activos. Agrega productos en Menú > Productos.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Asignar productos a un área',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: MangoColors.darkGray,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Selecciona un área de destino y marca los productos que '
                'deseas reasignar. Puedes seleccionar categorías completas.',
                style: TextStyle(fontSize: 13, color: MangoColors.muted),
              ),
              const SizedBox(height: 20),
              _AreaSelector(
                areas: _areas,
                selectedCode: _selectedAreaCode,
                onChanged: (code) =>
                    setState(() => _selectedAreaCode = code),
              ),
              const SizedBox(height: 20),
              ..._buildCategorySections(),
              // Productos sin categoría asignada.
              ..._buildUncategorizedSection(),
            ],
          ),
        ),
        if (_selectedItemIds.isNotEmpty && _selectedAreaCode != null)
          Positioned(
            left: 20,
            right: 20,
            bottom: 20,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(12),
              color: const Color(0xFF22C55E),
              child: InkWell(
                onTap: _applyBulk,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 14,
                    horizontal: 20,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.check_circle, color: Colors.white),
                      const SizedBox(width: 10),
                      Text(
                        'Asignar ${_selectedItemIds.length} producto(s) al '
                        'área seleccionada',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildCategorySections() {
    return _categories.map((cat) {
      final categoryId = cat['id'] as String;
      final name = cat['name'] as String? ?? 'Sin nombre';
      final items = _itemsForCategory(categoryId);
      if (items.isEmpty) return const SizedBox.shrink();
      return _buildCategoryCard(name, categoryId, items);
    }).toList();
  }

  List<Widget> _buildUncategorizedSection() {
    final items = _items
        .where((i) => i['category_id'] == null)
        .toList(growable: false);
    if (items.isEmpty) return const [];
    return [_buildCategoryCard('Sin categoría', null, items)];
  }

  Widget _buildCategoryCard(
    String title,
    String? categoryId,
    List<Map<String, dynamic>> items,
  ) {
    final selectAll = _categorySelectsAll(categoryId);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        title: Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '(${items.length})',
              style: const TextStyle(
                fontSize: 13,
                color: MangoColors.muted,
              ),
            ),
          ],
        ),
        leading: Checkbox(
          value: selectAll,
          tristate: true,
          onChanged: (v) => _toggleCategory(categoryId, v ?? false),
        ),
        children: items.map((item) {
          final id = item['id'] as String;
          final name = item['name'] as String? ?? '';
          final currentArea = item['print_area_code'] as String?;
          final selected = _selectedItemIds.contains(id);
          return CheckboxListTile(
            value: selected,
            onChanged: (v) => _toggleItem(id, v ?? false),
            title: Text(name),
            subtitle: Text(
              'Área actual: ${_areaNameForCode(currentArea)}',
              style: const TextStyle(fontSize: 12, color: MangoColors.muted),
            ),
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
          );
        }).toList(),
      ),
    );
  }

  String _areaNameForCode(String? code) {
    if (code == null || code.isEmpty) return 'Sin asignar';
    final match = _areas.firstWhere(
      (a) => a.code == code,
      orElse: () => PrintArea(
        id: '',
        businessId: '',
        name: code,
        code: code,
        isActive: true,
      ),
    );
    return match.name;
  }

  // ignore: unused_element
  void _refreshAreas() {
    final ctrl = ref.read(printingAreasViewModelProvider.notifier);
    if (_resolvedBusinessId != null) {
      ctrl.load(businessId: _resolvedBusinessId!, force: true);
    }
  }
}

class _AreaSelector extends StatelessWidget {
  const _AreaSelector({
    required this.areas,
    required this.selectedCode,
    required this.onChanged,
  });

  final List<PrintArea> areas;
  final String? selectedCode;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          const Icon(Icons.storefront_outlined, color: MangoColors.darkGray),
          const SizedBox(width: 12),
          const Text(
            'Asignar al área:',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: selectedCode,
                hint: const Text('Selecciona un área'),
                items: areas
                    .map(
                      (a) => DropdownMenuItem(
                        value: a.code,
                        child: Text(a.name),
                      ),
                    )
                    .toList(),
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
