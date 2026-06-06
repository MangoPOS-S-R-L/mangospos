import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/presentation/cashier/services/print_service.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/presentation/cashier/state/cash_close_formatters.dart';
import 'package:mangopos/presentation/cashier/widgets/close_summary_table.dart';

/// Paso de resultado post-firma. Aparece sólo después de que
/// `onCloseConfirmed` retorna OK.
///
/// Comportamiento:
///   - Auto-imprime el ticket de cierre una sola vez al montar.
///   - Muestra un botón "Reimprimir" para volver a imprimir si hace falta.
///   - El cierre del modal lo maneja el wizard via su footer "Cerrar".
class StepResult extends StatefulWidget {
  const StepResult({
    super.key,
    required this.input,
    required this.result,
    required this.denominations,
    required this.onClose,
    this.cashRegisterSessionId,
    this.canRecount = false,
    this.onRecount,
  });

  final CashCloseInput input;
  final CashCloseResult result;
  final List<DenominationCount> denominations;
  final VoidCallback onClose;

  /// Id de la sesión de caja. Si está presente, el ticket de cierre
  /// consulta `audit_logs` para contar cuántas veces el cajero recontó
  /// antes de firmar y muestra esa estadística en el reporte.
  final String? cashRegisterSessionId;

  /// Cuando true, después del auto-print aparece un botón "Volver a
  /// contar" que dispara [onRecount]. Solo lo controla el wizard padre
  /// — combina el toggle `allow_recount` del business con el límite de
  /// máximo 1 reconteo por sesión.
  final bool canRecount;
  final VoidCallback? onRecount;

  @override
  State<StepResult> createState() => _StepResultState();
}

class _StepResultState extends State<StepResult> {
  bool _printing = false;
  bool _autoPrintTried = false;
  String? _lastPrintError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_autoPrintTried) {
        _autoPrintTried = true;
        _printTicket(silent: true);
      }
    });
  }

  Future<void> _printTicket({bool silent = false}) async {
    if (_printing) return;
    setState(() {
      _printing = true;
      _lastPrintError = null;
    });
    try {
      final client = Supabase.instance.client;
      // Carga el count de reconteos para enriquecer el ticket. Solo se
      // ejecuta si tenemos el sessionId — para reimpresiones sin
      // contexto (improbable) defaultea a 0 y no se imprime la línea.
      int recountCount = 0;
      final sessionId = widget.cashRegisterSessionId;
      if (sessionId != null && sessionId.isNotEmpty) {
        recountCount = await PosSettingsRepository(client)
            .getCashRecountCount(sessionId);
      }
      final service = CashClosePrintService(client);
      await service.printCloseTicket(
        input: widget.input,
        result: widget.result,
        denominations: widget.denominations,
        printedAt: DateTime.now(),
        recountCount: recountCount,
        sessionId: sessionId,
      );
      if (!mounted) return;
      if (!silent) {
        AppToast.success(context, 'Cierre reimpreso correctamente');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastPrintError = e.toString();
      });
      if (!silent) {
        AppToast.error(context, 'No se pudo imprimir: $e');
      }
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final input = widget.input;
    final Color statusColor;
    final String statusText;
    final IconData statusIcon;
    if (result.isBalanced) {
      statusColor = MangoColors.successGreen;
      statusText = 'Caja cuadrada';
      statusIcon = Icons.check_circle_outline;
    } else if (result.hasSurplus) {
      statusColor = const Color(0xFFB45309);
      statusText = 'Sobrante detectado';
      statusIcon = Icons.warning_amber_rounded;
    } else {
      statusColor = const Color(0xFFA32D2D);
      statusText = 'Faltante detectado';
      statusIcon = Icons.error_outline;
    }
    final statusDetail = result.isBalanced
        ? 'Efectivo, tarjetas y transferencias coinciden con lo esperado.'
        : '${result.hasSurplus ? 'A favor' : 'En contra'}: ${formatRD(result.totalDifference.abs())}';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: statusColor.withValues(alpha: 0.3)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(statusIcon, color: statusColor, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        statusText,
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        statusDetail,
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.w500,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_printing)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          if (_lastPrintError != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFFFFEBEE),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFA32D2D)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.print_disabled_outlined,
                    color: Color(0xFFA32D2D),
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No se pudo imprimir automáticamente. Usa "Reimprimir" para reintentar.',
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
          const SizedBox(height: 12),
          CloseSummaryTable(input: input, result: result),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final cards = [
                _StatCard(
                  title: 'Total ventas',
                  value: formatRD(input.totalSales),
                ),
                _StatCard(
                  title: 'Transacciones',
                  value: input.transactionCount.toString(),
                ),
                _StatCard(
                  title: 'Monto inicial',
                  value: formatRD(input.startAmount),
                ),
                _StatCard(
                  title: 'Monto a depositar',
                  value: formatRD(result.totalCounted - input.startAmount),
                  highlight: true,
                ),
              ];
              return Row(
                children: [
                  for (var i = 0; i < cards.length; i++) ...[
                    Expanded(child: cards[i]),
                    if (i < cards.length - 1) const SizedBox(width: 8),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _printing ? null : () => _printTicket(),
                icon: const Icon(Icons.print_outlined, size: 16),
                label: const Text('Reimprimir'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: MangoColors.darkGray,
                  side: const BorderSide(color: MangoColors.cardBorder),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  textStyle: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              if (widget.canRecount && widget.onRecount != null) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: widget.onRecount,
                  icon: const Icon(Icons.replay_rounded, size: 16),
                  label: const Text('Volver a contar'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: MangoColors.primaryOrange,
                    side: const BorderSide(
                      color: MangoColors.primaryOrange,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    textStyle: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.value,
    this.highlight = false,
  });

  final String title;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: highlight ? const Color(0xFFFAEEDA) : MangoColors.bgLight,
        borderRadius: BorderRadius.circular(10),
        border: highlight
            ? null
            : Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 11,
              letterSpacing: 0.4,
              color: MangoColors.muted,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: highlight ? 18 : 15,
              color: highlight
                  ? MangoColors.primaryOrange
                  : MangoColors.darkGray,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
