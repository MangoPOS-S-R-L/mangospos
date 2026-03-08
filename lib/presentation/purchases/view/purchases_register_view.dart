import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router/routes.dart';
import '../state/purchases_state.dart';
import '../viewmodel/purchases_viewmodel.dart';

class PurchasesRegisterView extends ConsumerStatefulWidget {
  const PurchasesRegisterView({super.key});

  @override
  ConsumerState<PurchasesRegisterView> createState() =>
      _PurchasesRegisterViewState();
}

class _PurchasesRegisterViewState extends ConsumerState<PurchasesRegisterView> {
  final _notesCtrl = TextEditingController();
  final _orderNumberCtrl = TextEditingController();
  String? _supplierId;
  String? _warehouseId;
  String _status = 'draft';
  DateTime _expectedDate = DateTime.now().add(const Duration(days: 3));
  final List<_DraftItemControllers> _itemControllers = [
    _DraftItemControllers(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final vm = ref.read(purchasesViewModelProvider);
      await vm.init();
      if (!mounted) return;
      final state = vm.state;
      if (_supplierId == null && state.suppliers.isNotEmpty) {
        _supplierId = state.suppliers.first.id;
      }
      if (_warehouseId == null && state.warehouses.isNotEmpty) {
        _warehouseId = state.warehouses.first.id;
      }
      final nextNumber = await vm.generateNextOrderNumber();
      if (!mounted) return;
      setState(() {
        _orderNumberCtrl.text = nextNumber;
      });
    });
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    _orderNumberCtrl.dispose();
    for (final item in _itemControllers) {
      item.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(purchasesViewModelProvider);
    final state = vm.state;
    final currency = NumberFormat.currency(
      locale: 'es_DO',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    final total = _draftItems.fold<double>(0, (sum, item) => sum + item.total);
    final estimatedTax = _draftItems.fold<double>(
      0,
      (sum, item) => sum + ((item.total * item.taxRate) / 100),
    );

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: state.loading && state.suppliers.isEmpty && state.warehouses.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => context.go(AppRoutes.purchasesList),
                        icon: const Icon(Icons.arrow_back),
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Registro de compra',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              'Crea una orden de compra básica para proveedores',
                              style: TextStyle(
                                fontSize: 14,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: state.saving ? null : _submit,
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Guardar orden'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (state.error != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFFECACA)),
                      ),
                      child: Text(
                        state.error!,
                        style: const TextStyle(color: Color(0xFF991B1B)),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Datos generales',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _orderNumberCtrl,
                                      decoration: const InputDecoration(
                                        labelText: 'Número de orden',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: DropdownButtonFormField<String>(
                                      initialValue: _status,
                                      decoration: const InputDecoration(
                                        labelText: 'Estado',
                                      ),
                                      items: const [
                                        DropdownMenuItem(
                                          value: 'draft',
                                          child: Text('Borrador'),
                                        ),
                                        DropdownMenuItem(
                                          value: 'sent',
                                          child: Text('Enviada'),
                                        ),
                                      ],
                                      onChanged: (value) {
                                        if (value == null) return;
                                        setState(() {
                                          _status = value;
                                        });
                                      },
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: DropdownButtonFormField<String>(
                                      initialValue: _supplierId,
                                      decoration: const InputDecoration(
                                        labelText: 'Proveedor',
                                      ),
                                      items: state.suppliers
                                          .map(
                                            (supplier) => DropdownMenuItem(
                                              value: supplier.id,
                                              child: Text(supplier.name),
                                            ),
                                          )
                                          .toList(growable: false),
                                      onChanged: (value) {
                                        setState(() {
                                          _supplierId = value;
                                        });
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: DropdownButtonFormField<String>(
                                      initialValue: _warehouseId,
                                      decoration: const InputDecoration(
                                        labelText: 'Almacen',
                                      ),
                                      items: state.warehouses
                                          .map(
                                            (warehouse) => DropdownMenuItem(
                                              value: warehouse.id,
                                              child: Text(
                                                warehouse.isMain
                                                    ? '${warehouse.name} · Principal'
                                                    : warehouse.name,
                                              ),
                                            ),
                                          )
                                          .toList(growable: false),
                                      onChanged: (value) {
                                        setState(() {
                                          _warehouseId = value;
                                        });
                                      },
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () async {
                                        final picked = await showDatePicker(
                                          context: context,
                                          initialDate: _expectedDate,
                                          firstDate: DateTime.now().subtract(
                                            const Duration(days: 30),
                                          ),
                                          lastDate: DateTime.now().add(
                                            const Duration(days: 365),
                                          ),
                                        );
                                        if (picked == null) return;
                                        setState(() {
                                          _expectedDate = picked;
                                        });
                                      },
                                      icon: const Icon(Icons.event_outlined),
                                      label: Text(
                                        'Entrega ${DateFormat('dd/MM/yyyy').format(_expectedDate)}',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _notesCtrl,
                                maxLines: 3,
                                decoration: const InputDecoration(
                                  labelText: 'Notas',
                                  alignLabelWithHint: true,
                                ),
                              ),
                              const SizedBox(height: 24),
                              if (state.inventoryItems.isEmpty) ...[
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFFBEB),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: const Color(0xFFFDE68A),
                                    ),
                                  ),
                                  child: const Text(
                                    'No hay insumos activos en inventario. Puedes guardar la orden, pero no podrá subir stock automáticamente al recibirla.',
                                    style: TextStyle(color: Color(0xFF92400E)),
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    'Líneas de compra',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: _addLine,
                                    icon: const Icon(Icons.add),
                                    label: const Text('Agregar línea'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              for (var i = 0; i < _itemControllers.length; i++) ...[
                                _DraftItemCard(
                                  index: i,
                                  controllers: _itemControllers[i],
                                  inventoryItems: state.inventoryItems,
                                  onRemove: _itemControllers.length == 1
                                      ? null
                                      : () => _removeLine(i),
                                  onChanged: () => setState(() {}),
                                ),
                                const SizedBox(height: 12),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      SizedBox(
                        width: 280,
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Resumen',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 16),
                              _SummaryRow(
                                label: 'Líneas',
                                value: '${_draftItems.length}',
                              ),
                              const SizedBox(height: 10),
                              _SummaryRow(
                                label: 'Subtotal',
                                value: currency.format(total),
                              ),
                              const SizedBox(height: 10),
                              _SummaryRow(
                                label: 'ITBIS estimado',
                                value: currency.format(estimatedTax),
                              ),
                              const Divider(height: 24),
                              _SummaryRow(
                                label: 'Total estimado',
                                value: currency.format(total + estimatedTax),
                                bold: true,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  List<PurchaseDraftItem> get _draftItems => _itemControllers
      .map((controllers) => controllers.toDraftItem())
      .where(
        (item) =>
            item.description.trim().isNotEmpty || item.inventoryItemId != null,
      )
      .toList(growable: false);

  void _addLine() {
    setState(() {
      _itemControllers.add(_DraftItemControllers());
    });
  }

  void _removeLine(int index) {
    setState(() {
      final removed = _itemControllers.removeAt(index);
      removed.dispose();
    });
  }

  Future<void> _submit() async {
    if (_supplierId == null || _warehouseId == null) {
      return;
    }
    if (_draftItems.isEmpty) {
      return;
    }

    await ref.read(purchasesViewModelProvider).createPurchaseOrder(
      supplierId: _supplierId!,
      warehouseId: _warehouseId!,
      orderNumber: _orderNumberCtrl.text.trim(),
      status: _status,
      expectedDate: _expectedDate,
      notes: _notesCtrl.text.trim(),
      items: _draftItems,
    );

    if (!mounted) return;
    context.go(AppRoutes.purchasesList);
  }
}

class _DraftItemCard extends StatelessWidget {
  final int index;
  final _DraftItemControllers controllers;
  final List<PurchaseInventoryItem> inventoryItems;
  final VoidCallback? onRemove;
  final VoidCallback onChanged;

  const _DraftItemCard({
    required this.index,
    required this.controllers,
    required this.inventoryItems,
    required this.onChanged,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Línea ${index + 1}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (onRemove != null)
                IconButton(
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            initialValue: controllers.inventoryItemId,
            decoration: const InputDecoration(
              labelText: 'Insumo inventariable',
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('No vinculado'),
              ),
              ...inventoryItems.map(
                (item) => DropdownMenuItem<String?>(
                  value: item.id,
                  child: Text(
                    item.sku.trim().isEmpty
                        ? item.name
                        : '${item.name} · ${item.sku}',
                  ),
                ),
              ),
            ],
            onChanged: (value) {
              controllers.inventoryItemId = value;
              PurchaseInventoryItem? selected;
              for (final item in inventoryItems) {
                if (item.id == value) {
                  selected = item;
                  break;
                }
              }
              if (selected != null) {
                controllers.description.text = selected.name;
                if (controllers.unitCost.text.trim() == '0' &&
                    selected.cost > 0) {
                  controllers.unitCost.text = selected.cost.toStringAsFixed(2);
                }
              }
              onChanged();
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controllers.description,
            onChanged: (_) => onChanged(),
            decoration: const InputDecoration(labelText: 'Descripción'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controllers.quantity,
                  onChanged: (_) => onChanged(),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Cantidad'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: controllers.unitCost,
                  onChanged: (_) => onChanged(),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Costo unitario'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;

  const _SummaryRow({
    required this.label,
    required this.value,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
      color: const Color(0xFF0F172A),
    );
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: style.copyWith(
              color: bold ? const Color(0xFF0F172A) : const Color(0xFF64748B),
            ),
          ),
        ),
        Text(value, style: style),
      ],
    );
  }
}

class _DraftItemControllers {
  final description = TextEditingController();
  final quantity = TextEditingController(text: '1');
  final unitCost = TextEditingController(text: '0');
  String? inventoryItemId;

  PurchaseDraftItem toDraftItem() {
    double parse(String raw) => double.tryParse(raw.trim()) ?? 0;
    return PurchaseDraftItem(
      inventoryItemId: inventoryItemId,
      description: description.text.trim(),
      quantity: parse(quantity.text),
      unitCost: parse(unitCost.text),
    );
  }

  void dispose() {
    description.dispose();
    quantity.dispose();
    unitCost.dispose();
  }
}
