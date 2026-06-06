// lib/presentation/settings/cash_reasons/view/cash_reasons_view.dart
//
// Ajustes → Razones de Ingresos y Egresos. CRUD del catálogo
// `cash_transaction_reasons`. El cajero las elige al registrar un
// movimiento manual de caja (depósito, retiro o gasto).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/presentation/settings/cash_reasons/viewmodel/cash_reasons_viewmodel.dart';

class CashReasonsView extends ConsumerStatefulWidget {
  /// 'auto' o un UUID concreto del negocio. El VM lo resuelve antes de
  /// consultar.
  final String businessId;
  const CashReasonsView({super.key, required this.businessId});

  @override
  ConsumerState<CashReasonsView> createState() => _CashReasonsViewState();
}

class _CashReasonsViewState extends ConsumerState<CashReasonsView> {
  // null = todas; sino filtra por applies_to.
  String? _filter;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref
          .read(cashReasonsVmProvider.notifier)
          .load(businessId: widget.businessId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cashReasonsVmProvider);
    final text = Theme.of(context).textTheme;

    final visible = _filter == null
        ? state.items
        : state.items
            .where((r) => r.appliesTo == _filter || r.appliesTo == null)
            .toList(growable: false);

    return Scaffold(
      backgroundColor: MangoColors.sidebarBg,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoutes.settings),
        ),
        title: const Text('Razones de Ingresos y Egresos'),
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: .4,
        actions: [
          IconButton(
            tooltip: 'Refrescar',
            onPressed: () => ref
                .read(cashReasonsVmProvider.notifier)
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
                builder: (_) => const _CashReasonDialog(),
              );
            },
            icon: const Icon(Icons.add),
            label: const Text('Agregar razón'),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Catálogo de razones',
              style: text.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Cuando el cajero registra un movimiento de caja '
              '(ingreso, retiro o gasto), debe elegir una razón de esta '
              'lista. Sirve para auditoría y reportes. Si una razón '
              '"requiere PIN", el supervisor tendrá que autorizarla sin '
              'importar el monto.',
              style: text.bodySmall?.copyWith(color: MangoColors.muted),
            ),
            const SizedBox(height: 12),
            _FilterChips(
              value: _filter,
              onChanged: (v) => setState(() => _filter = v),
            ),
            const SizedBox(height: 12),
            if (state.errorMessage != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFFCA5A5)),
                ),
                child: Text(
                  state.errorMessage!,
                  style: const TextStyle(color: Color(0xFF991B1B)),
                ),
              ),
            if (state.isLoading && state.items.isEmpty)
              const Expanded(
                child: Center(
                  child: CircularProgressIndicator(
                    color: MangoColors.primaryOrange,
                  ),
                ),
              )
            else if (visible.isEmpty)
              const Expanded(child: _EmptyState())
            else
              Expanded(child: _ReasonsList(items: visible)),
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

