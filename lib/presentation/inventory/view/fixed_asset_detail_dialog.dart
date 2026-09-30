// Activos fijos — la ficha de un activo: todos sus datos, su historia y lo
// que se puede hacer con él (editar, trasladar / reasignar, cambiar estado,
// dar de baja o reactivar, imprimir el acta de asignación).
//
// Cada acción pasa por su RPC y el servidor deja la fila de historia; acá
// solo se vuelve a leer la historia para mostrarla.

import 'package:flutter/material.dart';

import '../../../core/currency/business_currency.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/repositories/fixed_assets_repository.dart';
import '../state/fixed_assets_state.dart';
import 'fixed_asset_form_dialog.dart';

Future<void> showFixedAssetDetailDialog(
  BuildContext context, {
  required FixedAsset asset,
  required FixedAssetsRepository repo,
  required String businessId,
  required List<FixedAssetOption> warehouses,
  required List<FixedAssetOption> employees,
  required List<String> knownCategories,
  required bool canManage,
  required BusinessCurrency money,
  required ValueChanged<FixedAsset> onChanged,
  required Future<void> Function(FixedAsset asset) onPrintAct,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => FixedAssetDetailDialog(
      asset: asset,
      repo: repo,
      businessId: businessId,
      warehouses: warehouses,
      employees: employees,
      knownCategories: knownCategories,
      canManage: canManage,
      money: money,
      onChanged: onChanged,
      onPrintAct: onPrintAct,
    ),
  );
}

/// Pastilla de estado: color + ícono + nombre (el color nunca va solo).
class FixedAssetStatusBadge extends StatelessWidget {
  const FixedAssetStatusBadge(this.status, {super.key, this.dense = false});

  final FixedAssetStatus status;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = status.color;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: dense ? 12 : 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              status.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: dense ? 11 : 12,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _fmtDateTime(DateTime? d) {
  if (d == null) return '';
  final l = d.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
}

class FixedAssetDetailDialog extends StatefulWidget {
  const FixedAssetDetailDialog({
    super.key,
    required this.asset,
    required this.repo,
    required this.businessId,
    required this.warehouses,
    required this.employees,
    required this.knownCategories,
    required this.canManage,
    required this.money,
    required this.onChanged,
    required this.onPrintAct,
  });

  final FixedAsset asset;
  final FixedAssetsRepository repo;
  final String businessId;
  final List<FixedAssetOption> warehouses;
  final List<FixedAssetOption> employees;
  final List<String> knownCategories;
  final bool canManage;
  final BusinessCurrency money;
  final ValueChanged<FixedAsset> onChanged;
  final Future<void> Function(FixedAsset asset) onPrintAct;

