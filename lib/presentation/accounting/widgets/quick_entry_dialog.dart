// Asiento rápido: plantillas de dos líneas para los movimientos que el dueño
// registra a mano todos los días (un gasto, un ingreso, un depósito). Evita
// tener que armar el asiento línea por línea y elegir cuentas — solo se pide
// monto, fecha y descripción.
//
// No es data de ejemplo: genera asientos reales, iguales a los del editor
// manual. Solo cambia la ergonomía.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/data/models/accounting_models.dart';
import 'package:mangopos/presentation/accounting/widgets/accounting_ui.dart';

class QuickEntryTemplate {
  final String label;
  final String hint;
  final IconData icon;

  /// Códigos del catálogo estándar sembrado por `fn_accounting_seed_chart`.
  final String debitCode;
  final String creditCode;

  /// Si no es null, el usuario puede cambiar la cuenta de ese lado eligiendo
  /// entre las cuentas de ese tipo (ej.: qué gasto fue).
  final AccountType? pickType;

  /// El selector reemplaza el debe (true) o el haber (false).
  final bool pickOnDebit;

  const QuickEntryTemplate({
    required this.label,
    required this.hint,
    required this.icon,
    required this.debitCode,
    required this.creditCode,
    this.pickType,
    this.pickOnDebit = true,
  });
}

const kQuickEntryTemplates = <QuickEntryTemplate>[
  QuickEntryTemplate(
    label: 'Gasto en efectivo',
    hint: 'Sale plata de caja y se registra el gasto',
    icon: Icons.receipt_rounded,
    debitCode: '610108',
    creditCode: '110101',
    pickType: AccountType.expense,
  ),
  QuickEntryTemplate(
    label: 'Otro ingreso',
    hint: 'Entra plata a caja por algo que no es venta del POS',
    icon: Icons.savings_rounded,
    debitCode: '110101',
    creditCode: '420101',
    pickType: AccountType.income,
    pickOnDebit: false,
  ),
  QuickEntryTemplate(
    label: 'Aporte de capital',
    hint: 'El dueño mete dinero al negocio',
    icon: Icons.account_balance_wallet_rounded,
    debitCode: '110101',
    creditCode: '310101',
  ),
  QuickEntryTemplate(
    label: 'Depósito al banco',
    hint: 'Pasa efectivo de caja a la cuenta bancaria',
    icon: Icons.account_balance_rounded,
    debitCode: '110103',
    creditCode: '110101',
  ),
  QuickEntryTemplate(
    label: 'Retiro del dueño',
    hint: 'El dueño saca dinero del negocio',
    icon: Icons.outbox_rounded,
    debitCode: '310201',
    creditCode: '110101',
  ),
];

class QuickEntryResult {
  final DateTime date;
  final String description;
  final List<JournalLineDraft> lines;

  const QuickEntryResult({
    required this.date,
    required this.description,
    required this.lines,
  });
}

Future<QuickEntryResult?> showQuickEntryDialog(
  BuildContext context, {
  required List<AccountingAccount> accounts,
}) {
  return showDialog<QuickEntryResult>(
    context: context,
    builder: (_) => _QuickEntryDialog(accounts: accounts),
  );
}

class _QuickEntryDialog extends StatefulWidget {
  final List<AccountingAccount> accounts;
  const _QuickEntryDialog({required this.accounts});

  @override
  State<_QuickEntryDialog> createState() => _QuickEntryDialogState();
}

class _QuickEntryDialogState extends State<_QuickEntryDialog> {
  int _selected = 0;
  DateTime _date = DateTime.now();
  final _amountCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  String? _pickedAccountId;

  QuickEntryTemplate get _template => kQuickEntryTemplates[_selected];

  double get _amount => double.tryParse(_amountCtrl.text.trim()) ?? 0;