class _FilterChips extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  const _FilterChips({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final entries = <MapEntry<String?, String>>[
      const MapEntry(null, 'Todas'),
      const MapEntry('deposit', 'Ingresos'),
      const MapEntry('withdrawal', 'Retiros'),
      const MapEntry('expense', 'Gastos'),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: entries.map((e) {
        final selected = value == e.key;
        return ChoiceChip(
          label: Text(e.value),
          selected: selected,
          onSelected: (_) => onChanged(e.key),
          selectedColor: MangoColors.primaryOrange.withValues(alpha: 0.18),
          labelStyle: TextStyle(
            color: selected ? MangoColors.primaryOrange : MangoColors.darkGray,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: selected
                  ? MangoColors.primaryOrange
                  : MangoColors.cardBorder,
            ),
          ),
        );
      }).toList(growable: false),
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
        children: const [
          Icon(Icons.list_alt_outlined, size: 56, color: Colors.black26),
          SizedBox(height: 12),
          Text(
            'No hay razones configuradas',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: MangoColors.darkGray,
            ),
          ),
          SizedBox(height: 6),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Agrega tu primera razón para que el cajero pueda elegirla '
              'al registrar movimientos manuales de caja.',
              textAlign: TextAlign.center,
              style: TextStyle(color: MangoColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReasonsList extends ConsumerWidget {
  final List<CashReason> items;
  const _ReasonsList({required this.items});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.builder(
      itemCount: items.length,
      padding: EdgeInsets.zero,
      itemBuilder: (ctx, i) {
        final r = items[i];
        return Padding(
          key: ValueKey('reason-${r.id}'),
          padding: const EdgeInsets.only(bottom: 12),
          child: _ReasonCard(reason: r),
        );
      },
    );
  }
}

class _ReasonCard extends ConsumerWidget {
  final CashReason reason;
  const _ReasonCard({required this.reason});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final inactiveBg = const Color(0xFFFAFAFA);
    final appliesColor = _appliesColor(reason.appliesTo);

    return Card(
      elevation: 0,
      color: reason.isActive ? Colors.white : inactiveBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: MangoColors.cardBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          reason.label,
                          style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: MangoColors.darkGray,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _Pill(
                        label: reason.appliesToDisplay,
                        color: appliesColor,
                      ),
                      if (reason.requiresPin) ...[
                        const SizedBox(width: 6),
                        const _Pill(
                          label: 'PIN',
                          color: Color(0xFFEA580C),
                        ),
                      ],
                      if (!reason.isActive) ...[
                        const SizedBox(width: 6),
                        _Pill(label: 'Inactiva', color: Colors.red.shade400),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Código: ${reason.code}',
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
                final notifier = ref.read(cashReasonsVmProvider.notifier);
                if (v == 'edit') {
                  await showDialog(
                    context: context,
                    builder: (_) => _CashReasonDialog(initial: reason),
                  );
                } else if (v == 'toggle') {
                  await notifier.toggleActive(reason.id, !reason.isActive);
                } else if (v == 'delete') {
                  final ok = await _confirmDelete(context, reason);
                  if (ok != true) return;
                  await notifier.remove(reason.id);
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
                      reason.isActive
                          ? Icons.visibility_off
                          : Icons.visibility,
                      size: 18,
                      color: MangoColors.darkGray,
                    ),
                    const SizedBox(width: 12),
                    Text(reason.isActive ? 'Desactivar' : 'Activar'),
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

  Color _appliesColor(String? appliesTo) {
    switch (appliesTo) {
      case 'deposit':
        return const Color(0xFF22C55E);
      case 'withdrawal':
        return const Color(0xFF3B82F6);
      case 'expense':
        return const Color(0xFFEF4444);
      default:
        return MangoColors.muted;
    }
  }

  Future<bool?> _confirmDelete(BuildContext context, CashReason r) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Eliminar razón'),
        content: Text(
          '¿Eliminar la razón "${r.label}"? Los movimientos que la '
          'usaron seguirán existiendo y conservarán el código '
          '"${r.code}" para reportes.',
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

class _CashReasonDialog extends ConsumerStatefulWidget {
  final CashReason? initial;
  const _CashReasonDialog({this.initial});

  @override
  ConsumerState<_CashReasonDialog> createState() => _CashReasonDialogState();
}

class _CashReasonDialogState extends ConsumerState<_CashReasonDialog> {
  late final TextEditingController _codeCtrl;
  late final TextEditingController _labelCtrl;
  // null = universal
  late String? _appliesTo;
  late bool _requiresPin;
  bool _isSaving = false;
  // Cuando estamos creando y el usuario no tocó el código aún, lo
  // autogeneramos a partir del label para que sea cómodo.
  bool _codeManuallyEdited = false;

  bool get _isEdit => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _codeCtrl = TextEditingController(text: r?.code ?? '');
    _labelCtrl = TextEditingController(text: r?.label ?? '');
    _appliesTo = r?.appliesTo;
    _requiresPin = r?.requiresPin ?? false;

    if (!_isEdit) {
      _labelCtrl.addListener(_syncCodeFromLabel);
    }
  }

  void _syncCodeFromLabel() {
    if (_codeManuallyEdited) return;
    _codeCtrl.value = TextEditingValue(
      text: _slugify(_labelCtrl.text),
      selection: TextSelection.collapsed(
        offset: _slugify(_labelCtrl.text).length,
      ),
    );
  }

  String _slugify(String s) {
    final lower = s.toLowerCase().trim();
    final replaced = lower
        .replaceAll(RegExp(r'[áàä]'), 'a')
        .replaceAll(RegExp(r'[éèë]'), 'e')
        .replaceAll(RegExp(r'[íìï]'), 'i')
        .replaceAll(RegExp(r'[óòö]'), 'o')
        .replaceAll(RegExp(r'[úùü]'), 'u')
        .replaceAll('ñ', 'n')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return replaced;
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _codeCtrl.text.trim();
    final label = _labelCtrl.text.trim();
    if (code.isEmpty || label.isEmpty) {
      AppToast.info(context, 'Código y etiqueta son obligatorios.');
      return;
    }
    setState(() => _isSaving = true);
    final notifier = ref.read(cashReasonsVmProvider.notifier);
    bool ok = false;
    try {
      if (_isEdit) {
        ok = await notifier.update(
          id: widget.initial!.id,
          label: label,
          appliesTo: _appliesTo,
          clearAppliesTo: _appliesTo == null,
          requiresPin: _requiresPin,
        );
      } else {
        ok = await notifier.create(
          code: code,
          label: label,
          appliesTo: _appliesTo,
          requiresPin: _requiresPin,
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
      title: Text(_isEdit ? 'Editar razón' : 'Agregar razón'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label('Etiqueta *'),
              _txt(
                _labelCtrl,
                hint: 'Ej. Pago a proveedor en efectivo',
              ),
              const SizedBox(height: 12),
              _label('Código *'),
              _txt(
                _codeCtrl,
                hint: 'Ej. supplier_cash',
                enabled: !_isEdit,
                onChanged: (_) {
                  if (!_isEdit) _codeManuallyEdited = true;
                },
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                    RegExp(r'[a-zA-Z0-9_]'),
                  ),
                ],
              ),
              if (_isEdit)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'El código no se puede cambiar para preservar el '
                    'historial de reportes.',
                    style: TextStyle(
                      fontSize: 11,
                      color: MangoColors.muted,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              _label('Aplica a'),
              DropdownButtonFormField<String?>(
                initialValue: _appliesTo,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                ),
                items: const [
                  DropdownMenuItem(
                      value: null, child: Text('Universal (cualquier tipo)')),
                  DropdownMenuItem(
                      value: 'deposit', child: Text('Ingreso (deposit)')),
                  DropdownMenuItem(
                      value: 'withdrawal',
                      child: Text('Retiro (withdrawal)')),
                  DropdownMenuItem(
                      value: 'expense', child: Text('Gasto (expense)')),
                ],
                onChanged: (v) => setState(() => _appliesTo = v),
              ),
              const SizedBox(height: 12),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _requiresPin,
                onChanged: (v) => setState(() => _requiresPin = v),
                title: const Text(
                  'Requiere PIN de supervisor',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Si está activo, cualquier movimiento con esta razón '
                  'pedirá PIN sin importar el monto.',
                  style: TextStyle(color: MangoColors.muted, fontSize: 12),
                ),
                activeThumbColor: MangoColors.primaryOrange,
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
    bool enabled = true,
    ValueChanged<String>? onChanged,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return TextField(
      controller: c,
      enabled: enabled,
      onChanged: onChanged,
      inputFormatters: inputFormatters,
      decoration: InputDecoration(
        hintText: hint,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        filled: !enabled,
        fillColor: enabled ? null : const Color(0xFFF5F5F5),
      ),
    );
  }
}
