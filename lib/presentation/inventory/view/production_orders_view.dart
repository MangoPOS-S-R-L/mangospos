// Módulo de producción — lista de órdenes + crear/cancelar.
// Para ver el detalle y completar una orden, se navega a
// `ProductionOrderDetailView`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/repositories/production_repository.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';
import 'package:mangopos/presentation/inventory/view/production_order_detail_view.dart';
import 'package:mangopos/presentation/inventory/viewmodel/inventory_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

class ProductionOrdersView extends ConsumerStatefulWidget {
  const ProductionOrdersView({super.key});

  @override
  ConsumerState<ProductionOrdersView> createState() =>
      _ProductionOrdersViewState();
}

class _ProductionOrdersViewState extends ConsumerState<ProductionOrdersView> {
  String? _businessId;
  bool _loading = true;
  String? _error;
  List<ProductionOrderSummary> _orders = const [];
  final Set<ProductionOrderStatus> _activeFilters = {
    ProductionOrderStatus.draft,
    ProductionOrderStatus.inProgress,
    ProductionOrderStatus.completed,
  };

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final id = await BusinessResolver.ensure('auto');
      _businessId = id;
      final orders = await ref
          .read(productionRepositoryProvider)
          .listByBusiness(
            businessId: id,
            statusFilter: _activeFilters.isEmpty ? null : _activeFilters,
          );
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = FriendlyError.humanize('No se pudieron cargar las órdenes: $e');
        _loading = false;
      });
    }
  }

  void _toggleFilter(ProductionOrderStatus status) {
    setState(() {
      if (_activeFilters.contains(status)) {
        _activeFilters.remove(status);
      } else {
        _activeFilters.add(status);
      }
    });
    _load();
  }

  Future<void> _openCreateDialog() async {
    final bid = _businessId;
    if (bid == null) return;
    final created = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CreateProductionOrderDialog(businessId: bid),
    );
    if (created == true) {
      _load();
    }
  }

  Future<void> _openDetail(ProductionOrderSummary order) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ProductionOrderDetailView(orderId: order.id),
      ),
    );
    if (changed == true) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionCtrl = ref.watch(sessionProvider.notifier);
    final canCreate = sessionCtrl.hasPermission('produccion.crear');

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: MangoColors.darkGray,
                      padding: const EdgeInsets.symmetric(horizontal: 0),
                    ),
                    onPressed: () => context.go(AppRoutes.inventoryHome),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Regresar'),
                  ),
                  const Spacer(),
                  if (canCreate)
                    FilledButton.icon(
                      onPressed: _openCreateDialog,
                      style: FilledButton.styleFrom(
                        backgroundColor: MangoColors.primaryOrange,
                      ),
                      icon: const Icon(Icons.add),
                      label: const Text('Nueva orden'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Producción',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: MangoColors.darkGray,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Transforma materias primas en productos terminados. Cada '
                'orden genera movimientos en el kardex y recalcula el costo '
                'del producto terminado.',
                style: TextStyle(fontSize: 13, color: MangoColors.muted),
              ),
              const SizedBox(height: 16),
              _StatusFilterBar(
                active: _activeFilters,
                onToggle: _toggleFilter,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _buildList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation(MangoColors.primaryOrange),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  color: Color(0xFFDC2626), size: 56),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFDC2626)),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Reintentar')),
            ],
          ),
        ),
      );
    }
    if (_orders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.precision_manufacturing_outlined,
                size: 72, color: MangoColors.muted),
            const SizedBox(height: 12),
            const Text(
              'Sin órdenes de producción',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Crea una orden para empezar a transformar materias primas.',
              style: TextStyle(fontSize: 12, color: MangoColors.muted),
            ),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: ListView.separated(
        itemCount: _orders.length,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
        itemBuilder: (ctx, i) => _OrderRow(
          order: _orders[i],
          onTap: () => _openDetail(_orders[i]),
        ),
      ),
    );
  }
}

class _StatusFilterBar extends StatelessWidget {
  final Set<ProductionOrderStatus> active;
  final void Function(ProductionOrderStatus) onToggle;

