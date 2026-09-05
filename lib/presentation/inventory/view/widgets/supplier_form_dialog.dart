// Alta y edición de un proveedor.
//
// Vivía dentro de `suppliers_view.dart`; desde la Fase 3 se abre también
// desde el interior del proveedor («Editar» en el encabezado): dos pantallas
// con el mismo formulario, un solo archivo.
//
// Lo que cambia respecto del formulario anterior son dos campos que eran
// texto libre y ahora se eligen:
//
//   1. **Condiciones de pago.** Antes se escribía «30 dias», «contado» o
//      «50% anticipo» a mano, y nada podía calcular un vencimiento. Ahora se
//      elige el tipo y —si es crédito— el plazo y desde cuándo cuenta. El
//      texto libre NO desaparece: queda como nota para los casos que no son
//      un plazo simple («2/10 neto 30»).
//   2. **RNC.** Se formatea y se avisa si ya existe en otra ficha del mismo
//      negocio. Ese número va a la factura fiscal: un duplicado es el mismo
//      contribuyente cargado dos veces, no un typo.
//
// Cuando la migración 20260819_0003 no está aplicada el bloque estructurado
// no se muestra y el formulario se comporta exactamente como antes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../data/repositories/suppliers_repository.dart';
import '../../state/inventory_state.dart';
import '../../state/supplier_overview_state.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

/// Abre el formulario. Devuelve `true` si se guardó algo.
Future<bool> showSupplierFormDialog(
  BuildContext context, {
  required String businessId,
  required SuppliersRepository repo,
  InventorySupplierDetail? edit,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        SupplierFormDialog(businessId: businessId, repo: repo, edit: edit),
  );
  return saved == true;
}

class SupplierFormDialog extends StatefulWidget {
  final String businessId;
  final SuppliersRepository repo;
  final InventorySupplierDetail? edit;

  const SupplierFormDialog({
    super.key,
    required this.businessId,
    required this.repo,
    this.edit,
  });

  @override
  State<SupplierFormDialog> createState() => _SupplierFormDialogState();
}

