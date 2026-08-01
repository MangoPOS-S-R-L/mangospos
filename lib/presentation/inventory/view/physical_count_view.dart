// Conteo físico — lista de sesiones + crear + navegación al detalle.
// El detalle vive en `physical_count_detail_view.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/repositories/physical_count_repository.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';
import 'package:mangopos/presentation/inventory/view/physical_count_detail_view.dart';
import 'package:mangopos/presentation/inventory/viewmodel/inventory_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';

class PhysicalCountView extends ConsumerStatefulWidget {
  const PhysicalCountView({super.key});

  @override
  ConsumerState<PhysicalCountView> createState() => _PhysicalCountViewState();
}

class _PhysicalCountViewState extends ConsumerState<PhysicalCountView> {
  String? _businessId;
  bool _loading = true;
  String? _error;
  List<PhysicalCountSummary> _sessions = const [];
  final Set<PhysicalCountStatus> _activeFilters = {
    PhysicalCountStatus.draft,
    PhysicalCountStatus.inProgress,
    PhysicalCountStatus.completed,
  };

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final id = await BusinessResolver.ensure('auto');
      _businessId = id;
      final list = await ref
          .read(physicalCountRepositoryProvider)
          .listByBusiness(
            businessId: id,
            statusFilter: _activeFilters.isEmpty ? null : _activeFilters,
          );
      if (!mounted) return;
      setState(() {
        _sessions = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudieron cargar las sesiones: $e';
        _loading = false;
      });
    }
  }

  void _toggleFilter(PhysicalCountStatus s) {
    setState(() {
      if (_activeFilters.contains(s)) {
        _activeFilters.remove(s);
      } else {
        _activeFilters.add(s);
      }
    });
    _load();
  }

  Future<void> _openCreate() async {
    final bid = _businessId;
    if (bid == null) return;
    final created = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CreatePhysicalCountDialog(businessId: bid),
    );
    if (created == true) _load();
  }

  Future<void> _openDetail(PhysicalCountSummary s) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PhysicalCountDetailView(sessionId: s.id),
      ),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final sessionCtrl = ref.watch(sessionProvider.notifier);
    final canCreate = sessionCtrl.hasPermission('inventario.conteo.crear');
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: MangoColors.darkGray,
                      padding: const EdgeInsets.symmetric(horizontal: 0),
                    ),
                    onPressed: () => context.go(AppRoutes.inventoryHome),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Regresar'),
                  ),
                  const Spacer(),
                  if (canCreate)
                    FilledButton.icon(
                      onPressed: _openCreate,
                      style: FilledButton.styleFrom(
                        backgroundColor: MangoColors.primaryOrange,
                      ),
                      icon: const Icon(Icons.add),
                      label: const Text('Nueva sesión'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Conteo físico',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: MangoColors.darkGray,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Cierre de inventario: congela el stock, cuenta a ciegas y '
                'el sistema aplica los ajustes por cada diferencia.',
                style: TextStyle(fontSize: 13, color: MangoColors.muted),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: PhysicalCountStatus.values
                    .map((s) => FilterChip(
                          selected: _activeFilters.contains(s),
                          onSelected: (_) => _toggleFilter(s),
                          label: Text(s.label),
                          selectedColor: _statusColor(s).withValues(alpha: 0.18),
                          checkmarkColor: _statusColor(s),
                        ))
                    .toList(growable: false),
              ),
              const SizedBox(height: 16),
              Expanded(child: _buildList()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation(MangoColors.primaryOrange),
        ),
      );
    }
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (_sessions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.fact_check_outlined, size: 72, color: MangoColors.muted),
            SizedBox(height: 12),
            Text(
              'Sin sesiones de conteo',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: MangoColors.darkGray,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Crea una sesión, elige la bodega y empieza a contar.',
              style: TextStyle(fontSize: 12, color: MangoColors.muted),
            ),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: ListView.separated(
        itemCount: _sessions.length,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
        itemBuilder: (ctx, i) => _SessionRow(
          session: _sessions[i],
          onTap: () => _openDetail(_sessions[i]),
        ),
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  final PhysicalCountSummary session;
  final VoidCallback onTap;
  const _SessionRow({required this.session, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('dd MMM yyyy HH:mm').format(session.startedAt);
    final progress = session.linesCount == 0
        ? 0.0
        : session.countedLines / session.linesCount;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 56,
              decoration: BoxDecoration(
                color: _statusColor(session.status),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          session.code,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                            letterSpacing: 0.3,
                            color: MangoColors.darkGray,
                          ),
                        ),
                      ),
                      if (session.isBlind) ...[
                        const SizedBox(width: 6),
                        const Tooltip(
                          message: 'Conteo a ciegas',
                          child: Icon(
                            Icons.visibility_off_outlined,
                            size: 14,
                            color: MangoColors.muted,
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    date,
                    style: const TextStyle(
                      fontSize: 11,
                      color: MangoColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.warehouseName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  Text(
                    session.status == PhysicalCountStatus.completed
                        ? '${session.linesCount} items · '
                            '${session.adjustmentsCount} ajustes'
                        : '${session.countedLines} / ${session.linesCount} '
                            'items contados',
                    style: const TextStyle(
                      fontSize: 11,
                      color: MangoColors.muted,
                    ),
                  ),
                  if (session.pendingRecount > 0)
                    Text(
                      '${session.pendingRecount} por recontar',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFD97706),
                      ),
                    ),
                  if (session.status == PhysicalCountStatus.completed &&
                      session.shrinkageValue.abs() >= 0.01)
                    Text(
                      'Merma ${_fmtMoney(session.shrinkageValue)}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFDC2626),
                      ),
                    ),
                  if (session.status == PhysicalCountStatus.inProgress) ...[
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 4,
                      child: LinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
                        backgroundColor: const Color(0xFFF1F5F9),
                        valueColor: const AlwaysStoppedAnimation(
                          MangoColors.primaryOrange,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _statusColor(session.status).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                session.status.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _statusColor(session.status),
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, color: MangoColors.muted),
          ],
        ),
      ),
    );
  }
}

