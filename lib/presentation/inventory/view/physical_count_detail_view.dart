// Detalle de sesión de conteo físico: header + líneas + acciones.
//
// Workflow visible:
//   draft       → [Congelar inventario] [Cancelar]
//   in_progress → editor de conteo por línea + [Completar conteo] [Cancelar]
//   completed   → solo vista (snapshot vs contado vs diferencia)
//   cancelled   → solo vista

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/repositories/physical_count_repository.dart';
import 'package:mangopos/services/session/session_controller.dart';

class PhysicalCountDetailView extends ConsumerStatefulWidget {
  final String sessionId;
  const PhysicalCountDetailView({super.key, required this.sessionId});

  @override
  ConsumerState<PhysicalCountDetailView> createState() =>
      _PhysicalCountDetailViewState();
}

class _PhysicalCountDetailViewState
    extends ConsumerState<PhysicalCountDetailView> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  PhysicalCountDetail? _detail;
  bool _dirty = false;

  // Filtro: ocultar líneas ya contadas para enfocarse en las pendientes.
  bool _onlyPending = false;

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
      final detail = await ref
          .read(physicalCountRepositoryProvider)
          .getDetail(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudo cargar la sesión: $e';
        _loading = false;
      });
    }
  }

  Future<void> _freeze() async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Congelar inventario'),
        content: const Text(
          'Se tomará un snapshot del stock actual de la bodega. A partir '
          'de este momento podrás registrar el conteo físico real para '
          'cada item.\n\n'
          'Sugerencia: detén entradas/salidas de la bodega mientras dure '
          'el conteo para no introducir desfases.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Congelar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(physicalCountRepositoryProvider)
          .freeze(widget.sessionId);
      _dirty = true;
      await _load();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo congelar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openComplete() async {
    final detail = _detail;
    if (detail == null) return;
    final pending = detail.lines.where((l) => l.countedQuantity == null).length;
    final adjustments = detail.lines.where((l) {
      final v = l.variance;
      return v != null && v.abs() >= 0.0001;
    }).toList(growable: false);

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _CompleteConfirmDialog(
        pending: pending,
        adjustments: adjustments,
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(physicalCountRepositoryProvider)
          .complete(widget.sessionId);
      _dirty = true;
      await _load();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo completar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openCancel() async {
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancelar sesión'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'La sesión se marcará como cancelada. No se generarán '
              'ajustes ni se moverá inventario.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Razón (opcional)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No, mantener'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sí, cancelar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(physicalCountRepositoryProvider).cancel(
            sessionId: widget.sessionId,
            reason: reasonCtrl.text.trim().isEmpty
                ? null
                : reasonCtrl.text.trim(),
          );
      _dirty = true;
      await _load();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo cancelar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveLine(PhysicalCountLine line, double value) async {
    try {
      await ref.read(physicalCountRepositoryProvider).setCount(
            sessionId: widget.sessionId,
            itemId: line.itemId,
            countedQuantity: value,
          );
      _dirty = true;
      // Recargar para actualizar contadores en header.
      await _load();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo guardar el conteo: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionCtrl = ref.read(sessionProvider.notifier);
    final canCreate = sessionCtrl.hasPermission('inventario.conteo.crear');
    final canComplete =
        sessionCtrl.hasPermission('inventario.conteo.completar');
    final canCancel = sessionCtrl.hasPermission('inventario.conteo.anular');

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.of(context).pop(_dirty);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F7F7),
        appBar: AppBar(
          title: Text(_detail?.header.code ?? 'Conteo físico'),
          backgroundColor: Colors.white,
          foregroundColor: MangoColors.darkGray,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(_dirty),
          ),
        ),
        body: _loading
            ? const Center(
                child: CircularProgressIndicator(
                  valueColor:
                      AlwaysStoppedAnimation(MangoColors.primaryOrange),
                ),
              )
            : _error != null
                ? Center(child: Text(_error!))
                : _buildContent(canCreate, canComplete, canCancel),
      ),
    );
  }

  Widget _buildContent(bool canCreate, bool canComplete, bool canCancel) {
    final d = _detail!;
    final h = d.header;
    final canActOnDraft = h.status == PhysicalCountStatus.draft;
    final canActOnInProgress = h.status == PhysicalCountStatus.inProgress;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HeaderCard(header: h),
          const SizedBox(height: 16),
          if (canActOnDraft && d.lines.isEmpty)
            _EmptyDraftHint()
          else
            _LinesCard(
              lines: d.lines,
              header: h,
              onlyPending: _onlyPending,
              onTogglePending: (v) => setState(() => _onlyPending = v),
              onSaveLine: canActOnInProgress ? _saveLine : null,
            ),
          const SizedBox(height: 20),
          Row(
            children: [
              if (canActOnDraft && canCreate)
                FilledButton.icon(
                  onPressed: _busy ? null : _freeze,
                  style: FilledButton.styleFrom(
                    backgroundColor: MangoColors.primaryOrange,
                  ),
                  icon: const Icon(Icons.ac_unit_rounded),
                  label: const Text('Congelar inventario'),
                ),
              if (canActOnInProgress && canComplete)
                FilledButton.icon(
                  onPressed: _busy ? null : _openComplete,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF059669),
                  ),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Completar conteo'),
                ),
              const Spacer(),
              if ((canActOnDraft || canActOnInProgress) && canCancel)
                TextButton.icon(
                  onPressed: _busy ? null : _openCancel,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFDC2626),
                  ),
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Cancelar sesión'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Header
// =============================================================================

class _HeaderCard extends StatelessWidget {
  final PhysicalCountSummary header;
  const _HeaderCard({required this.header});

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd MMM yyyy HH:mm');
    final progress = header.linesCount == 0
        ? 0.0
        : header.countedLines / header.linesCount;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: _statusColor(header.status).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  header.status.label,
                  style: TextStyle(
                    color: _statusColor(header.status),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                header.code,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  letterSpacing: 0.3,
                  color: MangoColors.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            header.warehouseName,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              _Metric(
                label: 'Items en sesión',
                value: header.linesCount.toString(),
              ),
              _Metric(
                label: 'Items contados',
                value: '${header.countedLines} / ${header.linesCount}',
                highlight: header.status == PhysicalCountStatus.inProgress,
              ),
              if (header.status == PhysicalCountStatus.completed)
                _Metric(
                  label: 'Ajustes aplicados',
                  value: header.adjustmentsCount.toString(),
                  highlight: true,
                ),
            ],
          ),
          if (header.status == PhysicalCountStatus.inProgress &&
              header.linesCount > 0) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: progress.clamp(0.0, 1.0),
                backgroundColor: const Color(0xFFF1F5F9),
                valueColor: const AlwaysStoppedAnimation(
                  MangoColors.primaryOrange,
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 12),
          _TimestampRow(
            label: 'Creada',
            timestamp: dateFormat.format(header.startedAt),
          ),
          if (header.frozenAt != null)
            _TimestampRow(
              label: 'Congelada',
              timestamp: dateFormat.format(header.frozenAt!),
            ),
          if (header.completedAt != null)
            _TimestampRow(
              label: 'Completada',
              timestamp: dateFormat.format(header.completedAt!),
            ),
          if (header.cancelledAt != null)
            _TimestampRow(
              label: 'Cancelada',
              timestamp: dateFormat.format(header.cancelledAt!),
            ),
          if (header.notes != null && header.notes!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                header.notes!,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
          if (header.cancellationReason != null &&
              header.cancellationReason!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFCA5A5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.cancel_outlined,
                      size: 16, color: Color(0xFFDC2626)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Razón: ${header.cancellationReason!}',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF991B1B)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;
  const _Metric({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: MangoColors.muted,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: highlight
                ? MangoColors.primaryOrange
                : MangoColors.darkGray,
          ),
        ),
      ],
    );
  }
}

