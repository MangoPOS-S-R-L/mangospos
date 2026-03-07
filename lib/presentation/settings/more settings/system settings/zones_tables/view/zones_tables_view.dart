import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/dining_table.dart';
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
      backgroundColor: const Color(0xFFF5F7FA), // Light gray background
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => context.go(AppRoutes.settings),
        ),
        title: const Text(
          'Ajustes · Zonas y mesas',
          style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Refrescar',
            onPressed: () => ref
                .read(zonesTablesVmProvider.notifier)
                .load(businessId: widget.businessId),
            icon: const Icon(Icons.refresh, color: Colors.black54),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: ElevatedButton.icon(
              onPressed: () async {
                final name = await _prompt(context, 'Nombre de la zona');
                if (name != null && name.trim().isNotEmpty) {
                  try {
                    await ref
                        .read(zonesTablesVmProvider.notifier)
                        .addZone(widget.businessId, name.trim());
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Zona creada'),
                        backgroundColor: const Color(0xFF22C55E),
                      ),
                    );
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Error: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Nueva Zona'),
              style: ElevatedButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange, // Orange
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      ),
      body: vm.loading && vm.zones.isEmpty
          ? const Center(
              child: CircularProgressIndicator(
                color: MangoColors.primaryOrange,
              ),
            )
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
              padding: const EdgeInsets.all(24),
              child: ListView.separated(
                itemCount: vm.zones.length,
                separatorBuilder: (_, __) => const SizedBox(height: 16),
                itemBuilder: (context, i) {
                  final zone = vm.zones[i];
                  final tables = vm.tablesByZone[zone.id] ?? const [];

                  return Card(
                    elevation: 0,
                    color: Colors.white,
                    surfaceTintColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: Colors.grey.withOpacity(0.2)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      zone.name,
                                      style: text.titleMedium?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 18,
                                        color: Colors.black87,
                                      ),
                                    ),
                                    Text(
                                      '${tables.length} mesas registradas',
                                      style: text.bodySmall?.copyWith(
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              // ---- Agregar mesa ----
                              TextButton.icon(
                                onPressed: () async {
                                  final nextCode = _generateNextTableCode(
                                    zone.name,
                                    tables,
                                  );
                                  final okCode = await _prompt(
                                    context,
                                    'Código de mesa',
                                    initialValue: nextCode,
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
                                          backgroundColor: const Color(0xFF22C55E),
                                        ),
                                      );
                                    } catch (e) {
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text('Error: $e'),
                                          backgroundColor: Colors.red,
                                        ),
                                      );
                                    }
                                  }
                                },
                                icon: const Icon(
                                  Icons.add_circle_outline,
                                  size: 20,
                                ),
                                label: const Text('Agregar mesa'),
                                style: TextButton.styleFrom(
                                  foregroundColor: const Color(0xFF22C55E),
                                  textStyle: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const Divider(height: 1, thickness: 0.5),
                          const SizedBox(height: 16),
                          // ---- Listado de mesas / chips ----
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: tables.isEmpty
                                ? [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 8,
                                        horizontal: 12,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.grey[100],
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        'No hay mesas configuradas',
                                        style: TextStyle(
                                          color: Colors.grey[600],
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  ]
                                : tables.map((t) {
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      // Usar Chip personalizado o decorado
                                      child: Chip(
                                        label: Text(
                                          t.code,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: Colors.black87,
                                          ),
                                        ),
                                        backgroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          side: BorderSide(
                                            color: Colors.grey.withOpacity(0.3),
                                          ),
                                        ),
                                        deleteIcon: const Icon(
                                          Icons.close,
                                          size: 16,
                                          color: Colors.redAccent,
                                        ),
                                        onDeleted: () async {
                                          final ok = await _confirm(
                                            context,
                                            '¿Eliminar mesa ${t.code}?',
                                          );
                                          if (ok == true) {
                                            await ref
                                                .read(
                                                  zonesTablesVmProvider
                                                      .notifier,
                                                )
                                                .deleteTable(
                                                  t.id,
                                                  zoneId: zone.id,
                                                );
                                          }
                                        },
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        visualDensity: VisualDensity.compact,
                                      ),
                                    );
                                  }).toList(),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
      bottomNavigationBar: vm.loading
          ? const LinearProgressIndicator(
              minHeight: 2,
              color: MangoColors.primaryOrange,
            )
          : const SizedBox.shrink(),
    );
  }

  // ---------- Helpers Logic ----------

  String _generateNextTableCode(
    String zoneName,
    List<DiningTable> existingTables,
  ) {
    // 1. Obtener iniciales (2 caracteres máximo)
    final words = zoneName.trim().split(RegExp(r'\s+'));
    String prefix = '';

    if (words.isNotEmpty) {
      if (words.length == 1) {
        // Si es una sola palabra, primeros 2 chars
        prefix = words[0]
            .substring(0, words[0].length >= 2 ? 2 : words[0].length)
            .toUpperCase();
      } else {
        // Si son varias, iniciales de las dos primeras
        prefix = words
            .take(2)
            .map((w) => w.isNotEmpty ? w[0] : '')
            .join()
            .toUpperCase();
      }
    }

    if (prefix.isEmpty) prefix = 'M'; // Fallback

    // 2. Buscar el número más alto con ese prefijo exacto
    int maxNum = 0;
    // Regex flexible: Prefijo + Digitos
    final regex = RegExp('^${RegExp.escape(prefix)}(\\d+)\$');

    for (final t in existingTables) {
      final codeUpper = t.code.trim().toUpperCase();
      final match = regex.firstMatch(codeUpper);
      if (match != null) {
        final numStr = match.group(1);
        if (numStr != null) {
          final n = int.tryParse(numStr);
          if (n != null && n > maxNum) {
            maxNum = n;
          }
        }
      }
    }

    // 3. Generar siguiente (padding 2 ceros)
    final nextNum = maxNum + 1;
    return '$prefix${nextNum.toString().padLeft(2, '0')}';
  }

  // ---------- Helpers UI ----------
  Future<String?> _prompt(
    BuildContext ctx,
    String title, {
    String? initialValue,
  }) async {
    final c = TextEditingController(text: initialValue);
    return showDialog<String>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        surfaceTintColor: Colors.white,
        backgroundColor: Colors.white,
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Escribe aquí',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 14,
            ),
          ),
          onSubmitted: (v) => Navigator.pop(dialogCtx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            style: TextButton.styleFrom(foregroundColor: Colors.grey[700]),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogCtx, c.text),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF22C55E),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
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
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        surfaceTintColor: Colors.white,
        backgroundColor: Colors.white,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            style: TextButton.styleFrom(foregroundColor: Colors.grey[700]),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red[600],
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }
}
