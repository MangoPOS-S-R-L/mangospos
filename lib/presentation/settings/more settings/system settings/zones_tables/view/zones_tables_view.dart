import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/models/dining_table.dart';
import 'package:mangopos/data/models/zone.dart';
import '../viewmodel/zones_tables_viewmodel.dart';
import 'zone_floor_editor.dart';

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
          // Toggle "Mostrar inactivas" — para reactivar mesas/zonas
          // que se desactivaron por soft-delete.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.archive_outlined,
                  size: 18,
                  color: Colors.black54,
                ),
                const SizedBox(width: 4),
                const Text(
                  'Inactivas',
                  style: TextStyle(color: Colors.black54, fontSize: 13),
                ),
                Switch.adaptive(
                  value: vm.showInactive,
                  onChanged: (v) => ref
                      .read(zonesTablesVmProvider.notifier)
                      .setShowInactive(v),
                ),
              ],
            ),
          ),
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
                    if (!context.mounted) return;
                    AppToast.success(context, 'Zona creada');
                  } catch (e) {
                    if (!context.mounted) return;
                    AppToast.error(context, 'Error: $e');
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
              child: Column(
                children: [
                  Card(
                    elevation: 0,
                    color: Colors.white,
                    surfaceTintColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: Colors.grey.withValues(alpha: 0.2),
                      ),
                    ),
                    child: SwitchListTile.adaptive(
                      value: vm.promptPeopleCountOnOpen,
                      onChanged: vm.savingOpenTableConfig
                          ? null
                          : (value) async {
                              await ref
                                  .read(zonesTablesVmProvider.notifier)
                                  .setPromptPeopleCountOnOpen(value);
                              if (!context.mounted) return;
                              AppToast.success(
                                context,
                                value
                                    ? 'Se pedirá cantidad de personas al abrir mesa.'
                                    : 'La mesa abrirá sin pedir cantidad de personas.',
                              );
                            },
                      secondary: vm.savingOpenTableConfig
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.groups_rounded),
                      title: const Text(
                        'Pedir cantidad de personas al abrir mesa',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: const Text(
                        'Si está activo, el camarero debe digitar la cantidad de comensales antes de abrir una mesa libre.',
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: ReorderableListView.builder(
                      itemCount: vm.zones.length,
                      buildDefaultDragHandles: false,
                      onReorder: (oldIndex, newIndex) {
                        if (oldIndex == newIndex) return;
                        final list = List.of(vm.zones);
                        final adjusted = newIndex > oldIndex
                            ? newIndex - 1
                            : newIndex;
                        final moved = list.removeAt(oldIndex);
                        list.insert(adjusted, moved);
                        ref
                            .read(zonesTablesVmProvider.notifier)
                            .reorderZones(list);
                      },
                      proxyDecorator: (child, index, animation) =>
                          Material(
                            color: Colors.transparent,
                            elevation: 6,
                            shadowColor: Colors.black26,
                            borderRadius: BorderRadius.circular(12),
                            child: child,
                          ),
                      padding: EdgeInsets.zero,
                      itemBuilder: (context, i) {
                        final zone = vm.zones[i];
                        final tables = vm.tablesByZone[zone.id] ?? const [];
                        final isInactiveZone = !zone.isActive;

                        return Padding(
                          key: ValueKey('zone-${zone.id}'),
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Card(
                          elevation: 0,
                          color: isInactiveZone
                              ? const Color(0xFFFAFAFA)
                              : Colors.white,
                          surfaceTintColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: Colors.grey.withValues(alpha: 0.2),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    // En pantallas angostas (teléfono) los
                                    // botones de acción competían con el
                                    // nombre de la zona en el mismo Row y lo
                                    // aplastaban a ancho ~0 → el nombre salía
                                    // vertical, letra por letra. Debajo de
                                    // 500px movemos las acciones a una fila
                                    // aparte, debajo del título.
                                    final narrow = constraints.maxWidth < 500;

                                    final dragHandle =
                                        ReorderableDragStartListener(
                                      index: i,
                                      child: const Padding(
                                        padding: EdgeInsets.only(right: 12),
                                        child: Icon(
                                          Icons.drag_indicator,
                                          size: 22,
                                          color: Colors.black38,
                                        ),
                                      ),
                                    );

                                    final titleBlock = Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                zone.name,
                                                style: text.titleMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      fontSize: 18,
                                                      color: isInactiveZone
                                                          ? Colors.grey[600]
                                                          : Colors.black87,
                                                      decoration:
                                                          isInactiveZone
                                                              ? TextDecoration
                                                                  .lineThrough
                                                              : null,
                                                    ),
                                              ),
                                            ),
                                            if (isInactiveZone) ...[
                                              const SizedBox(width: 8),
                                              _buildInactiveBadge(),
                                            ],
                                          ],
                                        ),
                                        Text(
                                          '${tables.length} mesas registradas',
                                          style: text.bodySmall?.copyWith(
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                      ],
                                    );

                                    final List<Widget> actions =
                                        isInactiveZone
                                            ? [
                                                TextButton.icon(
                                                  onPressed: () =>
                                                      _onReactivateZone(zone),
                                                  icon: const Icon(
                                                    Icons.unarchive_outlined,
                                                    size: 20,
                                                  ),
                                                  label: const Text(
                                                      'Reactivar zona'),
                                                  style: TextButton.styleFrom(
                                                    foregroundColor:
                                                        const Color(0xFF2563EB),
                                                    textStyle: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                              ]
                                            : [
                                                IconButton(
                                                  tooltip: 'Editar zona',
                                                  onPressed: () =>
                                                      _onEditZone(zone),
                                                  icon: const Icon(
                                                    Icons.edit_outlined,
                                                    size: 20,
                                                    color: Colors.black54,
                                                  ),
                                                ),
                                                IconButton(
                                                  tooltip: 'Eliminar zona',
                                                  onPressed: () => _onDeleteZone(
                                                    zone,
                                                    tables.length,
                                                  ),
                                                  icon: const Icon(
                                                    Icons.delete_outline,
                                                    size: 20,
                                                    color: Colors.redAccent,
                                                  ),
                                                ),
                                                IconButton(
                                                  tooltip: 'Editar plano',
                                                  onPressed: () =>
                                                      _onEditFloorPlan(zone),
                                                  icon: const Icon(
                                                    Icons
                                                        .space_dashboard_outlined,
                                                    size: 20,
                                                    color: Color(0xFF2563EB),
                                                  ),
                                                ),
                                                TextButton.icon(
                                                  onPressed: () =>
                                                      _onAddTable(zone, tables),
                                                  icon: const Icon(
                                                    Icons.add_circle_outline,
                                                    size: 20,
                                                  ),
                                                  label: const Text(
                                                      'Agregar mesa'),
                                                  style: TextButton.styleFrom(
                                                    foregroundColor:
                                                        const Color(0xFF22C55E),
                                                    textStyle: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                              ];

                                    if (narrow) {
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              dragHandle,
                                              Expanded(child: titleBlock),
                                            ],
                                          ),
                                          const SizedBox(height: 10),
                                          Align(
                                            alignment: Alignment.centerRight,
                                            child: Wrap(
                                              spacing: 4,
                                              runSpacing: 4,
                                              alignment: WrapAlignment.end,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: actions,
                                            ),
                                          ),
                                        ],
                                      );
                                    }

                                    return Row(
                                      children: [
                                        dragHandle,
                                        Expanded(child: titleBlock),
                                        ...actions,
                                      ],
                                    );
                                  },
                                ),
                                const SizedBox(height: 16),
                                const Divider(height: 1, thickness: 0.5),
                                const SizedBox(height: 16),
                                tables.isEmpty
                                    ? Container(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 8,
                                          horizontal: 12,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.grey[100],
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Text(
                                          'No hay mesas configuradas',
                                          style: TextStyle(
                                            color: Colors.grey[600],
                                            fontSize: 13,
                                          ),
                                        ),
                                      )
                                    : Wrap(
                                        spacing: 10,
                                        runSpacing: 10,
                                        children: tables
                                            .map(
                                              (t) => _TableTile(
                                                table: t,
                                                onEdit: () =>
                                                    _onEditTable(zone, t),
                                                onDelete: () =>
                                                    _onDeleteTable(zone, t),
                                                onReactivate: () =>
                                                    _onReactivateTable(zone, t),
                                                onMoveToZone: () =>
                                                    _onMoveTableToZone(
                                                      zone,
                                                      t,
                                                    ),
                                              ),
                                            )
                                            .toList(),
                                      ),
                              ],
                            ),
                          ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
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

  // ---------- Badge "Inactiva" ----------

  Widget _buildInactiveBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey[300],
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'INACTIVA',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: Colors.black54,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  // ---------- Handlers de Reactivación ----------

  Future<void> _onReactivateZone(Zone zone) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(zonesTablesVmProvider.notifier)
          .reactivateZone(zone.id);
      if (!context.mounted) return;
      _showSuccess(messenger, 'Zona "${zone.name}" reactivada');
    } catch (e) {
      if (!context.mounted) return;
      _showError(messenger, e.toString());
    }
  }

  Future<void> _onReactivateTable(Zone zone, DiningTable t) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(zonesTablesVmProvider.notifier)
          .reactivateTable(t.id, zoneId: zone.id);
      if (!context.mounted) return;
      _showSuccess(messenger, 'Mesa ${t.code} reactivada');
    } catch (e) {
      if (!context.mounted) return;
      _showError(messenger, e.toString());
    }
  }

  // ---------- Handlers de Zona ----------

  Future<void> _onEditZone(Zone zone) async {
    final messenger = ScaffoldMessenger.of(context);
    final newName = await _prompt(
      context,
      'Editar nombre de zona',
      initialValue: zone.name,
    );
    final trimmed = newName?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == zone.name) return;

    try {
      await ref
          .read(zonesTablesVmProvider.notifier)
          .updateZone(zone.id, trimmed);
      if (!context.mounted) return;
      _showSuccess(messenger, 'Zona actualizada');
    } catch (e) {
      if (!context.mounted) return;
      _showError(messenger, e.toString());
    }
  }

  Future<void> _onDeleteZone(Zone zone, int tableCount) async {
    final messenger = ScaffoldMessenger.of(context);
    final tablesText = tableCount == 1
        ? '1 mesa'
        : '$tableCount mesas';
    final ok = await _confirmDestructive(
      context,
      title: '¿Eliminar zona "${zone.name}"?',
      message: tableCount == 0
          ? 'Esta zona no tiene mesas. Esta acción no se puede deshacer.'
          : 'Se eliminarán $tablesText asociadas a esta zona. Si alguna '
                'tiene historial de ventas, se desactivará automáticamente '
                'para preservar el histórico.',
      confirmLabel: 'Eliminar zona',
    );
    if (ok != true) return;

    try {
      final outcome =
          await ref.read(zonesTablesVmProvider.notifier).deleteZone(zone.id);
      if (!context.mounted) return;
      _showSuccess(
        messenger,
        outcome == DeleteOutcome.deleted
            ? 'Zona eliminada'
            : 'Zona desactivada (se conservó el historial)',
      );
    } catch (e) {
      if (!context.mounted) return;
      _showError(messenger, e.toString());
    }
  }

  /// Abre el editor visual del plano (floor map) de la zona. Reusa la
  /// geometría ya cargada en `tablesByZone`; al guardar persiste el
  /// layout y refresca la lista. Se navega con `Navigator.push` para no
  /// tocar el router.
  Future<void> _onEditFloorPlan(Zone zone) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ZoneFloorEditorView(
          zoneId: zone.id,
          zoneName: zone.name,
        ),
      ),
    );
  }

  // ---------- Handlers de Mesa ----------

  Future<void> _onAddTable(Zone zone, List<DiningTable> existingTables) async {
    // Modal con tabs "Una" / "Varias". Para grupos grandes (T01-T20) el wizard
    // de rango ahorra muchísimo tiempo vs crear una por una.
    final mode = await _pickAddMode();
    if (mode == null) return;

    if (mode == _AddTableMode.single) {
      await _addSingleTable(zone, existingTables);
    } else {
      await _addBulkTables(zone, existingTables);
    }
  }

  Future<_AddTableMode?> _pickAddMode() async {
    return showDialog<_AddTableMode>(
      context: context,
      builder: (dCtx) => SimpleDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text(
          '¿Cómo querés agregar mesas?',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        children: [
          SimpleDialogOption(
            onPressed: () =>
                Navigator.pop(dCtx, _AddTableMode.single),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.add_circle_outline, color: Color(0xFF22C55E)),
                  SizedBox(width: 12),
                  Text('Una mesa'),
                ],
              ),
            ),
          ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.pop(dCtx, _AddTableMode.bulk),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.format_list_numbered, color: Color(0xFF22C55E)),
                  SizedBox(width: 12),
                  Text('Varias mesas (rango)'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addSingleTable(
    Zone zone,
    List<DiningTable> existingTables,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final defaultCode = _generateNextTableCode(zone.name, existingTables);
    final result = await _tableEditorDialog(
      title: 'Nueva mesa',
      initialCode: defaultCode,
      initialLabel: '',
      initialCapacity: 4,
    );
    if (result == null) return;

    try {
      await ref.read(zonesTablesVmProvider.notifier).addTable(
            zone.id,
            result.code,
            label: result.label,
            capacity: result.capacity,
          );
      if (!context.mounted) return;
      _showSuccess(messenger, 'Mesa creada');
    } catch (e) {
      if (!context.mounted) return;
      _showError(messenger, e.toString());
    }
  }

  Future<void> _addBulkTables(
    Zone zone,
    List<DiningTable> existingTables,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final suggestedPrefix = _generateNextTableCode(
      zone.name,
      existingTables,
    ).replaceAll(RegExp(r'\d+\$'), '');
    final result = await _bulkTableDialog(
      suggestedPrefix: suggestedPrefix.isEmpty ? 'M' : suggestedPrefix,
    );
    if (result == null) return;

    try {
      final r = await ref.read(zonesTablesVmProvider.notifier).addTablesBulk(
            zoneId: zone.id,
            prefix: result.prefix,
            from: result.from,
            to: result.to,
            padding: result.padding,
            capacity: result.capacity,
          );
      if (!context.mounted) return;
      final parts = <String>[];
      if (r.created > 0) {
        parts.add(r.created == 1 ? '1 mesa creada' : '${r.created} mesas creadas');
      }
      if (r.skipped > 0) {
        parts.add(
          r.skipped == 1
              ? '1 saltada (ya existía)'
              : '${r.skipped} saltadas (ya existían)',
        );
      }
      _showSuccess(
        messenger,
        parts.isEmpty ? 'No se crearon mesas' : parts.join(' · '),
      );
    } catch (e) {
      if (!context.mounted) return;
      _showError(messenger, e.toString());
    }
  }

  Future<_BulkTableResult?> _bulkTableDialog({
    required String suggestedPrefix,
  }) async {
    final prefixCtrl = TextEditingController(text: suggestedPrefix);
    final fromCtrl = TextEditingController(text: '1');
    final toCtrl = TextEditingController(text: '10');
    int capacity = 4;
    int padding = 2;
    String? errorText;

    return showDialog<_BulkTableResult>(
      context: context,
      builder: (dCtx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            String preview() {
              final p = prefixCtrl.text.trim();
              final f = int.tryParse(fromCtrl.text.trim()) ?? 1;
              final t = int.tryParse(toCtrl.text.trim()) ?? 1;
              if (p.isEmpty || f < 1 || t < f) return '—';
              final first = '$p${f.toString().padLeft(padding, '0')}';
              final last = '$p${t.toString().padLeft(padding, '0')}';
              final count = t - f + 1;
              return '$first → $last  ($count mesas)';
            }

            return AlertDialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.white,
              title: const Text(
                'Crear varias mesas',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Prefijo',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    TextField(
                      controller: prefixCtrl,
                      autofocus: true,
                      textCapitalization: TextCapitalization.characters,
                      decoration: _bulkInput('Ej: T, MESA, SP'),
                      onChanged: (_) => setSt(() {}),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Desde',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 4),
                              TextField(
                                controller: fromCtrl,
                                keyboardType: TextInputType.number,
                                decoration: _bulkInput('1'),
                                onChanged: (_) => setSt(() {}),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Hasta',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 4),
                              TextField(
                                controller: toCtrl,
                                keyboardType: TextInputType.number,
                                decoration: _bulkInput('10'),
                                onChanged: (_) => setSt(() {}),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Dígitos de relleno',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 1, label: Text('T1')),
                        ButtonSegment(value: 2, label: Text('T01')),
                        ButtonSegment(value: 3, label: Text('T001')),
                      ],
                      selected: {padding},
                      onSelectionChanged: (s) =>
                          setSt(() => padding = s.first),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Capacidad por mesa',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        IconButton.outlined(
                          onPressed: capacity <= 1
                              ? null
                              : () => setSt(() => capacity--),
                          icon: const Icon(Icons.remove),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '$capacity',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          capacity == 1 ? 'persona' : 'personas',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                        const SizedBox(width: 12),
                        IconButton.outlined(
                          onPressed: capacity >= 50
                              ? null
                              : () => setSt(() => capacity++),
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0FDF4),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFF22C55E).withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Vista previa',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFF15803D),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            preview(),
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              color: Color(0xFF15803D),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (errorText != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        errorText!,
                        style: TextStyle(
                          color: Colors.red[700],
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dCtx),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.grey[700],
                  ),
                  child: const Text('Cancelar'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final prefix = prefixCtrl.text.trim();
                    final from = int.tryParse(fromCtrl.text.trim());
                    final to = int.tryParse(toCtrl.text.trim());
                    if (prefix.isEmpty) {
                      setSt(() => errorText = 'El prefijo es obligatorio.');
                      return;
                    }
                    if (from == null || from < 1) {
                      setSt(() => errorText = '"Desde" debe ser ≥ 1.');
                      return;
                    }
                    if (to == null || to < from) {
                      setSt(() => errorText = '"Hasta" debe ser ≥ "Desde".');
                      return;
                    }
                    if (to - from + 1 > 200) {
                      setSt(
                        () => errorText =
                            'Máximo 200 mesas a la vez.',
                      );
                      return;
                    }
                    Navigator.pop(
                      dCtx,
                      _BulkTableResult(
                        prefix: prefix,
                        from: from,
                        to: to,
                        padding: padding,
                        capacity: capacity,
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF22C55E),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Crear mesas'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  InputDecoration _bulkInput(String hint) {
    return InputDecoration(
      hintText: hint,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 12,
      ),
      isDense: true,
    );
  }

  Future<void> _onEditTable(Zone zone, DiningTable t) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await _tableEditorDialog(
      title: 'Editar mesa ${t.code}',
      initialCode: t.code,
      initialLabel: t.label ?? '',
      initialCapacity: t.capacity,
    );
    if (result == null) return;

    try {
      await ref.read(zonesTablesVmProvider.notifier).updateTable(
            t.id,
            code: result.code,
            label: result.label,
            capacity: result.capacity,
            zoneId: zone.id,
          );
      if (!context.mounted) return;
      _showSuccess(messenger, 'Mesa actualizada');
    } catch (e) {
      if (!context.mounted) return;
      _showError(messenger, e.toString());
    }
  }

  /// PRD-12 F1: abre un dialog con las zonas activas del negocio
  /// (excepto la zona origen) y permite reasignar la mesa. Si el usuario
  /// confirma, llama al VM que invoca el RPC + refresca ambas zonas.
  Future<void> _onMoveTableToZone(Zone sourceZone, DiningTable t) async {
    final messenger = ScaffoldMessenger.of(context);
    final state = ref.read(zonesTablesVmProvider);
    final candidates = state.zones
        .where((z) => z.isActive && z.id != sourceZone.id)
        .toList(growable: false);

    if (candidates.isEmpty) {
      _showError(
        messenger,
        'No hay otras zonas activas a las que mover esta mesa.',
      );
      return;
    }

    final selectedZone = await showDialog<Zone>(
      context: context,
      builder: (dialogCtx) => _MoveTableZonePickerDialog(
        table: t,
        sourceZone: sourceZone,
        candidates: candidates,
      ),
    );

    if (selectedZone == null) return;
    if (!context.mounted) return;

    try {
      final moved = await ref
          .read(zonesTablesVmProvider.notifier)
          .moveTableToZone(
            tableId: t.id,
            targetZoneId: selectedZone.id,
            sourceZoneId: sourceZone.id,
          );
      if (!context.mounted) return;
      _showSuccess(
        messenger,
        moved
            ? 'Mesa ${t.code} movida a "${selectedZone.name}".'
            : 'La mesa ya estaba en "${selectedZone.name}".',
      );
    } catch (e) {
      if (!context.mounted) return;
      _showError(messenger, e.toString());
    }
  }

  Future<void> _onDeleteTable(Zone zone, DiningTable t) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _confirmDestructive(
      context,
      title: '¿Eliminar mesa ${t.code}?',
      message: 'Si la mesa tiene historial de ventas se desactivará '
          'automáticamente para preservar el histórico. En cualquier caso '
          'desaparece de la lista de mesas activas.',
      confirmLabel: 'Eliminar',
    );
    if (ok != true) return;

    try {
      final outcome = await ref
          .read(zonesTablesVmProvider.notifier)
          .deleteTable(t.id, zoneId: zone.id);
      if (!context.mounted) return;
      _showSuccess(
        messenger,
        outcome == DeleteOutcome.deleted
            ? 'Mesa eliminada'
            : 'Mesa desactivada (se conservó el historial)',
      );
    } catch (e) {
      if (!context.mounted) return;
      _showError(messenger, e.toString());
    }
  }

  // ---------- Modal rico de mesa ----------

  Future<_TableEditorResult?> _tableEditorDialog({
    required String title,
    required String initialCode,
    required String initialLabel,
    required int initialCapacity,
  }) async {
    final codeCtrl = TextEditingController(text: initialCode);
    final labelCtrl = TextEditingController(text: initialLabel);
    int capacity = initialCapacity.clamp(1, 50);

    return showDialog<_TableEditorResult>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setSt) => AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.white,
            title: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Código',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: codeCtrl,
                    autofocus: true,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      hintText: 'Ej: T01',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Etiqueta (opcional)',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: labelCtrl,
                    decoration: InputDecoration(
                      hintText: 'Ej: Mesa terraza grande',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Capacidad',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      IconButton.outlined(
                        onPressed: capacity <= 1
                            ? null
                            : () => setSt(() => capacity--),
                        icon: const Icon(Icons.remove),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '$capacity',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        capacity == 1 ? 'persona' : 'personas',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                      const SizedBox(width: 12),
                      IconButton.outlined(
                        onPressed: capacity >= 50
                            ? null
                            : () => setSt(() => capacity++),
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                style: TextButton.styleFrom(foregroundColor: Colors.grey[700]),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () {
                  final code = codeCtrl.text.trim();
                  if (code.isEmpty) return;
                  Navigator.pop(
                    dialogCtx,
                    _TableEditorResult(
                      code: code,
                      label: labelCtrl.text.trim(),
                      capacity: capacity,
                    ),
                  );
                },
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
      },
    );
  }

  // ---------- Confirmación destructiva con mensaje específico ----------

  Future<bool?> _confirmDestructive(
    BuildContext ctx, {
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    return showDialog<bool>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Text(message),
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
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  // ---------- Snackbar helpers ----------

  void _showSuccess(ScaffoldMessengerState messenger, String text) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: const Color(0xFF22C55E),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showError(ScaffoldMessengerState messenger, String text) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: Colors.red[600],
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'OK',
          textColor: Colors.white,
          onPressed: () {},
        ),
      ),
    );
    // Limpia el error del state para que no se quede pegado.
    Future.microtask(
      () => ref.read(zonesTablesVmProvider.notifier).clearError(),
    );
  }
}

