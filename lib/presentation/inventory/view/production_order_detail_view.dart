// Detalle de orden de producción: header + líneas + acciones según
// el status actual.
//
// Workflow visible:
//   draft       → [Iniciar producción] [Cancelar]
//   in_progress → [Completar producción] [Cancelar]
//   completed   → solo vista (lectura)
//   cancelled   → solo vista

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/repositories/production_repository.dart';
import 'package:mangopos/services/session/session_controller.dart';

class ProductionOrderDetailView extends ConsumerStatefulWidget {
  final String orderId;
  const ProductionOrderDetailView({super.key, required this.orderId});

  @override
  ConsumerState<ProductionOrderDetailView> createState() =>
      _ProductionOrderDetailViewState();
}

class _ProductionOrderDetailViewState
    extends ConsumerState<ProductionOrderDetailView> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  ProductionOrderDetail? _detail;
  bool _dirty = false;

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
          .read(productionRepositoryProvider)
          .getDetail(widget.orderId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudo cargar la orden: $e';
        _loading = false;
      });
    }
  }

  Future<void> _start() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(productionRepositoryProvider).start(widget.orderId);
      _dirty = true;
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo iniciar: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openComplete() async {
    final detail = _detail;
    if (detail == null) return;
    final completed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CompleteProductionDialog(detail: detail),
    );
    if (completed == true) {
      _dirty = true;
      await _load();
    }
  }

  Future<void> _openCancel() async {
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancelar orden'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'La orden se marcará como cancelada. No se mueve inventario.',
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
      await ref.read(productionRepositoryProvider).cancel(
            orderId: widget.orderId,
            reason: reasonCtrl.text.trim().isEmpty
                ? null
                : reasonCtrl.text.trim(),
          );
      _dirty = true;
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo cancelar: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canComplete = ref
        .read(sessionProvider.notifier)
        .hasPermission('produccion.completar');
    final canCancel =
        ref.read(sessionProvider.notifier).hasPermission('produccion.anular');

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.of(context).pop(_dirty);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F7F7),
        appBar: AppBar(
          title: Text(_detail?.header.code ?? 'Orden de producción'),
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
                : _buildContent(canComplete, canCancel),
      ),
    );
  }

  Widget _buildContent(bool canComplete, bool canCancel) {
    final d = _detail!;
    final h = d.header;
    final canActOnDraft = h.status == ProductionOrderStatus.draft;
    final canActOnInProgress = h.status == ProductionOrderStatus.inProgress;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HeaderCard(header: h),
          const SizedBox(height: 16),
          _LinesCard(lines: d.lines, header: h),
          const SizedBox(height: 20),
          Row(
            children: [
              if (canActOnDraft && canComplete) ...[
                FilledButton.icon(
                  onPressed: _busy ? null : _start,
                  style: FilledButton.styleFrom(
                    backgroundColor: MangoColors.primaryOrange,
                  ),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Iniciar producción'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _openComplete,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Completar directo'),
                ),
              ],
              if (canActOnInProgress && canComplete)
                FilledButton.icon(
                  onPressed: _busy ? null : _openComplete,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF059669),
                  ),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Completar producción'),
                ),
              const Spacer(),
              if ((canActOnDraft || canActOnInProgress) && canCancel)
                TextButton.icon(
                  onPressed: _busy ? null : _openCancel,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFDC2626),
                  ),
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Cancelar orden'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final ProductionOrderSummary header;
  const _HeaderCard({required this.header});

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd MMM yyyy HH:mm');
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
            header.finishedItemName,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              _Metric(
                label: 'Cantidad planeada',
                value:
                    '${_fmtQty(header.plannedYield)} ${header.finishedItemUnit}',
              ),
              if (header.actualYield != null)
                _Metric(
                  label: 'Cantidad producida',
                  value:
                      '${_fmtQty(header.actualYield!)} ${header.finishedItemUnit}',
                  highlight: true,
                ),
              _Metric(
                label: 'Bodega origen',
                value: header.sourceWarehouseName,
              ),
              _Metric(
                label: 'Bodega destino',
                value: header.destinationWarehouseName,
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 12),
          _TimestampRow(
            label: 'Creada',
            timestamp: dateFormat.format(header.createdAt),
          ),
          if (header.startedAt != null)
            _TimestampRow(
              label: 'Iniciada',
              timestamp: dateFormat.format(header.startedAt!),
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
                ? const Color(0xFF059669)
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

class _LinesCard extends StatelessWidget {
  final List<ProductionOrderLine> lines;
  final ProductionOrderSummary header;
  const _LinesCard({required this.lines, required this.header});

  @override
  Widget build(BuildContext context) {
    final completed = header.status == ProductionOrderStatus.completed;
    final cancelled = header.status == ProductionOrderStatus.cancelled;
    final showConsumed = completed || cancelled;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              'Insumos',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: MangoColors.darkGray,
              ),
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
            child: Row(
              children: [
                const Expanded(
                  flex: 5,
                  child: Text(
                    'Insumo',
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
                    showConsumed ? 'Planeado' : 'A consumir',
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: MangoColors.muted,
                    ),
                  ),
                ),
                if (showConsumed)
                  const Expanded(
                    flex: 2,
                    child: Text(
                      'Consumido',
                      textAlign: TextAlign.end,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: MangoColors.muted,
                      ),
                    ),
                  ),
                const Expanded(
                  flex: 2,
                  child: Text(
                    'Costo unit.',
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
          ...lines.map((l) => _LineRow(line: l, showConsumed: showConsumed)),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  final ProductionOrderLine line;
  final bool showConsumed;
  const _LineRow({required this.line, required this.showConsumed});

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(
      symbol: 'RD\$',
      decimalDigits: 2,
      locale: 'en_US',
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Text(
              line.itemName,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: MangoColors.darkGray,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${_fmtQty(line.plannedQuantity)} ${line.unit}',
              textAlign: TextAlign.end,
              style: const TextStyle(color: MangoColors.muted),
            ),
          ),
          if (showConsumed)
            Expanded(
              flex: 2,
              child: Text(
                line.consumedQuantity == null
                    ? '—'
                    : '${_fmtQty(line.consumedQuantity!)} ${line.unit}',
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: line.consumedQuantity == null
                      ? MangoColors.muted
                      : MangoColors.darkGray,
                ),
              ),
            ),
          Expanded(
            flex: 2,
            child: Text(
              line.costPerUnit == null
                  ? '—'
                  : currency.format(line.costPerUnit),
              textAlign: TextAlign.end,
              style: const TextStyle(color: MangoColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Diálogo de completar producción
// =============================================================================

class _CompleteProductionDialog extends ConsumerStatefulWidget {
  final ProductionOrderDetail detail;
  const _CompleteProductionDialog({required this.detail});

  @override
  ConsumerState<_CompleteProductionDialog> createState() =>
      _CompleteProductionDialogState();
}

class _CompleteProductionDialogState
    extends ConsumerState<_CompleteProductionDialog> {
  late TextEditingController _yieldCtrl;
  late Map<String, TextEditingController> _lineCtrls;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _yieldCtrl = TextEditingController(
      text: _fmtQty(widget.detail.header.plannedYield),
    );
    _lineCtrls = {
      for (final l in widget.detail.lines)
        l.itemId: TextEditingController(text: _fmtQty(l.plannedQuantity)),
    };
  }

  @override
  void dispose() {
    _yieldCtrl.dispose();
    for (final c in _lineCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final actualYield = double.tryParse(_yieldCtrl.text.replaceAll(',', '.'));
    if (actualYield == null || actualYield <= 0) {
      setState(() => _error = 'Cantidad producida inválida.');
      return;
    }
    final overrides = <String, double>{};
    for (final l in widget.detail.lines) {
      final raw = _lineCtrls[l.itemId]?.text.replaceAll(',', '.');
      final v = double.tryParse(raw ?? '');
      if (v == null || v < 0) {
        setState(() => _error = 'Cantidad consumida inválida en ${l.itemName}.');
        return;
      }
      overrides[l.itemId] = v;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(productionRepositoryProvider).complete(
            orderId: widget.detail.header.id,
            actualYield: actualYield,
            lineConsumption: overrides,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'No se pudo completar: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Completar ${widget.detail.header.code}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Ajusta las cantidades reales si hubo mermas. El sistema '
                'generará movimientos en el kardex y recalculará el costo '
                'del producto terminado.',
                style: TextStyle(fontSize: 12, color: MangoColors.muted),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _yieldCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText:
                      'Cantidad producida (${widget.detail.header.finishedItemUnit})',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Consumo real de insumos',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: MangoColors.muted,
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: widget.detail.lines.map((l) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: Text(l.itemName,
                                  overflow: TextOverflow.ellipsis),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: _lineCtrls[l.itemId],
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                  decimal: true,
                                ),
                                decoration: InputDecoration(
                                  border: const OutlineInputBorder(),
                                  isDense: true,
                                  suffixText: l.unit,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(growable: false),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: const TextStyle(
                        color: Color(0xFFDC2626), fontSize: 12)),
              ],
              const SizedBox(height: 16),
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
                      backgroundColor: const Color(0xFF059669),
                    ),
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Completar producción'),
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

Color _statusColor(ProductionOrderStatus s) {
  switch (s) {
    case ProductionOrderStatus.draft:
      return const Color(0xFF6B7280);
    case ProductionOrderStatus.inProgress:
      return MangoColors.primaryOrange;
    case ProductionOrderStatus.completed:
      return const Color(0xFF059669);
    case ProductionOrderStatus.cancelled:
      return const Color(0xFFDC2626);
  }
}

String _fmtQty(double v) {
  if (v == v.truncate()) return v.truncate().toString();
  return v.toStringAsFixed(2);
}
