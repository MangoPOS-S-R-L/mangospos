import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import '../viewmodel/menus_viewmodel.dart';

class MenusView extends ConsumerStatefulWidget {
  final String businessId; // puede ser 'auto'
  const MenusView({super.key, required this.businessId});

  @override
  ConsumerState<MenusView> createState() => _MenusViewState();
}

class _MenusViewState extends ConsumerState<MenusView> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(menusVmProvider.notifier).load(businessId: widget.businessId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(menusVmProvider);
    final text = Theme.of(context).textTheme;
    final isBusy = vm.loading;

    return Scaffold(
      backgroundColor: MangoColors.sidebarBg,
      appBar: AppBar(
        title: const Text('Menús'),
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: .4,
        actions: [
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              foregroundColor: MangoColors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: isBusy
                ? null
                : () async {
                    final name = await _prompt(context, 'Nombre del menú');
                    if (name != null && name.trim().isNotEmpty) {
                      await ref
                          .read(menusVmProvider.notifier)
                          .create(name: name.trim());
                    }
                  },
            icon: const Icon(Icons.add),
            label: const Text('Agregar menú'),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Buscador
            TextField(
              controller: _search,
              enabled: !isBusy,
              decoration: InputDecoration(
                hintText: 'Busca tu menú aquí',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: MangoColors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: MangoColors.cardBorder),
                ),
              ),
              onChanged: (v) => ref.read(menusVmProvider.notifier).setSearch(v),
            ),
            const SizedBox(height: 12),

            // Chips horizontales con los menús
            SizedBox(
              height: 72,
              child: vm.loading && vm.list.isEmpty
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: MangoColors.primaryOrange,
                      ),
                    )
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: vm.filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 12),
                      itemBuilder: (context, i) {
                        final m = vm.filtered[i];
                        final selected = m.id == vm.selectedId;
                        return GestureDetector(
                          onTap: isBusy
                              ? null
                              : () => ref
                                    .read(menusVmProvider.notifier)
                                    .select(m.id),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? MangoColors.primaryOrange
                                  : MangoColors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: selected
                                    ? MangoColors.primaryOrange
                                    : MangoColors.cardBorder,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.restaurant_menu,
                                      size: 18,
                                      color: selected
                                          ? MangoColors.white
                                          : MangoColors.darkGray,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      m.name,
                                      style: text.titleSmall?.copyWith(
                                        color: selected
                                            ? MangoColors.white
                                            : MangoColors.darkGray,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${m.itemsCount ?? 0} Artículos',
                                  style: text.bodySmall?.copyWith(
                                    color: selected
                                        ? MangoColors.white.withOpacity(0.9)
                                        : MangoColors.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),

            const SizedBox(height: 16),
            // Título del seleccionado
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                vm.selected?.name ?? '',
                style: text.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: MangoColors.darkGray,
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Acciones del seleccionado
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: MangoColors.darkGray,
                    side: BorderSide(color: MangoColors.cardBorder),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: isBusy || vm.selected == null
                      ? null
                      : () async {
                          final newName = await _prompt(
                            context,
                            'Renombrar menú',
                          );
                          if (newName != null && newName.trim().isNotEmpty) {
                            await ref
                                .read(menusVmProvider.notifier)
                                .rename(vm.selected!.id, newName.trim());
                          }
                        },
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Actualizar'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: isBusy || vm.selected == null
                      ? null
                      : () async {
                          final ok = await _confirm(
                            context,
                            '¿Eliminar menú "${vm.selected!.name}"?',
                          );
                          if (ok == true) {
                            await ref
                                .read(menusVmProvider.notifier)
                                .remove(vm.selected!.id);
                          }
                        },
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text(''),
                ),
              ],
            ),

            const SizedBox(height: 12),
            // Aquí luego mostraremos los items del menú seleccionado en tabla.
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: MangoColors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: MangoColors.cardBorder),
                ),
                child: const Center(
                  child: Text(
                    'Tabla de artículos del menú (pendiente)',
                    style: TextStyle(color: MangoColors.muted),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),

      bottomNavigationBar: isBusy
          ? const LinearProgressIndicator(
              minHeight: 2,
              color: MangoColors.primaryOrange,
            )
          : const SizedBox.shrink(),
    );
  }

  Future<String?> _prompt(BuildContext ctx, String title) async {
    final c = TextEditingController();
    return showDialog<String>(
      context: ctx,
      builder: (d) => AlertDialog(
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
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: MangoColors.darkGray,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(d),
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
            onPressed: () => Navigator.pop(d, c.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirm(BuildContext ctx, String title) async {
    return showDialog<bool>(
      context: ctx,
      builder: (d) => AlertDialog(
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
            onPressed: () => Navigator.pop(d, false),
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
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Sí, eliminar'),
          ),
        ],
      ),
    );
  }
}