// ============================================================
// Widgets privados y models del editor
// ============================================================

class _TableEditorResult {
  final String code;
  final String label;
  final int capacity;
  const _TableEditorResult({
    required this.code,
    required this.label,
    required this.capacity,
  });
}

enum _AddTableMode { single, bulk }

class _BulkTableResult {
  final String prefix;
  final int from;
  final int to;
  final int padding;
  final int capacity;
  const _BulkTableResult({
    required this.prefix,
    required this.from,
    required this.to,
    required this.padding,
    required this.capacity,
  });
}

/// Tile de mesa con menú contextual (3 puntos) que ofrece Editar / Eliminar.
/// Reemplaza el `Chip` ambiguo donde el `onTap` y la `X` chocaban: aquí el
/// tap general abre Editar, y el menú deja Eliminar como acción separada
/// y explícita.
class _TableTile extends StatelessWidget {
  final DiningTable table;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onReactivate;
  /// Acción "Mover a zona…" (PRD-12 F1). Abre un selector de zonas en
  /// el caller. Solo se muestra cuando la mesa está activa.
  final VoidCallback onMoveToZone;

  const _TableTile({
    required this.table,
    required this.onEdit,
    required this.onDelete,
    required this.onReactivate,
    required this.onMoveToZone,
  });

  @override
  Widget build(BuildContext context) {
    final inactive = !table.isActive;
    final hasLabel = (table.label ?? '').isNotEmpty && table.label != table.code;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        // Tap general: editar si activa, reactivar si inactiva.
        onTap: inactive ? onReactivate : onEdit,
        child: Container(
          width: 140,
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          decoration: BoxDecoration(
            color: inactive ? Colors.grey[100] : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: inactive
                  ? Colors.grey.withValues(alpha: 0.4)
                  : Colors.grey.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            table.code,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              color:
                                  inactive ? Colors.grey[600] : Colors.black87,
                              decoration: inactive
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ),
                        if (inactive) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey[300],
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: const Text(
                              'INACTIVA',
                              style: TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                                color: Colors.black54,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (hasLabel)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          table.label!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[600],
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Cap: ${table.capacity}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[500],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Acciones',
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.more_vert,
                  size: 18,
                  color: Colors.black54,
                ),
                onSelected: (value) {
                  switch (value) {
                    case 'edit':
                      onEdit();
                      break;
                    case 'move':
                      onMoveToZone();
                      break;
                    case 'delete':
                      onDelete();
                      break;
                    case 'reactivate':
                      onReactivate();
                      break;
                  }
                },
                itemBuilder: (_) => inactive
                    ? const [
                        PopupMenuItem(
                          value: 'reactivate',
                          child: Row(
                            children: [
                              Icon(
                                Icons.unarchive_outlined,
                                size: 18,
                                color: Color(0xFF2563EB),
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Reactivar',
                                style: TextStyle(color: Color(0xFF2563EB)),
                              ),
                            ],
                          ),
                        ),
                      ]
                    : const [
                        PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(Icons.edit_outlined, size: 18),
                              SizedBox(width: 8),
                              Text('Editar'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'move',
                          child: Row(
                            children: [
                              Icon(
                                Icons.swap_horiz_rounded,
                                size: 18,
                                color: Color(0xFF2563EB),
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Mover a otra zona…',
                                style: TextStyle(color: Color(0xFF2563EB)),
                              ),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: Colors.redAccent,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Eliminar',
                                style: TextStyle(color: Colors.redAccent),
                              ),
                            ],
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

/// PRD-12 F1: dialog para reasignar la zona de una mesa. Muestra lista
/// vertical con las zonas activas (excluyendo la zona origen). Al tap
/// devuelve el `Zone` seleccionado vía `Navigator.pop`. Cancelar
/// retorna `null` y el caller no hace nada.
class _MoveTableZonePickerDialog extends StatelessWidget {
  final DiningTable table;
  final Zone sourceZone;
  final List<Zone> candidates;

  const _MoveTableZonePickerDialog({
    required this.table,
    required this.sourceZone,
    required this.candidates,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Mover mesa ${table.code}',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Actualmente en "${sourceZone.name}". Selecciona la zona '
            'destino. La cuenta y los items se quedan intactos.',
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF6B7280),
              fontWeight: FontWeight.normal,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: candidates.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (ctx, i) {
            final zone = candidates[i];
            return InkWell(
              onTap: () => Navigator.pop(ctx, zone),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2563EB).withValues(
                          alpha: 0.10,
                        ),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.location_on_outlined,
                        color: Color(0xFF2563EB),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        zone.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: Color(0xFF111827),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: Colors.black38,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
