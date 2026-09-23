import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';

import '../../core/offline/offline_readiness.dart';
import '../../core/offline/offline_readiness_provider.dart';
import '../../core/offline/offline_refreshers.dart';

/// La misma entrada en móvil y escritorio, separada del contador de ventas
/// pendientes: descargar datos y subir ventas son tareas distintas.
class OfflinePreparationBanner extends ConsumerWidget {
  const OfflinePreparationBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinator = ref.watch(offlineSyncCoordinatorProvider);
    final readiness = ref.watch(offlineReadinessProvider);
    final ready =
        readiness.value?.ready == true &&
        coordinator.failedSteps.isEmpty &&
        !readiness.isLoading;
    final busy = coordinator.isRefreshing;
    final color = ready ? const Color(0xFF166534) : const Color(0xFF92400E);
    final label = busy
        ? 'Preparando datos offline…'
        : readiness.isLoading
        ? 'Verificando datos offline…'
        : ready
        ? 'Datos offline listos'
        : 'Preparación offline pendiente';
    return Material(
      color: ready ? const Color(0xFFF0FDF4) : const Color(0xFFFFFBEB),
      child: InkWell(
        onTap: () async {
          ref.invalidate(offlineReadinessProvider);
          final action = await showDialog<OfflineReadinessAction>(
            context: context,
            builder: (_) => const _OfflinePreparationDialog(),
          );
          if (!context.mounted || action != OfflineReadinessAction.bindDevice) {
            return;
          }
          await context.push(AppRoutes.settingsDeviceBinding);
          if (context.mounted) ref.invalidate(offlineReadinessProvider);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                ready
                    ? Icons.offline_pin_outlined
                    : Icons.download_for_offline_outlined,
                color: color,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: color, fontSize: 13),
                ),
              ),
              Text(
                'Ver detalles',
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Icon(Icons.chevron_right, color: color, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflinePreparationDialog extends ConsumerWidget {
  const _OfflinePreparationDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinator = ref.watch(offlineSyncCoordinatorProvider);
    final result = ref.watch(offlineReadinessProvider);
    // No mostrar la copia anterior mientras cambia el negocio o se revisa.
    final data = result.isLoading ? null : result.value;
    final pending = data?.checks.where((check) => !check.ready).toList();
    final onlyBindingMissing =
        pending?.length == 1 &&
        pending!.single.action == OfflineReadinessAction.bindDevice;
    final busy = coordinator.isRefreshing;
    final step = coordinator.currentStep;
    final currentLabel = step != null && step < offlineDownloadLabels.length
        ? offlineDownloadLabels[step]
        : 'Datos del negocio';
    final failures = coordinator.failedSteps
        .map(
          (i) => i < offlineDownloadLabels.length
              ? offlineDownloadLabels[i]
              : 'Datos del negocio',
        )
        .toList();
    return AlertDialog(
      title: const Text('Preparación sin internet'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Verifica las copias guardadas en este equipo para ventas, mesas y cocina.',
              ),
              const SizedBox(height: 12),
              Text(
                coordinator.isOnline
                    ? 'Con internet · puedes actualizar las descargas.'
                    : 'Sin internet · se revisan las copias guardadas.',
              ),
              if (onlyBindingMissing) ...[
                const SizedBox(height: 12),
                const Text(
                  'Los datos de ventas y cocina están guardados. Falta preparar el acceso con PIN para iniciar sesión sin internet.',
                ),
              ],
              if (busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text('Descargando: $currentLabel'),
              ],
              if (failures.isNotEmpty && !busy) ...[
                const SizedBox(height: 12),
                Text(
                  'No se completó la actualización de: ${failures.join(', ')}. '
                  'Revisa los pendientes indicados abajo y vuelve a intentarlo.',
                  style: const TextStyle(color: Color(0xFF92400E)),
                ),
              ],
              if (result.hasError) ...[
                const SizedBox(height: 12),
                const Text(
                  'No se pudieron verificar los datos guardados. Vuelve a intentarlo.',
                ),
              ] else if (data == null) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ] else ...[
                const SizedBox(height: 8),
                for (final check in data.checks)
                  _ReadinessRow(
                    check: check,
                    canBind: coordinator.isOnline && !busy,
                    onBind: () => Navigator.of(
                      context,
                    ).pop(OfflineReadinessAction.bindDevice),
                  ),
                const SizedBox(height: 8),
                Text(
                  'Última revisión: ${DateFormat('dd/MM/yyyy HH:mm').format(data.checkedAt)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                'La impresión necesita conexión local con las impresoras. '
                'Este estado verifica datos guardados; no prueba la entrega de papel ni el arranque offline de la aplicación.',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
        FilledButton.icon(
          onPressed: busy
              ? null
              : () async {
                  if (coordinator.isOnline) {
                    await coordinator.refreshAll(motivo: 'preparación manual');
                  }
                  if (context.mounted) ref.invalidate(offlineReadinessProvider);
                },
          icon: const Icon(Icons.refresh),
          label: Text(
            busy
                ? 'Descargando…'
                : coordinator.isOnline
                ? 'Actualizar descargas'
                : 'Revisar datos guardados',
          ),
        ),
      ],
    );
  }
}

class _ReadinessRow extends StatelessWidget {
  const _ReadinessRow({
    required this.check,
    required this.canBind,
    required this.onBind,
  });
  final OfflineReadinessCheck check;
  final bool canBind;
  final VoidCallback onBind;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          check.ready ? Icons.check_circle_outline : Icons.error_outline,
          color: check.ready
              ? const Color(0xFF166534)
              : const Color(0xFF92400E),
          size: 22,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                check.label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(check.detail),
              if (check.action == OfflineReadinessAction.bindDevice &&
                  !check.ready) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: canBind ? onBind : null,
                  icon: const Icon(Icons.link),
                  label: const Text('Vincular este equipo'),
                ),
                if (!canBind)
                  const Text(
                    'La vinculación necesita internet y que termine la descarga en curso.',
                  ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}
