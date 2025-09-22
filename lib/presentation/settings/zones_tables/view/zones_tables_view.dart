import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import '../viewmodel/zones_tables_viewmodel.dart';

class ZonesTablesView extends ConsumerStatefulWidget {
  /// Puede venir 'auto' o un UUID real. El VM lo resuelve antes de consultar.
  final String businessId;
  const ZonesTablesView({super.key, required this.businessId});

  @override
  ConsumerState<ZonesTablesView> createState() => _ZonesTablesViewState();
}

class _ZonesTablesViewState extends ConsumerState<ZonesTablesView> {
  @override
  void initState() {
    super.initState();
    // Cargar una vez al montar
    Future.microtask(() {
      ref
          .read(zonesTablesVmProvider.notifier)
          .load(businessId: widget.businessId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(zonesTablesVmProvider);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: MangoColors.sidebarBg,
      appBar: AppBar(
        // Regresar SIN pop (evita crash de go_router si no hay stack)
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoutes.settings),
        ),
        title: const Text('Ajustes · Zonas y mesas'),
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: .4,
        actions: [
          IconButton(
            tooltip: 'Refrescar',
            onPressed: () => ref
                .read(zonesTablesVmProvider.notifier)
                .load(businessId: widget.businessId),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Nueva zona',
            onPressed: () async {
              final name = await _prompt(context, 'Nombre de la zona');
              if (name != null && name.trim().isNotEmpty) {
                try {
                  await ref
                      .read(zonesTablesVmProvider.notifier)
                      .addZone(widget.businessId, name.trim());
                  if (!mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Zona creada')));
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('Error: $e')));
                }
              }
            },
            icon: const Icon(Icons.add_circle_outline),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: vm.loading && vm.zones.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : vm.error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Error: ${vm.error}',
                  style: text.bodyMedium?.copyWith(color: Colors.red),
                ),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: ListView.separated(
                itemCount: vm.zones.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  final zone = vm.zones[i];
                  final tables = vm.tablesByZone[zone.id] ?? const [];

                  return Card(
                    elevation: .5,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: Colors.black.withOpacity(.08)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  zone.name,
                                  style: text.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: MangoColors.darkGray,
                                  ),
                                ),
                              ),
                              Text(
                                '${tables.length} mesas',
                                style: text.bodySmall?.copyWith(
                                  color: Colors.grey[600],
                                ),
                              ),
                              const SizedBox(width: 8),
                              // ---- Agregar mesa ----
                              IconButton(
                                tooltip: 'Agregar mesa',
                                icon: const Icon(Icons.add),
                                onPressed: () async {
                                  final okCode = await _prompt(
                                    context,
                                    'Código de mesa (ej: T01)',
                                  );
                                  if (okCode != null &&
                                      okCode.trim().isNotEmpty) {
                                    try {
                                      await ref
                                          .read(zonesTablesVmProvider.notifier)
                                          .addTable(zone.id, okCode.trim());
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('Mesa creada'),
                                        ),
                                      );
                                    } catch (e) {
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(content: Text('Error: $e')),
                                      );
                                    }
                                  }
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // ---- Listado de mesas / chips ----
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: tables.isEmpty
                                ? [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 6,
                                        horizontal: 10,
                                      ),
                                      decoration: BoxDecoration(
                                        color: MangoColors.sidebarBg,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        'No hay mesas',
                                        style: text.bodySmall,
                                      ),
                                    ),
                                  ]
                                : tables.map((t) {
                                    return Chip(
                                      label: Text(
                                        t.code,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      backgroundColor: MangoColors.white,
                                      side: BorderSide(
                                        color: Colors.black.withOpacity(.08),
                                      ),
                                      deleteIcon: const Icon(
                                        Icons.close,
                                        size: 18,
                                      ),
                                      onDeleted: () async {
                                        final ok = await _confirm(
                                          context,
                                          '¿Eliminar mesa ${t.code}?',
                                        );
                                        if (ok == true) {
                                          await ref
                                              .read(
                                                zonesTablesVmProvider.notifier,
                                              )
                                              .deleteTable(
                                                t.id,
                                                zoneId: zone.id,
                                              );
                                        }
                                      },
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    );
                                  }).toList(),
                          ),
                          const SizedBox(height: 6),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
      bottomNavigationBar: vm.loading
          ? const LinearProgressIndicator(minHeight: 2)
          : const SizedBox.shrink(),
    );
  }

  // ---------- Helpers UI ----------
  Future<String?> _prompt(BuildContext ctx, String title) async {
    final c = TextEditingController();
    return showDialog<String>(
      context: ctx,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Escribe aquí'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirm(BuildContext ctx, String title) async {
    return showDialog<bool>(
      context: ctx,
      builder: (_) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sí, eliminar'),
          ),
        ],
      ),
    );
  }
}