  @override
  void initState() {
    super.initState();
    _syncPicked();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  /// Al cambiar de plantilla, precarga la cuenta por defecto del selector.
  void _syncPicked() {
    final t = _template;
    if (t.pickType == null) {
      _pickedAccountId = null;
      return;
    }
    final defaultCode = t.pickOnDebit ? t.debitCode : t.creditCode;
    _pickedAccountId = _byCode(defaultCode)?.id ?? _pickable().firstOrNull?.id;
  }

  AccountingAccount? _byCode(String code) {
    for (final a in widget.accounts) {
      if (a.code == code) return a;
    }
    return null;
  }

  List<AccountingAccount> _pickable() {
    final type = _template.pickType;
    if (type == null) return const [];
    return widget.accounts
        .where((a) => a.isPostable && a.isActive && a.type == type)
        .toList();
  }

  /// Faltan cuentas del catálogo estándar (alguien las borró o renombró el
  /// código): mejor avisar que postear contra la cuenta equivocada.
  String? get _missingCode {
    final t = _template;
    if (_byCode(t.debitCode) == null && !(t.pickType != null && t.pickOnDebit)) {
      return t.debitCode;
    }
    if (_byCode(t.creditCode) == null &&
        !(t.pickType != null && !t.pickOnDebit)) {
      return t.creditCode;
    }
    return null;
  }

  bool get _canSave =>
      _amount > 0 &&
      _missingCode == null &&
      (_template.pickType == null || _pickedAccountId != null);

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd/MM/yyyy');
    final t = _template;

    return Dialog(
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          child: AccountingCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AccountingCardHeader(
                  title: 'Asiento rápido',
                  subtitle: 'Elige el tipo de movimiento y el monto. '
                      'El asiento se arma solo y queda en el libro diario.',
                  trailing: IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (var i = 0; i < kQuickEntryTemplates.length; i++)
                      _templateChip(i),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(t.hint,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.mutedForeground)),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _amountCtrl,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'^\d*\.?\d{0,2}')),
                        ],
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700),
                        decoration: const InputDecoration(
                          labelText: 'Monto',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.calendar_today_rounded,
                            size: 16),
                        label: Text(df.format(_date)),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _date,
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now()
                                .add(const Duration(days: 365)),
                          );
                          if (picked != null) setState(() => _date = picked);
                        },
                      ),
                    ),
                  ],
                ),
                if (t.pickType != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  DropdownButtonFormField<String>(
                    initialValue: _pickedAccountId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: t.pickType == AccountType.expense
                          ? '¿Qué gasto fue?'
                          : '¿Qué ingreso fue?',
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      for (final a in _pickable())
                        DropdownMenuItem(
                          value: a.id,
                          child: Text('${a.code} · ${a.name}',
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => setState(() => _pickedAccountId = v),
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _descCtrl,
                  decoration: InputDecoration(
                    labelText: 'Descripción (opcional)',
                    hintText: t.label,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                _preview(),
                if (_missingCode != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Falta la cuenta $_missingCode en el catálogo. Créala o '
                    'usa el editor de asientos manual.',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.destructive),
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancelar'),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    FilledButton(
                      onPressed: _canSave ? _submit : null,
                      child: const Text('Registrar'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _templateChip(int index) {
    final t = kQuickEntryTemplates[index];
    final selected = index == _selected;
    return InkWell(
      borderRadius: BorderRadius.circular(kAcctRadius),
      onTap: () => setState(() {
        _selected = index;
        _syncPicked();
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.10)
              : Colors.white,
          borderRadius: BorderRadius.circular(kAcctRadius),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(t.icon,
                size: 16,
                color: selected
                    ? AppColors.primary
                    : AppColors.mutedForeground),
            const SizedBox(width: AppSpacing.sm),
            Text(t.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? AppColors.primary
                      : AppColors.foreground,
                )),
          ],
        ),
      ),
    );
  }

  /// Muestra el asiento que se va a generar antes de confirmarlo: es la forma
  /// más rápida de que alguien sin formación contable entienda qué hace cada
  /// plantilla.
  Widget _preview() {
    final debit = _debitAccount();
    final credit = _creditAccount();
    final money = NumberFormat('#,##0.00');
    final amount = _amount > 0 ? money.format(_amount) : '—';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.muted.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(kAcctRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ASIENTO QUE SE VA A GENERAR',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 0.4,
                fontWeight: FontWeight.w700,
                color: AppColors.mutedForeground,
              )),
          const SizedBox(height: AppSpacing.sm),
          _previewLine('Debe', debit, amount),
          _previewLine('Haber', credit, amount),
        ],
      ),
    );
  }

  Widget _previewLine(String side, AccountingAccount? account, String amount) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(side,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.mutedForeground)),
          ),
          Expanded(
            child: Text(
              account == null
                  ? '(cuenta no encontrada)'
                  : '${account.code} · ${account.name}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          Text(amount,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  AccountingAccount? _debitAccount() {
    final t = _template;
    if (t.pickType != null && t.pickOnDebit) {
      return widget.accounts.where((a) => a.id == _pickedAccountId).firstOrNull;
    }
    return _byCode(t.debitCode);
  }

  AccountingAccount? _creditAccount() {
    final t = _template;
    if (t.pickType != null && !t.pickOnDebit) {
      return widget.accounts.where((a) => a.id == _pickedAccountId).firstOrNull;
    }
    return _byCode(t.creditCode);
  }

  void _submit() {
    final debit = _debitAccount();
    final credit = _creditAccount();
    if (debit == null || credit == null) return;
    final description = _descCtrl.text.trim().isEmpty
        ? _template.label
        : _descCtrl.text.trim();

    Navigator.of(context).pop(QuickEntryResult(
      date: _date,
      description: description,
      lines: [
        JournalLineDraft(accountId: debit.id, debit: _amount),
        JournalLineDraft(accountId: credit.id, credit: _amount),
      ],
    ));
  }
}
