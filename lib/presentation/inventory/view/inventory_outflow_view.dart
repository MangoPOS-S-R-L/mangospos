import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../services/inventory_scan.dart';
import '../state/adjust_reasons.dart';
import '../state/inventory_state.dart';
import '../utils/outflow_note.dart';
import '../utils/waste_exit_printing.dart';
import '../viewmodel/inventory_viewmodel.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/inventory/item_classification.dart';
import '../../../core/inventory/pack_conversion.dart';
import '../../../core/inventory/unit_conversion.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/utils/app_time.dart';
import 'widgets/inventory_back_button.dart';
import 'widgets/item_outflows_dialog.dart';
import 'widgets/unit_dropdown.dart';
import 'package:mangopos/core/utils/app_snackbar.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../services/printing/waste_exit_pdf.dart';
import '../../../services/session/session_controller.dart';
import 'package:go_router/go_router.dart';
import '../../../app/router/routes.dart';
import '../state/outflow_reasons.dart';
import 'widgets/outflow_history_section.dart';

class InventoryOutflowView extends ConsumerStatefulWidget {
  const InventoryOutflowView({super.key});

  @override
  ConsumerState<InventoryOutflowView> createState() =>
      _InventoryOutflowViewState();
}

class _InventoryOutflowViewState extends ConsumerState<InventoryOutflowView> {
  final TextEditingController _searchController = TextEditingController();

  /// Filas de la tabla que se dibujan. La tabla vive dentro de un scroll de
  /// página (`shrinkWrap`), así que dibuja TODAS sus filas en cada rebuild:
  /// con catálogos de cientos de insumos eso trababa la pantalla. Se muestra
  /// una página y "Ver más"; buscar es lo que acota de verdad.
  static const int _pageSize = 50;
  int _visibleCount = _pageSize;

