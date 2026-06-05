import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/mango_colors.dart';
import '../../core/update/web_version_checker.dart';

/// Banner superior que avisa cuando se publicó un build web más nuevo del que
/// está corriendo. Aparece SOLO en web y solo cuando el checker detectó un
/// `version.json` distinto al del arranque. "Actualizar ahora" recarga el
/// navegador para bajar el build nuevo. En desktop/móvil nunca se muestra
/// (el provider queda en `false`), así que aquí no hace falta `kIsWeb`.
class UpdateAvailableBanner extends ConsumerWidget {
  const UpdateAvailableBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updateAvailable = ref.watch(webUpdateAvailableProvider);
    if (!updateAvailable) return const SizedBox.shrink();

    return Material(
      color: MangoColors.primaryOrange.withValues(alpha: 0.12),
      child: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Color(0x33F97316)),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Icon(
              Icons.system_update_alt_rounded,
              color: MangoColors.primaryOrange,
              size: 20,
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Hay una versión nueva disponible. Actualiza para obtener las '
                'últimas mejoras.',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF7C2D12),
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: () =>
                  ref.read(webUpdateAvailableProvider.notifier).reloadApp(),
              style: FilledButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Actualizar ahora'),
            ),
          ],
        ),
      ),
    );
  }
}
