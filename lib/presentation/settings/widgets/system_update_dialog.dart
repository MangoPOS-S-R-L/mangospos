import 'package:auto_updater/auto_updater.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/core/utils/friendly_error.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_update_provider.dart';

/// «Actualizaciones»: la versión instalada frente a la última publicada para
/// esta plataforma (`app_releases`), y cómo actualizar. Lo abren el menú de
/// usuario (junto a «Ajustes del sistema») y Configuración → Sistema.
class SystemUpdateDialog extends ConsumerWidget {
  const SystemUpdateDialog({super.key});

  static const _ink = Color(0xFF1C1917);
  static const _orange = Color(0xFFF97316);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(appUpdateStatusProvider);
    final installed = ref.watch(installedAppVersionProvider).value;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: Colors.white,
      // Desplazable: con la tarjeta de versión nueva no cabe en pantallas bajas
      // (tablets de 600 px de alto).
      child: SingleChildScrollView(
        child: Container(
          padding: const EdgeInsets.all(28),
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F1F1),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(
                  Icons.system_update_alt_rounded,
                  size: 40,
                  color: _ink,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Actualizaciones',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: _ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                installed == null
                    ? 'Versión instalada: …'
                    : 'Versión instalada: ${installed.version} (${installed.build})',
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
              const SizedBox(height: 20),
              status.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(color: _ink),
                ),
                error: (e, _) => _Message(
                  icon: Icons.cloud_off_rounded,
                  color: Colors.grey[600]!,
                  title: 'No se pudo consultar si hay versiones nuevas.',
                  detail: FriendlyError.from(e),
                ),
                data: (s) {
                  final latest = s.latest;
                  if (latest == null) {
                    return _Message(
                      icon: Icons.info_outline_rounded,
                      color: Colors.grey[600]!,
                      title:
                          'Todavía no hay versiones publicadas para este equipo.',
                    );
                  }
                  if (!s.updateAvailable) {
                    return _Message(
                      icon: Icons.check_circle_outline,
                      color: Colors.green[700]!,
                      title: 'Estás al día.',
                      detail: 'La última versión es la ${latest.version}.',
                    );
                  }
                  return _UpdateCard(status: s);
                },
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(color: Colors.grey[300]!),
                        ),
                      ),
                      child: const Text(
                        'Cerrar',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _ink,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextButton(
                      onPressed: status.isLoading
                          ? null
                          : () => ref.invalidate(appUpdateStatusProvider),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(color: Colors.grey[300]!),
                        ),
                      ),
                      child: const Text(
                        'Buscar de nuevo',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _ink,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String? detail;

  const _Message({
    required this.icon,
    required this.color,
    required this.title,
    this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 30),
        const SizedBox(height: 10),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        if (detail != null) ...[
          const SizedBox(height: 6),
          Text(
            detail!,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
          ),
        ],
      ],
    );
  }
}

class _UpdateCard extends StatelessWidget {
  final AppUpdateStatus status;

  const _UpdateCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final latest = status.latest!;
    final published = latest.publishedAt == null
        ? null
        : DateFormat('dd/MM/yyyy').format(latest.publishedAt!);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFED7AA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Hay una versión nueva: ${latest.version}',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: SystemUpdateDialog._ink,
            ),
          ),
          if (published != null) ...[
            const SizedBox(height: 2),
            Text(
              'Publicada el $published',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
          if (latest.notes != null) ...[
            const SizedBox(height: 10),
            Text(latest.notes!, style: const TextStyle(fontSize: 13)),
          ],
          const SizedBox(height: 10),
          Text(
            'Antes de actualizar, espera a que no queden ventas pendientes de '
            'subir (la nube sin pendientes).',
            style: TextStyle(fontSize: 12, color: Colors.grey[700]),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _update(context),
              icon: const Icon(Icons.download_rounded),
              label: Text(_actionLabel()),
              style: FilledButton.styleFrom(
                backgroundColor: SystemUpdateDialog._orange,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _actionLabel() => switch (status.platform) {
    'windows' => 'Actualizar ahora',
    'android' || 'ios' => 'Abrir la tienda',
    'web' => 'Recargar la página',
    _ => 'Descargar la versión nueva',
  };

  Future<void> _update(BuildContext context) async {
    final url = status.latest?.downloadUrl;
    try {
      if (status.platform == 'windows') {
        // Windows se actualiza con su propio instalador (appcast.xml).
        await autoUpdater.checkForUpdates();
        return;
      }
      if (status.platform == 'web') {
        await launchUrl(Uri.base, webOnlyWindowName: '_self');
        return;
      }
      if (url == null) {
        if (context.mounted) {
          AppToast.error(
            context,
            'Esta versión no tiene enlace de descarga. Pídela a soporte.',
          );
        }
        return;
      }
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && context.mounted) {
        AppToast.error(context, 'No se pudo abrir el enlace de descarga.');
      }
    } catch (e) {
      if (context.mounted) {
        AppToast.error(
          context,
          'No se pudo iniciar la actualización: ${FriendlyError.from(e)}',
        );
      }
    }
  }
}
