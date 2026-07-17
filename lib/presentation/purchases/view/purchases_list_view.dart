import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router/routes.dart';
import '../state/purchases_state.dart';
import '../viewmodel/purchases_viewmodel.dart';
import '../widgets/create_supplier_dialog.dart';
import 'purchase_receive_dialog.dart';

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
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    final dateFormat = DateFormat('dd/MM/yyyy');

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: state.loading && state.orders.isEmpty && state.suppliers.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Column(
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
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          OutlinedButton.icon(
                            onPressed: state.saving
                                ? null
                                : () => _showCreateSupplierDialog(context),
                            icon: const Icon(Icons.group_add_outlined),
                            label: const Text('Nuevo proveedor'),
                          ),
                          FilledButton.icon(
                            onPressed: () => context.go(AppRoutes.purchasesRegister),
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
                              return ListTile(
                                isThreeLine: _canReceiveOrder(order.status),
                                title: Text(
                                  '${order.orderNumber} · ${order.supplierName}',
                                ),
                                subtitle: Text(
                                  '${order.warehouseName} · ${_statusLabel(order.status)}'
                                  '${order.expectedDate == null ? '' : ' · Esperada ${dateFormat.format(order.expectedDate!)}'}',
                                ),
                                trailing: SizedBox(
                                  width: 160,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        currency.format(order.total),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        dateFormat.format(order.createdAt),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF64748B),
                                        ),
                                      ),
                                      if (_canReceiveOrder(order.status)) ...[
                                        const SizedBox(height: 8),
                                        OutlinedButton(
                                          onPressed: state.saving
                                              ? null
                                              : () => _openReceiveDialog(order),
                                          child: Text(
                                            order.status == 'partial'
                                                ? 'Recibir resto'
                                                : 'Recibir',
                                          ),
                                        ),
                                      ],
                                    ],
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

  String _statusLabel(String status) {
    switch (status) {
      case 'draft':
        return 'Borrador';
      case 'sent':
        return 'Enviada';
      case 'partial':
        return 'Parcial';
      case 'received':
        return 'Recibida';
      case 'cancelled':
        return 'Cancelada';
      default:
        return status;
    }
  }

  bool _canReceiveOrder(String status) {
    return status != 'received' && status != 'cancelled';
  }

  Future<void> _openReceiveDialog(PurchaseOrderSummary order) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PurchaseReceiveDialog(order: order),
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