class _SupplierFormDialogState extends State<SupplierFormDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _rncCtrl;
  late final TextEditingController _contactCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _addressCtrl;
  late final TextEditingController _termsCtrl;
  late final TextEditingController _notesCtrl;
  late final TextEditingController _daysCtrl;
  late final TextEditingController _minOrderCtrl;
  late final TextEditingController _leadCtrl;

  SupplierTermsType? _termsType;
  SupplierTermsBase _termsBase = SupplierTermsBase.invoice;
  late bool _isActive;
  bool _saving = false;
  String? _error;

  /// Nombres de las otras fichas con el mismo RNC. Es aviso, no bloqueo: hay
  /// negocios que cargan la misma razón social dos veces a propósito (dos
  /// sucursales del mismo suplidor) y el dueño decide.
  List<String> _rncDupes = const [];
  bool _checkingRnc = false;

  bool get _isEdit => widget.edit != null;

  /// Plazos que se ofrecen de un toque. Los mismos que ya usa el registro de
  /// compras para el vencimiento de la cuenta por pagar.
  static const _offeredDays = <int>[15, 30, 45, 60];

  @override
  void initState() {
    super.initState();
    final e = widget.edit;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _rncCtrl = TextEditingController(text: e?.rnc ?? '');
    _contactCtrl = TextEditingController(text: e?.contactName ?? '');
    _phoneCtrl = TextEditingController(text: e?.phone ?? '');
    _emailCtrl = TextEditingController(text: e?.email ?? '');
    _addressCtrl = TextEditingController(text: e?.address ?? '');
    _termsCtrl = TextEditingController(text: e?.paymentTerms ?? '');
    _notesCtrl = TextEditingController(text: e?.notes ?? '');
    _minOrderCtrl = TextEditingController(
      text: e?.minOrderAmount == null ? '' : _trimZeros(e!.minOrderAmount!),
    );
    _leadCtrl = TextEditingController(text: e?.leadTimeDays?.toString() ?? '');
    _isActive = e?.isActive ?? true;

    // Se PRECARGA lo que ya se puede deducir del texto libre. Al abrir la
    // ficha de un proveedor viejo con «30 dias» escrito a mano, el formulario
    // llega con Crédito · 30 días marcado: confirmar es un clic y el dato
    // deja de ser una cadena.
    final terms = e == null
        ? SupplierTerms.unknown
        : SupplierTerms.fromSupplier(e);
    _termsType = terms.type;
    _termsBase = terms.base;
    _daysCtrl = TextEditingController(
      text: terms.type == SupplierTermsType.credito && (terms.days ?? 0) > 0
          ? terms.days.toString()
          : '',
    );
  }

  static String _trimZeros(double value) {
    final text = value.toStringAsFixed(2);
    return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _rncCtrl.dispose();
    _contactCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _addressCtrl.dispose();
    _termsCtrl.dispose();
    _notesCtrl.dispose();
    _daysCtrl.dispose();
    _minOrderCtrl.dispose();
    _leadCtrl.dispose();
    super.dispose();
  }

  String? _orNull(String v) => v.trim().isEmpty ? null : v.trim();

  double? _amountOrNull(String v) {
    final clean = v.trim().replaceAll(',', '');
    if (clean.isEmpty) return null;
    return double.tryParse(clean);
  }

  Future<void> _checkRnc() async {
    final rnc = _rncCtrl.text.trim();
    if (rnc.isEmpty) {
      if (mounted) setState(() => _rncDupes = const []);
      return;
    }
    setState(() => _checkingRnc = true);
    final dupes = await widget.repo.findRncDuplicates(
      businessId: widget.businessId,
      rnc: rnc,
      exceptId: widget.edit?.id,
    );
    if (!mounted) return;
    setState(() {
      _rncDupes = dupes;
      _checkingRnc = false;
    });
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'El nombre es obligatorio.');
      return;
    }

    int? days;
    if (_termsType == SupplierTermsType.credito) {
      days = int.tryParse(_daysCtrl.text.trim());
      if (days == null || days <= 0 || days > 365) {
        setState(
          () => _error =
              'Un crédito necesita un plazo entre 1 y 365 días. Si no lo '
              'sabés todavía, dejá el tipo sin definir.',
        );
        return;
      }
    } else if (_termsType == SupplierTermsType.contado) {
      days = 0;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.repo.saveSupplier(
        businessId: widget.businessId,
        supplierId: widget.edit?.id,
        name: name,
        rnc: _orNull(_rncCtrl.text),
        contactName: _orNull(_contactCtrl.text),
        phone: _orNull(_phoneCtrl.text),
        email: _orNull(_emailCtrl.text),
        address: _orNull(_addressCtrl.text),
        paymentTerms: _orNull(_termsCtrl.text),
        notes: _orNull(_notesCtrl.text),
        isActive: _isActive,
        termsType: switch (_termsType) {
          SupplierTermsType.contado => 'contado',
          SupplierTermsType.credito => 'credito',
          SupplierTermsType.anticipo => 'anticipo',
          null => null,
        },
        termsDays: days,
        termsFrom: _termsType == SupplierTermsType.credito
            ? (_termsBase == SupplierTermsBase.receipt ? 'receipt' : 'invoice')
            : null,
        minOrderAmount: _amountOrNull(_minOrderCtrl.text),
        leadTimeDays: int.tryParse(_leadCtrl.text.trim()),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = FriendlyError.from(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final structured = widget.repo.termsSupported;

    return AlertDialog(
      title: Text(_isEdit ? 'Editar proveedor' : 'Nuevo proveedor'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: 'Nombre *'),
                autofocus: true,
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _rncCtrl,
                      onEditingComplete: _checkRnc,
                      onTapOutside: (_) => _checkRnc(),
                      decoration: InputDecoration(
                        labelText: 'RNC',
                        hintText: '000-00000-0',
                        suffixIcon: _checkingRnc
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _contactCtrl,
                      decoration: const InputDecoration(labelText: 'Contacto'),
                      textCapitalization: TextCapitalization.words,
                    ),
                  ),
                ],
              ),
              if (_rncDupes.isNotEmpty) ...[
                const SizedBox(height: 8),
                _Notice(
                  color: AppColors.warning,
                  icon: Icons.report_gmailerrorred_outlined,
                  text:
                      'Ese RNC ya está en ${_rncDupes.length == 1 ? 'la ficha' : 'las fichas'} '
                      'de ${_rncDupes.join(', ')}. Ese número va a la factura '
                      'fiscal: si es el mismo contribuyente, conviene una sola '
                      'ficha.',
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: 'Teléfono'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _addressCtrl,
                decoration: const InputDecoration(labelText: 'Dirección'),
                maxLines: 2,
              ),
              const SizedBox(height: 18),
              if (structured) ..._commercialBlock() else ..._legacyTermsBlock(),
              const SizedBox(height: 12),
              TextField(
                controller: _notesCtrl,
                decoration: const InputDecoration(labelText: 'Notas'),
                maxLines: 2,
              ),
              const SizedBox(height: 6),
              CheckboxListTile(
                value: _isActive,
                onChanged: (v) => setState(() => _isActive = v ?? true),
                title: const Text('Proveedor activo'),
                subtitle: Text(
                  'Un proveedor inactivo no aparece para crear órdenes, pero '
                  'su historial se conserva.',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.mutedForeground,
                  ),
                ),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                _Notice(
                  color: AppColors.destructive,
                  icon: Icons.error_outline,
                  text: _error!,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(_isEdit ? 'Guardar' : 'Crear'),
        ),
      ],
    );
  }

  // ── Condiciones estructuradas ───────────────────────────────────────────

  List<Widget> _commercialBlock() {
    final isCredit = _termsType == SupplierTermsType.credito;

    return [
      Row(
        children: [
          Icon(Icons.handshake_outlined, size: 17, color: AppColors.primary),
          const SizedBox(width: 7),
          Text(
            'Condiciones comerciales',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Text(
        'De acá salen los vencimientos de la cuenta por pagar. Sin tipo, la '
        'compra a crédito pide la fecha a mano.',
        style: TextStyle(fontSize: 11.5, color: AppColors.mutedForeground),
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _choice(
            label: 'Sin definir',
            selected: _termsType == null,
            color: AppColors.warning,
            onTap: () => setState(() => _termsType = null),
          ),
          _choice(
            label: 'Contado',
            selected: _termsType == SupplierTermsType.contado,
            color: AppColors.success,
            onTap: () => setState(() => _termsType = SupplierTermsType.contado),
          ),
          _choice(
            label: 'Crédito',
            selected: isCredit,
            color: AppColors.info,
            onTap: () => setState(() => _termsType = SupplierTermsType.credito),
          ),
          _choice(
            label: 'Anticipo',
            selected: _termsType == SupplierTermsType.anticipo,
            color: AppColors.reserved,
            onTap: () =>
                setState(() => _termsType = SupplierTermsType.anticipo),
          ),
        ],
      ),
      if (isCredit) ...[
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SizedBox(
              width: 120,
              child: TextField(
                controller: _daysCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Plazo (días)',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final d in _offeredDays)
                    _choice(
                      label: '$d d',
                      selected: _daysCtrl.text.trim() == '$d',
                      color: AppColors.info,
                      dense: true,
                      onTap: () => setState(() {
                        _daysCtrl.text = '$d';
                      }),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text(
              'Cuenta desde',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.mutedForeground,
              ),
            ),
            const SizedBox(width: 10),
            _choice(
              label: 'Factura',
              selected: _termsBase == SupplierTermsBase.invoice,
              color: AppColors.info,
              dense: true,
              onTap: () =>
                  setState(() => _termsBase = SupplierTermsBase.invoice),
            ),
            const SizedBox(width: 6),
            _choice(
              label: 'Recepción',
              selected: _termsBase == SupplierTermsBase.receipt,
              color: AppColors.info,
              dense: true,
              onTap: () =>
                  setState(() => _termsBase = SupplierTermsBase.receipt),
            ),
          ],
        ),
      ],
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _minOrderCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Mínimo de orden',
                hintText: 'Opcional',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _leadCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Entrega prometida (días)',
                hintText: 'Opcional',
                isDense: true,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _termsCtrl,
        decoration: const InputDecoration(
          labelText: 'Nota de condiciones',
          hintText: 'Ej: 50% anticipo y resto contra entrega',
          helperText: 'Para lo que no es un plazo simple. Se muestra literal.',
          isDense: true,
        ),
      ),
    ];
  }

  /// Esquema viejo: exactamente el campo de antes, sin promesas que la base
  /// no puede cumplir.
  List<Widget> _legacyTermsBlock() => [
    TextField(
      controller: _termsCtrl,
      decoration: const InputDecoration(
        labelText: 'Condiciones de pago',
        hintText: 'Ej: 30 días, contado, 50% anticipo',
      ),
    ),
    const SizedBox(height: 6),
    Text(
      'Este negocio todavía guarda las condiciones como texto. Con la '
      'migración 20260819_0003 aplicada se eligen y los vencimientos se '
      'calculan solos.',
      style: TextStyle(fontSize: 11.5, color: AppColors.mutedForeground),
    ),
  ];

  Widget _choice({
    required String label,
    required bool selected,
    required Color color,
    required VoidCallback onTap,
    bool dense = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        constraints: BoxConstraints(minHeight: dense ? 30 : 38),
        padding: EdgeInsets.symmetric(horizontal: dense ? 10 : 14, vertical: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.10) : AppColors.card,
          border: Border.all(
            color: selected ? color.withValues(alpha: 0.55) : AppColors.border,
            width: selected ? 1.4 : 1,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: dense ? 12 : 13,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            color: selected ? color : AppColors.foreground,
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String text;

  const _Notice({required this.color, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: AppColors.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
