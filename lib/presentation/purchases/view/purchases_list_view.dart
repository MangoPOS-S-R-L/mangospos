import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router/routes.dart';
import '../../../services/session/session_controller.dart';
import '../state/goods_receipt.dart';
import '../state/purchases_state.dart';
import '../utils/purchase_status.dart';
import '../viewmodel/purchases_viewmodel.dart';
import '../widgets/create_supplier_dialog.dart';
import 'goods_receipt_dialog.dart';
import '../../../core/theme/app_colors.dart';
import 'package:mangopos/core/utils/app_snackbar.dart';

class PurchasesListView extends ConsumerStatefulWidget {
  const PurchasesListView({super.key});

  @override
  ConsumerState<PurchasesListView> createState() => _PurchasesListViewState();
}

class _PurchasesListViewState extends ConsumerState<PurchasesListView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(purchasesViewModelProvider).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(purchasesViewModelProvider);
    final state = vm.state;
    // `compras.acceso` gatea la ruta, pero hasta acá no había nada que
    // separara consultar de comprar: cualquiera que abriera el módulo podía
    // crear órdenes, recibir mercancía y dar de alta proveedores.
    final sessionCtrl = ref.watch(sessionProvider.notifier);
    final canCreateOrder = sessionCtrl.hasPermission('compras.ordenes.crear');
    final canReceive = sessionCtrl.hasPermission('compras.ordenes.recibir');
    // `compras.ordenes.anular` no se aplica acá: la pantalla filtra por
    // estado "Cancelada" pero no expone ninguna acción para anular una orden.
    final canEditSuppliers =
        sessionCtrl.hasPermission('compras.proveedores.crear_editar');
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    final dateFormat = DateFormat('dd/MM/yyyy');
    final pendingPayables =
        state.orders.where((o) => o.payablePending).length;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: state.loading && state.orders.isEmpty && state.suppliers.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Compras se abre desde Más Opciones con `context.go`,
                      // que REEMPLAZA el stack: sin este botón (y su fallback
                      // a Ajustes) la pantalla no tiene salida hacia atrás.
                      IconButton(
                        onPressed: () {
                          if (context.canPop()) {
                            context.pop();
                          } else {
                            context.go(AppRoutes.settings);
                          }
                        },
                        icon: const Icon(Icons.arrow_back),
                        tooltip: 'Volver a Ajustes',
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Compras',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              'Proveedores y órdenes de compra del negocio',
                              style: TextStyle(
                                fontSize: 14,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        alignment: WrapAlignment.end,
                        children: [
                          if (canEditSuppliers)
                            OutlinedButton.icon(
                              onPressed: state.saving
                                  ? null
                                  : () => _showCreateSupplierDialog(context),
                              icon: const Icon(Icons.group_add_outlined),
                              label: const Text('Nuevo proveedor'),
                            ),
                          if (canCreateOrder)
                            FilledButton.icon(
                              onPressed: () =>
                                  context.go(AppRoutes.purchasesRegister),
                              icon: const Icon(Icons.add_shopping_cart),
                              label: const Text('Nueva orden'),
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
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _SummaryCard(
                        title: 'Proveedores activos',
                        value: '${state.suppliers.where((s) => s.isActive).length}',
                        color: const Color(0xFF2563EB),
                      ),
                      _SummaryCard(
                        title: 'Órdenes borrador',
                        value:
                            '${state.totalsByStatus['draft'] == null ? 0 : state.orders.where((o) => o.status == 'draft').length}',
                        color: const Color(0xFFF59E0B),
                      ),
                      _SummaryCard(
                        title: 'Total recibido',
                        value: currency.format(state.totalsByStatus['received'] ?? 0),
                        color: const Color(0xFF059669),
                      ),
                      // Cola de atrasadas: compras a crédito cuya deuda no
                      // llegó a registrarse. Solo aparece si hay alguna, para
                      // que su presencia signifique algo.
                      if (pendingPayables > 0)
                        _SummaryCard(
                          title: 'CxP pendientes de registrar',
                          value: '$pendingPayables',
                          color: const Color(0xFFDC2626),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: state.selectedStatus ?? 'all',
                          decoration: InputDecoration(
                            labelText: 'Estado',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          items: const [
                            DropdownMenuItem(value: 'all', child: Text('Todos')),
                            DropdownMenuItem(value: 'draft', child: Text('Borrador')),
                            DropdownMenuItem(value: 'sent', child: Text('Enviada')),
                            DropdownMenuItem(value: 'partial', child: Text('Parcial')),
                            DropdownMenuItem(value: 'received', child: Text('Recibida')),
                            DropdownMenuItem(
                              value: 'cancelled',
                              child: Text('Cancelada'),
                            ),
                          ],
                          onChanged: state.saving
                              ? null
                              : (value) => ref
                                    .read(purchasesViewModelProvider)
                                    .selectStatus(value),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filledTonal(
                        onPressed: state.saving
                            ? null
                            : () => ref.read(purchasesViewModelProvider).refresh(),
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Órdenes recientes',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (state.orders.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'Aún no hay órdenes de compra registradas.',
                              style: TextStyle(color: Color(0xFF64748B)),
                            ),
                          )
                        else ...[
                          ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: state.orders.length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final order = state.orders[index];
                              // Fila propia en vez de ListTile: la orden tiene
                              // que ser tocable (abre su factura) y además
                              // llevar el botón de recibir; el `trailing` de
                              // un ListTile no da alto para las dos cosas.
                              return Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  // La factura completa —productos, costos,
                                  // ITBIS y descuentos— vive en su propia
                                  // pantalla: el listado solo trae el total.
                                  onTap: () => context.go(
                                    AppRoutes.purchasesOrderDetailPath(order.id),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      20,
                                      12,
                                      16,
                                      12,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Row(
                                                children: [
                                                  Flexible(
                                                    child: Text(
                                                      '${order.orderNumber} · ${order.supplierName}',
                                                      overflow: TextOverflow
                                                          .ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 15,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                  ),
                                                  // §6.4 — La compra se guardó
                                                  // a crédito pero la deuda no
                                                  // nació. Un estado partido
                                                  // solo se descubre cuando el
                                                  // proveedor viene a cobrar:
                                                  // aquí se ve.
                                                  if (order.payablePending) ...[
                                                    const SizedBox(width: 8),
                                                    const _PendingPayableChip(),
                                                  ],
                                                ],
                                              ),
                                              const SizedBox(height: 3),
                                              Text(
                                                '${order.warehouseName} · ${purchaseStatusLabel(order.status)}'
                                                '${order.expectedDate == null ? '' : ' · Esperada ${dateFormat.format(order.expectedDate!)}'}',
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                  color: Color(0xFF475569),
                                                ),
                                              ),
                                              // Factura y NCF en su propio
                                              // renglón: son identificadores
                                              // distintos y ambos hacen falta
                                              // para conciliar contra el papel.
                                              Text(
                                                [
                                                  if (order
                                                      .invoiceNumber
                                                      .isNotEmpty)
                                                    'Factura ${order.invoiceNumber}',
                                                  if (order.ncf.isNotEmpty)
                                                    'NCF ${order.ncf}',
                                                  if (order
                                                          .invoiceNumber
                                                          .isEmpty &&
                                                      order.ncf.isEmpty)
                                                    'Sin factura registrada',
                                                ].join(' · '),
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Color(0xFF94A3B8),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            Text(
                                              currency.format(order.total),
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              dateFormat.format(
                                                order.createdAt,
                                              ),
                                              style: const TextStyle(
                                                fontSize: 12,
                                                color: Color(0xFF64748B),
                                              ),
                                            ),
                                            if (canReceive &&
                                                _canReceiveOrder(
                                                  order.status,
                                                )) ...[
                                              const SizedBox(height: 8),
                                              OutlinedButton(
                                                onPressed: state.saving
                                                    ? null
                                                    : () => _openReceiveDialog(
                                                        order,
                                                      ),
                                                child: Text(
                                                  order.status == 'partial'
                                                      ? 'Recibir resto'
                                                      : 'Recibir',
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        // El papel de la compra, sin tener
                                        // que abrir la factura: es lo que
                                        // pide quien archiva o quien va a
                                        // recibir la mercancía.
                                        IconButton(
                                          tooltip: 'Imprimir orden de compra',
                                          icon: const Icon(
                                            Icons.print_outlined,
                                            size: 20,
                                          ),
                                          onPressed: () =>
                                              _openOrderDocument(order),
                                        ),
                                        // Afordancia de "esto se abre": la
                                        // fila lleva a la factura completa.
                                        const Icon(
                                          Icons.chevron_right,
                                          size: 20,
                                          color: Color(0xFF94A3B8),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                          if (state.ordersHasMore || state.ordersLoadingMore)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 12,
                                horizontal: 20,
                              ),
                              child: Center(
                                child: state.ordersLoadingMore
                                    ? const SizedBox(
                                        height: 28,
                                        width: 28,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.4,
                                        ),
                                      )
                                    : OutlinedButton.icon(
                                        onPressed: () => ref
                                            .read(purchasesViewModelProvider)
                                            .loadMoreOrders(),
                                        icon: const Icon(
                                          Icons.expand_more_rounded,
                                          size: 18,
                                        ),
                                        label: const Text('Cargar más'),
                                      ),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Proveedores',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (state.suppliers.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'No hay proveedores registrados.',
                              style: TextStyle(color: Color(0xFF64748B)),
                            ),
                          )
                        else
                          ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: state.suppliers.length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final supplier = state.suppliers[index];
                              final contact = supplier.contactName.trim().isEmpty
                                  ? 'Sin contacto'
                                  : supplier.contactName.trim();
                              final phone = supplier.phone.trim().isEmpty
                                  ? 'Sin teléfono'
                                  : supplier.phone.trim();
                              return ListTile(
                                title: Text(supplier.name),
                                subtitle: Text('$contact · $phone'),
                                trailing: Text(
                                  supplier.isActive ? 'Activo' : 'Inactivo',
                                  style: TextStyle(
                                    color: supplier.isActive
                                        ? const Color(0xFF059669)
                                        : const Color(0xFF94A3B8),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Future<void> _showCreateSupplierDialog(BuildContext context) async {
    await showCreateSupplierDialog(context, ref);
  }

  bool _canReceiveOrder(String status) {
    return status != 'received' && status != 'cancelled';
  }

  Future<void> _openReceiveDialog(PurchaseOrderSummary order) async {
    // Recibir → emitir conduce → imprimirlo. El flujo completo vive en
    // showPurchaseReceiveFlow para que el listado y el detalle hagan lo mismo.
    await showPurchaseReceiveFlow(context, ref, order);
  }

  /// Orden de compra impresa desde el listado. El listado solo tiene el
  /// resumen (no las líneas), así que la factura se relee antes de armar el
  /// papel: un documento a medias no sirve para recibir contra él.
  Future<void> _openOrderDocument(PurchaseOrderSummary order) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final detail = await ref
          .read(purchasesViewModelProvider)
          .loadOrderDetail(order.id);
      if (!mounted) return;
      await showGoodsReceiptDialog(
        context,
        ref,
        receipt: GoodsReceipt.fromOrderDetail(
          detail,
          issuedByName: detail.createdByName,
        ),
        isReprint: true,
      );
    } catch (e) {
      messenger.showAppSnackBar(
        SnackBar(content: Text('No se pudo abrir la orden de compra: $e')),
      );
    }
  }
}

/// Marca de la orden cuya cuenta por pagar no llegó a nacer (§6.4 del PRD).
class _PendingPayableChip extends StatelessWidget {
  const _PendingPayableChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: const Text(
        'CxP pendiente de registrar',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Color(0xFF991B1B),
        ),
      ),
    );
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFF64748B),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 20,
            ),
          ),
        ],
      ),
    );
  }
}
