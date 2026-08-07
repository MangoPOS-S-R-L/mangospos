import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/data/models/accounting_models.dart';
import 'package:mangopos/presentation/accounting/widgets/accounting_ui.dart';

/// Editor de asiento manual. Devuelve el borrador validado (fecha,
/// descripción, referencia, líneas) o `null` si se cancela. No postea: de eso
/// se encarga el ViewModel, que es quien traduce los errores de la BD.
class JournalEntryDraft {
  final DateTime date;
  final String description;
  final String? reference;
  final List<JournalLineDraft> lines;

  const JournalEntryDraft({
    required this.date,
    required this.description,
    required this.lines,
    this.reference,
  });
}

Future<JournalEntryDraft?> showJournalEntryDialog(
  BuildContext context, {
  required List<AccountingAccount> accounts,
  required List<AccountingCostCenter> costCenters,
}) {
  return showDialog<JournalEntryDraft>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _JournalEntryDialog(
      accounts: accounts,
      costCenters: costCenters,
    ),
  );
}

class _JournalEntryDialog extends StatefulWidget {
  final List<AccountingAccount> accounts;
  final List<AccountingCostCenter> costCenters;

  const _JournalEntryDialog({
    required this.accounts,
    required this.costCenters,
  });

  @override
  State<_JournalEntryDialog> createState() => _JournalEntryDialogState();
}

class _JournalEntryDialogState extends State<_JournalEntryDialog> {
  DateTime _date = DateTime.now();
  final _descCtrl = TextEditingController();
  final _refCtrl = TextEditingController();
  final List<_LineRow> _rows = [_LineRow(), _LineRow()];

