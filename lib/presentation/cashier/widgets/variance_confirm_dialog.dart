// Sprint Caja Profesional — Fase D.
//
// Modal de confirmación de cierre con varianza grande. Se muestra antes
// de cerrar formalmente la caja cuando |diferencia| supera el umbral
// configurado por el negocio (`cash_variance_alert_threshold`).
//
// El admin/manager debe escribir una nota corta explicando la causa
// (faltante o sobrante) antes de confirmar el cierre. La nota se
// concatena a `cash_register_sessions.notes` y el cierre queda
// marcado con bandera `variance_flagged=true` (vía la migración 0016).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';

class VarianceConfirmResult {
  final bool confirmed;
  final String note;

  const VarianceConfirmResult({required this.confirmed, required this.note});
}

/// Muestra el modal y resuelve con `confirmed=true` si el usuario acepta
/// + escribió razón, o `confirmed=false` si canceló.
Future<VarianceConfirmResult> showVarianceConfirmDialog(
  BuildContext context, {
  required double difference,
  required double threshold,
}) async {
  final controller = TextEditingController();
  String fmt(double v) {
    final abs = v.abs();
    final whole = abs.truncate();
    final decimals = ((abs - whole) * 100).round().toString().padLeft(2, '0');
    final wholeStr = whole.toString().replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]},',
        );
    return 'RD\$ $wholeStr.$decimals';
  }

  final isSurplus = difference > 0;
  final result = await showDialog<VarianceConfirmResult>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return AlertDialog(
        title: Row(
          children: [
            Icon(
              isSurplus ? Icons.add_circle : Icons.warning_amber_rounded,
              color: isSurplus
                  ? MangoColors.successGreen
                  : const Color(0xFFEF4444),
            ),
            const SizedBox(width: 8),
            Text(isSurplus ? 'Sobrante alto' : 'Faltante alto'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isSurplus
                    ? const Color(0xFFEFFDF4)
                    : const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSurplus
                      ? MangoColors.successGreen
                      : const Color(0xFFEF4444),
                ),
              ),
              child: Row(
                children: [
                  const Text(
                    'Diferencia:',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Text(
                    '${isSurplus ? '+' : '-'}${fmt(difference)}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: isSurplus
                          ? MangoColors.successGreen
                          : const Color(0xFFEF4444),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Supera el umbral de ${fmt(threshold)} configurado para tu '
              'negocio. Antes de confirmar, agrega una nota explicando '
              'la causa (rotura de billete, vuelto mal contado, etc.). '
              'La nota queda en el historial de cierres.',
              style: const TextStyle(fontSize: 12, color: MangoColors.muted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 3,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Razón / nota *',
                hintText: 'Obligatoria para auditoría',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(
              const VarianceConfirmResult(confirmed: false, note: ''),
            ),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
            ),
            onPressed: () {
              final note = controller.text.trim();
              if (note.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(
                    content: Text('La nota es obligatoria.'),
                  ),
                );
                return;
              }
              Navigator.of(ctx).pop(
                VarianceConfirmResult(confirmed: true, note: note),
              );
            },
            child: const Text('Confirmar cierre'),
          ),
        ],
      );
    },
  );

  return result ??
      const VarianceConfirmResult(confirmed: false, note: '');
}

/// Helper que envuelve `closeSession` con la verificación de varianza.
/// Lee el umbral configurado del negocio; si `|endAmount − expectedCash|
/// > umbral`, muestra el dialog. Sólo si el usuario confirma con
/// razón, se llama a `closeSession` (apendeando la nota a `notes`).
///
/// Devuelve:
///   - `null` si el usuario canceló el cierre por la alerta.
///   - El response del RPC de cierre si se completó.
///
/// El caller decide qué hacer ante `null` (típicamente: no avanzar
/// con el flujo posterior).
Future<Map<String, dynamic>?> closeSessionWithVarianceCheck({
  required BuildContext context,
  required WidgetRef ref,
  required String businessId,
  required String sessionId,
  required double endAmount,
  required double expectedCash,
  String? notes,
  bool forceWithOpenTables = false,
}) async {
  final repo = ref.read(cashierRepositoryProvider);
  final threshold = await repo.getVarianceAlertThreshold(businessId);
  final difference = endAmount - expectedCash;

  var finalNotes = notes;

  if (threshold > 0 && difference.abs() > threshold) {
    if (!context.mounted) return null;
    final res = await showVarianceConfirmDialog(
      context,
      difference: difference,
      threshold: threshold,
    );
    if (!res.confirmed) return null;
    final varianceTag = '[VARIANCE_NOTE: ${res.note}]';
    finalNotes = (finalNotes == null || finalNotes.isEmpty)
        ? varianceTag
        : '$finalNotes | $varianceTag';
  }

  final response = await repo.closeSession(
    sessionId: sessionId,
    endAmount: endAmount,
    notes: finalNotes,
    forceWithOpenTables: forceWithOpenTables,
  );

  // Flag de varianza en la sesión (post-close, fire-and-forget).
  if (threshold > 0 && difference.abs() > threshold) {
    unawaited(
      repo.markSessionVarianceFlagged(sessionId).catchError((_) {}),
    );
  }

  return response;
}