  @override
  State<FixedAssetDetailDialog> createState() => _FixedAssetDetailDialogState();
}

class _FixedAssetDetailDialogState extends State<FixedAssetDetailDialog> {
  late FixedAsset _asset = widget.asset;
  List<FixedAssetMovement> _history = const [];
  bool _loadingHistory = true;
  String? _historyError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _loadingHistory = true;
      _historyError = null;
    });
    try {
      final rows = await widget.repo.listMovements(_asset.id);
      if (!mounted) return;
      setState(() {
        _history = rows;
        _loadingHistory = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingHistory = false;
        _historyError = fixedAssetSaveError(e);
      });
    }
  }

  void _applied(FixedAsset updated) {
    setState(() => _asset = updated);
    widget.onChanged(updated);
    _loadHistory();
  }

  Future<void> _edit() async {
    final saved = await showFixedAssetFormDialog(
      context,
      repo: widget.repo,
      businessId: widget.businessId,
      warehouses: widget.warehouses,
      employees: widget.employees,
      knownCategories: widget.knownCategories,
      asset: _asset,
    );
    if (saved != null && mounted) _applied(saved);
  }

  Future<void> _move() async {
    final saved = await showDialog<FixedAsset>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MoveDialog(
        asset: _asset,
        repo: widget.repo,
        warehouses: widget.warehouses,
        employees: widget.employees,
      ),
    );
    if (saved != null && mounted) _applied(saved);
  }

  Future<void> _changeStatus() async {
    final saved = await showDialog<FixedAsset>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _StatusDialog(asset: _asset, repo: widget.repo),
    );
    if (saved != null && mounted) _applied(saved);
  }

  Future<void> _retire() async {
    final saved = await showDialog<FixedAsset>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _NoteActionDialog(
        title: 'Dar de baja ${_asset.code}',
        message:
            'Sale de la operación: deja de contar en el valor y se esconde '
            'de la lista (se ve con «Mostrar dados de baja»). La historia se '
            'conserva y se puede reactivar.',
        label: 'Motivo de la baja *',
        hint: 'Ej.: Se vendió, se dañó sin arreglo, se donó',
        confirm: 'Dar de baja',
        required: true,
        destructive: true,
        run: (note) => widget.repo.setStatus(
          assetId: _asset.id,
          status: FixedAssetStatus.retired,
          notes: note,
        ),
      ),
    );
    if (saved != null && mounted) _applied(saved);
  }

  Future<void> _reactivate() async {
    final saved = await showDialog<FixedAsset>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _NoteActionDialog(
        title: 'Reactivar ${_asset.code}',
        message: 'Vuelve a estar «En uso» y a contar en el valor del '
            'registro.',
        label: 'Nota (opcional)',
        hint: 'Ej.: Se reparó y volvió al salón',
        confirm: 'Reactivar',
        required: false,
        destructive: false,
        run: (note) => widget.repo.setStatus(
          assetId: _asset.id,
          status: FixedAssetStatus.active,
          notes: note,
        ),
      ),
    );
    if (saved != null && mounted) _applied(saved);
  }

  Future<void> _printAct() async {
    setState(() => _busy = true);
    try {
      await widget.onPrintAct(_asset);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 600;
    final a = _asset;
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: narrow ? 10 : 40,
        vertical: narrow ? 16 : 32,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 780, maxHeight: size.height * 0.92),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(a, narrow),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(narrow ? 14 : 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (a.status.isRetired) ...[
                      _RetiredBox(asset: a),
                      const SizedBox(height: 14),
                    ],
                    _fields(a),
                    const SizedBox(height: 18),
                    Text(
                      'Historia',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.foreground,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _historySection(),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: EdgeInsets.all(narrow ? 10 : 14),
              child: _actions(a),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(FixedAsset a, bool narrow) {
    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? 14 : 20, 12, 6, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      a.code,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                    FixedAssetStatusBadge(a.status),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  a.name,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppColors.foreground,
                  ),
                ),
                if (a.brandModel.isNotEmpty)
                  Text(
                    a.brandModel,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.mutedForeground,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Cerrar',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _fields(FixedAsset a) {
    final today = DateTime.now();
    final garantia = a.warrantyUntil == null
        ? '—'
        : '${fmtFixedAssetDate(a.warrantyUntil)}'
            '${a.warrantyActive(today) ? ' (vigente)' : ' (vencida)'}';
    final fields = <(String, String, IconData)>[
      ('Ubicación', a.locationLabel, Icons.place_outlined),
      ('Responsable', a.responsibleLabel, Icons.person_outline),
      ('Categoría', a.category ?? '—', Icons.category_outlined),
      ('Número de serie', a.serialNumber ?? '—', Icons.qr_code_2_rounded),
      (
        'Costo de compra',
        a.purchaseCost == null
            ? '—'
            : widget.money.formatAmount(a.purchaseCost!),
        Icons.payments_outlined,
      ),
      (
        'Fecha de compra',
        a.purchaseDate == null ? '—' : fmtFixedAssetDate(a.purchaseDate),
        Icons.event_outlined,
      ),
      ('Proveedor', a.supplierName ?? '—', Icons.storefront_outlined),
      ('Garantía hasta', garantia, Icons.verified_user_outlined),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 520 ? 2 : 1;
        const gap = 12.0;
        final w = (c.maxWidth - gap * (cols - 1)) / cols;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: gap,
              runSpacing: 10,
              children: [
                for (final f in fields)
                  SizedBox(
                    width: w,
                    child: _FieldTile(label: f.$1, value: f.$2, icon: f.$3),
                  ),
              ],
            ),
            if ((a.notes ?? '').isNotEmpty) ...[
              const SizedBox(height: 10),
              _FieldTile(
                label: 'Notas',
                value: a.notes!,
                icon: Icons.notes_rounded,
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _historySection() {
    if (_loadingHistory) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_historyError != null) {
      return Row(
        children: [
          Expanded(
            child: Text(
              _historyError!,
              style: TextStyle(color: AppColors.destructive, fontSize: 12),
            ),
          ),
          TextButton(onPressed: _loadHistory, child: const Text('Reintentar')),
        ],
      );
    }
    if (_history.isEmpty) {
      return Text(
        'Sin movimientos registrados.',
        style: TextStyle(color: AppColors.mutedForeground, fontSize: 13),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < _history.length; i++)
          _HistoryTile(
            movement: _history[i],
            last: i == _history.length - 1,
          ),
      ],
    );
  }

  Widget _actions(FixedAsset a) {
    final retired = a.status.isRetired;
    final disabled = _busy;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: [
        OutlinedButton.icon(
          key: const Key('fixed-asset-act'),
          onPressed: disabled ? null : _printAct,
          icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
          label: const Text('Acta de asignación'),
        ),
        if (widget.canManage) ...[
          OutlinedButton.icon(
            key: const Key('fixed-asset-edit'),
            onPressed: disabled ? null : _edit,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Editar'),
          ),
          if (!retired) ...[
            OutlinedButton.icon(
              key: const Key('fixed-asset-move'),
              onPressed: disabled ? null : _move,
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: const Text('Trasladar / reasignar'),
            ),
            OutlinedButton.icon(
              key: const Key('fixed-asset-status'),
              onPressed: disabled ? null : _changeStatus,
              icon: const Icon(Icons.flag_outlined, size: 18),
              label: const Text('Cambiar estado'),
            ),
            FilledButton.tonalIcon(
              key: const Key('fixed-asset-retire'),
              onPressed: disabled ? null : _retire,
              style: FilledButton.styleFrom(
                foregroundColor: AppColors.destructive,
              ),
              icon: const Icon(Icons.do_not_disturb_on_outlined, size: 18),
              label: const Text('Dar de baja'),
            ),
          ] else
            FilledButton.icon(
              key: const Key('fixed-asset-reactivate'),
              onPressed: disabled ? null : _reactivate,
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('Reactivar'),
            ),
        ],
      ],
    );
  }
}

class _FieldTile extends StatelessWidget {
  const _FieldTile({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppColors.mutedForeground),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.mutedForeground,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(fontSize: 14, color: AppColors.foreground),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RetiredBox extends StatelessWidget {
  const _RetiredBox({required this.asset});

  final FixedAsset asset;

  @override
  Widget build(BuildContext context) {
    final cuando = asset.retiredAt == null
        ? ''
        : ' el ${fmtFixedAssetDate(asset.retiredAt!.toLocal())}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.muted,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Text(
        'Dado de baja$cuando. Motivo: ${asset.retiredReason ?? '—'}',
        style: TextStyle(fontSize: 13, color: AppColors.foreground),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.movement, required this.last});

  final FixedAssetMovement movement;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final m = movement;
    final quien = m.createdByName;
    final meta = [
      _fmtDateTime(m.createdAt),
      ?quien,
    ].where((s) => s.isNotEmpty).join(' · ');
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: AppColors.muted,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    m.eventType.icon,
                    size: 15,
                    color: AppColors.foreground,
                  ),
                ),
                if (!last)
                  Expanded(
                    child: Container(width: 1.5, color: AppColors.border),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 14, top: 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.eventType.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: AppColors.foreground,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    m.description,
                    style: TextStyle(fontSize: 13, color: AppColors.foreground),
                  ),
                  if ((m.notes ?? '').isNotEmpty)
                    Text(
                      '«${m.notes}»',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontStyle: FontStyle.italic,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  if (meta.isNotEmpty)
                    Text(
                      meta,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Diálogos de acción ─────────────────────────────────────────────────────

class _MoveDialog extends StatefulWidget {
  const _MoveDialog({
    required this.asset,
    required this.repo,
    required this.warehouses,
    required this.employees,
  });

  final FixedAsset asset;
  final FixedAssetsRepository repo;
  final List<FixedAssetOption> warehouses;
  final List<FixedAssetOption> employees;

  @override
  State<_MoveDialog> createState() => _MoveDialogState();
}

class _MoveDialogState extends State<_MoveDialog> {
  late String? _warehouseId = widget.asset.warehouseId;
  late String? _employeeId = widget.asset.assignedEmployeeId;
  late final _location = TextEditingController(
    text: widget.asset.locationNote ?? '',
  );
  final _notes = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _location.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final a = widget.asset;
    final location = _location.text.trim();
    final sameWh = _warehouseId == a.warehouseId;
    final sameLoc = location == (a.locationNote ?? '');
    final sameEmp = _employeeId == a.assignedEmployeeId;
    if (sameWh && sameLoc && sameEmp) {
      setState(() => _error = 'No cambiaste la ubicación ni el responsable.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.repo.moveAsset(
        assetId: a.id,
        warehouseId: _warehouseId,
        locationNote: location.isEmpty ? null : location,
        employeeId: _employeeId,
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      );
      if (!mounted) return;
      AppToast.success(context, '${saved.code} actualizado.');
      Navigator.pop(context, saved);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = fixedAssetSaveError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.asset;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return AlertDialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: narrow ? 12 : 40,
        vertical: 24,
      ),
      title: Text('Trasladar / reasignar ${a.code}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ahora: ${a.locationLabel} · ${a.responsibleLabel}',
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppColors.mutedForeground,
                ),
              ),
              const SizedBox(height: 12),
              FixedAssetWarehouseDropdown(
                warehouses: widget.warehouses,
                value: _warehouseId,
                currentName: a.warehouseName.isEmpty ? null : a.warehouseName,
                onChanged: (v) => setState(() => _warehouseId = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _location,
                decoration: const InputDecoration(
                  labelText: 'Nota de ubicación',
                  hintText: 'Ej.: Barra, al lado de la caja',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              FixedAssetEmployeeDropdown(
                employees: widget.employees,
                value: _employeeId,
                currentName: a.employeeName.isEmpty ? null : a.employeeName,
                onChanged: (v) => setState(() => _employeeId = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Motivo (opcional)',
                  hintText: 'Queda en la historia',
                  isDense: true,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(color: AppColors.destructive, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

class _StatusDialog extends StatefulWidget {
  const _StatusDialog({required this.asset, required this.repo});

  final FixedAsset asset;
  final FixedAssetsRepository repo;

  @override
  State<_StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends State<_StatusDialog> {
  late FixedAssetStatus _status = widget.asset.status;
  final _notes = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_status == widget.asset.status) {
      setState(() => _error = 'Elige un estado distinto al actual.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.repo.setStatus(
        assetId: widget.asset.id,
        status: _status,
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      );
      if (!mounted) return;
      AppToast.success(context, '${saved.code}: ${saved.status.label}.');
      Navigator.pop(context, saved);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = fixedAssetSaveError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return AlertDialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: narrow ? 12 : 40,
        vertical: 24,
      ),
      title: Text('Estado de ${widget.asset.code}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in FixedAssetStatus.selectable)
                    ChoiceChip(
                      key: ValueKey('fixed-asset-status-${s.wire}'),
                      avatar: Icon(s.icon, size: 16, color: s.color),
                      label: Text(s.label),
                      selected: _status == s,
                      onSelected: (_) => setState(() => _status = s),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Nota (opcional)',
                  hintText: 'Ej.: No enfría; se llamó al técnico',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Para sacarlo del registro usa «Dar de baja».',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.mutedForeground,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(color: AppColors.destructive, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

/// Confirmación con nota: sirve para la baja (motivo obligatorio) y para
/// reactivar (nota opcional).
class _NoteActionDialog extends StatefulWidget {
  const _NoteActionDialog({
    required this.title,
    required this.message,
    required this.label,
    required this.hint,
    required this.confirm,
    required this.required,
    required this.destructive,
    required this.run,
  });

  final String title;
  final String message;
  final String label;
  final String hint;
  final String confirm;
  final bool required;
  final bool destructive;
  final Future<FixedAsset> Function(String? note) run;

  @override
  State<_NoteActionDialog> createState() => _NoteActionDialogState();
}

class _NoteActionDialogState extends State<_NoteActionDialog> {
  final _note = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final note = _note.text.trim();
    if (widget.required && note.isEmpty) {
      setState(() => _error = 'Escribe el motivo.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.run(note.isEmpty ? null : note);
      if (!mounted) return;
      AppToast.success(context, '${saved.code}: ${saved.status.label}.');
      Navigator.pop(context, saved);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = fixedAssetSaveError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return AlertDialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: narrow ? 12 : 40,
        vertical: 24,
      ),
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.message),
              const SizedBox(height: 12),
              TextField(
                key: const Key('fixed-asset-note'),
                controller: _note,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: widget.label,
                  hintText: widget.hint,
                  isDense: true,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(color: AppColors.destructive, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('fixed-asset-note-confirm'),
          style: widget.destructive
              ? FilledButton.styleFrom(backgroundColor: AppColors.destructive)
              : null,
          onPressed: _saving ? null : _save,
          child: Text(widget.confirm),
        ),
      ],
    );
  }
}
