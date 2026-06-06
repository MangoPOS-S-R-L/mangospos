// Sugerencias de reorden — agrupa insumos por proveedor sugerido y deja
// crear una OC en draft directamente. Solo aparecen insumos cuyo stock
// está en o bajo min_stock.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/repositories/reorder_repository.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';
import 'package:mangopos/presentation/inventory/viewmodel/inventory_viewmodel.dart';
import 'package:mangopos/presentation/purchases/state/purchases_state.dart';
import 'package:mangopos/presentation/purchases/viewmodel/purchases_viewmodel.dart';

class InventoryReorderView extends ConsumerStatefulWidget {
  const InventoryReorderView({super.key});

  @override
  ConsumerState<InventoryReorderView> createState() =>
      _InventoryReorderViewState();
}

class _InventoryReorderViewState extends ConsumerState<InventoryReorderView> {
  String? _businessId;
  bool _loading = true;
  String? _error;
  List<ReorderSuggestion> _suggestions = const [];
  List<InventoryWarehouse> _warehouses = const [];

  // Estado de selección y edición por insumo.
  final Set<String> _selected = {};
  final Map<String, TextEditingController> _qtyControllers = {};
  String? _creatingForSupplier; // ID del proveedor con OC en vuelo.

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    for (final c in _qtyControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final id = await BusinessResolver.ensure('auto');
      _businessId = id;
      final repo = ref.read(reorderRepositoryProvider);
      final invRepo = ref.read(inventoryRepositoryProvider);
      final results = await Future.wait([
        repo.getSuggestions(id),
        invRepo.getWarehouses(id),
      ]);
      if (!mounted) return;
      setState(() {
        _suggestions = results[0] as List<ReorderSuggestion>;
        _warehouses = (results[1] as List<InventoryWarehouse>)
            .where((w) => w.name != '__IN_TRANSIT__')
            .toList(growable: false);
        for (final s in _suggestions) {
          _qtyControllers.putIfAbsent(
            s.inventoryItemId,
            () => TextEditingController(text: _fmtQty(s.suggestedQty)),
          );
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudieron cargar las sugerencias: $e';
        _loading = false;
      });
    }
  }

  Map<String?, List<ReorderSuggestion>> get _groupedBySupplier {
    final map = <String?, List<ReorderSuggestion>>{};
    for (final s in _suggestions) {
      final key = s.suggestedSupplierId;
      map.putIfAbsent(key, () => []).add(s);
    }
    return map;
  }

  void _toggleAll(List<ReorderSuggestion> group, bool select) {
    setState(() {
      for (final s in group) {
        if (select) {
          _selected.add(s.inventoryItemId);
        } else {
          _selected.remove(s.inventoryItemId);
        }
      }
    });
  }

  Future<void> _createPurchaseOrder(
    String? supplierId,
    String? supplierName,
    List<ReorderSuggestion> group,
  ) async {
    final selectedItems = group
        .where((s) => _selected.contains(s.inventoryItemId))
        .toList(growable: false);
    if (selectedItems.isEmpty) {
      AppToast.info(context, 'Selecciona al menos un insumo.');
      return;
    }
    if (supplierId == null) {
      // Necesitamos un proveedor para crear la OC. El admin debe elegir
      // uno en la lista de proveedores existentes del negocio.
      final picked = await _pickSupplierDialog();
      if (!mounted || picked == null) return;
      supplierId = picked.$1;
      supplierName = picked.$2;
    }
    if (_warehouses.isEmpty) {
      AppToast.info(
        context,
        'Tu negocio no tiene bodegas activas configuradas.',
      );
      return;
    }
    final warehouse = _warehouses.firstWhere(
      (w) => w.isMain,
      orElse: () => _warehouses.first,
    );

    setState(() => _creatingForSupplier = supplierId);
    try {
      final draftItems = <PurchaseDraftItem>[];
      for (final s in selectedItems) {
        final raw = _qtyControllers[s.inventoryItemId]?.text
                .replaceAll(',', '.')
                .trim() ??
            '';
        final qty = double.tryParse(raw) ?? 0;
        if (qty <= 0) continue;
        draftItems.add(
          PurchaseDraftItem(
            inventoryItemId: s.inventoryItemId,
            description: s.name,
            quantity: qty,
            unitCost: s.preferredUnitCost,
          ),
        );
      }
      if (draftItems.isEmpty) {
        AppToast.info(context, 'Las cantidades deben ser mayores a 0.');
        return;
      }

      final orderNumber = _generateOrderNumber();
      await ref.read(purchasesRepositoryProvider).createPurchaseOrder(
            businessId: _businessId!,
            supplierId: supplierId,
            warehouseId: warehouse.id,
            orderNumber: orderNumber,
            status: 'pending',
            expectedDate: DateTime.now().add(const Duration(days: 3)),
            notes: 'OC generada desde sugerencias de reorden',
            items: draftItems,
          );

      if (!mounted) return;
      AppToast.success(
        context,
        'OC $orderNumber creada para ${supplierName ?? 'proveedor'} '
        'con ${draftItems.length} líneas',
      );
      // Limpiar selección de este grupo y recargar.
      setState(() {
        for (final s in selectedItems) {
          _selected.remove(s.inventoryItemId);
        }
      });
      await _load();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo crear la OC: $e');
    } finally {
      if (mounted) setState(() => _creatingForSupplier = null);
    }
  }

