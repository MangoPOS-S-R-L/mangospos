import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/offline/offline_pos_service.dart';
import '../../core/utils/app_snackbar.dart';
import '../../data/models/offline_payment_replay.dart';
import '../../services/session/session_controller.dart';
import '../cashier/viewmodel/cashier_viewmodel.dart';
import '../sales/viewmodel/sales_viewmodel.dart';

/// T07 (20261010_0008): decisión explícita sobre un cobro hecho sin red que no
/// se aplicó solo (caja cerrada, cuenta cambiada o ya cobrada…). La toma el
/// servidor con el recibo del cobro (solo dueño, administrador o gerente).
/// Devuelve true si el cobro quedó resuelto.
Future<bool> showOfflinePaymentResolutionDialog(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> action,
) async {
  final businessId = ref.read(sessionProvider).activeBusinessId;
  final actionId = action['id']?.toString();
  if (businessId == null || businessId.isEmpty || actionId == null) {
    return false;
  }
  final reason = action['payment_resolution']?.toString();
  final rawDetail = action['payment_resolution_detail'];
  final options = OfflinePaymentResolution.allowedFor(
    reason,
    rawDetail is Map ? Map<String, dynamic>.from(rawDetail) : null,
  );
  final amount = (action['amount'] as num?)?.toDouble();
  final paidAt = DateTime.tryParse(
    action['paid_at']?.toString() ?? '',
  )?.toLocal();
  final noteController = TextEditingController();

  String? selected = options.isEmpty ? null : options.first;
  final decision = await showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Resolver cobro sin red'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(OfflinePaymentResolution.reasonMessage(reason)),
              const SizedBox(height: 8),
              Text(
                [
                  if (amount != null) 'Monto: ${amount.toStringAsFixed(2)}',
                  if (paidAt != null) 'Cobrado: ${_formatDate(paidAt)}',
                ].join(' · '),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              if (options.isEmpty)
                const Text('No hay una decisión disponible para este caso.')
              else
                RadioGroup<String>(
                  groupValue: selected,
                  onChanged: (value) => setState(() => selected = value),
                  child: Column(
                    children: [
                      for (final option in options)
                        RadioListTile<String>(
                          value: option,
                          contentPadding: EdgeInsets.zero,
                          title: Text(OfflinePaymentResolution.label(option)),
                        ),
                    ],
                  ),
                ),
              if (selected == OfflinePaymentResolution.acknowledge)
                TextField(
                  controller: noteController,
                  decoration: const InputDecoration(
                    labelText: 'Nota (qué se hizo con este dinero)',
                  ),
                  maxLines: 2,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: selected == null
                ? null
                : () => Navigator.pop(dialogContext, selected),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    ),
  );
  final note = noteController.text.trim();
  noteController.dispose();
  if (decision == null || !context.mounted) return false;

  String? targetSessionId;
  if (decision == OfflinePaymentResolution.applyToReviewOrder) {
    // Si este equipo tiene la caja abierta, el cobro entra ahí; si no, en su
    // caja original (el servidor la exige abierta).
    try {
      targetSessionId = (await ref
              .read(cashierRepositoryProvider)
              .requireActiveSession(
                businessId: businessId,
                canOperateAnyDevice: ref.read(sessionProvider).isOwnerOrAdmin,
              ))
          .id;
    } catch (_) {}
  }
  if (decision == OfflinePaymentResolution.postToOpenSession) {
    try {
      final session = await ref
          .read(cashierRepositoryProvider)
          .requireActiveSession(
            businessId: businessId,
            canOperateAnyDevice: ref.read(sessionProvider).isOwnerOrAdmin,
          );
      targetSessionId = session.id;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showAppSnackBar(
          SnackBar(
            content: Text(
              'Para registrarlo abre la caja de este equipo. '
              '${e.toString().replaceFirst('Exception: ', '')}',
            ),
          ),
        );
      }
      return false;
    }
  }

  try {
    final result = await OfflinePosService().resolveOfflinePayment(
      businessId: businessId,
      actionId: actionId,
      resolution: decision,
      salesRepository: ref.read(salesRepositoryProvider),
      targetSessionId: targetSessionId,
      note: note.isEmpty ? null : note,
    );
    if (!context.mounted) return result.settled;
    ScaffoldMessenger.of(context).showAppSnackBar(
      SnackBar(
        content: Text(
          result.settled
              ? 'Cobro resuelto.'
              : OfflinePaymentResolution.reasonMessage(result.reason),
        ),
      ),
    );
    return result.settled;
  } catch (e) {
    if (context.mounted) {
      final raw = e.toString();
      ScaffoldMessenger.of(context).showAppSnackBar(
        SnackBar(
          content: Text(
            raw.contains('RESOLVE_DENIED')
                ? 'Solo el dueño, un administrador o un gerente puede '
                      'resolver este cobro.'
                : raw.contains('TARGET_SESSION_NOT_OPEN')
                ? 'La caja de este equipo no está abierta.'
                : raw.contains('REVIEW_ORDER_NOT_OPEN')
                ? 'La cuenta en revisión ya se cerró o se unió a otra.'
                : 'No se pudo resolver el cobro: $raw',
          ),
        ),
      );
    }
    return false;
  }
}

String _formatDate(DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(at.day)}/${two(at.month)}/${at.year} '
      '${two(at.hour)}:${two(at.minute)}';
}