  @override
  void dispose() {
    _descCtrl.dispose();
    _refCtrl.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  double get _totalDebit =>
      _rows.fold(0.0, (sum, r) => sum + r.debit);
  double get _totalCredit =>
      _rows.fold(0.0, (sum, r) => sum + r.credit);
  double get _difference =>
      double.parse((_totalDebit - _totalCredit).toStringAsFixed(2));

  bool get _canSave =>
      _descCtrl.text.trim().isNotEmpty &&
      _totalDebit > 0 &&
      _difference == 0 &&
      _rows.where((r) => r.accountId != null && (r.debit > 0 || r.credit > 0))
              .length >=
          2;

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd/MM/yyyy');
    final money = NumberFormat('#,##0.00');

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AccountingCardHeader(
                title: 'Nuevo asiento manual',
                subtitle: 'Los débitos tienen que igualar a los créditos. '
                    'Solo se listan cuentas de detalle activas.',
                trailing: IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.calendar_today_rounded, size: 16),
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
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _descCtrl,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Descripción del asiento',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: TextField(
                      controller: _refCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Referencia',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              // Flexible + mainAxisSize.min: la caja de líneas crece con el
              // contenido y recién scrollea cuando pasa el alto del diálogo.
              // Con Expanded se estiraba al máximo y dejaba un hueco vacío
              // enorme cuando el asiento tenía solo dos líneas.
              Flexible(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(kAcctRadius),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: AppColors.muted.withValues(alpha: 0.5),
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(kAcctRadius)),
                        ),
                        child: const Text(
                          'LÍNEAS DEL ASIENTO',
                          style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 0.4,
                            fontWeight: FontWeight.w700,
                            color: AppColors.mutedForeground,
                          ),
                        ),
                      ),
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(AppSpacing.md,
                              AppSpacing.md, AppSpacing.md, 0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var i = 0; i < _rows.length; i++)
                                _buildLine(i, money),
                            ],
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(
                              left: AppSpacing.sm, bottom: AppSpacing.xs),
                          child: TextButton.icon(
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('Agregar línea'),
                            onPressed: () =>
                                setState(() => _rows.add(_LineRow())),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppColors.muted.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(kAcctRadius),
                ),
                child: Row(
                  children: [
                    _total('Débitos', _totalDebit, money),
                    const SizedBox(width: AppSpacing.xxl),
                    _total('Créditos', _totalCredit, money),
                    const SizedBox(width: AppSpacing.xxl),
                    _total('Diferencia', _difference, money,
                        color: _difference == 0
                            ? AppColors.success
                            : AppColors.destructive),
                    const Spacer(),
                    if (_difference != 0)
                      Flexible(
                        child: Text(
                          'El asiento no cuadra.',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              color: AppColors.destructive,
                              fontSize: 12,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
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
                    child: const Text('Registrar asiento'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _total(String label, double value, NumberFormat money,
      {Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 11, color: AppColors.mutedForeground)),
        Text(money.format(value),
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }

  Widget _buildLine(int index, NumberFormat money) {
    final row = _rows[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: DropdownButtonFormField<String>(
              initialValue: row.accountId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Cuenta',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                for (final a in widget.accounts)
                  DropdownMenuItem(
                    value: a.id,
                    child: Text('${a.code} · ${a.name}',
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => row.accountId = v),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (widget.costCenters.isNotEmpty) ...[
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String>(
                initialValue: row.costCenterId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'C. costo',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('—')),
                  for (final c in widget.costCenters.where((c) => c.isActive))
                    DropdownMenuItem(
                      value: c.id,
                      child: Text(c.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => row.costCenterId = v),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            flex: 2,
            child: TextField(
              controller: row.debitCtrl,
              textAlign: TextAlign.right,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [_moneyFormatter],
              decoration: const InputDecoration(
                labelText: 'Debe',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() {
                if (row.debit > 0) row.creditCtrl.clear();
              }),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            flex: 2,
            child: TextField(
              controller: row.creditCtrl,
              textAlign: TextAlign.right,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [_moneyFormatter],
              decoration: const InputDecoration(
                labelText: 'Haber',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() {
                if (row.credit > 0) row.debitCtrl.clear();
              }),
            ),
          ),
          IconButton(
            tooltip: 'Quitar línea',
            icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
            onPressed: _rows.length <= 2
                ? null
                : () => setState(() {
                      _rows.removeAt(index).dispose();
                    }),
          ),
        ],
      ),
    );
  }

  void _submit() {
    final lines = _rows
        .where((r) => r.accountId != null && (r.debit > 0 || r.credit > 0))
        .map((r) => JournalLineDraft(
              accountId: r.accountId,
              costCenterId: r.costCenterId,
              debit: r.debit,
              credit: r.credit,
            ))
        .toList();
    Navigator.of(context).pop(JournalEntryDraft(
      date: _date,
      description: _descCtrl.text,
      reference: _refCtrl.text.trim().isEmpty ? null : _refCtrl.text.trim(),
      lines: lines,
    ));
  }
}

final _moneyFormatter =
    FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'));

class _LineRow {
  String? accountId;
  String? costCenterId;
  final debitCtrl = TextEditingController();
  final creditCtrl = TextEditingController();

  double get debit => double.tryParse(debitCtrl.text.trim()) ?? 0;
  double get credit => double.tryParse(creditCtrl.text.trim()) ?? 0;

  void dispose() {
    debitCtrl.dispose();
    creditCtrl.dispose();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Alta / edición de cuenta contable
// ─────────────────────────────────────────────────────────────────────────────

class AccountFormResult {
  final String? id;
  final String code;
  final String name;
  final String accountType;
  final String? parentId;
  final bool isPostable;

  const AccountFormResult({
    this.id,
    required this.code,
    required this.name,
    required this.accountType,
    this.parentId,
    required this.isPostable,
  });
}

Future<AccountFormResult?> showAccountFormDialog(
  BuildContext context, {
  AccountingAccount? account,
  required List<AccountingAccount> accounts,
}) {
  return showDialog<AccountFormResult>(
    context: context,
    builder: (_) => _AccountFormDialog(account: account, accounts: accounts),
  );
}

class _AccountFormDialog extends StatefulWidget {
  final AccountingAccount? account;
  final List<AccountingAccount> accounts;

  const _AccountFormDialog({this.account, required this.accounts});

  @override
  State<_AccountFormDialog> createState() => _AccountFormDialogState();
}

class _AccountFormDialogState extends State<_AccountFormDialog> {
  late final TextEditingController _codeCtrl;
  late final TextEditingController _nameCtrl;
  late String _type;
  String? _parentId;
  late bool _isPostable;

  @override
  void initState() {
    super.initState();
    final a = widget.account;
    _codeCtrl = TextEditingController(text: a?.code ?? '');
    _nameCtrl = TextEditingController(text: a?.name ?? '');
    _type = a?.type.code ?? 'expense';
    _parentId = a?.parentId;
    _isPostable = a?.isPostable ?? true;
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.accounts
        .where((a) => !a.isPostable && a.id != widget.account?.id)
        .toList();

    return AlertDialog(
      title: Text(widget.account == null ? 'Nueva cuenta' : 'Editar cuenta'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _codeCtrl,
              decoration: const InputDecoration(
                labelText: 'Código',
                helperText: 'Dos dígitos por nivel: 1 → 11 → 1101 → 110101',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Nombre',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(
                labelText: 'Naturaleza',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final t in AccountType.values)
                  DropdownMenuItem(value: t.code, child: Text(t.label)),
              ],
              onChanged: (v) => setState(() => _type = v ?? 'expense'),
            ),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<String>(
              initialValue: _parentId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Cuenta padre',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('Sin padre')),
                for (final g in groups)
                  DropdownMenuItem(
                    value: g.id,
                    child: Text('${g.code} · ${g.name}',
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _parentId = v),
            ),
            const SizedBox(height: AppSpacing.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isPostable,
              title: const Text('Admite asientos'),
              subtitle: const Text(
                  'Apágalo si la cuenta solo agrupa a otras en los reportes.'),
              onChanged: (v) => setState(() => _isPostable = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            if (_codeCtrl.text.trim().isEmpty ||
                _nameCtrl.text.trim().isEmpty) {
              return;
            }
            Navigator.of(context).pop(AccountFormResult(
              id: widget.account?.id,
              code: _codeCtrl.text.trim(),
              name: _nameCtrl.text.trim(),
              accountType: _type,
              parentId: _parentId,
              isPostable: _isPostable,
            ));
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Alta / edición de centro de costo
// ─────────────────────────────────────────────────────────────────────────────

class CostCenterFormResult {
  final String? id;
  final String code;
  final String name;
  final String kind;

  const CostCenterFormResult({
    this.id,
    required this.code,
    required this.name,
    required this.kind,
  });
}

Future<CostCenterFormResult?> showCostCenterDialog(
  BuildContext context, {
  AccountingCostCenter? costCenter,
}) {
  final codeCtrl = TextEditingController(text: costCenter?.code ?? '');
  final nameCtrl = TextEditingController(text: costCenter?.name ?? '');
  var kind = costCenter?.kind ?? 'cost_center';

  return showDialog<CostCenterFormResult>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(costCenter == null
            ? 'Nuevo centro de costo'
            : 'Editar centro de costo'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: codeCtrl,
                decoration: const InputDecoration(
                  labelText: 'Código',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Nombre',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
                initialValue: kind,
                decoration: const InputDecoration(
                  labelText: 'Tipo',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                      value: 'cost_center', child: Text('Centro de costo')),
                  DropdownMenuItem(
                      value: 'department', child: Text('Departamento')),
                  DropdownMenuItem(value: 'project', child: Text('Proyecto')),
                  DropdownMenuItem(value: 'branch', child: Text('Sucursal')),
                ],
                onChanged: (v) => setState(() => kind = v ?? 'cost_center'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              if (codeCtrl.text.trim().isEmpty ||
                  nameCtrl.text.trim().isEmpty) {
                return;
              }
              Navigator.of(ctx).pop(CostCenterFormResult(
                id: costCenter?.id,
                code: codeCtrl.text.trim(),
                name: nameCtrl.text.trim(),
                kind: kind,
              ));
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    ),
  );
}
