// Popup del proceso de anulación de una venta con comprobante fiscal.
//
// POR QUÉ EXISTE:
//   Anular una factura electrónica dejó de ser un botón instantáneo. Detrás
//   pasan cuatro cosas —se anula la venta, se emite la NOTA DE CRÉDITO que la
//   reversa, se manda a la DGII y se imprime— y cada una puede tardar
//   segundos o quedarse a medias por su cuenta (falta la secuencia E34, la
//   DGII no responde, la impresora está apagada). Con un toast al final el
//   cajero no sabe si la nota salió, y la nota es justamente el documento que
//   el cliente tiene que llevarse.
//
//   El popup nombra los pasos y los va marcando. Lo mismo que hace
//   `PaymentProgressOverlay` con el cobro; se escribió aparte y no reusando
//   sus filas privadas para no tocar el camino de cobro, que es el más
//   sensible de la app.
//
// REGLA: el popup nunca convierte un problema de la nota en un error de la
// anulación. La venta anulada ya está anulada; si la nota queda pendiente se
// pinta ámbar y se dice qué hacer, no rojo.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../data/models/credit_note_result.dart';
import '../../../data/models/sales_models.dart';
import '../../../data/repositories/sales_repository.dart';
import '../../sales/viewmodel/sales_viewmodel.dart';
import '../utils/credit_note_printing.dart';

/// Resultado del proceso, para el call site.
class AnnulmentProcessOutcome {
  /// La venta se anuló (aunque la nota haya quedado pendiente).
  final bool annulled;

  /// Notas emitidas o intentadas, una por comprobante de la venta.
  final List<CreditNoteResult> creditNotes;

  /// Mensaje del error cuando la anulación misma falló.
  final String? error;

  const AnnulmentProcessOutcome({
    required this.annulled,
    this.creditNotes = const [],
    this.error,
  });
}

/// Abre el popup y corre el proceso completo: anula la venta y le emite su
/// nota de crédito. No lanza.
Future<AnnulmentProcessOutcome> showAnnulmentProcessDialog(
  BuildContext context,
  WidgetRef ref, {
  required String paymentId,
  required String orderId,
  String? checkId,
  required String reason,
}) async {
  final outcome = await showDialog<AnnulmentProcessOutcome>(
    context: context,
    // Sin barrera: cerrar a medias dejaría al cajero sin saber si la nota
    // salió. El diálogo se cierra con su propio botón, ya terminado.
    barrierDismissible: false,
    builder: (_) => _AnnulmentProcessDialog(
      paymentId: paymentId,
      orderId: orderId,
      checkId: checkId,
      reason: reason,
    ),
  );
  return outcome ?? const AnnulmentProcessOutcome(annulled: false);
}

/// Reintenta SOLO la nota de un comprobante que ya está anulado.
///
/// Es el camino de vuelta cuando la nota quedó pendiente (típico: faltaba la
/// secuencia E34). El RPC es idempotente, así que si la nota ya existía no se
/// emite otra: se reimprime la que hay.
Future<AnnulmentProcessOutcome> showCreditNoteRetryDialog(
  BuildContext context,
  WidgetRef ref, {
  required String fiscalDocumentId,
  required String reason,
}) async {
  final outcome = await showDialog<AnnulmentProcessOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AnnulmentProcessDialog(
      fiscalDocumentId: fiscalDocumentId,
      reason: reason,
    ),
  );
  return outcome ?? const AnnulmentProcessOutcome(annulled: false);
}

enum _StepState { pending, running, done, warned, failed, skipped }

class _StepData {
  _StepData(this.label);

  final String label;
  _StepState state = _StepState.pending;

  /// Renglón chico bajo la etiqueta: el NCF emitido, el estado de la DGII,
  /// el motivo por el que se saltó.
  String? detail;
}

class _AnnulmentProcessDialog extends ConsumerStatefulWidget {
  const _AnnulmentProcessDialog({
    this.paymentId,
    this.orderId,
    this.checkId,
    this.fiscalDocumentId,
    required this.reason,
  });

  /// Modo anulación: la venta a anular.
  final String? paymentId;
  final String? orderId;
  final String? checkId;

  /// Modo reintento: el comprobante YA anulado al que le falta la nota.
  final String? fiscalDocumentId;

  final String reason;

  bool get isRetry => fiscalDocumentId != null;

  @override
  ConsumerState<_AnnulmentProcessDialog> createState() =>
      _AnnulmentProcessDialogState();
}

