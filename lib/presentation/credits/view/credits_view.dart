import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/presentation/credits/viewmodel/credits_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';

/// Sección Créditos: cuentas por cobrar (ventas a crédito) y cuentas por
/// pagar (compras a crédito a proveedores), con abonos e historial.
class CreditsView extends ConsumerStatefulWidget {
  const CreditsView({super.key});

  @override
  ConsumerState<CreditsView> createState() => _CreditsViewState();
}

enum _CreditFilter { open, overdue, all }

class _CreditsViewState extends ConsumerState<CreditsView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  String _search = '';
  _CreditFilter _filter = _CreditFilter.open;
  String? _lastBusinessId;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(creditsViewModelProvider).init();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final vm = ref.watch(creditsViewModelProvider);
    final currency = currentBusinessCurrencyOrFallback(ref);

    if (session.activeBusinessId != null &&
        session.activeBusinessId != _lastBusinessId) {
      _lastBusinessId = session.activeBusinessId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _searchController.clear();
          _search = '';
          ref.read(creditsViewModelProvider).init();
        }
      });
    }

    final isPayablesTab = _tabController.index == 1;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Créditos',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: AppColors.foreground,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Actualizar',
                  onPressed: vm.isLoading ? null : () => vm.reload(),
                  icon: const Icon(Icons.refresh, color: AppColors.mutedForeground),
                ),
                if (isPayablesTab) ...[
                  const SizedBox(width: AppSpacing.md),
                  ElevatedButton.icon(
                    onPressed: () => _openManualPayableDialog(),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Registrar cuenta por pagar'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.lg),

            // Totales
            Row(
              children: [
                _SummaryCard(
                  label: 'Por cobrar',
                  amount: currency.formatAmount(vm.totalReceivableOpen),
                  overdue: vm.totalReceivableOverdue > 0
                      ? 'Vencido: ${currency.formatAmount(vm.totalReceivableOverdue)}'
                      : null,
                  color: AppColors.primary,
                  icon: Icons.call_received,
                ),
                const SizedBox(width: AppSpacing.lg),
                _SummaryCard(
                  label: 'Por pagar',
                  amount: currency.formatAmount(vm.totalPayableOpen),
                  overdue: vm.totalPayableOverdue > 0
                      ? 'Vencido: ${currency.formatAmount(vm.totalPayableOverdue)}'
                      : null,
                  color: Colors.deepOrange,
                  icon: Icons.call_made,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),

            TabBar(
              controller: _tabController,
              isScrollable: true,
              labelColor: AppColors.primary,
              unselectedLabelColor: AppColors.mutedForeground,
              indicatorColor: AppColors.primary,
              tabs: const [
                Tab(text: 'Cuentas por Cobrar'),
                Tab(text: 'Cuentas por Pagar'),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),

            // Toolbar: búsqueda + filtro
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: (v) => setState(() => _search = v.trim()),
                    decoration: InputDecoration(
                      hintText: isPayablesTab
                          ? 'Buscar por proveedor o número de factura'
                          : 'Buscar por cliente',
                      prefixIcon: const Icon(Icons.search,
                          color: AppColors.mutedForeground),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.button),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.button),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 0,
                        horizontal: AppSpacing.lg,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                SegmentedButton<_CreditFilter>(
                  segments: const [
                    ButtonSegment(
                        value: _CreditFilter.open, label: Text('Abiertas')),
                    ButtonSegment(
                        value: _CreditFilter.overdue, label: Text('Vencidas')),
                    ButtonSegment(
                        value: _CreditFilter.all, label: Text('Todas')),
                  ],
                  selected: {_filter},
                  onSelectionChanged: (s) => setState(() => _filter = s.first),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),

            Expanded(
              child: vm.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _buildList(vm.receivables, isPayable: false),
                        _buildList(vm.payables, isPayable: true),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _applyFilters(
    List<Map<String, dynamic>> credits, {
    required bool isPayable,
  }) {
    return credits.where((c) {
      final status = c['status'] as String? ?? 'pending';
      switch (_filter) {
        case _CreditFilter.open:
          if (status == 'paid' || status == 'cancelled') return false;
          break;
        case _CreditFilter.overdue:
          if (!CreditsViewModel.isOverdue(c)) return false;
          break;
        case _CreditFilter.all:
          break;
      }
      if (_search.isEmpty) return true;
      final q = _search.toLowerCase();
      final party = _partyName(c, isPayable: isPayable);
      final invoice = c['invoice_number'] as String?;
      return (party ?? '').toLowerCase().contains(q) ||
          (invoice ?? '').toLowerCase().contains(q);
    }).toList(growable: false);
  }

  Widget _buildList(
    List<Map<String, dynamic>> credits, {
    required bool isPayable,
  }) {
    final filtered = _applyFilters(credits, isPayable: isPayable);
    if (filtered.isEmpty) {
      return Center(
        child: Text(
          isPayable
              ? 'No hay cuentas por pagar en este filtro.'
              : 'No hay cuentas por cobrar en este filtro.\nLas ventas cobradas con el método "Crédito" aparecen aquí.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.mutedForeground),
        ),
      );
    }
    return ListView.separated(
      itemCount: filtered.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
      itemBuilder: (context, index) =>
          _CreditCard(
            credit: filtered[index],
            isPayable: isPayable,
            onAbono: () => _openAbonoDialog(
              filtered[index],
              isPayable: isPayable,
            ),
            onHistory: () => _openHistoryDialog(
              filtered[index],
              isPayable: isPayable,
            ),
            onCancel: () => _confirmCancel(
              filtered[index],
              isPayable: isPayable,
            ),
          ),
    );
  }

  Future<void> _openAbonoDialog(
    Map<String, dynamic> credit, {
    required bool isPayable,
  }) async {
    final result = await showDialog<_AbonoResult>(
      context: context,
      builder: (_) => _AbonoDialog(credit: credit, isPayable: isPayable),
    );
    if (result == null || !mounted) return;
    final vm = ref.read(creditsViewModelProvider);
    try {
      if (isPayable) {
        await vm.registerPayablePayment(
          creditId: credit['id'] as String,
          amount: result.amount,
          paymentMethodCode: result.methodCode,
          reference: result.reference,
          affectCashSession: result.affectCash,
        );
      } else {
        await vm.registerReceivableAbono(
          creditId: credit['id'] as String,
          amount: result.amount,
          paymentMethodCode: result.methodCode,
          reference: result.reference,
        );
      }
      if (mounted) AppToast.success(context, 'Abono registrado.');
    } catch (e) {
      if (mounted) AppToast.error(context, _friendlyError(e));
    }
  }

  Future<void> _openHistoryDialog(
    Map<String, dynamic> credit, {
    required bool isPayable,
  }) async {
    final vm = ref.read(creditsViewModelProvider);
    await showDialog<void>(
      context: context,
      builder: (_) => _HistoryDialog(
        credit: credit,
        isPayable: isPayable,
        loader: isPayable
            ? vm.getPayablePayments(credit['id'] as String)
            : vm.getReceivablePayments(credit['id'] as String),
      ),
    );
  }

  Future<void> _confirmCancel(
    Map<String, dynamic> credit, {
    required bool isPayable,
  }) async {
    final reasonCtrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Cancelar crédito'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'El saldo pendiente se condona: dejará de contarse como '
                'deuda y libera el cupo. Esta acción NO revierte la venta '
                'ni la compra, ni los abonos ya recibidos.',
              ),
              const SizedBox(height: AppSpacing.lg),
              TextField(
                controller: reasonCtrl,
                autofocus: true,
                maxLines: 2,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Razón (obligatoria)',
                  hintText: 'Ej.: cliente no va a pagar, acuerdo comercial…',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Volver'),
            ),
            FilledButton(
              onPressed: reasonCtrl.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(ctx, reasonCtrl.text.trim()),
              child: const Text('Cancelar crédito'),
            ),
          ],
        ),
      ),
    );
    reasonCtrl.dispose();
    if (reason == null || reason.isEmpty || !mounted) return;
    final vm = ref.read(creditsViewModelProvider);
    try {
      if (isPayable) {
        await vm.cancelPayable(credit['id'] as String, reason: reason);
      } else {
        await vm.cancelReceivable(credit['id'] as String, reason: reason);
      }
      if (mounted) AppToast.success(context, 'Crédito cancelado.');
    } catch (e) {
      if (mounted) AppToast.error(context, _friendlyError(e));
    }
  }

  Future<void> _openManualPayableDialog() async {
    final vm = ref.read(creditsViewModelProvider);
    List<Map<String, dynamic>> suppliers;
    try {
      suppliers = await vm.getSuppliers();
    } catch (e) {
      if (mounted) AppToast.error(context, _friendlyError(e));
      return;
    }
    if (!mounted) return;
    if (suppliers.isEmpty) {
      AppToast.info(
        context,
        'Primero registra un proveedor en Inventario → Proveedores.',
      );
      return;
    }
    final result = await showDialog<_ManualPayableResult>(
      context: context,
      builder: (_) => _ManualPayableDialog(suppliers: suppliers),
    );
    if (result == null || !mounted) return;
    try {
      await vm.createManualPayable(
        supplierId: result.supplierId,
        amount: result.amount,
        invoiceNumber: result.invoiceNumber,
        dueDate: result.dueDate,
        notes: result.notes,
      );
      if (mounted) AppToast.success(context, 'Cuenta por pagar registrada.');
    } catch (e) {
      if (mounted) AppToast.error(context, _friendlyError(e));
    }
  }
}

