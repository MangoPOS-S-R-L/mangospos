import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/presentation/settings/more%20settings/menus/categories/viewmodel/category_viewmodel.dart';

class CategoriesView extends ConsumerStatefulWidget {
  /// Puede venir 'auto' o un UUID real. El VM lo resuelve antes de consultar.
  final String businessId;
  const CategoriesView({super.key, required this.businessId});

  @override
  ConsumerState<CategoriesView> createState() => _CategoriesViewState();
}

class _CategoriesViewState extends ConsumerState<CategoriesView> {
  @override
  void initState() {
    super.initState();
    // Cargar una vez al montar
    Future.microtask(() {
      ref
          .read(categoriesVmProvider.notifier)
          .load(businessId: widget.businessId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(categoriesVmProvider);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: MangoColors.sidebarBg,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoutes.settings),
        ),
        title: const Text('Gestión de productos · Categorías'),
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: .4,
        actions: [
          IconButton(
            tooltip: 'Refrescar',
            onPressed: () => ref
                .read(categoriesVmProvider.notifier)
                .load(businessId: widget.businessId),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              foregroundColor: MangoColors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () async {
              final name = await _prompt(context, 'Nombre de la categoría');
              if (name != null && name.trim().isNotEmpty) {
                try {
                  await ref
                      .read(categoriesVmProvider.notifier)
                      .create(name: name.trim());
                  if (!mounted) return;
                  AppToast.success(context, 'Categoría creada');
                } catch (e) {
                  if (!mounted) return;
                  AppToast.error(context, 'Error: $e');
                }
              }
            },
            icon: const Icon(Icons.add),
            label: const Text('Nueva categoría'),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: vm.data.isLoading && vm.list.isEmpty
          ? const Center(
              child: CircularProgressIndicator(
                color: MangoColors.primaryOrange,
              ),
            )
          : vm.data.hasError
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Error: ${vm.data.error}',
                  style: text.bodyMedium?.copyWith(color: Colors.red),
                ),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: ReorderableListView.builder(
                itemCount: vm.list.length,
                buildDefaultDragHandles: false,
                onReorder: (oldIndex, newIndex) {
                  if (oldIndex == newIndex) return;
                  final list = List.of(vm.list);
                  // ReorderableListView entrega newIndex post-remove: si
                  // se mueve hacia abajo, el destino real es newIndex-1.
                  final adjusted = newIndex > oldIndex
                      ? newIndex - 1
                      : newIndex;
                  final moved = list.removeAt(oldIndex);
                  list.insert(adjusted, moved);
                  ref.read(categoriesVmProvider.notifier).reorder(list);
                },
                proxyDecorator: (child, index, animation) => Material(
                  color: Colors.transparent,
                  elevation: 6,
                  shadowColor: Colors.black26,
                  borderRadius: BorderRadius.circular(12),
                  child: child,
                ),
                padding: EdgeInsets.zero,
                itemBuilder: (context, i) {
                  final cat = vm.list[i];
                  return Padding(
                    key: ValueKey('cat-${cat.id}'),
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      elevation: 0,
                      color: MangoColors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: MangoColors.cardBorder),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        leading: ReorderableDragStartListener(
                          index: i,
                          child: const Icon(
                            Icons.drag_indicator,
                            size: 22,
                            color: Colors.black38,
                          ),
                        ),
                        title: Row(
                          children: [
                            // Swatch del color actual. Sin color → circulo
                            // outlined que invita a setearlo.
                            Container(
                              width: 16,
                              height: 16,
                              decoration: BoxDecoration(
                                color: cat.color != null
                                    ? _hexToColor(cat.color!)
                                    : null,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: cat.color != null
                                      ? Colors.transparent
                                      : MangoColors.cardBorder,
                                  width: 1.5,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                cat.name,
                                style: text.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: MangoColors.darkGray,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        subtitle: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: cat.isActive
                                    ? MangoColors.successGreen.withOpacity(0.1)
                                    : MangoColors.muted.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                cat.isActive ? 'Activa' : 'Inactiva',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: cat.isActive
                                      ? MangoColors.successGreen
                                      : MangoColors.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                        trailing: PopupMenuButton<String>(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          onSelected: (v) async {
                            if (v == 'rename') {
                              final newName = await _prompt(
                                context,
                                'Renombrar categoría',
                              );
                              if (newName != null && newName.trim().isNotEmpty) {
                                await ref
                                    .read(categoriesVmProvider.notifier)
                                    .rename(cat.id, newName.trim());
                              }
                            } else if (v == 'color') {
                              final picked = await _showColorPicker(
                                context,
                                cat.color,
                              );
                              if (picked != null) {
                                await ref
                                    .read(categoriesVmProvider.notifier)
                                    .updateColor(cat.id, picked.hex);
                              }
                            } else if (v == 'toggle') {
                              await ref
                                  .read(categoriesVmProvider.notifier)
                                  .toggleActive(cat.id, !cat.isActive);
                            } else if (v == 'delete') {
                              final ok = await _confirm(
                                context,
                                '¿Eliminar "${cat.name}"?',
                              );
                              if (ok == true) {
                                await ref
                                    .read(categoriesVmProvider.notifier)
                                    .remove(cat.id);
                              }
                            }
                          },
                          itemBuilder: (ctx) => [
                            const PopupMenuItem(
                              value: 'rename',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.edit,
                                    size: 18,
                                    color: MangoColors.darkGray,
                                  ),
                                  SizedBox(width: 12),
                                  Text('Renombrar'),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'color',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.palette_outlined,
                                    size: 18,
                                    color: MangoColors.darkGray,
                                  ),
                                  SizedBox(width: 12),
                                  Text('Cambiar color'),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'toggle',
                              child: Row(
                                children: [
                                  Icon(
                                    cat.isActive
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                    size: 18,
                                    color: MangoColors.darkGray,
                                  ),
                                  const SizedBox(width: 12),
                                  Text(cat.isActive ? 'Desactivar' : 'Activar'),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                    color: Colors.red,
                                  ),
                                  SizedBox(width: 12),
                                  Text(
                                    'Eliminar',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
      bottomNavigationBar: vm.data.isLoading
          ? const LinearProgressIndicator(
              minHeight: 2,
              color: MangoColors.primaryOrange,
            )
          : const SizedBox.shrink(),
    );
  }

  // ---------- Helpers UI ----------
  Future<String?> _prompt(BuildContext ctx, String title) async {
    final c = TextEditingController();
    return showDialog<String>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: MangoColors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: MangoColors.darkGray,
          ),
        ),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Escribe aquí',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: MangoColors.cardBorder),
            ),
          ),
          onSubmitted: (v) => Navigator.pop(dialogCtx, v),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: MangoColors.darkGray,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              foregroundColor: MangoColors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(dialogCtx, c.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  /// Convierte un hex `#RRGGBB` (o `RRGGBB`) a `Color`. Devuelve un gris
  /// neutro si el formato es inválido para que la UI no crashee con
  /// datos legacy mal escritos.
  Color _hexToColor(String hex) {
    final cleaned = hex.replaceAll('#', '').trim();
    if (cleaned.length != 6) return MangoColors.cardBorder;
    final parsed = int.tryParse(cleaned, radix: 16);
    if (parsed == null) return MangoColors.cardBorder;
    return Color(0xFF000000 | parsed);
  }

  /// Picker de color con paleta predefinida + opción "Sin color". Devuelve
  /// `null` si el usuario cancela; si guarda, devuelve un wrapper con el
  /// hex elegido (puede ser `null` si eligió "Sin color"). Usar wrapper en
  /// vez de `String?` directo porque ambos valores (cancelar / guardar
  /// sin color) coincidirían en `null` y perderíamos la diferencia.
  Future<_PickedColor?> _showColorPicker(
    BuildContext ctx,
    String? currentHex,
  ) async {
    const palette = <String>[
      '#EF4444', // rojo
      '#F97316', // naranja
      '#EAB308', // amarillo
      '#22C55E', // verde
      '#14B8A6', // teal
      '#3B82F6', // azul
      '#6366F1', // indigo
      '#A855F7', // morado
      '#EC4899', // rosa
      '#92400E', // marrón
      '#6B7280', // gris
    ];
    String? selected = currentHex;
    return showDialog<_PickedColor?>(
      context: ctx,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (sbCtx, setLocalState) => AlertDialog(
            backgroundColor: MangoColors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text(
              'Color de la categoría',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: MangoColors.darkGray,
              ),
            ),
            content: SizedBox(
              width: 320,
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  // "Sin color" → null
                  _ColorSwatchTile(
                    color: null,
                    selected: selected == null,
                    onTap: () => setLocalState(() => selected = null),
                  ),
                  ...palette.map(
                    (hex) => _ColorSwatchTile(
                      color: _hexToColor(hex),
                      selected:
                          selected != null &&
                          selected!.toLowerCase() == hex.toLowerCase(),
                      onTap: () => setLocalState(() => selected = hex),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: MangoColors.darkGray,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => Navigator.pop(dialogCtx),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: MangoColors.primaryOrange,
                  foregroundColor: MangoColors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () =>
                    Navigator.pop(dialogCtx, _PickedColor(selected)),
                child: const Text('Guardar'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<bool?> _confirm(BuildContext ctx, String title) async {
    return showDialog<bool>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: MangoColors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: MangoColors.darkGray,
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: MangoColors.darkGray,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: MangoColors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Sí, eliminar'),
          ),
        ],
      ),
    );
  }
}

/// Wrapper para distinguir "usuario canceló el dialog" (Navigator.pop sin
/// args devuelve null) de "usuario guardó eligiendo Sin color" (devuelve
/// `_PickedColor(null)`). Sin esto los dos casos colisionarían en `null`.
class _PickedColor {
  final String? hex;
  const _PickedColor(this.hex);
}

/// Swatch circular individual del picker. `color == null` representa
/// "Sin color" (círculo outlined con icono `block`).
class _ColorSwatchTile extends StatelessWidget {
  const _ColorSwatchTile({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? MangoColors.primaryOrange
                : (color == null
                      ? MangoColors.cardBorder
                      : Colors.transparent),
            width: selected ? 3 : 1.5,
          ),
        ),
        child: color == null
            ? const Icon(Icons.block, color: Colors.black38, size: 20)
            : (selected
                  ? const Icon(Icons.check, color: Colors.white, size: 20)
                  : null),
      ),
    );
  }
}
