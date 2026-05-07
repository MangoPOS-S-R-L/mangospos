// lib/presentation/settings/payment_methods/view/payment_methods_view.dart
//
// Ajustes → Tipos de Pago. Hoy solo expone la sección "Transferencias"
// con CRUD de cuentas bancarias del negocio. Diseñado para crecer:
// más adelante se pueden añadir secciones para tarjeta (datáfono),
// efectivo (denominaciones), QR, etc. — el shell ya está aquí.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/bank_account.dart';
import 'package:mangopos/presentation/settings/payment_methods/viewmodel/bank_accounts_viewmodel.dart';

class PaymentMethodsView extends ConsumerStatefulWidget {
  /// 'auto' o un UUID concreto del negocio. El VM lo resuelve antes de
  /// consultar.
  final String businessId;
  const PaymentMethodsView({super.key, required this.businessId});

  @override
  ConsumerState<PaymentMethodsView> createState() => _PaymentMethodsViewState();
}

class _PaymentMethodsViewState extends ConsumerState<PaymentMethodsView> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref
          .read(bankAccountsVmProvider.notifier)
          .load(businessId: widget.businessId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(bankAccountsVmProvider);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: MangoColors.sidebarBg,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoutes.settings),
        ),
        title: const Text('Tipos de Pago'),
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: .4,
        actions: [
          IconButton(
            tooltip: 'Refrescar',
            onPressed: () => ref
                .read(bankAccountsVmProvider.notifier)
                .load(businessId: widget.businessId),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              foregroundColor: MangoColors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () async {
              await showDialog(
                context: context,
                builder: (_) => const _BankAccountDialog(),
              );
            },
            icon: const Icon(Icons.add),
            label: const Text('Agregar cuenta'),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ─── Encabezado de sección ─────────────────────────────────
            Text(
              'Transferencias bancarias',
              style: text.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Cuentas donde recibes transferencias. Al cobrar por '
              'transferencia, el cajero elige a cuál cuenta llegó el dinero '
              'para tener trazabilidad.',
              style: text.bodySmall?.copyWith(color: MangoColors.muted),
            ),
            const SizedBox(height: 16),

            // ─── Cuerpo ────────────────────────────────────────────────
            if (state.isLoading && state.items.isEmpty)
              const Expanded(
                child: Center(
                  child: CircularProgressIndicator(
                    color: MangoColors.primaryOrange,
                  ),
                ),
              )
            else if (state.errorMessage != null && state.items.isEmpty)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Error: ${state.errorMessage}',
                      style: text.bodyMedium?.copyWith(color: Colors.red),
                    ),
                  ),
                ),
              )
            else if (state.items.isEmpty)
              const Expanded(child: _EmptyState())
            else
              Expanded(child: _AccountsList(items: state.items)),
          ],
        ),
      ),
      bottomNavigationBar: state.isLoading
          ? const LinearProgressIndicator(
              minHeight: 2,
              color: MangoColors.primaryOrange,
            )
          : const SizedBox.shrink(),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.account_balance_outlined,
              size: 56, color: Colors.black26),
          const SizedBox(height: 12),
          const Text(
            'No tienes cuentas bancarias configuradas',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Agrega tu primera cuenta para que el cajero pueda elegirla '
              'al cobrar por transferencia.',
              textAlign: TextAlign.center,
              style: TextStyle(color: MangoColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountsList extends ConsumerWidget {
  final List<BankAccount> items;
  const _AccountsList({required this.items});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ReorderableListView.builder(
      itemCount: items.length,
      buildDefaultDragHandles: false,
      onReorder: (oldIndex, newIndex) {
        if (oldIndex == newIndex) return;
        final list = List.of(items);
        final adjusted = newIndex > oldIndex ? newIndex - 1 : newIndex;
        final moved = list.removeAt(oldIndex);
        list.insert(adjusted, moved);
        ref.read(bankAccountsVmProvider.notifier).reorder(list);
      },
      proxyDecorator: (child, index, animation) => Material(
        color: Colors.transparent,
        elevation: 6,
        shadowColor: Colors.black26,
        borderRadius: BorderRadius.circular(12),
        child: child,
      ),
      padding: EdgeInsets.zero,
      itemBuilder: (ctx, i) {
        final acc = items[i];
        return Padding(
          key: ValueKey('bank-${acc.id}'),
          padding: const EdgeInsets.only(bottom: 12),
          child: _AccountCard(account: acc, index: i),
        );
      },
    );
  }
}

class _AccountCard extends ConsumerWidget {
  final BankAccount account;
  final int index;
  const _AccountCard({required this.account, required this.index});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final inactiveBg = const Color(0xFFFAFAFA);
    return Card(
      elevation: 0,
      color: account.isActive ? Colors.white : inactiveBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: MangoColors.cardBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(Icons.drag_indicator,
                    size: 22, color: Colors.black38),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          account.displayLabel,
                          style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: MangoColors.darkGray,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _Pill(
                        label: account.currency,
                        color: const Color(0xFF3B82F6),
                      ),
                      const SizedBox(width: 6),
                      _Pill(
                        label: account.accountType.displayName,
                        color: MangoColors.muted,
                      ),
                      if (!account.isActive) ...[
                        const SizedBox(width: 6),
                        _Pill(label: 'Inactiva', color: Colors.red.shade400),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${account.bankName} · #${account.accountNumber}'
                    '${account.accountHolder != null ? ' · ${account.accountHolder}' : ''}',
                    style: text.bodySmall?.copyWith(color: MangoColors.muted),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              onSelected: (v) async {
                final notifier = ref.read(bankAccountsVmProvider.notifier);
                if (v == 'edit') {
                  await showDialog(
                    context: context,
                    builder: (_) => _BankAccountDialog(initial: account),
                  );
                } else if (v == 'toggle') {
                  await notifier.toggleActive(account.id, !account.isActive);
                } else if (v == 'delete') {
                  final ok = await _confirmDelete(context, account);
                  if (ok != true) return;
                  await notifier.remove(account.id);
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'edit',
                  child: Row(children: [
                    Icon(Icons.edit, size: 18, color: MangoColors.darkGray),
                    SizedBox(width: 12),
                    Text('Editar'),
                  ]),
                ),
                PopupMenuItem(
                  value: 'toggle',
                  child: Row(children: [
                    Icon(
                      account.isActive
                          ? Icons.visibility_off
                          : Icons.visibility,
                      size: 18,
                      color: MangoColors.darkGray,
                    ),
                    const SizedBox(width: 12),
                    Text(account.isActive ? 'Desactivar' : 'Activar'),
                  ]),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(children: [
                    Icon(Icons.delete_outline, size: 18, color: Colors.red),
                    SizedBox(width: 12),
                    Text('Eliminar', style: TextStyle(color: Colors.red)),
                  ]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirmDelete(BuildContext context, BankAccount acc) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Eliminar cuenta'),
        content: Text(
          '¿Eliminar la cuenta "${acc.displayLabel}"? Los pagos hechos a '
          'esta cuenta seguirán existiendo (referencia se vacía).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  const _Pill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
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

// ─── Dialog crear / editar ───────────────────────────────────────────────────

class _BankAccountDialog extends ConsumerStatefulWidget {
  final BankAccount? initial;
  const _BankAccountDialog({this.initial});

  @override
  ConsumerState<_BankAccountDialog> createState() =>
      _BankAccountDialogState();
}

class _BankAccountDialogState extends ConsumerState<_BankAccountDialog> {
  late final TextEditingController _bankNameCtrl;
  late final TextEditingController _accountNumberCtrl;
  late final TextEditingController _accountHolderCtrl;
  late final TextEditingController _aliasCtrl;
  late BankAccountType _accountType;
  late String _currency;
  bool _isSaving = false;

  bool get _isEdit => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final a = widget.initial;
    _bankNameCtrl = TextEditingController(text: a?.bankName ?? '');
    _accountNumberCtrl = TextEditingController(text: a?.accountNumber ?? '');
    _accountHolderCtrl =
        TextEditingController(text: a?.accountHolder ?? '');
    _aliasCtrl = TextEditingController(text: a?.alias ?? '');
    _accountType = a?.accountType ?? BankAccountType.corriente;
    _currency = a?.currency ?? 'DOP';
  }

  @override
  void dispose() {
    _bankNameCtrl.dispose();
    _accountNumberCtrl.dispose();
    _accountHolderCtrl.dispose();
    _aliasCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final bank = _bankNameCtrl.text.trim();
    final num = _accountNumberCtrl.text.trim();
    if (bank.isEmpty || num.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Banco y número de cuenta son obligatorios.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() => _isSaving = true);
    final notifier = ref.read(bankAccountsVmProvider.notifier);
    bool ok = false;
    try {
      if (_isEdit) {
        ok = await notifier.update(
          id: widget.initial!.id,
          bankName: bank,
          accountNumber: num,
          accountHolder: _accountHolderCtrl.text,
          accountType: _accountType,
          currency: _currency,
          alias: _aliasCtrl.text,
        );
      } else {
        ok = await notifier.create(
          bankName: bank,
          accountNumber: num,
          accountHolder: _accountHolderCtrl.text,
          accountType: _accountType,
          currency: _currency,
          alias: _aliasCtrl.text,
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(_isEdit ? 'Editar cuenta' : 'Agregar cuenta bancaria'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label('Banco *'),
              _txt(
                _bankNameCtrl,
                hint: 'Ej. Banreservas, Popular, BHD, TPago, Yappi…',
              ),
              const SizedBox(height: 12),
              _label('Número de cuenta *'),
              _txt(
                _accountNumberCtrl,
                hint: 'Ej. 9601-2345-67',
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              _label('Titular de la cuenta'),
              _txt(
                _accountHolderCtrl,
                hint: 'Ej. Restaurante Mango S.R.L.',
              ),
              const SizedBox(height: 12),
              _label('Alias amigable'),
              _txt(
                _aliasCtrl,
                hint: 'Ej. Cuenta principal, Delivery, Dólares…',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _label('Tipo'),
                        DropdownButtonFormField<BankAccountType>(
                          initialValue: _accountType,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                          ),
                          items: BankAccountType.values
                              .map((t) => DropdownMenuItem(
                                    value: t,
                                    child: Text(t.displayName),
                                  ))
                              .toList(growable: false),
                          onChanged: (v) {
                            if (v != null) setState(() => _accountType = v);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _label('Moneda'),
                        DropdownButtonFormField<String>(
                          initialValue: _currency,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                          ),
                          items: const [
                            DropdownMenuItem(
                                value: 'DOP', child: Text('DOP')),
                            DropdownMenuItem(
                                value: 'USD', child: Text('USD')),
                            DropdownMenuItem(
                                value: 'EUR', child: Text('EUR')),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _currency = v);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: MangoColors.primaryOrange,
            foregroundColor: Colors.white,
          ),
          onPressed: _isSaving ? null : _submit,
          child: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(_isEdit ? 'Guardar' : 'Agregar'),
        ),
      ],
    );
  }

  Widget _label(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          s,
          style: const TextStyle(
              fontWeight: FontWeight.w600, color: MangoColors.darkGray),
        ),
      );

  Widget _txt(
    TextEditingController c, {
    String? hint,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: c,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        hintText: hint,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }
}