class _AnnulmentProcessDialogState
    extends ConsumerState<_AnnulmentProcessDialog> {
  // En el reintento la venta YA está anulada: listar ese paso lo haría creer
  // que se va a anular otra vez.
  late final List<_StepData> _steps = [
    if (!widget.isRetry) _StepData('Anulando la venta'),
    _StepData('Emitiendo la nota de crédito'),
    _StepData('Enviando a la DGII'),
    _StepData('Imprimiendo la nota'),
  ];

  int get _kAnular => 0;
  int get _kNota => widget.isRetry ? 0 : 1;
  int get _kDgii => _kNota + 1;
  int get _kImprimir => _kNota + 2;

  bool _finished = false;
  String? _fatalError;
  final List<CreditNoteResult> _notes = [];

  @override
  void initState() {
    super.initState();
    // Después del primer frame: el proceso escribe estado y no puede correr
    // durante el build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _set(int index, _StepState state, {String? detail}) {
    if (!mounted) return;
    setState(() {
      _steps[index].state = state;
      if (detail != null) _steps[index].detail = detail;
    });
  }

  Future<void> _run() async {
    final repo = ref.read(salesRepositoryProvider);

    // ── 1. Anular ────────────────────────────────────────────────────────
    List<String> cancelledDocIds;
    if (widget.isRetry) {
      cancelledDocIds = [widget.fiscalDocumentId!];
    } else {
      _set(_kAnular, _StepState.running);
      try {
        cancelledDocIds = await repo.annulPayment(
          paymentId: widget.paymentId!,
          orderId: widget.orderId!,
          checkId: widget.checkId,
          reason: widget.reason,
        );
        _set(_kAnular, _StepState.done);
      } catch (e) {
        _set(_kAnular, _StepState.failed, detail: _clean(e.toString()));
        for (final i in [_kNota, _kDgii, _kImprimir]) {
          _set(i, _StepState.skipped, detail: 'No se ejecutó');
        }
        if (mounted) {
          setState(() {
            _finished = true;
            _fatalError = _clean(e.toString());
          });
        }
        return;
      }
    }

    // Venta sin comprobante fiscal: no hay nada que reversar y decirlo es
    // mejor que dejar tres pasos grises sin explicación.
    if (cancelledDocIds.isEmpty) {
      for (final i in [_kNota, _kDgii, _kImprimir]) {
        _set(i, _StepState.skipped, detail: 'La venta no tenía comprobante');
      }
      if (mounted) setState(() => _finished = true);
      return;
    }

    // ── 2. Nota de crédito ───────────────────────────────────────────────
    _set(_kNota, _StepState.running);
    for (final docId in cancelledDocIds) {
      _notes.add(
        await repo.issueCreditNote(
          fiscalDocumentId: docId,
          reason: widget.reason,
        ),
      );
    }

    final issued = _notes.where((n) => n.hasNote).toList();
    final pending = _notes.where((n) => n.needsAttention).toList();

    if (issued.isEmpty) {
      if (pending.isNotEmpty) {
        _set(_kNota, _StepState.warned, detail: pending.first.message);
      } else {
        _set(
          _kNota,
          _StepState.skipped,
          detail: _notes.isEmpty ? null : _notes.first.message,
        );
      }
      for (final i in [_kDgii, _kImprimir]) {
        _set(i, _StepState.skipped, detail: 'Sin nota que enviar');
      }
      if (mounted) setState(() => _finished = true);
      return;
    }

    _set(
      _kNota,
      pending.isEmpty ? _StepState.done : _StepState.warned,
      detail: issued.map((n) => n.ncfNumber ?? '').join('  '),
    );

    // ── 3. DGII ──────────────────────────────────────────────────────────
    // Solo las electrónicas viajan. La B04 de papel no tiene este paso y
    // decirlo evita que el cajero espere algo que no va a pasar.
    final electronic = issued.where((n) => n.isElectronic).toList();
    FiscalDocument? noteDoc;
    if (electronic.isEmpty) {
      _set(_kDgii, _StepState.skipped, detail: 'Nota de papel (B04)');
    } else {
      _set(_kDgii, _StepState.running);
      for (final note in electronic) {
        final id = note.creditNoteId;
        if (id == null || id.isEmpty) continue;
        final doc = await _pushToDgii(repo, id);
        noteDoc ??= doc;
      }
      final status = noteDoc?.ecfStatus ?? 'pending';
      switch (status) {
        case 'accepted':
          _set(_kDgii, _StepState.done, detail: 'Aceptada por la DGII');
        case 'sent':
          _set(
            _kDgii,
            _StepState.done,
            detail: 'Enviada. La DGII confirma en unos minutos.',
          );
        case 'rejected':
          _set(
            _kDgii,
            _StepState.warned,
            detail: _clean(noteDoc?.lastError ?? 'La DGII rechazó la nota'),
          );
        default:
          _set(
            _kDgii,
            _StepState.warned,
            detail: 'Todavía en cola. Se reenvía sola.',
          );
      }
    }

    // ── 4. Imprimir ──────────────────────────────────────────────────────
    // Una por nota: en un pago dividido la venta tiene un comprobante por
    // sub-cuenta, y cada uno se anula con SU nota. Imprimir solo la primera
    // dejaría al cliente con papel de una y nada de las otras.
    _set(_kImprimir, _StepState.running);
    var printed = 0;
    var failedPrints = 0;
    for (final note in issued) {
      final noteId = note.creditNoteId;
      if (noteId == null || noteId.isEmpty) continue;
      try {
        final doc = (noteDoc != null && noteDoc.id == noteId)
            ? noteDoc
            : await repo.getFiscalDocumentById(noteId);
        final original = await repo.getFiscalDocumentById(
          note.fiscalDocumentId,
        );
        if (doc == null || !mounted) {
          failedPrints++;
          continue;
        }
        final ok = await CreditNotePrinting.printThermal(
          context,
          ref,
          note: doc,
          originalNcf: original?.ncfNumber ?? note.originalNcf ?? '',
          originalIssuedAt: original?.issuedAt,
          reason: widget.reason,
        );
        if (ok) {
          printed++;
        } else {
          failedPrints++;
        }
      } catch (_) {
        failedPrints++;
      }
    }
    if (printed == 0) {
      _set(
        _kImprimir,
        _StepState.warned,
        detail: 'Reimprímela desde el historial',
      );
    } else {
      _set(
        _kImprimir,
        failedPrints == 0 ? _StepState.done : _StepState.warned,
        detail: failedPrints == 0
            ? (issued.length > 1 ? '$printed notas impresas' : null)
            : 'Faltó imprimir $failedPrints. Reimprímelas desde el historial.',
      );
    }

    if (mounted) setState(() => _finished = true);
  }

  /// Empuja la nota a la DGII y devuelve su fila actualizada.
  ///
  /// Mismo patrón que el cobro: `emit-document` en modo síncrono con timeout,
  /// y pase lo que pase se re-lee la fila. Si no alcanzó, el cron y el webhook
  /// terminan el trabajo — la nota YA está emitida y encolada.
  Future<FiscalDocument?> _pushToDgii(
    SalesRepository repo,
    String noteId,
  ) async {
    try {
      await Supabase.instance.client.functions
          .invoke('emit-document', body: {'fiscal_document_id': noteId})
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Timeout o error de red: la nota queda en la cola de emisión.
    }
    try {
      return await repo.getFiscalDocumentById(noteId);
    } catch (_) {
      return null;
    }
  }

  static String _clean(String raw) =>
      raw.replaceFirst('Exception: ', '').trim();

  @override
  Widget build(BuildContext context) {
    final warned = _steps.any((s) => s.state == _StepState.warned);
    final failed = _fatalError != null;

    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        failed
            ? 'No se pudo anular'
            : widget.isRetry
            ? (_finished ? 'Nota de crédito' : 'Emitiendo la nota')
            : (_finished ? 'Anulación completada' : 'Anulando la venta'),
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < _steps.length; i++)
              _StepRow(step: _steps[i], isLast: i == _steps.length - 1),
            if (_finished && (warned || failed)) ...[
              const SizedBox(height: AppSpacing.md),
              _Hint(
                text: failed
                    ? _fatalError!
                    : widget.isRetry
                    ? 'La nota todavía no quedó completa. Revisa el aviso de '
                          'arriba y vuelve a intentarlo.'
                    : 'La venta quedó anulada. Lo que falta de la nota se '
                          'resuelve desde el historial, sin volver a anular.',
                color: failed ? AppColors.destructive : AppColors.warning,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _finished
              ? () => Navigator.pop(
                  context,
                  AnnulmentProcessOutcome(
                    annulled: !failed,
                    creditNotes: List.unmodifiable(_notes),
                    error: _fatalError,
                  ),
                )
              : null,
          child: Text(_finished ? 'Listo' : 'Procesando...'),
        ),
      ],
    );
  }
}