  /// Búsqueda LOCAL sobre los insumos ya cargados. Antes cada tecla recargaba
  /// todo del servidor (~7 consultas) para filtrar igual en el cliente, y
  /// además dejaba filtrada la lista compartida con las otras pantallas.
  List<InventoryItemSummary> _filter(List<InventoryItemSummary> items) {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return items;
    return items
        .where(
          (i) =>
              i.name.toLowerCase().contains(q) ||
              i.sku.toLowerCase().contains(q) ||
              i.description.toLowerCase().contains(q) ||
              i.barcode.toLowerCase().contains(q),
        )
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(inventoryViewModelProvider).init();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(inventoryViewModelProvider);
    final state = vm.state;
    // El servidor solo deja a dueño/admin/gerente, pero un rol con permisos
    // a la medida puede no tenerlos: el catálogo dice que las salidas son de
    // `inventario.ajustes.crear` y el alta/edición de insumos de
    // `inventario.productos.crear_editar` (igual que en Insumos).
    final session = ref.watch(sessionProvider.notifier);
    ref.watch(sessionProvider);
    final canOutflow = session.hasPermission('inventario.ajustes.crear');
    final canEditItems = session.hasPermission(
      'inventario.productos.crear_editar',
    );
    // La bodega virtual de tránsito no es un almacén donde se pueda mermar:
    // sacar de ahí rompe la recepción de la transferencia.
    final warehouses = state.warehouses
        .where((w) => w.name != '__IN_TRANSIT__')
        .toList(growable: false);
    final filteredItems = _filter(state.items);
    final visibleItems = filteredItems.length > _visibleCount
        ? filteredItems.sublist(0, _visibleCount)
        : filteredItems;
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      body: state.loading && state.items.isEmpty
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: InventoryBackButton(),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Inventario',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                color: AppColors.foreground,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Insumos, stock actual y salidas manuales',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => _printTodayA4(context),
                            icon: const Icon(Icons.print_outlined),
                            label: const Text('Imprimir A4'),
                          ),
                          OutlinedButton.icon(
                            onPressed: state.saving || !canEditItems
                                ? null
                                : () => _showCreateItemDialog(context),
                            icon: const Icon(Icons.add_box_outlined),
                            label: const Text('Nuevo insumo'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.primary,
                              side: BorderSide(color: AppColors.primary),
                            ),
                          ),
                          FilledButton.icon(
                            key: const Key('outflow-open'),
                            onPressed:
                                state.items.isEmpty ||
                                    state.saving ||
                                    !canOutflow
                                ? null
                                : () => _showOutflowDialog(context),
                            icon: const Icon(Icons.logout_rounded),
                            label: const Text('Registrar salida'),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (state.error != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.destructive.withValues(alpha:0.05),
                        borderRadius: BorderRadius.circular(AppRadius.card),
                        border: Border.all(color: AppColors.destructive.withValues(alpha:0.2)),
                      ),
                      child: Text(
                        state.error!,
                        style: TextStyle(color: AppColors.destructive),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _searchController,
                          onChanged: (_) => setState(
                            () => _visibleCount = _pageSize,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Buscar por nombre, SKU o descripcion',
                            prefixIcon: const Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(AppRadius.card),
                            ),
                            filled: true,
                            fillColor: AppColors.card,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 1,
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(state.selectedWarehouseId),
                          isExpanded: true,
                          // Solo si está en la lista: un id que no está en
                          // `items` tumba el DropdownButton con un assert.
                          initialValue: warehouses.any(
                                  (w) => w.id == state.selectedWarehouseId)
                              ? state.selectedWarehouseId
                              : null,
                          decoration: InputDecoration(
                            labelText: 'Almacen',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(AppRadius.card),
                            ),
                            filled: true,
                            fillColor: AppColors.card,
                          ),
                          items: warehouses
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
                          onChanged: state.saving
                              ? null
                              : (value) => ref
                                    .read(inventoryViewModelProvider)
                                    .selectWarehouse(value),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filledTonal(
                        onPressed: state.saving
                            ? null
                            : () => ref
                                  .read(inventoryViewModelProvider)
                                  .refresh(),
                        icon: const Icon(Icons.refresh),
                        style: IconButton.styleFrom(
                          backgroundColor: AppColors.primary.withValues(alpha:0.1),
                          foregroundColor: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _SummaryCard(
                        title: 'Insumos activos',
                        value:
                            '${state.items.where((item) => item.isActive).length}',
                        color: AppColors.primary,
                      ),
                      _SummaryCard(
                        title: 'Stock bajo',
                        value:
                            '${state.items.where((item) => item.isLowStock).length}',
                        color: AppColors.warning,
                      ),
                      _SummaryCard(
                        title: 'Valor inventario',
                        value: currency.format(
                          state.items.fold<double>(
                            0,
                            (sum, item) => sum + (item.stock * item.cost),
                          ),
                        ),
                        color: AppColors.success,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      border: Border.all(color: AppColors.border),
                      boxShadow: AppShadows.cardElevated,
                    ),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: Text(
                                  'INSUMO',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.mutedForeground,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  'STOCK',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.mutedForeground,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  'UNIDAD BASE',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.mutedForeground,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  'COSTO',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.mutedForeground,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 120),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        if (filteredItems.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.inventory_2_outlined, size: 32, color: AppColors.mutedForeground),
                                  const SizedBox(height: 8),
                                  Text(
                                    state.items.isEmpty
                                        ? 'No hay insumos registrados en este almacen.'
                                        : 'Ningún insumo coincide con la búsqueda.',
                                    style: TextStyle(color: AppColors.mutedForeground),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: visibleItems.length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final item = visibleItems[index];
                              // Toda la fila abre la ficha del insumo: sus
                              // salidas, cada una imprimible por separado.
                              return InkWell(
                                key: ValueKey('outflow-row-${item.id}'),
                                onTap: () => _showItemSheet(context, item),
                                child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 14,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      flex: 3,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.name,
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.foreground,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            [
                                              if (item.sku.isNotEmpty) item.sku,
                                              item.unit,
                                              if (item.description.isNotEmpty)
                                                item.description,
                                            ].join(' · '),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: AppColors.mutedForeground,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        item.stock.toStringAsFixed(2),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: item.isLowStock
                                              ? AppColors.warning
                                              : AppColors.foreground,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        item.unit.toUpperCase(),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(currency.format(item.cost)),
                                    ),
                                    SizedBox(
                                      width: 176,
                                      child: Wrap(
                                        alignment: WrapAlignment.end,
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          IconButton(
                                            tooltip: 'Editar insumo',
                                            onPressed:
                                                state.saving || !canEditItems
                                                ? null
                                                : () => _showEditItemDialog(
                                                    context,
                                                    item,
                                                  ),
                                            icon: const Icon(
                                              Icons.edit_outlined,
                                            ),
                                          ),
                                          IconButton(
                                            key: ValueKey(
                                              'outflow-print-${item.id}',
                                            ),
                                            tooltip: 'Imprimir salidas',
                                            onPressed: () =>
                                                _showItemSheet(context, item),
                                            icon: const Icon(
                                              Icons.print_outlined,
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: 'Eliminar insumo',
                                            onPressed:
                                                state.saving || !canEditItems
                                                ? null
                                                : () => _showDeleteItemDialog(
                                                    context,
                                                    item,
                                                  ),
                                            icon: const Icon(
                                              Icons.delete_outline,
                                              color: Color(0xFFEF4444),
                                            ),
                                          ),
                                          FilledButton.tonal(
                                            onPressed:
                                                state.saving || !canOutflow
                                                ? null
                                                : () => _showOutflowDialog(
                                                    context,
                                                    initialItem: item,
                                                  ),
                                            style: FilledButton.styleFrom(
                                              backgroundColor: AppColors.primary.withValues(alpha:0.1),
                                              foregroundColor: AppColors.primary,
                                            ),
                                            child: const Text('Salida'),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                ),
                              );
                            },
                          ),
                        if (filteredItems.length > visibleItems.length) ...[
                          const Divider(height: 1),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: TextButton.icon(
                              onPressed: () => setState(
                                () => _visibleCount += _pageSize,
                              ),
                              icon: const Icon(Icons.expand_more),
                              label: Text(
                                'Ver más (${filteredItems.length - visibleItems.length} restantes)',
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  OutflowHistorySection(
                    key: const Key('outflow-history'),
                    // Otra bodega o una salida nueva: se vuelve a leer.
                    reloadKey:
                        '${state.selectedWarehouseId}|'
                        '${state.movements.isEmpty ? '' : state.movements.first.id}|'
                        '${state.movements.length}',
                    load: (days) => ref
                        .read(inventoryViewModelProvider)
                        .loadOutflowHistory(days: days),
                    itemsById: {for (final i in state.items) i.id: i},
                    money: currentBusinessCurrencyOrFallback(ref),
                    onPrintTicket: _printMovementTicket,
                    onPrintA4: _printA4,
                    onOpenYield: () => context.push(AppRoutes.inventoryYield),
                  ),
                ],
              ),
            ),
    );
  }

  /// Mermas de HOY de la bodega seleccionada, en una hoja A4 para firmar.
  ///
  /// Se piden al servidor: la lista de la pantalla son los últimos 60
  /// movimientos de TODOS los tipos (en una bodega con ventas, las salidas de
  /// la mañana ya no están ahí al mediodía), y "hoy" es el día de RD.
  Future<void> _printTodayA4(BuildContext context) async {
    List<InventoryMovementEntry> today;
    try {
      today = await ref.read(inventoryViewModelProvider).loadTodayOutflows();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showAppSnackBar(
        const SnackBar(
          content: Text(
            'No se pudieron leer las salidas de hoy. Revisa la conexión.',
          ),
        ),
      );
      return;
    }
    if (!context.mounted) return;
    if (today.isEmpty) {
      ScaffoldMessenger.of(context).showAppSnackBar(
        const SnackBar(content: Text('No hay salidas registradas hoy.')),
      );
      return;
    }
    await _printA4(today);
  }

  String _warehouseName() {
    final state = ref.read(inventoryViewModelProvider).state;
    for (final w in state.warehouses) {
      if (w.id == state.selectedWarehouseId) return w.name;
    }
    return 'Bodega';
  }

  String _businessName() {
    final negocio = (ref.read(sessionProvider).activeBusinessName ?? '').trim();
    return negocio.isEmpty ? 'MangoPOS' : negocio;
  }

  /// Conduce en PDF (A4) de las salidas dadas. El motivo se lee del prefijo
  /// de la nota ("Vencido — …"), que la salida guarda siempre, esté o no
  /// desplegada la columna `reason_code`. El costo es el del MOVIMIENTO (el
  /// de ese día); el del insumo solo si el movimiento no lo guardó.
  Future<void> _printA4(List<InventoryMovementEntry> movements) async {
    final state = ref.read(inventoryViewModelProvider).state;
    final itemsById = {for (final i in state.items) i.id: i};
    final lines = [
      for (final m in movements)
        () {
          final item = itemsById[m.itemId];
          final note = splitOutflowNote(m.notes);
          return WasteExitPdfLine(
            date: m.createdAt,
            itemName: m.itemName,
            quantity: m.quantity.abs(),
            unit: item?.unit ?? '',
            reason: outflowReasonByCode(m.outflowReason).label,
            notes: note.detail,
            costPerUnit: m.costPerUnit ?? item?.cost ?? 0,
            destination: m.destination ?? '',
          );
        }(),
    ];
    await _printA4Lines(lines);
  }

  Future<void> _printA4Lines(List<WasteExitPdfLine> lines) async {
    try {
      await WasteExitPdf.printDocument(
        lines: lines,
        businessName: _businessName(),
        warehouseName: _warehouseName(),
        // Sin nombre a propósito: quien imprime no es necesariamente quien
        // sacó la mercancía. Las dos firmas se llenan a mano.
        currency: currentBusinessCurrencyOrFallback(ref),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showAppSnackBar(
        SnackBar(content: Text('No se pudo imprimir: $e')),
      );
    }
  }

  /// Reimprime el ticket de UNA salida ya registrada. Sin la existencia de
  /// ese momento (no se guardó) y sin «Registrado por» (quien reimprime no
  /// es quien la sacó): el ticket sale marcado como REIMPRESIÓN.
  Future<void> _printMovementTicket(InventoryMovementEntry m) async {
    final businessId = ref.read(inventoryViewModelProvider).state.businessId;
    if (businessId == null) return;
    final state = ref.read(inventoryViewModelProvider).state;
    InventoryItemSummary? item;
    for (final i in state.items) {
      if (i.id == m.itemId) item = i;
    }
    final note = splitOutflowNote(m.notes);
    await WasteExitPrinting.print(
      context,
      ref,
      businessId: businessId,
      businessName: _businessName(),
      itemName: m.itemName,
      quantity: m.quantity.abs(),
      unit: item?.unit ?? '',
      reasonLabel: outflowReasonByCode(m.outflowReason).label,
      warehouseName: _warehouseName(),
      notes: note.detail.isEmpty ? null : note.detail,
      destination: m.destination,
      stockBefore: null,
      stockAfter: null,
      costPerUnit: m.costPerUnit ?? item?.cost ?? 0,
      occurredAt: AppTime.astToUtc(m.createdAt),
      reprint: true,
    );
  }

  /// Ficha del insumo: sus salidas en esta bodega, cada una imprimible sola
  /// (ticket o A4), todas juntas en A4, o registrar una nueva.
  Future<void> _showItemSheet(
    BuildContext context,
    InventoryItemSummary item,
  ) async {
    final canOutflow = ref
        .read(sessionProvider.notifier)
        .hasPermission('inventario.ajustes.crear');
    final register = await showDialog<bool>(
      context: context,
      builder: (_) => InventoryItemOutflowsDialog(
        item: item,
        warehouseName: _warehouseName(),
        canRegister: canOutflow,
        load: (days) => ref
            .read(inventoryViewModelProvider)
            .loadItemOutflows(item.id, days: days),
        onPrintTicket: _printMovementTicket,
        onPrintA4: _printA4,
      ),
    );
    if (register == true && context.mounted) {
      await _showOutflowDialog(context, initialItem: item);
    }
  }

  Future<void> _showCreateItemDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _InventoryItemDialog(
        title: 'Nuevo insumo',
        onSubmit: (payload) async {
          await ref
              .read(inventoryViewModelProvider)
              .createItem(
                name: payload.name,
                sku: payload.sku,
                description: payload.description,
                unit: payload.unit,
                cost: payload.cost,
                minStock: payload.minStock,
                maxStock: payload.maxStock,
                initialStock: payload.initialStock,
                purchaseUnit: payload.purchaseUnit,
                packSize: payload.packSize,
                conversionUnit: payload.conversionUnit,
                conversionFactor: payload.conversionFactor,
              );
        },
      ),
    );
  }

  Future<void> _showEditItemDialog(
    BuildContext context,
    InventoryItemSummary item,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _InventoryItemDialog(
        title: 'Editar insumo',
        initialItem: item,
        onSubmit: (payload) async {
          await ref
              .read(inventoryViewModelProvider)
              .updateItem(
                itemId: item.id,
                name: payload.name,
                sku: payload.sku,
                description: payload.description,
                unit: payload.unit,
                cost: payload.cost,
                minStock: payload.minStock,
                maxStock: payload.maxStock,
                isActive: payload.isActive,
                purchaseUnit: payload.purchaseUnit,
                packSize: payload.packSize,
                conversionUnit: payload.conversionUnit,
                conversionFactor: payload.conversionFactor,
              );
        },
      ),
    );
  }