class _TimestampRow extends StatelessWidget {
  final String label;
  final String timestamp;
  const _TimestampRow({required this.label, required this.timestamp});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(
                  fontSize: 11, color: MangoColors.muted),
            ),
          ),
          Text(
            timestamp,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: MangoColors.darkGray,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyDraftHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFED7AA)),
      ),
      child: Row(
        children: [
          const Icon(Icons.ac_unit_rounded,
              size: 28, color: MangoColors.primaryOrange),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sesión en borrador',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: MangoColors.darkGray,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Aún no has congelado el stock. Cuando estés listo, '
                  'congela el inventario para tomar el snapshot por '
                  'item y empezar el conteo.',
                  style: TextStyle(
                      fontSize: 12, color: MangoColors.darkGray),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Líneas
// =============================================================================

class _LinesCard extends StatelessWidget {
  final List<PhysicalCountLine> lines;
  final PhysicalCountSummary header;
  final bool onlyPending;
  final ValueChanged<bool> onTogglePending;
  final Future<void> Function(PhysicalCountLine, double)? onSaveLine;
  const _LinesCard({
    required this.lines,
    required this.header,
    required this.onlyPending,
    required this.onTogglePending,
    required this.onSaveLine,
  });

  @override
  Widget build(BuildContext context) {
    final editable = header.status == PhysicalCountStatus.inProgress &&
        onSaveLine != null;
    final visible = onlyPending && editable
        ? lines.where((l) => l.countedQuantity == null).toList(growable: false)
        : lines;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
            child: Row(
              children: [
                const Text(
                  'Items a contar',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: MangoColors.darkGray,
                  ),
                ),
                const Spacer(),
                if (editable)
                  Row(
                    children: [
                      const Text(
                        'Solo pendientes',
                        style: TextStyle(
                            fontSize: 12, color: MangoColors.muted),
                      ),
                      Switch(
                        value: onlyPending,
                        activeTrackColor: MangoColors.primaryOrange,
                        onChanged: onTogglePending,
                      ),
                    ],
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFFF8FAFC),
              border: Border(
                top: BorderSide(color: Color(0xFFE5E7EB)),
                bottom: BorderSide(color: Color(0xFFE5E7EB)),
              ),
            ),
            child: const Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Text(
                    'Item',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: MangoColors.muted,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    'Snapshot',
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: MangoColors.muted,
                    ),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    'Contado',
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: MangoColors.muted,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    'Diferencia',
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: MangoColors.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  onlyPending
                      ? 'No hay items pendientes 🎉'
                      : 'Sin items en esta sesión',
                  style: const TextStyle(color: MangoColors.muted),
                ),
              ),
            )
          else
            ...visible.map((l) => _LineRow(
                  line: l,
                  editable: editable,
                  onSave: onSaveLine,
                )),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _LineRow extends StatefulWidget {
  final PhysicalCountLine line;
  final bool editable;
  final Future<void> Function(PhysicalCountLine, double)? onSave;
  const _LineRow({
    required this.line,
    required this.editable,
    required this.onSave,
  });

  @override
  State<_LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<_LineRow> {
  late TextEditingController _ctrl;
  late FocusNode _focus;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.line.countedQuantity == null
          ? ''
          : _fmtQty(widget.line.countedQuantity!),
    );
    _focus = FocusNode();
    _focus.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _LineRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si llega un valor nuevo desde backend y no estamos editando, sincronizar.
    if (!_focus.hasFocus &&
        oldWidget.line.countedQuantity != widget.line.countedQuantity) {
      _ctrl.text = widget.line.countedQuantity == null
          ? ''
          : _fmtQty(widget.line.countedQuantity!);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) {
      _maybeSave();
    }
  }

  Future<void> _maybeSave() async {
    final raw = _ctrl.text.replaceAll(',', '.').trim();
    if (raw.isEmpty) return;
    final v = double.tryParse(raw);
    if (v == null || v < 0) {
      AppToast.info(
        context,
        'Cantidad inválida en "${widget.line.itemName}".',
      );
      return;
    }
    if (widget.line.countedQuantity != null &&
        (widget.line.countedQuantity! - v).abs() < 0.0001) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave?.call(widget.line, v);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    final variance = line.variance;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.itemName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: MangoColors.darkGray,
                  ),
                ),
                if (line.counterNotes != null &&
                    line.counterNotes!.isNotEmpty)
                  Text(
                    line.counterNotes!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: MangoColors.muted,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${_fmtQty(line.snapshotQuantity)} ${line.unit}',
              textAlign: TextAlign.end,
              style: const TextStyle(color: MangoColors.muted),
            ),
          ),
          Expanded(
            flex: 3,
            child: widget.editable
                ? Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      textAlign: TextAlign.end,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onSubmitted: (_) => _maybeSave(),
                      decoration: InputDecoration(
                        isDense: true,
                        border: const OutlineInputBorder(),
                        suffixText: line.unit,
                        hintText: '—',
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        suffixIcon: _saving
                            ? const Padding(
                                padding: EdgeInsets.all(8),
                                child: SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    ),
                  )
                : Text(
                    line.countedQuantity == null
                        ? '—'
                        : '${_fmtQty(line.countedQuantity!)} ${line.unit}',
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: line.countedQuantity == null
                          ? MangoColors.muted
                          : MangoColors.darkGray,
                    ),
                  ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              variance == null
                  ? '—'
                  : '${variance > 0 ? '+' : ''}${_fmtQty(variance)} ${line.unit}',
              textAlign: TextAlign.end,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: variance == null
                    ? MangoColors.muted
                    : (variance.abs() < 0.0001
                        ? const Color(0xFF059669)
                        : (variance > 0
                            ? const Color(0xFF059669)
                            : const Color(0xFFDC2626))),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Diálogo de completar conteo
// =============================================================================

class _CompleteConfirmDialog extends StatelessWidget {
  final int pending;
  final List<PhysicalCountLine> adjustments;
  const _CompleteConfirmDialog({
    required this.pending,
    required this.adjustments,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Completar conteo físico',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Se generarán movimientos de ajuste por cada diferencia entre '
                'el snapshot y el conteo. Los items sin diferencia no generan '
                'movimiento. Items sin contar no se ajustan.',
                style: TextStyle(fontSize: 12, color: MangoColors.muted),
              ),
              if (pending > 0) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFDE68A)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded,
                          size: 18, color: Color(0xFFD97706)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Hay $pending item(s) sin contar. Si continúas, esos '
                          'items no generarán ajustes y se quedarán con el '
                          'stock actual.',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF92400E)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                adjustments.isEmpty
                    ? 'Sin diferencias — no se generarán ajustes.'
                    : 'Ajustes a generar (${adjustments.length})',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: MangoColors.muted,
                ),
              ),
              const SizedBox(height: 8),
              if (adjustments.isNotEmpty)
                Flexible(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        children: adjustments.map((l) {
                          final v = l.variance!;
                          final sign = v > 0 ? '+' : '';
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    l.itemName,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                Text(
                                  '$sign${_fmtQty(v)} ${l.unit}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: v > 0
                                        ? const Color(0xFF059669)
                                        : const Color(0xFFDC2626),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(growable: false),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Volver'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF059669),
                    ),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Aplicar ajustes y cerrar'),
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

String _fmtQty(double v) {
  if (v == v.truncate()) return v.truncate().toString();
  return v.toStringAsFixed(2);
}