/// Una fila: indicador + etiqueta + detalle + el riel a la siguiente.
class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.isLast});

  final _StepData step;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final color = switch (step.state) {
      _StepState.failed => AppColors.destructive,
      _StepState.warned => AppColors.warning,
      _StepState.done || _StepState.running => AppColors.primary,
      _ => AppColors.mutedForeground,
    };

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              SizedBox(width: 26, height: 26, child: _Indicator(step.state)),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    color: step.state == _StepState.pending
                        ? AppColors.mutedForeground.withValues(alpha: 0.2)
                        : color.withValues(alpha: 0.35),
                  ),
                ),
            ],
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                top: 3,
                bottom: isLast ? 0 : AppSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: step.state == _StepState.running
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: color,
                    ),
                  ),
                  if ((step.detail ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        step.detail!,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: step.state == _StepState.warned
                              ? AppColors.warning
                              : AppColors.mutedForeground,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Indicator extends StatelessWidget {
  const _Indicator(this.state);

  final _StepState state;

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case _StepState.running:
        return const Padding(
          padding: EdgeInsets.all(2),
          child: CircularProgressIndicator(strokeWidth: 2.5),
        );
      case _StepState.done:
        return _circle(AppColors.primary, Icons.check);
      case _StepState.warned:
        return _circle(AppColors.warning, Icons.priority_high_rounded);
      case _StepState.failed:
        return _circle(AppColors.destructive, Icons.close_rounded);
      case _StepState.skipped:
        return _circle(
          AppColors.mutedForeground.withValues(alpha: 0.5),
          Icons.remove_rounded,
        );
      case _StepState.pending:
        return Center(
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.mutedForeground.withValues(alpha: 0.45),
                width: 2,
              ),
            ),
          ),
        );
    }
  }

  Widget _circle(Color color, IconData icon) => DecoratedBox(
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: Center(child: Icon(icon, size: 15, color: Colors.white)),
  );
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12.5, height: 1.4, color: color),
      ),
    );
  }
}
