import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../viewmodel/menu_browser_viewmodel.dart';

/// Sub-pestañas de "presentación" dentro de una categoría del catálogo.
/// Se generan automáticamente con las etiquetas distintas de los productos
/// cargados (`state.presentationTabs`) y filtran el grid por
/// `state.selectedPresentation`. Compartido por desktop (catalog_column) y
/// mobile (menu_browser_tabs / menu_browser_sheet).
///
/// Solo se muestra cuando hay ≥2 etiquetas distintas (con una sola no
/// aporta). Si no hay etiquetas, ocupa cero espacio.
class PresentationTabs extends ConsumerWidget {
  const PresentationTabs({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = ref.watch(
      menuBrowserVmProvider.select((s) => s.presentationTabs),
    );
    final selected = ref.watch(
      menuBrowserVmProvider.select((s) => s.selectedPresentation),
    );

    if (tabs.length < 2) return const SizedBox.shrink();

    final notifier = ref.read(menuBrowserVmProvider.notifier);

    Widget chip(String label, bool isSel, VoidCallback onTap) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: isSel,
          showCheckmark: false,
          labelStyle: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isSel ? AppColors.primary : AppColors.mutedForeground,
          ),
          selectedColor: AppColors.primary.withValues(alpha: 0.12),
          backgroundColor: AppColors.card,
          side: BorderSide(
            color: isSel ? AppColors.primary : AppColors.border,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
          onSelected: (_) => onTap(),
        ),
      );
    }

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 2),
        children: [
          chip('Todas', selected == null,
              () => notifier.setSelectedPresentation(null)),
          for (final t in tabs)
            chip(t, selected == t, () => notifier.setSelectedPresentation(t)),
        ],
      ),
    );
  }
}
