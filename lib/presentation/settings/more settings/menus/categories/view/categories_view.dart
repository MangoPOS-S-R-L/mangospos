import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
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
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Categoría creada')),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('Error: $e')));
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
              child: ListView.separated(
                itemCount: vm.list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  final cat = vm.list[i];
                  return Card(
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
                      title: Text(
                        cat.name,
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: MangoColors.darkGray,
                        ),
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