  /// Diálogo simple para elegir un proveedor cuando no hay sugerido
  /// (insumo nunca antes comprado). Trae proveedores activos del negocio.
  Future<(String, String)?> _pickSupplierDialog() async {
    // Cargar proveedores via init() del VM (idempotente).
    final purchasesVm = ref.read(purchasesViewModelProvider);
    if (purchasesVm.state.suppliers.isEmpty) {
      await purchasesVm.init();
    }
    if (!mounted) return null;
    final suppliers = ref.read(purchasesViewModelProvider).state.suppliers
        .where((s) => s.isActive)
        .toList(growable: false);
    if (suppliers.isEmpty) {
      AppToast.info(
        context,
        'No tienes proveedores activos. Crea uno en Inventario → Proveedores.',
      );
      return null;
    }
    return showDialog<(String, String)>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Elige proveedor para esta OC'),
          content: SizedBox(
            width: 360,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: suppliers.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final s = suppliers[i];
                final subtitle = [s.contactName, s.phone]
                    .where((v) => v.trim().isNotEmpty)
                    .join(' · ');
                return ListTile(
                  title: Text(s.name),
                  subtitle: subtitle.isEmpty ? null : Text(subtitle),
                  onTap: () =>
                      Navigator.of(ctx).pop((s.id, s.name)),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancelar'),
            ),
          ],
        );
      },
    );
  }

  String _generateOrderNumber() {
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    return 'REORD-$stamp';
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
              : context.go(AppRoutes.inventoryHome),
        ),
        title: const Text('Sugerencias de reorden'),
        actions: [
          IconButton(
            tooltip: 'Refrescar',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                valueColor:
                    AlwaysStoppedAnimation(MangoColors.primaryOrange),
              ),
            )
          : _error != null
              ? Center(child: Text(_error!))
              : _suggestions.isEmpty
                  ? const _EmptyState()
                  : _buildList(),
    );
  }

  Widget _buildList() {
    final groups = _groupedBySupplier;
    final supplierKeys = groups.keys.toList(growable: false)
      ..sort((a, b) {
        if (a == null) return 1;
        if (b == null) return -1;
        final ga = groups[a]!.first.suggestedSupplierName ?? '';
        final gb = groups[b]!.first.suggestedSupplierName ?? '';
        return ga.compareTo(gb);
      });
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemCount: supplierKeys.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return _Header(totalItems: _suggestions.length);
        }
        final supplierId = supplierKeys[i - 1];
        final group = groups[supplierId]!;
        final supplierName = supplierId == null
            ? 'Sin proveedor sugerido'
            : (group.first.suggestedSupplierName ?? 'Proveedor');
        return _SupplierGroupCard(
          supplierId: supplierId,
          supplierName: supplierName,
          items: group,
          selectedIds: _selected,
          qtyControllers: _qtyControllers,
          isCreating: _creatingForSupplier == supplierId,
          onToggleAll: (sel) => _toggleAll(group, sel),
          onToggleOne: (s) {
            setState(() {
              if (_selected.contains(s.inventoryItemId)) {
                _selected.remove(s.inventoryItemId);
              } else {
                _selected.add(s.inventoryItemId);
              }
            });
          },
          onCreateOrder: () =>
              _createPurchaseOrder(supplierId, supplierName, group),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final int totalItems;
  const _Header({required this.totalItems});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFF97316), Color(0xFFFBAA16)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.shopping_cart_outlined, color: Colors.white, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$totalItems insumo${totalItems == 1 ? '' : 's'} bajo mínimo',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Revisa, ajusta cantidades y crea órdenes de compra '
                  'agrupadas por proveedor.',
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 56,
            color: MangoColors.successGreen.withValues(alpha: 0.7),
          ),
          const SizedBox(height: 12),
          const Text(
            'Sin sugerencias de reorden',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 6),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Todos tus insumos con stock mínimo configurado están por '
              'encima del umbral. Si no ves ningún insumo aquí, revisa '
              'que tengas `min_stock` configurado en Inventario → Insumos.',
              textAlign: TextAlign.center,
              style: TextStyle(color: MangoColors.muted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _SupplierGroupCard extends StatelessWidget {
  final String? supplierId;
  final String supplierName;
  final List<ReorderSuggestion> items;
  final Set<String> selectedIds;
  final Map<String, TextEditingController> qtyControllers;
  final bool isCreating;
  final ValueChanged<bool> onToggleAll;
  final ValueChanged<ReorderSuggestion> onToggleOne;
  final VoidCallback onCreateOrder;

  const _SupplierGroupCard({
    required this.supplierId,
    required this.supplierName,
    required this.items,
    required this.selectedIds,
    required this.qtyControllers,
    required this.isCreating,
    required this.onToggleAll,
    required this.onToggleOne,
    required this.onCreateOrder,
  });

  @override
  Widget build(BuildContext context) {
    final selectedCount =
        items.where((s) => selectedIds.contains(s.inventoryItemId)).length;
    final allSelected = selectedCount == items.length;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        children: [
          // Header del grupo
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 8),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: MangoColors.primaryOrange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.local_shipping_outlined,
                    size: 18,
                    color: MangoColors.primaryOrange,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        supplierName,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: MangoColors.darkGray,
                        ),
                      ),
                      Text(
                        '${items.length} insumo${items.length == 1 ? '' : 's'} '
                        '· $selectedCount seleccionado${selectedCount == 1 ? '' : 's'}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: MangoColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => onToggleAll(!allSelected),
                  child:
                      Text(allSelected ? 'Limpiar' : 'Seleccionar todos'),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: MangoColors.cardBorder),
          // Líneas
          for (final s in items)
            _ReorderRow(
              suggestion: s,
              isSelected: selectedIds.contains(s.inventoryItemId),
              qtyController: qtyControllers[s.inventoryItemId]!,
              onToggle: () => onToggleOne(s),
            ),
          // Footer con CTA
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            decoration: const BoxDecoration(
              color: Color(0xFFFAFAFA),
              borderRadius: BorderRadius.vertical(
                bottom: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    selectedCount == 0
                        ? 'Selecciona insumos para esta OC'
                        : '$selectedCount insumo${selectedCount == 1 ? '' : 's'} listos para pedir',
                    style: const TextStyle(
                      fontSize: 12,
                      color: MangoColors.muted,
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed:
                      (isCreating || selectedCount == 0) ? null : onCreateOrder,
                  icon: isCreating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.add_shopping_cart, size: 18),
                  label: Text(
                    isCreating ? 'Creando...' : 'Crear OC',
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: MangoColors.primaryOrange,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReorderRow extends StatelessWidget {
  final ReorderSuggestion suggestion;
  final bool isSelected;
  final TextEditingController qtyController;
  final VoidCallback onToggle;

  const _ReorderRow({
    required this.suggestion,
    required this.isSelected,
    required this.qtyController,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat('#,##0.00', 'en_US');
    final dateFmt = DateFormat('dd MMM yyyy');
    final s = suggestion;
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 14, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: isSelected,
              onChanged: (_) => onToggle(),
              activeColor: MangoColors.primaryOrange,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: 10,
                    runSpacing: 2,
                    children: [
                      _MetaPill(
                        label:
                            'Stock: ${_fmtQty(s.currentStock)} ${s.unit}',
                        color: const Color(0xFFC2410C),
                      ),
                      _MetaPill(
                        label:
                            'Mín: ${_fmtQty(s.minStock)}',
                        color: MangoColors.muted,
                      ),
                      if (s.maxStock != null)
                        _MetaPill(
                          label: 'Máx: ${_fmtQty(s.maxStock!)}',
                          color: MangoColors.muted,
                        ),
                      _MetaPill(
                        label:
                            'Costo: RD\$ ${currency.format(s.preferredUnitCost)}',
                        color: MangoColors.muted,
                      ),
                      if (s.lastPurchaseAt != null)
                        _MetaPill(
                          label:
                              'Última compra: ${dateFmt.format(s.lastPurchaseAt!.toLocal())}',
                          color: MangoColors.muted,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 84,
              child: TextField(
                controller: qtyController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
                ],
                textAlign: TextAlign.end,
                decoration: InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  hintText: 'Qty',
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 10,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  final String label;
  final Color color;
  const _MetaPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

String _fmtQty(double v) {
  if (v == v.truncateToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(2);
}