  Future<void> _showDeleteItemDialog(
    BuildContext context,
    InventoryItemSummary item,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: const Text('Eliminar insumo'),
        content: Text(
          'Se eliminará "${item.name}" de la lista. Su historial de '
          'movimientos y recetas se conservan; puedes reactivarlo luego. '
          '¿Deseas continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(inventoryViewModelProvider).deactivateItem(item.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showAppSnackBar(
        SnackBar(content: Text('"${item.name}" eliminado')),
      );
    }
  }

  Future<void> _showOutflowDialog(
    BuildContext context, {
    InventoryItemSummary? initialItem,
  }) async {
    final state = ref.read(inventoryViewModelProvider).state;
    // Se leen ANTES de guardar: son los datos del conduce.
    var warehouseName = 'Bodega';
    for (final w in state.warehouses) {
      if (w.id == state.selectedWarehouseId) warehouseName = w.name;
    }
    final businessId = state.businessId;

    final saved = await showDialog<_SavedOutflow>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _InventoryOutflowDialog(
        items: state.items,
        // Desde el encabezado NO se preselecciona nada: antes quedaba marcado
        // el primer insumo de la lista y, si la persona buscaba otro sin
        // tocar la fila, se descontaba (e imprimía) el equivocado.
        initialItemId: initialItem?.id,
        onSubmit: (item, quantity, reason, notes, operationId, destination) =>
            ref
                .read(inventoryViewModelProvider)
                .registerOutflow(
                  itemId: item.id,
                  quantity: quantity,
                  reasonCode: reason.code,
                  reasonLabel: reason.label,
                  notes: notes,
                  operationId: operationId,
                  costPerUnit: item.cost,
                  destination: destination,
                ),
      ),
    );

    // EL CONDUCE: después de guardar (una impresora caída no puede impedir
    // que la merma quede) y con el diálogo YA cerrado. Pedido del dueño
    // (2026-09-30): no se imprime solo — se PREGUNTA, con ticket o A4.
    if (saved == null || businessId == null || !context.mounted) return;
    final choice = await showDialog<OutflowPrintChoice>(
      context: context,
      builder: (_) => OutflowSavedPrintDialog(
        itemName: saved.item.name,
        quantity: saved.quantity,
        unit: saved.item.unit,
        reasonLabel: saved.reason.label,
      ),
    );
    if (!context.mounted) return;
    switch (choice) {
      case OutflowPrintChoice.ticket:
        final session = ref.read(sessionProvider);
        await WasteExitPrinting.print(
          context,
          ref,
          businessId: businessId,
          businessName: _businessName(),
          itemName: saved.item.name,
          quantity: saved.quantity,
          unit: saved.item.unit,
          reasonLabel: saved.reason.label,
          warehouseName: warehouseName,
          notes: saved.notes,
          destination: saved.destination,
          operatorName: session.userName,
          stockBefore: saved.item.stock,
          stockAfter: saved.item.stock - saved.quantity,
          costPerUnit: saved.item.cost,
        );
      case OutflowPrintChoice.a4:
        await _printA4Lines([
          WasteExitPdfLine(
            date: AppTime.nowAst(),
            itemName: saved.item.name,
            quantity: saved.quantity,
            unit: saved.item.unit,
            reason: saved.reason.label,
            notes: saved.notes ?? '',
            costPerUnit: saved.item.cost,
            destination: saved.destination ?? '',
          ),
        ]);
      case OutflowPrintChoice.none:
      case null:
        break;
    }
  }
}

