import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/currency/business_currency_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../data/repositories/table_deposit_repository.dart';
import '../../../services/session/session_controller.dart';
import '../../cashier/viewmodel/cashier_viewmodel.dart';

/// Abono (saldo prepagado) de una mesa.
///
/// El cliente deja un monto en la mesa, el dinero entra a la caja en ese
/// momento y cada factura que se cobre en esa mesa lo descuenta. El saldo vive
/// en la mesa física: sobrevive al cierre de la visita y al cierre de caja, y
/// dura hasta agotarse.
///
/// Devuelve `true` si algo cambió, para que el caller refresque el saldo.
Future<bool> showTableDepositDialog(
  BuildContext context, {
  required String tableId,
  required String tableLabel,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => TableDepositDialog(
      tableId: tableId,
      tableLabel: tableLabel,
    ),
  );
  return result ?? false;
}

class TableDepositDialog extends ConsumerStatefulWidget {
  const TableDepositDialog({
    super.key,
    required this.tableId,
    required this.tableLabel,
  });

  final String tableId;
  final String tableLabel;

  @override
  ConsumerState<TableDepositDialog> createState() => _TableDepositDialogState();
}

class _TableDepositDialogState extends ConsumerState<TableDepositDialog> {
  final _amountCtrl = TextEditingController();
  final _holderCtrl = TextEditingController();
  final _referenceCtrl = TextEditingController();

  String _methodCode = 'cash';
  bool _loading = true;
  bool _saving = false;
  String? _error;

  TableDepositAccount _account = TableDepositAccount.empty;
  List<TableDepositMovement> _movements = const [];

  /// Algo se registró: el caller tiene que refrescar el saldo aunque el
  /// cajero cierre el diálogo con la X.
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _holderCtrl.dispose();
    _referenceCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final repo = ref.read(tableDepositRepositoryProvider);
    try {
      final account = await repo.getBalance(widget.tableId);
      List<TableDepositMovement> movements = const [];
      try {
        movements = await repo.getMovements(widget.tableId, limit: 20);
      } catch (_) {
        // El historial es informativo: si falla, el abono se puede registrar
        // igual.
      }
      if (!mounted) return;
      setState(() {
        _account = account;
        _movements = movements;
        if (_holderCtrl.text.isEmpty && (account.holderName ?? '').isNotEmpty) {
          _holderCtrl.text = account.holderName!;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = TableDepositRepository.friendlyError(e);
        _loading = false;
      });
    }
  }

