// Historial de salidas / mermas con filtro por MOTIVO (Salidas / Mermas).
//
// Pedido del dueño (2026-09-30): «hay que agregar filtros para saber la razón
// de la merma o salida». Reemplaza a «Últimos movimientos» (8 movimientos de
// cualquier tipo, sin motivo): acá salen las mermas del período con su motivo,
// cuánto costaron y cada una imprimible sola; el total se lee por motivo.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/currency/business_currency.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_shadows.dart';
import '../../state/inventory_state.dart';
import '../../state/outflow_reasons.dart';
import '../../utils/outflow_note.dart';

String _fmtQty(double v) {
  final s = v.toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

class OutflowHistorySection extends StatefulWidget {
  const OutflowHistorySection({
    super.key,
    required this.reloadKey,
    required this.load,
    required this.itemsById,
    required this.money,
    required this.onPrintTicket,
    required this.onPrintA4,
    this.onOpenYield,
  });

  /// Cambia cuando hay que volver a leer (otra bodega, una salida nueva).
  final String reloadKey;
  final Future<List<InventoryMovementEntry>> Function(int days) load;

  /// Para la unidad y el costo de respaldo de cada insumo.
  final Map<String, InventoryItemSummary> itemsById;
  final BusinessCurrency money;
  final Future<void> Function(InventoryMovementEntry movement) onPrintTicket;
  final Future<void> Function(List<InventoryMovementEntry> movements) onPrintA4;

  /// Abre «Rendimiento y mermas».
  final VoidCallback? onOpenYield;

  @override
  State<OutflowHistorySection> createState() => _OutflowHistorySectionState();
}

class _OutflowHistorySectionState extends State<OutflowHistorySection> {
  static const _pageSize = 30;
  static final _dateFormat = DateFormat('dd/MM HH:mm');

  int _days = 7;
  String? _reason;
  int _visible = _pageSize;
  bool _loading = true;
  String? _error;
  List<InventoryMovementEntry> _entries = const [];
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant OutflowHistorySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadKey != widget.reloadKey) _reload();
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.load(_days);
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = entries;
        _loading = false;
        _visible = _pageSize;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = 'No se pudieron leer las salidas. Revisa la conexión.';
        _loading = false;
      });
    }
  }

  double _costOf(InventoryMovementEntry m) {
    final unitCost = m.costPerUnit ?? widget.itemsById[m.itemId]?.cost ?? 0;
    return m.quantity.abs() * unitCost;
  }

  @override
  Widget build(BuildContext context) {
    // Totales por motivo del período (sin el filtro, para los chips).
    final byReason = <String, ({int count, double value})>{};
    for (final m in _entries) {
      final code = m.outflowReason;
      final prev = byReason[code];
      byReason[code] = (
        count: (prev?.count ?? 0) + 1,
        value: (prev?.value ?? 0) + _costOf(m),
      );
    }
    final reasonsPresent = [
      for (final r in kOutflowReasons)
        if (byReason.containsKey(r.code)) r,
    ];
    final filtered = _reason == null
        ? _entries
        : _entries.where((m) => m.outflowReason == _reason).toList();
    final total = filtered.fold<double>(0, (s, m) => s + _costOf(m));
    final shown = filtered.take(_visible).toList(growable: false);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.cardElevated,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    Text(
                      'Salidas y mermas',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppColors.foreground,
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SegmentedButton<int>(
                          key: const Key('outflow-history-period'),
                          segments: const [
                            ButtonSegment(value: 1, label: Text('Hoy')),
                            ButtonSegment(value: 7, label: Text('7 días')),
                            ButtonSegment(value: 30, label: Text('30 días')),
                          ],
                          selected: {_days},
                          showSelectedIcon: false,
                          onSelectionChanged: (v) {
                            setState(() => _days = v.first);
                            _reload();
                          },
                        ),
                        OutlinedButton.icon(
                          key: const Key('outflow-history-a4'),
                          onPressed: _loading || filtered.isEmpty
                              ? null
                              : () => widget.onPrintA4(filtered),
                          icon: const Icon(
                            Icons.description_outlined,
                            size: 18,
                          ),
                          label: const Text('Imprimir lista (A4)'),
                        ),
                        if (widget.onOpenYield != null)
                          TextButton.icon(
                            onPressed: widget.onOpenYield,
                            icon: const Icon(
                              Icons.donut_large_outlined,
                              size: 18,
                            ),
                            label: const Text('Ver rendimiento'),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      key: const Key('outflow-reason-all'),
                      label: Text('Todos · ${_entries.length}'),
                      selected: _reason == null,
                      onSelected: (_) => setState(() {
                        _reason = null;
                        _visible = _pageSize;
                      }),
                    ),
                    for (final r in reasonsPresent)
                      ChoiceChip(
                        key: ValueKey('outflow-reason-${r.code}'),
                        avatar: Icon(r.icon, size: 16),
                        label: Text('${r.label} · ${byReason[r.code]!.count}'),
                        selected: _reason == r.code,
                        onSelected: (_) => setState(() {
                          _reason = _reason == r.code ? null : r.code;
                          _visible = _pageSize;
                        }),
                      ),
                  ],
                ),
                if (!_loading && _error == null && filtered.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    '${filtered.length} ${filtered.length == 1 ? 'salida' : 'salidas'} · '
                    '${widget.money.formatAmount(total)}'
                    '${_reason == null ? '' : ' por «${outflowReasonByCode(_reason!).label}»'}',
                    key: const Key('outflow-history-summary'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.foreground,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text(_error!, style: TextStyle(color: AppColors.destructive)),
                  TextButton.icon(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Reintentar'),
                  ),
                ],
              ),
            )
          else if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 32,
                      color: AppColors.mutedForeground,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _reason == null
                          ? (_days == 1
                                ? 'No hay salidas registradas hoy.'
                                : 'No hay salidas en los últimos $_days días.')
                          : 'Ninguna salida por ese motivo en el período.',
                      style: TextStyle(color: AppColors.mutedForeground),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            for (final m in shown) _row(m),
            if (filtered.length > shown.length)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: TextButton.icon(
                    onPressed: () => setState(() => _visible += _pageSize),
                    icon: const Icon(Icons.expand_more),
                    label: Text(
                      'Ver más (${filtered.length - shown.length} restantes)',
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _row(InventoryMovementEntry m) {
    final reason = outflowReasonByCode(m.outflowReason);
    final unit = widget.itemsById[m.itemId]?.unit ?? '';
    final note = splitOutflowNote(m.notes).detail;
    return Container(
      key: ValueKey('outflow-history-${m.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.muted,
            child: Icon(reason.icon, size: 18, color: AppColors.foreground),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${m.itemName} · −${_fmtQty(m.quantity.abs())}'
                  '${unit.isEmpty ? '' : ' $unit'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    reason.label,
                    _dateFormat.format(m.createdAt),
                    if (m.destination != null) 'Para ${m.destination}',
                    if (note.isNotEmpty) note,
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            widget.money.formatAmount(_costOf(m)),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
          IconButton(
            tooltip: 'Reimprimir ticket',
            icon: const Icon(Icons.receipt_long_outlined, size: 20),
            onPressed: () => widget.onPrintTicket(m),
          ),
          IconButton(
            tooltip: 'Imprimir hoja A4',
            icon: const Icon(Icons.description_outlined, size: 20),
            onPressed: () => widget.onPrintA4([m]),
          ),
        ],
      ),
    );
  }
}
