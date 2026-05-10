import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mangopos/app/theme/mango_colors.dart';

import '../cash_close_detailed_wizard.dart';
import '../state/detailed_wizard_state.dart';

/// Diálogo de confirmación final del wizard detallado.
///
/// Sub-fase F · muestra resumen compacto de los 3 totales + total reportado +
/// aviso de inmutabilidad. Botones: Cancelar (foco por defecto) / Sí, firmar.
///
/// Comportamiento:
/// - El primer foco va a "Cancelar" (deliberado: Enter accidental no firma).
/// - Esc cierra el diálogo (equivalente a Cancelar).
/// - Al confirmar: invoca `onConfirm`. Si éxito, hace pop con `true`. Si
///   throws, muestra error inline y permite reintentar (no descarta el conteo).
class ConfirmCloseDialog extends StatefulWidget {
  const ConfirmCloseDialog({
    super.key,
    required this.snapshot,
    this.onConfirm,
  });

  final DetailedWizardSnapshot snapshot;
  final DetailedCloseHandler? onConfirm;

  @override
  State<ConfirmCloseDialog> createState() => _ConfirmCloseDialogState();
}

class _ConfirmCloseDialogState extends State<ConfirmCloseDialog> {
  bool _loading = false;
  String? _error;

  Future<void> _confirm() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final handler = widget.onConfirm;
      if (handler != null) {
        await handler(widget.snapshot);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _humanize(e);
      });
    }
  }

  void _cancel() {
    if (_loading) return;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape):
            _loading ? () {} : _cancel,
      },
      child: _buildDialog(s),
    );
  }

  Widget _buildDialog(DetailedWizardSnapshot s) {
    return AlertDialog(
      backgroundColor: MangoColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      title: const Text(
        '¿Desea enviar el conteo?',
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 18,
          color: MangoColors.darkGray,
        ),
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _row('Efectivo', 'RD\$ ${_formatInt(s.cashAmount)}'),
            const SizedBox(height: 6),
            _row('Tarjeta', 'RD\$ ${_formatInt(s.cardAmount.round())}'),
            const SizedBox(height: 6),
            _row('Transferencia', 'RD\$ ${_formatInt(s.transferAmount.round())}'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFAEEDA),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Total reportado',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: MangoColors.darkGray,
                      ),
                    ),
                  ),
                  Text(
                    'RD\$ ${_formatInt(s.result.totalReported.round())}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: MangoColors.darkGray,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Esta acción no se puede deshacer. La conciliación contra el sistema la verá únicamente el supervisor.',
              style: TextStyle(
                color: MangoColors.muted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFEBEE),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFA32D2D)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Color(0xFFA32D2D),
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: Color(0xFFA32D2D),
                          fontSize: 12,
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
          autofocus: true,
          onPressed: _cancel,
          style: TextButton.styleFrom(
            foregroundColor: MangoColors.darkGray,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _loading ? null : _confirm,
          style: ElevatedButton.styleFrom(
            backgroundColor: MangoColors.successGreen,
            foregroundColor: MangoColors.white,
            disabledBackgroundColor: MangoColors.cardBorder,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(MangoColors.white),
                  ),
                )
              : const Text(
                  'Sí, firmar y cerrar',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
        ),
      ],
    );
  }

  Widget _row(String label, String value) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, color: MangoColors.darkGray),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: MangoColors.darkGray,
          ),
        ),
      ],
    );
  }
}

String _formatInt(int v) {
  final s = v.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

String _humanize(Object e) {
  final raw = e.toString();
  if (raw.contains('OPEN_TABLES_EXIST')) {
    return 'Hay órdenes abiertas. Ciérralas o anúlalas antes de cerrar caja.';
  }
  if (raw.contains('SESSION_ALREADY_CLOSED')) {
    return 'Esta sesión de caja ya fue cerrada.';
  }
  if (raw.contains('SESSION_NOT_FOUND')) {
    return 'No se encontró la sesión de caja.';
  }
  if (raw.contains('cash_count_blind is immutable')) {
    return 'Este conteo ya fue firmado y no se puede modificar.';
  }
  return 'No se pudo cerrar la caja: $raw';
}