// Igual que el resto del módulo de inventario (ver
// `consolidated_inventory_view.dart`), la moneda va fija en RD$.
final _currency = NumberFormat.currency(
  locale: 'en_US',
  symbol: 'RD\$ ',
  decimalDigits: 2,
);

String _fmtMoney(double v) => _currency.format(v);

Color _statusColor(PhysicalCountStatus s) {
  switch (s) {
    case PhysicalCountStatus.draft:
      return const Color(0xFF6B7280);
    case PhysicalCountStatus.inProgress:
      return MangoColors.primaryOrange;
    case PhysicalCountStatus.completed:
      return const Color(0xFF059669);
    case PhysicalCountStatus.cancelled:
      return const Color(0xFFDC2626);
  }
}

// =============================================================================
// Dialog de creación
// =============================================================================

class _CreatePhysicalCountDialog extends ConsumerStatefulWidget {
  final String businessId;
  const _CreatePhysicalCountDialog({required this.businessId});

  @override
  ConsumerState<_CreatePhysicalCountDialog> createState() =>
      _CreatePhysicalCountDialogState();
}

class _CreatePhysicalCountDialogState
    extends ConsumerState<_CreatePhysicalCountDialog> {
  bool _loading = true;
  bool _submitting = false;
  String? _error;
  List<InventoryWarehouse> _warehouses = const [];
  String? _warehouseId;
  // Un cierre de mes normalmente se cuenta a ciegas.
  bool _isBlind = true;
  final TextEditingController _notesCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(inventoryRepositoryProvider);
      final warehouses = await repo.getWarehouses(widget.businessId);
      if (!mounted) return;
      setState(() {
        // Excluir __IN_TRANSIT__ — no es una bodega física contable.
        _warehouses = warehouses
            .where((w) => w.name != '__IN_TRANSIT__')
            .toList(growable: false);
        if (_warehouses.isNotEmpty) {
          final main = _warehouses.firstWhere(
            (w) => w.isMain,
            orElse: () => _warehouses.first,
          );
          _warehouseId = main.id;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error cargando bodegas: $e';
        _loading = false;
      });
    }
  }

  Future<void> _submit() async {
    if (_warehouseId == null) {
      setState(() => _error = 'Selecciona una bodega.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(physicalCountRepositoryProvider).create(
            businessId: widget.businessId,
            warehouseId: _warehouseId!,
            notes: _notesCtrl.text.trim().isEmpty
                ? null
                : _notesCtrl.text.trim(),
            isBlind: _isBlind,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'No se pudo crear la sesión: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _loading
              ? const SizedBox(
                  height: 160,
                  child: Center(
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation(
                        MangoColors.primaryOrange,
                      ),
                    ),
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Nueva sesión de conteo físico',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Selecciona la bodega a contar. Después podrás congelar '
                      'el stock para empezar el conteo.',
                      style: TextStyle(fontSize: 12, color: MangoColors.muted),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: _warehouseId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Bodega',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: _warehouses
                          .map((w) => DropdownMenuItem<String>(
                                value: w.id,
                                child: Text(w.name +
                                    (w.isMain ? ' (principal)' : '')),
                              ))
                          .toList(growable: false),
                      onChanged: (v) => setState(() => _warehouseId = v),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: _isBlind
                            ? const Color(0xFFFFF7ED)
                            : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: _isBlind
                              ? const Color(0xFFFED7AA)
                              : const Color(0xFFE5E7EB),
                        ),
                      ),
                      child: SwitchListTile(
                        value: _isBlind,
                        onChanged: (v) => setState(() => _isBlind = v),
                        activeThumbColor: MangoColors.primaryOrange,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        title: const Text(
                          'Conteo a ciegas',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          _isBlind
                              ? 'Quien cuenta no verá el stock del sistema ni '
                                  'la diferencia. Se revelan al completar.'
                              : 'Se mostrará el stock del sistema mientras se '
                                  'cuenta.',
                          style: const TextStyle(
                            fontSize: 11,
                            color: MangoColors.muted,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _notesCtrl,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Notas (opcional)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: const TextStyle(
                          color: Color(0xFFDC2626),
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: _submitting
                              ? null
                              : () => Navigator.of(context).pop(false),
                          child: const Text('Cancelar'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: MangoColors.primaryOrange,
                          ),
                          onPressed: _warehouses.isEmpty || _submitting
                              ? null
                              : _submit,
                          child: _submitting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Crear'),
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