/// Nombre del cliente/proveedor embebido en la fila del crédito.
String? _partyName(Map<String, dynamic> credit, {required bool isPayable}) {
  final party = credit[isPayable ? 'suppliers' : 'customers'];
  if (party is Map) return party['name'] as String?;
  return null;
}

String _friendlyError(Object e) {
  final msg = e.toString();
  if (msg.contains('CASH_SESSION_REQUIRED') ||
      msg.contains('caja abierta')) {
    return 'Necesitas una caja abierta para movimientos en efectivo.';
  }
  if (msg.contains('CASH_SESSION_NOT_OPEN')) {
    return 'La caja seleccionada ya no está abierta.';
  }
  if (msg.contains('ABONO_EXCEEDS_BALANCE')) {
    return 'El abono supera el saldo pendiente.';
  }
  if (msg.contains('CREDIT_ALREADY_CLOSED')) {
    return 'Este crédito ya está saldado o cancelado.';
  }
  return 'Error: $msg';
}

// ─────────────────────────────────────────────────────────────────────────────
// Widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SummaryCard extends StatelessWidget {
  final String label;
  final String amount;
  final String? overdue;
  final Color color;
  final IconData icon;

  const _SummaryCard({
    required this.label,
    required this.amount,
    required this.overdue,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: color.withValues(alpha: 0.12),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                  Text(
                    amount,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.foreground,
                    ),
                  ),
                  if (overdue != null)
                    Text(
                      overdue!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.redAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreditCard extends ConsumerWidget {
  final Map<String, dynamic> credit;
  final bool isPayable;
  final VoidCallback onAbono;
  final VoidCallback onHistory;
  final VoidCallback onCancel;

  const _CreditCard({
    required this.credit,
    required this.isPayable,
    required this.onAbono,
    required this.onHistory,
    required this.onCancel,
  });

  /// Cancelar (condonar) solo para quien el RLS deja escribir:
  /// CxC = owner/admin (`cc_admin_update`); CxP = también supervisor
  /// (write owner/admin/manager). Ocultarlo evita mostrar una opción que
  /// el guardado igual rechazaría.
  bool _canCancel(WidgetRef ref) {
    // read (no watch): se evalúa al abrir el menú, fuera del build.
    final session = ref.read(sessionProvider);
    if (session.isOwner) return true;
    final role = session.activeRole;
    if (role == PosRole.administrador) return true;
    return isPayable && role == PosRole.supervisor;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currency = currentBusinessCurrencyOrFallback(ref);
    final status = credit['status'] as String? ?? 'pending';
    final overdue = CreditsViewModel.isOverdue(credit);
    final isOpen = status != 'paid' && status != 'cancelled';
    final party = _partyName(credit, isPayable: isPayable);
    final balance = ((credit['balance'] as num?) ?? 0).toDouble();
    final original = ((credit['original_amount'] as num?) ?? 0).toDouble();
    final invoice = credit['invoice_number'] as String?;
    final createdAt = DateTime.tryParse(credit['created_at'] as String? ?? '');
    final dueDate = DateTime.tryParse(credit['due_date'] as String? ?? '');
    final dateFmt = DateFormat('dd/MM/yyyy');

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
          color: overdue ? Colors.redAccent.withValues(alpha: 0.5) : AppColors.border,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  party ?? (isPayable ? 'Proveedor' : 'Cliente'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.foreground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (invoice != null && invoice.isNotEmpty)
                      'Factura $invoice',
                    if (createdAt != null) dateFmt.format(createdAt.toLocal()),
                  ].join(' · '),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Vencimiento',
                  style: TextStyle(
                      fontSize: 11, color: AppColors.mutedForeground),
                ),
                Text(
                  dueDate != null ? dateFmt.format(dueDate) : '—',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color:
                        overdue ? Colors.redAccent : AppColors.foreground,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Saldo',
                  style: TextStyle(
                      fontSize: 11, color: AppColors.mutedForeground),
                ),
                Text(
                  currency.formatAmount(balance),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppColors.foreground,
                  ),
                ),
                Text(
                  'de ${currency.formatAmount(original)}',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.mutedForeground),
                ),
              ],
            ),
          ),
          _StatusChip(status: status, overdue: overdue),
          const SizedBox(width: AppSpacing.lg),
          // Registrar un abono/pago mueve caja: `creditos.abonar`. Antes
          // bastaba con `creditos.acceso` para cobrar contra una cuenta.
          if (isOpen &&
              ref.read(sessionProvider.notifier).hasPermission('creditos.abonar'))
            FilledButton.tonal(
              onPressed: onAbono,
              child: Text(isPayable ? 'Pagar' : 'Abonar'),
            ),
          PopupMenuButton<String>(
            tooltip: 'Opciones',
            onSelected: (value) {
              if (value == 'history') onHistory();
              if (value == 'cancel') onCancel();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'history',
                child: Text('Ver historial de abonos'),
              ),
              // Cancelar (condonar) solo para quien el RLS deja escribir:
              // CxC = owner/admin; CxP = también supervisor (manager).
              if (isOpen && _canCancel(ref))
                const PopupMenuItem(
                  value: 'cancel',
                  child: Text('Cancelar crédito'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  final bool overdue;

  const _StatusChip({required this.status, required this.overdue});

  @override
  Widget build(BuildContext context) {
    final (label, color) = overdue
        ? ('Vencido', Colors.redAccent)
        : switch (status) {
            'paid' => ('Saldado', Colors.green),
            'partial' => ('Abonado', Colors.orange),
            'cancelled' => ('Cancelado', AppColors.mutedForeground),
            _ => ('Pendiente', AppColors.primary),
          };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Diálogo de abono / pago
// ─────────────────────────────────────────────────────────────────────────────

class _AbonoResult {
  final double amount;
  final String methodCode;
  final String? reference;
  final bool affectCash;

  const _AbonoResult({
    required this.amount,
    required this.methodCode,
    required this.reference,
    required this.affectCash,
  });
}

class _AbonoDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic> credit;
  final bool isPayable;

  const _AbonoDialog({required this.credit, required this.isPayable});

  @override
  ConsumerState<_AbonoDialog> createState() => _AbonoDialogState();
}

class _AbonoDialogState extends ConsumerState<_AbonoDialog> {
  late final TextEditingController _amountCtrl;
  final TextEditingController _referenceCtrl = TextEditingController();
  String _methodCode = 'cash';
  bool _affectCash = true;

  double get _balance =>
      ((widget.credit['balance'] as num?) ?? 0).toDouble();

  @override
  void initState() {
    super.initState();
    _amountCtrl =
        TextEditingController(text: _balance.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _referenceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currency = currentBusinessCurrencyOrFallback(ref);
    final party = _partyName(widget.credit, isPayable: widget.isPayable);

    return AlertDialog(
      title: Text(widget.isPayable ? 'Pagar a proveedor' : 'Registrar abono'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${party ?? ''} · Saldo ${currency.formatAmount(_balance)}',
              style: const TextStyle(color: AppColors.mutedForeground),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _amountCtrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Monto',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            DropdownButtonFormField<String>(
              initialValue: _methodCode,
              decoration: const InputDecoration(
                labelText: 'Forma de pago',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'cash', child: Text('Efectivo')),
                DropdownMenuItem(value: 'card', child: Text('Tarjeta')),
                DropdownMenuItem(
                    value: 'transfer', child: Text('Transferencia')),
              ],
              onChanged: (v) => setState(() => _methodCode = v ?? 'cash'),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _referenceCtrl,
              decoration: const InputDecoration(
                labelText: 'Referencia (opcional)',
                border: OutlineInputBorder(),
              ),
            ),
            if (_methodCode == 'cash') ...[
              const SizedBox(height: AppSpacing.md),
              if (widget.isPayable)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _affectCash,
                  onChanged: (v) =>
                      setState(() => _affectCash = v ?? true),
                  title: const Text(
                    'Descontar de la caja abierta (gasto)',
                    style: TextStyle(fontSize: 14),
                  ),
                )
              else
                const Text(
                  'El efectivo entra a tu caja abierta como depósito.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.isPayable ? 'Registrar pago' : 'Registrar abono'),
        ),
      ],
    );
  }

  void _submit() {
    final amount =
        double.tryParse(_amountCtrl.text.trim().replaceAll(',', ''));
    if (amount == null || amount <= 0) {
      AppToast.info(context, 'Digita un monto válido.');
      return;
    }
    if (amount > _balance + 0.01) {
      AppToast.info(context, 'El abono no puede superar el saldo.');
      return;
    }
    Navigator.pop(
      context,
      _AbonoResult(
        amount: amount,
        methodCode: _methodCode,
        reference: _referenceCtrl.text.trim().isEmpty
            ? null
            : _referenceCtrl.text.trim(),
        affectCash: _affectCash,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Historial de abonos
// ─────────────────────────────────────────────────────────────────────────────

class _HistoryDialog extends ConsumerWidget {
  final Map<String, dynamic> credit;
  final bool isPayable;
  final Future<List<Map<String, dynamic>>> loader;

  const _HistoryDialog({
    required this.credit,
    required this.isPayable,
    required this.loader,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currency = currentBusinessCurrencyOrFallback(ref);
    final dateFmt = DateFormat('dd/MM/yyyy HH:mm');

    return AlertDialog(
      title: const Text('Historial de abonos'),
      content: SizedBox(
        width: 440,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: loader,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Text('Error: ${snapshot.error}');
            }
            final payments = snapshot.data ?? const [];
            if (payments.isEmpty) {
              return const Text(
                'Sin abonos registrados.',
                style: TextStyle(color: AppColors.mutedForeground),
              );
            }
            return ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: payments.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final p = payments[index];
                  final createdAt =
                      DateTime.tryParse(p['created_at'] as String? ?? '');
                  final method = isPayable
                      ? _methodLabel(p['payment_method_code'] as String?)
                      : ((p['payment_methods'] as Map?)?['name'] as String? ??
                          _methodLabel(
                              (p['payment_methods'] as Map?)?['code']
                                  as String?));
                  final reference = p['reference'] as String?;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      currency.formatAmount(
                          ((p['amount'] as num?) ?? 0).toDouble()),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text([
                      method,
                      if (reference != null && reference.isNotEmpty)
                        'Ref: $reference',
                    ].join(' · ')),
                    trailing: Text(
                      createdAt != null
                          ? dateFmt.format(createdAt.toLocal())
                          : '',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }

  static String _methodLabel(String? code) => switch (code) {
        'cash' => 'Efectivo',
        'card' => 'Tarjeta',
        'transfer' => 'Transferencia',
        null || '' => 'Otro',
        final other => other,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Alta manual de cuenta por pagar
// ─────────────────────────────────────────────────────────────────────────────

class _ManualPayableResult {
  final String supplierId;
  final double amount;
  final String? invoiceNumber;
  final DateTime? dueDate;
  final String? notes;

  const _ManualPayableResult({
    required this.supplierId,
    required this.amount,
    required this.invoiceNumber,
    required this.dueDate,
    required this.notes,
  });
}

class _ManualPayableDialog extends StatefulWidget {
  final List<Map<String, dynamic>> suppliers;

  const _ManualPayableDialog({required this.suppliers});

  @override
  State<_ManualPayableDialog> createState() => _ManualPayableDialogState();
}

class _ManualPayableDialogState extends State<_ManualPayableDialog> {
  final TextEditingController _amountCtrl = TextEditingController();
  final TextEditingController _invoiceCtrl = TextEditingController();
  final TextEditingController _notesCtrl = TextEditingController();
  String? _supplierId;
  DateTime? _dueDate;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _invoiceCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd/MM/yyyy');
    return AlertDialog(
      title: const Text('Registrar cuenta por pagar'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _supplierId,
              decoration: const InputDecoration(
                labelText: 'Proveedor',
                border: OutlineInputBorder(),
              ),
              items: widget.suppliers
                  .map(
                    (s) => DropdownMenuItem(
                      value: s['id'] as String,
                      child: Text(s['name'] as String? ?? ''),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _supplierId = v),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Monto adeudado',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _invoiceCtrl,
              decoration: const InputDecoration(
                labelText: 'Número de factura (opcional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _dueDate ??
                      DateTime.now().add(const Duration(days: 30)),
                  firstDate: DateTime.now()
                      .subtract(const Duration(days: 365)),
                  lastDate:
                      DateTime.now().add(const Duration(days: 365 * 3)),
                );
                if (picked != null) setState(() => _dueDate = picked);
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Fecha de vencimiento (opcional)',
                  border: OutlineInputBorder(),
                ),
                child: Text(
                  switch (_dueDate) {
                    final due? => dateFmt.format(due),
                    null => '—',
                  },
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _notesCtrl,
              decoration: const InputDecoration(
                labelText: 'Notas (opcional)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Registrar'),
        ),
      ],
    );
  }

  void _submit() {
    final amount =
        double.tryParse(_amountCtrl.text.trim().replaceAll(',', ''));
    if (_supplierId == null) {
      AppToast.info(context, 'Selecciona el proveedor.');
      return;
    }
    if (amount == null || amount <= 0) {
      AppToast.info(context, 'Digita un monto válido.');
      return;
    }
    Navigator.pop(
      context,
      _ManualPayableResult(
        supplierId: _supplierId!,
        amount: amount,
        invoiceNumber: _invoiceCtrl.text.trim().isEmpty
            ? null
            : _invoiceCtrl.text.trim(),
        dueDate: _dueDate,
        notes:
            _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      ),
    );
  }
}
