// Modal para quitar impuestos de UNA orden puntual (estilo Square POS).
//
// Caso real: el negocio cobra ITBIS 18% + Propina Ley 10%, el cliente pide
// que le quiten la propina. Hasta ahora la única salida era editar el
// catálogo del producto — que afecta a TODAS las ventas, no a esta.
//
// QUIÉN MANDA: el backend. Al confirmar se llama
// `fn_set_order_excluded_taxes`, que re-resuelve la tasa de cada item,
// repuebla `order_item_tax_lines` y recalcula los totales de la orden. Este
// widget no calcula un solo centavo: los montos que muestra son una
// PREVISUALIZACIÓN sobre el subtotal vigente, y lo que se cobra sale de la
// recarga posterior.
//
// El aviso del ITBIS es deliberado. La decisión del dueño (2026-08-13) fue
// permitir quitar cualquier impuesto, igual que Square. Pero en RD quitar el
// ITBIS de un comprobante con NCF es una declaración a la DGII, no una
// preferencia de UI — así que se avisa en el momento y la exclusión queda
// auditada (quién y cuándo) en `order_excluded_taxes`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/tax/tax_engine.dart';

/// Muestra el modal. Devuelve el conjunto final de `taxes.id` excluidos si el
/// usuario confirmó, o null si canceló.
Future<Set<String>?> showOrderTaxesDialog({
  required BuildContext context,
  required List<TaxDef> taxes,
  required Set<String> excludedTaxIds,
  required double subtotal,
  required NumberFormat currency,
  bool readOnly = false,
  String? readOnlyReason,
}) {
  return showDialog<Set<String>>(
    context: context,
    builder: (_) => _OrderTaxesDialog(
      taxes: taxes,
      excludedTaxIds: excludedTaxIds,
      subtotal: subtotal,
      currency: currency,
      readOnly: readOnly,
      readOnlyReason: readOnlyReason,
    ),
  );
}

class _OrderTaxesDialog extends ConsumerStatefulWidget {
  const _OrderTaxesDialog({
    required this.taxes,
    required this.excludedTaxIds,
    required this.subtotal,
    required this.currency,
    required this.readOnly,
    this.readOnlyReason,
  });

  final List<TaxDef> taxes;
  final Set<String> excludedTaxIds;
  final double subtotal;
  final NumberFormat currency;
  final bool readOnly;
  final String? readOnlyReason;

  @override
  ConsumerState<_OrderTaxesDialog> createState() => _OrderTaxesDialogState();
}

class _OrderTaxesDialogState extends ConsumerState<_OrderTaxesDialog> {
  late Set<String> _excluded;

  @override
  void initState() {
    super.initState();
    _excluded = {...widget.excludedTaxIds};
  }

  bool _isApplied(TaxDef tax) => !_excluded.contains(tax.id);

  /// Heurística SOLO para el aviso visual. No bloquea nada: el dueño decidió
  /// que cualquier impuesto se puede quitar. Sirve para que el cajero sepa
  /// que ese en particular va declarado a la DGII.
  bool _isFiscal(TaxDef tax) => tax.includeInEcf && !tax.effectiveIsServiceFee;

  double get _appliedTotal => widget.taxes
      .where(_isApplied)
      .fold<double>(0, (sum, t) => sum + widget.subtotal * t.rateDecimal);

  @override
  Widget build(BuildContext context) {
    final removingFiscal = widget.taxes.any(
      (t) => !_isApplied(t) && _isFiscal(t),
    );

    return AlertDialog(
      title: const Text('Impuestos de esta orden'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.readOnly
                  ? (widget.readOnlyReason ??
                        'Esta orden ya no admite cambios.')
                  : 'Desmarca los que no quieras cobrar en esta orden. No '
                        'afecta el catálogo ni las demás ventas.',
              style: const TextStyle(fontSize: 13, color: MangoColors.muted),
            ),
            const SizedBox(height: 16),
            if (widget.taxes.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Este negocio no tiene impuestos configurados para este '
                  'tipo de venta.',
                  style: TextStyle(fontSize: 13),
                ),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final tax in widget.taxes)
                        _TaxRow(
                          tax: tax,
                          applied: _isApplied(tax),
                          amount: widget.subtotal * tax.rateDecimal,
                          currency: widget.currency,
                          isFiscal: _isFiscal(tax),
                          enabled: !widget.readOnly,
                          onChanged: (applied) => setState(() {
                            if (applied) {
                              _excluded.remove(tax.id);
                            } else {
                              _excluded.add(tax.id);
                            }
                          }),
                        ),
                    ],
                  ),
                ),
              ),
            if (widget.taxes.isNotEmpty) ...[
              const Divider(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Impuestos a cobrar',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    widget.currency.format(_appliedTotal),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ],
            if (removingFiscal && !widget.readOnly) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: Color(0xFFB45309),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Estás quitando un impuesto que se declara a la DGII. '
                        'La factura saldrá sin él y quedará registrado quién '
                        'lo quitó.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF92400E),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.readOnly ? 'Cerrar' : 'Cancelar'),
        ),
        if (!widget.readOnly)
          FilledButton(
            onPressed: widget.taxes.isEmpty
                ? null
                : () => Navigator.of(context).pop(_excluded),
            child: const Text('Aplicar'),
          ),
      ],
    );
  }
}

class _TaxRow extends StatelessWidget {
  const _TaxRow({
    required this.tax,
    required this.applied,
    required this.amount,
    required this.currency,
    required this.isFiscal,
    required this.enabled,
    required this.onChanged,
  });

  final TaxDef tax;
  final bool applied;
  final double amount;
  final NumberFormat currency;
  final bool isFiscal;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final pct = tax.rate.truncateToDouble() == tax.rate
        ? '${tax.rate.toInt()}%'
        : '${tax.rate}%';

    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: applied,
      onChanged: enabled ? onChanged : null,
      title: Row(
        children: [
          Flexible(
            child: Text(
              '${tax.name} ($pct)',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: applied ? null : MangoColors.muted,
                decoration: applied ? null : TextDecoration.lineThrough,
              ),
            ),
          ),
          if (isFiscal) ...[
            const SizedBox(width: 8),
            const Tooltip(
              message: 'Se declara a la DGII',
              child: Icon(
                Icons.account_balance_outlined,
                size: 14,
                color: MangoColors.muted,
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        applied ? currency.format(amount) : 'No se cobra',
        style: TextStyle(
          fontSize: 12,
          color: applied ? MangoColors.muted : const Color(0xFFB45309),
        ),
      ),
    );
  }
}