  Future<String?> _resolveCashSessionId() async {
    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) return null;
    final session = await ref
        .read(cashierRepositoryProvider)
        .requireActiveSession(businessId: businessId);
    return session.id;
  }

  Future<void> _submitDeposit() async {
    final amount = double.tryParse(_amountCtrl.text.trim().replaceAll(',', ''));
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Escribe un monto mayor que cero.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final sessionId = await _resolveCashSessionId();
      if (sessionId == null || sessionId.isEmpty) {
        throw const TableDepositException(
          'Necesitas una caja abierta para registrar el abono.',
        );
      }
      final account = await ref
          .read(tableDepositRepositoryProvider)
          .addDeposit(
            tableId: widget.tableId,
            amount: amount,
            cashierSessionId: sessionId,
            paymentMethodCode: _methodCode,
            reference: _referenceCtrl.text.trim().isEmpty
                ? null
                : _referenceCtrl.text.trim(),
            holderName: _holderCtrl.text.trim().isEmpty
                ? null
                : _holderCtrl.text.trim(),
          );
      if (!mounted) return;
      _changed = true;
      _amountCtrl.clear();
      _referenceCtrl.clear();
      setState(() {
        _account = account;
        _saving = false;
      });
      await _load();
      if (!mounted) return;
      final currency = currentBusinessCurrencyOrFallback(ref);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Abono registrado. La mesa queda con '
            '${currency.formatAmount(account.balance)}.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is TableDepositException
            ? e.message
            : TableDepositRepository.friendlyError(e);
      });
    }
  }

  Future<void> _submitRefund() async {
    final currency = currentBusinessCurrencyOrFallback(ref);
    final controller = TextEditingController(
      text: _account.balance.toStringAsFixed(2),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Devolver saldo en efectivo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'La mesa tiene ${currency.formatAmount(_account.balance)} sin '
              'consumir. Lo que devuelvas sale de la caja abierta.',
              style: const TextStyle(color: AppColors.mutedForeground),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Monto a devolver',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Devolver'),
          ),
        ],
      ),
    );

    final amount = double.tryParse(controller.text.trim().replaceAll(',', ''));
    controller.dispose();
    if (confirmed != true || amount == null || amount <= 0) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final sessionId = await _resolveCashSessionId();
      if (sessionId == null || sessionId.isEmpty) {
        throw const TableDepositException(
          'Necesitas una caja abierta para devolver el saldo.',
        );
      }
      await ref.read(tableDepositRepositoryProvider).refund(
            tableId: widget.tableId,
            amount: amount,
            cashierSessionId: sessionId,
          );
      if (!mounted) return;
      _changed = true;
      setState(() => _saving = false);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is TableDepositException
            ? e.message
            : TableDepositRepository.friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = currentBusinessCurrencyOrFallback(ref);
    final canDeposit = ref
        .read(sessionProvider.notifier)
        .hasPermission('ventas.abono_mesa.registrar');
    final canRefund = ref
        .read(sessionProvider.notifier)
        .hasPermission('ventas.abono_mesa.devolver');

    return AlertDialog(
      title: Text('Abono · ${widget.tableLabel}'),
      content: SizedBox(
        width: 460,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _BalanceHeader(
                      balance: _account.balance,
                      holderName: _account.holderName,
                      formatted: currency.formatAmount(_account.balance),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF2F2),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFFECACA)),
                        ),
                        child: Text(
                          _error!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFB91C1C),
                          ),
                        ),
                      ),
                    ],
                    if (!canDeposit) ...[
                      const SizedBox(height: AppSpacing.lg),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: const Text(
                          'Solo el dueño o un administrador puede cargar saldo '
                          'a una mesa. Desde la caja sí se puede cobrar contra '
                          'este saldo en el cobro normal.',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.mutedForeground,
                          ),
                        ),
                      ),
                    ],
                    if (canDeposit) ...[
                      const SizedBox(height: AppSpacing.lg),
                      const Text(
                        'Registrar abono',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextField(
                        controller: _amountCtrl,
                        autofocus: true,
                        enabled: !_saving,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Monto que abona',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextField(
                        controller: _holderCtrl,
                        enabled: !_saving,
                        decoration: const InputDecoration(
                          labelText: 'A nombre de (recomendado)',
                          helperText:
                              'El saldo queda en la mesa, no en la visita: '
                              'el nombre evita que otro cliente lo consuma.',
                          helperMaxLines: 3,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      DropdownButtonFormField<String>(
                        initialValue: _methodCode,
                        decoration: const InputDecoration(
                          labelText: 'Con qué paga el abono',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'cash',
                            child: Text('Efectivo'),
                          ),
                          DropdownMenuItem(
                            value: 'card',
                            child: Text('Tarjeta'),
                          ),
                          DropdownMenuItem(
                            value: 'transfer',
                            child: Text('Transferencia'),
                          ),
                        ],
                        onChanged: _saving
                            ? null
                            : (v) => setState(() => _methodCode = v ?? 'cash'),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextField(
                        controller: _referenceCtrl,
                        enabled: !_saving,
                        decoration: const InputDecoration(
                          labelText: 'Referencia (opcional)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _submitDeposit,
                          icon: _saving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.add),
                          label: const Text('Registrar abono'),
                        ),
                      ),
                    ],
                    if (_movements.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.lg),
                      const Text(
                        'Movimientos',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      ..._movements.map(
                        (m) => _MovementRow(
                          movement: m,
                          amount: currency.formatAmount(m.amount.abs()),
                          balance: currency.formatAmount(m.balanceAfter),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        if (canRefund && _account.hasBalance)
          TextButton(
            onPressed: _saving ? null : _submitRefund,
            child: const Text('Devolver saldo'),
          ),
        FilledButton(
          onPressed: _saving ? null : () => Navigator.pop(context, _changed),
          child: const Text('Listo'),
        ),
      ],
    );
  }
}

class _BalanceHeader extends StatelessWidget {
  const _BalanceHeader({
    required this.balance,
    required this.holderName,
    required this.formatted,
  });

  final double balance;
  final String? holderName;
  final String formatted;

  @override
  Widget build(BuildContext context) {
    final hasBalance = balance > 0.005;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: hasBalance ? const Color(0xFFF0FDF4) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: hasBalance ? const Color(0xFFBBF7D0) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Saldo disponible',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            formatted,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: hasBalance
                  ? const Color(0xFF15803D)
                  : AppColors.mutedForeground,
            ),
          ),
          if ((holderName ?? '').isNotEmpty)
            Text(
              'A nombre de $holderName',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF166534),
              ),
            ),
        ],
      ),
    );
  }
}

class _MovementRow extends StatelessWidget {
  const _MovementRow({
    required this.movement,
    required this.amount,
    required this.balance,
  });

  final TableDepositMovement movement;
  final String amount;
  final String balance;

  @override
  Widget build(BuildContext context) {
    final isIn = movement.amount > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            isIn ? Icons.south_west_rounded : Icons.north_east_rounded,
            size: 14,
            color: isIn ? const Color(0xFF15803D) : const Color(0xFFB45309),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              movement.typeLabel,
              style: const TextStyle(fontSize: 12.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${isIn ? '+' : '−'}$amount',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: isIn ? const Color(0xFF15803D) : const Color(0xFFB45309),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'queda $balance',
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}