  const _StatusFilterBar({required this.active, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: ProductionOrderStatus.values
          .map((s) => FilterChip(
                selected: active.contains(s),
                onSelected: (_) => onToggle(s),
                label: Text(s.label),
                selectedColor: _statusColor(s).withValues(alpha: 0.18),
                checkmarkColor: _statusColor(s),
              ))
          .toList(growable: false),
    );
  }
}

Color _statusColor(ProductionOrderStatus s) {
  switch (s) {
    case ProductionOrderStatus.draft:
      return const Color(0xFF6B7280);
    case ProductionOrderStatus.inProgress:
      return MangoColors.primaryOrange;
    case ProductionOrderStatus.completed:
      return const Color(0xFF059669);
    case ProductionOrderStatus.cancelled:
      return const Color(0xFFDC2626);
  }
}

class _OrderRow extends StatelessWidget {
  final ProductionOrderSummary order;
  final VoidCallback onTap;

  const _OrderRow({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('dd MMM yyyy HH:mm').format(order.createdAt);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 56,
              decoration: BoxDecoration(
                color: _statusColor(order.status),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    order.code,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      letterSpacing: 0.3,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  Text(
                    date,
                    style: const TextStyle(
                      fontSize: 11,
                      color: MangoColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    order.finishedItemName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  Text(
                    '${order.linesCount} insumos · ${order.sourceWarehouseName} → ${order.destinationWarehouseName}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: MangoColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    order.status == ProductionOrderStatus.completed &&
                            order.actualYield != null
                        ? '${_fmtQty(order.actualYield!)} ${order.finishedItemUnit}'
                        : '${_fmtQty(order.plannedYield)} ${order.finishedItemUnit}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  if (order.status == ProductionOrderStatus.completed &&
                      order.actualYield != null)
                    const Text(
                      'Producido',
                      style: TextStyle(fontSize: 10, color: MangoColors.muted),
                    )
                  else
                    const Text(
                      'Planeado',
                      style: TextStyle(fontSize: 10, color: MangoColors.muted),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _statusColor(order.status).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                order.status.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _statusColor(order.status),
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, color: MangoColors.muted),
          ],
        ),
      ),
    );
  }
}

String _fmtQty(double v) {
  if (v == v.truncate()) return v.truncate().toString();
  return v.toStringAsFixed(2);
}

// =============================================================================
// Diálogo de creación
// =============================================================================

class _CreateProductionOrderDialog extends ConsumerStatefulWidget {
  final String businessId;
  const _CreateProductionOrderDialog({required this.businessId});

  @override
  ConsumerState<_CreateProductionOrderDialog> createState() =>
      _CreateProductionOrderDialogState();
}