class _SummaryCard extends StatelessWidget {
  final String title;
  final String value;
  final Color color;

  const _SummaryCard({
    required this.title,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.cardElevated,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.mutedForeground,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemDialogPayload {
  final String name;
  final String? sku;
  final String? description;
  final String unit;
  final double cost;
  final double minStock;
  final double? maxStock;
  final double initialStock;
  final bool isActive;
  final String? purchaseUnit;
  final double packSize;
  // Equivalencia propia: null = no tocarla; '' = borrarla.
  final String? conversionUnit;
  final double? conversionFactor;

  const _ItemDialogPayload({
    required this.name,
    required this.sku,
    required this.description,
    required this.unit,
    required this.cost,
    required this.minStock,
    required this.maxStock,
    required this.initialStock,
    required this.isActive,
    required this.purchaseUnit,
    required this.packSize,
    this.conversionUnit,
    this.conversionFactor,
  });
}

class _InventoryItemDialog extends StatefulWidget {
  final String title;
  final InventoryItemSummary? initialItem;
  final Future<void> Function(_ItemDialogPayload payload) onSubmit;

  const _InventoryItemDialog({
    required this.title,
    required this.onSubmit,
    this.initialItem,
  });

  @override
  State<_InventoryItemDialog> createState() => _InventoryItemDialogState();
}

class _InventoryItemDialogState extends State<_InventoryItemDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _skuController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _unitController;
  late final TextEditingController _costController;
  late final TextEditingController _minStockController;
  late final TextEditingController _maxStockController;
  late final TextEditingController _initialStockController;
  // Conversión de empaque: se compra en `purchase_unit` (ej. botella) que
  // contiene `pack_size` unidades base (ej. 700 ml). Vacío = sin conversión.
  late final TextEditingController _purchaseUnitController;
  late final TextEditingController _packSizeController;
  String _selectedPresentation = 'unidad';
  bool _isActive = true;
  bool _saving = false;
  // Secciones del catálogo según lo GUARDADO: una unidad fuera del catálogo
  // queda en «Actual» para no perderla al editar.
  late final List<UnitSection> _baseSections;
  late final List<UnitSection> _purchaseSections;
  // Equivalencia propia: 1 [unidad base] = N [otra unidad] (1 ea = 200 g).
  late final TextEditingController _conversionFactorController;
  String _conversionUnit = '';
  // Si la ficha llegó sabiendo qué equivalencia tenía. Si no (esquema viejo)
  // y nadie la toca, al guardar no se manda: así no se borra una que exista.
  late final bool _conversionKnown;
  bool _conversionTouched = false;

  @override
  void initState() {
    super.initState();
    final item = widget.initialItem;
    _nameController = TextEditingController(text: item?.name ?? '');
    _skuController = TextEditingController(text: item?.sku ?? '');
    _descriptionController = TextEditingController(
      text: item?.description ?? '',
    );
    _unitController = TextEditingController(text: item?.unit ?? 'unidad');
    _baseSections = baseUnitSections(current: item?.unit);
    _purchaseSections = purchaseUnitSections(current: item?.purchaseUnit);
    // Antes la unidad se pasaba a minúsculas y un «L» se guardaba «l». Ahora
    // arranca como su código del catálogo («gr» → g) o, si no está en el
    // catálogo, tal cual.
    _selectedPresentation = unitSelectionValue(
      _baseSections,
      item?.unit,
      fallback: 'unidad',
    );

    _costController = TextEditingController(
      text: item == null ? '' : item.cost.toStringAsFixed(2),
    );
    _minStockController = TextEditingController(
      text: item == null ? '' : item.minStock.toStringAsFixed(2),
    );
    _maxStockController = TextEditingController(
      text: item?.maxStock?.toStringAsFixed(2) ?? '',
    );
    _initialStockController = TextEditingController();
    _purchaseUnitController = TextEditingController(
      text: unitSelectionValue(
        _purchaseSections,
        item?.purchaseUnit,
        fallback: '',
      ),
    );
    _conversionKnown = item == null || item.conversionKnown;
    _conversionUnit = item?.conversionUnit ?? '';
    _conversionFactorController = TextEditingController(
      text: (item != null && item.conversionFactor > 0)
          ? _trimNum(item.conversionFactor)
          : '',
    );
    _packSizeController = TextEditingController(
      text: (item != null && item.packSize > 1)
          ? _trimNum(item.packSize)
          : '',
    );
    _isActive = item?.isActive ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _skuController.dispose();
    _descriptionController.dispose();
    _unitController.dispose();
    _costController.dispose();
    _minStockController.dispose();
    _maxStockController.dispose();
    _initialStockController.dispose();
    _purchaseUnitController.dispose();
    _packSizeController.dispose();
    _conversionFactorController.dispose();
    super.dispose();
  }

  String _trimNum(double v) {
    final s = v.toStringAsFixed(2);
    if (s.endsWith('.00')) return s.substring(0, s.length - 3);
    if (s.endsWith('0')) return s.substring(0, s.length - 1);
    return s;
  }

  /// Contenido que sale solo cuando se compra en una medida convertible
  /// (1 lb = 453.59 g, 1 gal = 3785.41 mL).
  double? get _autoPackSize {
    final pu = _purchaseUnitController.text.trim();
    if (pu.isEmpty) return null;
    return autoPackSize(
      purchaseUnit: pu,
      baseUnit: _selectedPresentation,
      conversionUnit: _conversion?.unit,
      conversionFactor: _conversion?.factor,
    );
  }

  double get _packSizeValue => resolvePackSize(
        purchaseUnit: _purchaseUnitController.text,
        baseUnit: _selectedPresentation,
        conversionUnit: _conversion?.unit,
        conversionFactor: _conversion?.factor,
        manual: double.tryParse(
          _packSizeController.text.trim().replaceAll(',', '.'),
        ),
      );

  double? get _conversionFactorValue => double.tryParse(
        _conversionFactorController.text.trim().replaceAll(',', '.'),
      );

  List<UnitSection> get _conversionSections => conversionUnitSections(
        baseUnit: _selectedPresentation,
        current: _conversionUnit,
      );

  /// La equivalencia válida para la base elegida, o null.
  ({String unit, double factor})? get _conversion => resolveItemConversion(
        baseUnit: _selectedPresentation,
        unit: _conversionUnit,
        factor: _conversionFactorValue,
      );

  /// Qué mandar al guardar: null = no tocarla (la ficha llegó sin saber cuál
  /// tenía y nadie la cambió); '' = borrarla; si no, la unidad.
  String? get _conversionUnitForSave {
    final conversion = _conversion;
    if (conversion != null) return conversion.unit;
    if (!_conversionKnown && !_conversionTouched) return null;
    return '';
  }

  /// Texto bajo la equivalencia: «1 ea = 200 g», o por qué no se guardará.
  String? _conversionHint() {
    final conversion = _conversion;
    if (conversion != null) {
      return conversionLabel(
        baseUnit: _selectedPresentation,
        unit: conversion.unit,
        factor: conversion.factor,
      );
    }
    if (_conversionUnit.trim().isEmpty) return null;
    if ((_conversionFactorValue ?? 0) <= 0) {
      return '¿Cuánto equivale 1 ${unitShortLabel(_selectedPresentation)}?';
    }
    return 'No aplica con esta unidad base: no se guardará';
  }

  /// Texto bajo el bloque de empaque: «700 mL / Botella» + costo por base.
  String? _packPreview() {
    final pu = _purchaseUnitController.text.trim();
    final size = _packSizeValue;
    if (pu.isEmpty || size == 1) return null;
    final baseLabel = unitShortLabel(_selectedPresentation);
    final cost = double.tryParse(_costController.text.trim().replaceAll(',', '.'));
    final perBase = (cost != null && cost > 0)
        ? '  ·  costo ${_trimNum(cost / size)} / $baseLabel'
        : '';
    final pack = packLabel(
      packSize: size,
      baseUnit: _selectedPresentation,
      purchaseUnit: pu,
    );
    return '$pack$perBase';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
      title: Text(
        widget.title,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 22,
          color: AppColors.foreground,
        ),
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      content: SizedBox(
        // Responsivo: en pantallas chicas el diálogo ocupa el ancho
        // disponible (evita que se corten campos/botones); en grandes, 460.
        width: MediaQuery.of(context).size.width < 520 ? double.maxFinite : 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(_nameController, 'Nombre'),
              const SizedBox(height: 12),
              _field(_skuController, 'SKU'),
              const SizedBox(height: 12),
              _field(_descriptionController, 'Descripcion'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _selectedPresentation,
                      dropdownColor: AppColors.card,
                      decoration: InputDecoration(
                        labelText: 'Unidad base',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.card),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.card),
                          borderSide: BorderSide(color: AppColors.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.card),
                          borderSide: BorderSide(color: AppColors.primary, width: 2),
                        ),
                      ),
                      isExpanded: true,
                      items: unitDropdownItems(_baseSections),
                      selectedItemBuilder:
                          unitDropdownSelectedBuilder(_baseSections),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _selectedPresentation = val);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field(
                      _costController,
                      'Costo',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Conversión de empaque: comprar en botella/caja, consumir en la
              // unidad base. Ej: 1 botella = 700 ml. Vacío = sin conversión.
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _purchaseUnitController.text,
                      isExpanded: true,
                      dropdownColor: AppColors.card,
                      decoration: _dropdownDecoration('Unidad de compra'),
                      items: unitDropdownItems(
                        _purchaseSections,
                        emptyLabel: 'Sin empaque',
                      ),
                      selectedItemBuilder: unitDropdownSelectedBuilder(
                        _purchaseSections,
                        emptyLabel: 'Sin empaque',
                      ),
                      onChanged: (v) => setState(
                        () => _purchaseUnitController.text = v ?? '',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _autoPackSize != null
                        ? InputDecorator(
                            decoration:
                                _dropdownDecoration('Contenido por empaque'),
                            child: Text(
                              '${formatUnitQty(_autoPackSize!)} '
                              '${unitShortLabel(_selectedPresentation)} · automático',
                              style: TextStyle(
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          )
                        : _field(
                            _packSizeController,
                            'Contenido por empaque',
                            hint: '24',
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                  ),
                ],
              ),
              if (_packPreview() != null) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _packPreview()!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              // Equivalencia propia: cuánto pesa o mide UNA unidad base. Con
              // ella una receta en gramos descuenta de un insumo que se cuenta
              // por unidad (1 ea = 200 g de aguacate).
              Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      '1 ${unitShortLabel(_selectedPresentation)} =',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.foreground,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: _field(
                      _conversionFactorController,
                      'Cantidad',
                      hint: '200',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: (_) =>
                          setState(() => _conversionTouched = true),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      // Las opciones dependen de la base: al cambiarla, la key
                      // rehace el campo con la lista nueva.
                      key: ValueKey('conversion|$_selectedPresentation'),
                      initialValue: unitSelectionValue(
                        _conversionSections,
                        _conversionUnit,
                        fallback: '',
                      ),
                      isExpanded: true,
                      dropdownColor: AppColors.card,
                      decoration: _dropdownDecoration('Equivale a (opcional)'),
                      items: unitDropdownItems(
                        _conversionSections,
                        emptyLabel: 'Sin equivalencia',
                      ),
                      selectedItemBuilder: unitDropdownSelectedBuilder(
                        _conversionSections,
                        emptyLabel: 'Sin equivalencia',
                      ),
                      onChanged: (v) => setState(() {
                        _conversionUnit = v ?? '';
                        _conversionTouched = true;
                      }),
                    ),
                  ),
                ],
              ),
              if (_conversionHint() != null) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _conversionHint()!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _conversion != null
                          ? AppColors.primary
                          : AppColors.mutedForeground,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _field(
                      _minStockController,
                      'Stock minimo',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field(
                      _maxStockController,
                      'Stock maximo',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                  ),
                ],
              ),
              if (widget.initialItem == null) ...[
                const SizedBox(height: 12),
                _field(
                  _initialStockController,
                  'Stock inicial',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
              ] else ...[
                const SizedBox(height: 12),
                SwitchListTile(
                  value: _isActive,
                  activeThumbColor: AppColors.primary,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Insumo activo'),
                  onChanged: (value) => setState(() => _isActive = value),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(
            'Cancelar',
            style: TextStyle(color: AppColors.mutedForeground),
          ),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          child: Text(
            _saving ? 'Guardando...' : 'Guardar',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  /// Mismo borde que el selector de unidad base, para los campos que no son
  /// texto (unidad de compra, contenido automático).
  InputDecoration _dropdownDecoration(String label) {
    return InputDecoration(
      labelText: label,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        borderSide: BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        borderSide: BorderSide(color: AppColors.primary, width: 2),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboardType,
    void Function(String)? onChanged,
    String? hint,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: AppColors.mutedForeground),
        filled: true,
        fillColor: AppColors.muted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          borderSide: BorderSide(color: AppColors.primary, width: 2),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    double parse(String value) => double.tryParse(value.trim()) ?? 0;
    final maxStockRaw = _maxStockController.text.trim();

    setState(() => _saving = true);
    try {
      await widget.onSubmit(
        _ItemDialogPayload(
          name: name,
          sku: _skuController.text.trim().isEmpty
              ? null
              : _skuController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          unit: _selectedPresentation,
          cost: parse(_costController.text),
          minStock: parse(_minStockController.text),
          maxStock: maxStockRaw.isEmpty ? null : parse(maxStockRaw),
          initialStock: parse(_initialStockController.text),
          isActive: _isActive,
          purchaseUnit: _purchaseUnitController.text.trim().isEmpty
              ? null
              : _purchaseUnitController.text.trim(),
          packSize: _packSizeValue,
          conversionUnit: _conversionUnitForSave,
          conversionFactor: _conversion?.factor,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }
}

/// Lo que quedó registrado, para imprimir el conduce con el diálogo cerrado.
typedef _SavedOutflow = ({
  InventoryItemSummary item,
  double quantity,
  AdjustReason reason,
  String? notes,
  String? destination,
});

/// Cantidad sin ceros de relleno: 12 → «12», 1.5 → «1.5».
String _fmtOutflowQty(double v) {
  final s = v.toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

class _InventoryOutflowDialog extends StatefulWidget {
  final List<InventoryItemSummary> items;
  final String? initialItemId;

  /// [quantity] ya en unidad BASE. [operationId] es la llave de esta salida:
  /// la misma en cada reintento del diálogo. [destination] es el área de un
  /// consumo interno; `null` en cualquier otro motivo.
  final Future<void> Function(
    InventoryItemSummary item,
    double quantity,
    AdjustReason reason,
    String? notes,
    String operationId,
    String? destination,
  )
  onSubmit;

  const _InventoryOutflowDialog({
    required this.items,
    required this.initialItemId,
    required this.onSubmit,
  });

  @override
  State<_InventoryOutflowDialog> createState() =>
      _InventoryOutflowDialogState();
}

class _InventoryOutflowDialogState extends State<_InventoryOutflowDialog> {
  String? _selectedItemId;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _quantityController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();
  bool _saving = false;
  AdjustReason? _reason;
  String? _error;

  /// La persona tocó un motivo. Hasta entonces el motivo lo propone la clase
  /// del insumo (un gastable sale por consumo interno, el menaje por rotura)
  /// y cambia si cambia el insumo; después ya no se toca.
  bool _reasonPicked = false;

  /// La cantidad se digita en la unidad de COMPRA (botella, caja) en vez de
  /// la base (ml, unidad). Solo se ofrece si el insumo tiene empaque.
  bool _inPack = false;

  /// Llave de ESTA salida. Si el guardado queda pero se pierde la respuesta
  /// y la persona reintenta, el servidor reconoce la llave y no resta dos
  /// veces.
  final String _operationId = const Uuid().v4();

  /// Solo los motivos que son SALIDA (rotura, vencido, limpieza, faltante,
  /// donación). Un conteo o una corrección se hacen desde el ajuste de
  /// Insumos, que fija el stock; esta pantalla resta.
  static final List<AdjustReason> _exitReasons = kAdjustReasons
      .where((r) => r.isExit)
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    _selectedItemId = widget.initialItemId;
    final initial = _selectedItem;
    if (initial != null) _reason = _suggestedReason(initial);
    _quantityController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchController.dispose();
    _quantityController.dispose();
    _notesController.dispose();
    _destinationController.dispose();
    super.dispose();
  }

  static AdjustReason? _suggestedReason(InventoryItemSummary item) =>
      switch (item.itemClassification) {
        ItemClassification.supply => adjustReasonByCode(kInternalUseReason),
        ItemClassification.smallware => adjustReasonByCode('breakage'),
        _ => null,
      };

  bool get _isInternalUse => _reason?.code == kInternalUseReason;

  InventoryItemSummary? get _selectedItem {
    final id = _selectedItemId;
    if (id == null) return null;
    for (final i in widget.items) {
      if (i.id == id) return i;
    }
    return null;
  }

  bool _hasPack(InventoryItemSummary item) =>
      hasPack(item.packSize, item.purchaseUnit, baseUnit: item.unit);

  List<InventoryItemSummary> get _filteredItems {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return widget.items;
    return widget.items
        .where(
          (i) =>
              i.name.toLowerCase().contains(q) ||
              i.sku.toLowerCase().contains(q) ||
              i.description.toLowerCase().contains(q) ||
              i.barcode.toLowerCase().contains(q),
        )
        .toList(growable: false);
  }

  void _select(InventoryItemSummary item) {
    if (item.id != _selectedItemId) {
      _selectedItemId = item.id;
      _inPack = false;
      if (!_reasonPicked) _reason = _suggestedReason(item);
    }
    _error = null;
  }

  /// La selección sigue a la búsqueda: un solo resultado queda elegido, y un
  /// insumo que la búsqueda escondió deja de estarlo (nadie descuenta lo que
  /// no está viendo).
  void _onSearchChanged() {
    final filtered = _filteredItems;
    setState(() {
      if (filtered.length == 1) {
        _select(filtered.first);
      } else if (_selectedItemId != null &&
          !filtered.any((i) => i.id == _selectedItemId)) {
        _selectedItemId = null;
        _inPack = false;
      }
    });
  }

  double? get _typedQuantity {
    final raw = _quantityController.text.trim().replaceAll(',', '.');
    return double.tryParse(raw);
  }

  /// Cantidad en unidad BASE (lo que se resta del stock).
  double? _baseQuantity(InventoryItemSummary item) {
    final typed = _typedQuantity;
    if (typed == null) return null;
    return _inPack ? packToBase(typed, item.packSize) : typed;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredItems;
    final item = _selectedItem;
    return InventoryScanListener(
      enabled: true,
      items: widget.items,
      // En una salida, escanear elige el insumo y lo deja visible: la
      // cantidad y el motivo los pone la persona, que es el punto de
      // registrar una merma.
      onItem: (scanned) {
        _searchController.text = scanned.name;
        setState(() => _select(scanned));
      },
      child: AlertDialog(
      title: const Text('Registrar salida de inventario'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _searchController,
              onChanged: (_) => _onSearchChanged(),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                hintText: 'Buscar insumo...',
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged();
                        },
                      ),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              height: 200,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        'No se encontraron insumos.',
                        style: TextStyle(color: AppColors.mutedForeground),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final row = filtered[index];
                        final selected = row.id == _selectedItemId;
                        return ListTile(
                          dense: true,
                          selected: selected,
                          selectedTileColor:
                              AppColors.primary.withValues(alpha: 0.08),
                          title: Text(
                            row.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            [
                              if (row.sku.isNotEmpty) row.sku,
                              'Stock: ${_fmtOutflowQty(row.stock)} ${row.unit}',
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: selected
                              ? Icon(
                                  Icons.check_circle,
                                  color: AppColors.primary,
                                  size: 20,
                                )
                              : null,
                          onTap: _saving
                              ? null
                              : () => setState(() => _select(row)),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 10),
            _selectedBanner(item),
            const SizedBox(height: 12),
            if (item != null && _hasPack(item)) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(value: false, label: Text(item.unit)),
                    ButtonSegment(
                      value: true,
                      label: Text(item.purchaseUnit.trim()),
                    ),
                  ],
                  selected: {_inPack},
                  showSelectedIcon: false,
                  onSelectionChanged: _saving
                      ? null
                      : (v) => setState(() => _inPack = v.first),
                ),
              ),
              const SizedBox(height: 10),
            ],
            TextField(
              key: const Key('outflow-quantity'),
              controller: _quantityController,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Cantidad',
                suffixText: item == null
                    ? null
                    : (_inPack ? item.purchaseUnit.trim() : item.unit),
                helperText: _packHelper(item),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Motivo',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final reason in _exitReasons)
                    ChoiceChip(
                      avatar: Icon(
                        reason.icon,
                        size: 16,
                        color: _reason?.code == reason.code
                            ? Colors.white
                            : AppColors.mutedForeground,
                      ),
                      label: Text(reason.label),
                      tooltip: reason.description,
                      showCheckmark: false,
                      selected: _reason?.code == reason.code,
                      selectedColor: AppColors.primary,
                      labelStyle: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: _reason?.code == reason.code
                            ? Colors.white
                            : AppColors.foreground,
                      ),
                      onSelected: _saving
                          ? null
                          : (_) => setState(() {
                                _reason = reason;
                                _reasonPicked = true;
                                _error = null;
                              }),
                    ),
                ],
              ),
            ),
            if (_isInternalUse) ...[
              const SizedBox(height: 12),
              _destinationField(),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _notesController,
              enabled: !_saving,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Notas (opcional)',
                hintText: 'Qué pasó, quién lo vio',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: Color(0xFFEF4444),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('outflow-submit'),
          onPressed: _saving ? null : _submit,
          child: Text(_saving ? 'Guardando...' : 'Registrar'),
        ),
      ],
      ),
    );
  }

  /// A qué área va un consumo interno. Opcional —no se tranca una salida
  /// por esto—, pero es lo que permite ver cuánto gasta cada área.
  Widget _destinationField() {
    final current = _destinationController.text.trim().toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const Key('outflow-destination'),
          controller: _destinationController,
          enabled: !_saving,
          textCapitalization: TextCapitalization.sentences,
          maxLength: 60,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: '¿Para qué área?',
            hintText: 'Baños, cocina, salón…',
            counterText: '',
            prefixIcon: const Icon(Icons.place_outlined, size: 20),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final area in kSuggestedDestinations)
              ChoiceChip(
                label: Text(area),
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                selected: current == area.toLowerCase(),
                onSelected: _saving
                    ? null
                    : (_) => setState(() {
                          _destinationController.text = area;
                        }),
              ),
          ],
        ),
      ],
    );
  }

  /// Qué insumo se va a descontar, siempre a la vista.
  Widget _selectedBanner(InventoryItemSummary? item) {
    final none = item == null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: none
            ? AppColors.muted
            : AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: none
              ? AppColors.border
              : AppColors.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Text(
        none
            ? 'Toca en la lista el insumo que salió.'
            : 'Insumo: ${item.name} · existencia '
                  '${_fmtOutflowQty(item.stock)} ${item.unit}',
        key: const Key('outflow-selected'),
        style: TextStyle(
          fontSize: 13,
          fontWeight: none ? FontWeight.w500 : FontWeight.w700,
          color: none ? AppColors.mutedForeground : AppColors.foreground,
        ),
      ),
    );
  }

  String? _packHelper(InventoryItemSummary? item) {
    if (item == null || !_inPack) return null;
    final base = _baseQuantity(item);
    if (base == null) {
      return '1 ${item.purchaseUnit.trim()} = '
          '${_fmtOutflowQty(item.packSize)} ${item.unit}';
    }
    return '= ${_fmtOutflowQty(base)} ${item.unit}';
  }

  Future<bool> _confirmOverStock(
    InventoryItemSummary item,
    double quantity,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('La salida es mayor que la existencia'),
        content: Text(
          'Vas a sacar ${_fmtOutflowQty(quantity)} ${item.unit} de '
          '${item.name}, pero hay ${_fmtOutflowQty(item.stock)} ${item.unit}. '
          'Quedará en ${_fmtOutflowQty(item.stock - quantity)} ${item.unit}.\n\n'
          'Revisa la cantidad. ¿Registrar igual?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Revisar'),
          ),
          FilledButton(
            key: const Key('outflow-overstock-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Registrar igual'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _submit() async {
    // Un segundo toque antes del rebuild no manda otra salida.
    if (_saving) return;
    final item = _selectedItem;
    if (item == null) {
      setState(() => _error = 'Elige en la lista el insumo que salió');
      return;
    }
    final quantity = _baseQuantity(item) ?? 0;
    if (quantity <= 0) {
      setState(() => _error = 'Ingresa la cantidad que salió');
      return;
    }
    final reason = _reason;
    if (reason == null) {
      setState(() => _error = 'Selecciona el motivo de la salida');
      return;
    }
    if (quantity > item.stock + 0.000001) {
      final go = await _confirmOverStock(item, quantity);
      if (!go || !mounted) return;
    }

    final notes = _notesController.text.trim().isEmpty
        ? null
        : _notesController.text.trim();
    final area = _destinationController.text.trim();
    final destination =
        reason.code == kInternalUseReason && area.isNotEmpty ? area : null;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSubmit(
        item,
        quantity,
        reason,
        notes,
        _operationId,
        destination,
      );
      if (!mounted) return;
      Navigator.of(context).pop<_SavedOutflow>((
        item: item,
        quantity: quantity,
        reason: reason,
        notes: notes,
        destination: destination,
      ));
    } catch (e) {
      if (mounted) {
        final raw = '$e';
        setState(
          () => _error = raw.contains('INVENTORY_ACCESS_DENIED')
              ? 'Tu rol no puede registrar salidas: solo dueño, '
                    'administrador o gerente.'
              : 'No se pudo registrar la salida. Puedes reintentar: no se '
                    'descontará dos veces.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }
}