class _CreateProductionOrderDialogState
    extends ConsumerState<_CreateProductionOrderDialog> {
  bool _loading = true;
  bool _submitting = false;
  String? _error;
  List<Map<String, dynamic>> _producibleItems = const [];
  List<InventoryWarehouse> _warehouses = const [];
  String? _selectedItemId;
  String? _sourceWarehouseId;
  String? _destinationWarehouseId;
  final TextEditingController _yieldCtrl = TextEditingController();
  final TextEditingController _notesCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadOptions);
  }

  @override
  void dispose() {
    _yieldCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    try {
      final repo = ref.read(productionRepositoryProvider);
      final invRepo = ref.read(inventoryRepositoryProvider);
      final items = await repo.listProducibleItems(businessId: widget.businessId);
      final warehouses = await invRepo.getWarehouses(widget.businessId);
      if (!mounted) return;
      setState(() {
        _producibleItems = items;
        _warehouses = warehouses;
        if (items.isNotEmpty) {
          _selectedItemId = items.first['item_id']?.toString();
        }
        if (warehouses.isNotEmpty) {
          final main = warehouses.firstWhere(
            (w) => w.isMain,
            orElse: () => warehouses.first,
          );
          _sourceWarehouseId = main.id;
          _destinationWarehouseId = main.id;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = FriendlyError.humanize('Error cargando opciones: $e');
        _loading = false;
      });
    }
  }

  Future<void> _submit() async {
    if (_selectedItemId == null ||
        _sourceWarehouseId == null ||
        _destinationWarehouseId == null) {
      setState(() => _error = 'Completa todos los campos requeridos.');
      return;
    }
    final yield_ = double.tryParse(_yieldCtrl.text.replaceAll(',', '.'));
    if (yield_ == null || yield_ <= 0) {
      setState(() => _error = 'Cantidad a producir inválida.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(productionRepositoryProvider).create(
            businessId: widget.businessId,
            finishedItemId: _selectedItemId!,
            plannedYield: yield_,
            sourceWarehouseId: _sourceWarehouseId!,
            destinationWarehouseId: _destinationWarehouseId!,
            notes: _notesCtrl.text.trim().isEmpty
                ? null
                : _notesCtrl.text.trim(),
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = FriendlyError.humanize('No se pudo crear la orden: $e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _loading
              ? const SizedBox(
                  height: 200,
                  child: Center(
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation(
                        MangoColors.primaryOrange,
                      ),
                    ),
                  ),
                )
              : _buildForm(),
        ),
      ),
    );
  }

  Widget _buildForm() {
    final yieldUnit = _selectedItem()?['unit']?.toString() ?? 'unidad';
    final recipeYield =
        (_selectedItem()?['recipe_yield'] as num?)?.toDouble() ?? 1;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Nueva orden de producción',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: MangoColors.darkGray,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Solo se listan inventory items que tienen receta de producción.',
          style: TextStyle(fontSize: 12, color: MangoColors.muted),
        ),
        const SizedBox(height: 16),
        if (_producibleItems.isEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF7ED),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFFD7B5)),
            ),
            child: const Text(
              'No tienes inventory items con receta de producción. Crea una '
              'receta primero (en /menu/recipes selecciona un inventory_item '
              'como target).',
              style: TextStyle(fontSize: 12),
            ),
          )
        else ...[
          const Text(
            'Producto a fabricar',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: MangoColors.muted,
            ),
          ),
          const SizedBox(height: 4),
          DropdownButtonFormField<String>(
            initialValue: _selectedItemId,
            isExpanded: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: _producibleItems
                .map<DropdownMenuItem<String>>(
                  (m) => DropdownMenuItem<String>(
                    value: m['item_id']?.toString(),
                    child: Text(
                      '${m['name']} (rinde ${_fmtQty((m['recipe_yield'] as num?)?.toDouble() ?? 1)} ${m['unit']})',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(growable: false),
            onChanged: (v) => setState(() => _selectedItemId = v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _yieldCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Cantidad a producir ($yieldUnit)',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    helperText: 'Receta base: ${_fmtQty(recipeYield)} $yieldUnit',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _sourceWarehouseId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Bodega origen (insumos)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: _warehouses
                      .map((w) => DropdownMenuItem<String>(
                            value: w.id,
                            child: Text(w.name + (w.isMain ? ' (principal)' : '')),
                          ))
                      .toList(growable: false),
                  onChanged: (v) => setState(() => _sourceWarehouseId = v),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _destinationWarehouseId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Bodega destino (producto)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: _warehouses
                      .map((w) => DropdownMenuItem<String>(
                            value: w.id,
                            child: Text(w.name + (w.isMain ? ' (principal)' : '')),
                          ))
                      .toList(growable: false),
                  onChanged: (v) => setState(() => _destinationWarehouseId = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notesCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Notas (opcional)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: const TextStyle(color: Color(0xFFDC2626), fontSize: 12),
          ),
        ],
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _submitting
                  ? null
                  : () => Navigator.of(context).pop(false),
              child: const Text('Cancelar'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange,
              ),
              onPressed: _producibleItems.isEmpty || _submitting
                  ? null
                  : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Crear orden'),
            ),
          ],
        ),
      ],
    );
  }

  Map<String, dynamic>? _selectedItem() {
    if (_selectedItemId == null) return null;
    for (final m in _producibleItems) {
      if (m['item_id']?.toString() == _selectedItemId) return m;
    }
    return null;
  }
}
