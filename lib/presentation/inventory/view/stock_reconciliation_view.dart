import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/inventory_state.dart';
import '../viewmodel/inventory_viewmodel.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';

/// Catálogo de razones de ajuste (Sprint Inventario V1.1, migración 0017).
/// El backend valida que el `reason_code` esté en este enum: si agregas o
/// quitas valores acá, sincroniza el CHECK constraint en la DB.
class _AdjustReason {
  final String code;
  final String label;
  final String description;
  final IconData icon;
  const _AdjustReason(this.code, this.label, this.description, this.icon);
}

const List<_AdjustReason> _kAdjustReasons = [
  _AdjustReason(
    'physical_count',
    'Conteo físico',
    'Cuadrar con la realidad de la bodega',
    Icons.fact_check_rounded,
  ),
  _AdjustReason(
    'breakage',
    'Rotura / dañado',
    'Producto roto o no apto para venta',
    Icons.broken_image_rounded,
  ),
  _AdjustReason(
    'expiration',
    'Vencido',
    'Producto vencido o caducado',
    Icons.event_busy_rounded,
  ),
  _AdjustReason(
    'theft',
    'Faltante / robo',
    'Faltante sospechoso o pérdida',
    Icons.no_accounts_rounded,
  ),
  _AdjustReason(
    'donation',
    'Donación / cortesía',
    'Regalo, donación o cortesía',
    Icons.volunteer_activism_rounded,
  ),
  _AdjustReason(
    'correction',
    'Corrección',
    'Corrección de error operativo',
    Icons.edit_note_rounded,
  ),
  _AdjustReason(
    'other',
    'Otro',
    'Otro motivo (requiere notas)',
    Icons.more_horiz_rounded,
  ),
];

class StockReconciliationView extends ConsumerStatefulWidget {
  const StockReconciliationView({super.key});

  @override
  ConsumerState<StockReconciliationView> createState() =>
      _StockReconciliationViewState();
}

class _StockReconciliationViewState
    extends ConsumerState<StockReconciliationView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(inventoryViewModelProvider).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(inventoryViewModelProvider).state;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Ajustes de inventario')),
      body: state.loading && state.items.isEmpty
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : ListView.separated(
              padding: const EdgeInsets.all(24),
              itemCount: state.items.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final item = state.items[index];
                return Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(color: AppColors.border),
                    boxShadow: AppShadows.soft,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppColors.foreground,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Actual: ${item.stock.toStringAsFixed(2)} ${item.unit} · Mínimo: ${item.minStock.toStringAsFixed(2)}',
                              style: TextStyle(
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          ],
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: state.saving
                            ? null
                            : () => _showAdjustDialog(context, item),
                        child: const Text('Ajustar'),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Future<void> _showAdjustDialog(
    BuildContext context,
    InventoryItemSummary item,
  ) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _AdjustDialog(item: item),
    );
  }
}

class _AdjustDialog extends ConsumerStatefulWidget {
  final InventoryItemSummary item;
  const _AdjustDialog({required this.item});

  @override
  ConsumerState<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends ConsumerState<_AdjustDialog> {
  late final TextEditingController _countedController;
  late final TextEditingController _notesController;
  _AdjustReason? _selectedReason;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _countedController = TextEditingController(
      text: widget.item.stock.toStringAsFixed(2),
    );
    _notesController = TextEditingController();
  }

  @override
  void dispose() {
    _countedController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  double get _countedValue {
    return double.tryParse(_countedController.text.trim().replaceAll(',', '.')) ??
        widget.item.stock;
  }

  double get _delta => _countedValue - widget.item.stock;

  bool get _notesRequired => _selectedReason?.code == 'other';

  String? _validate() {
    if (_selectedReason == null) {
      return 'Selecciona un motivo de ajuste';
    }
    final raw = _countedController.text.trim();
    if (raw.isEmpty) return 'Ingresa la cantidad contada';
    final parsed = double.tryParse(raw.replaceAll(',', '.'));
    if (parsed == null || parsed < 0) return 'Cantidad inválida';
    if (_delta == 0) {
      return 'El stock contado es igual al actual; nada que ajustar';
    }
    if (_notesRequired && _notesController.text.trim().isEmpty) {
      return 'Las notas son obligatorias cuando el motivo es "Otro"';
    }
    return null;
  }

  Future<void> _submit() async {
    final error = _validate();
    if (error != null) {
      setState(() => _errorMessage = error);
      return;
    }
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(inventoryViewModelProvider)
          .adjustInventory(
            itemId: widget.item.id,
            countedStock: _countedValue,
            reasonCode: _selectedReason!.code,
            notes: _notesController.text.trim().isEmpty
                ? null
                : _notesController.text.trim(),
          );
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Ajuste registrado: ${_delta > 0 ? '+' : ''}${_delta.toStringAsFixed(2)} ${widget.item.unit}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = _humanizeError(e.toString());
      });
    }
  }

  String _humanizeError(String raw) {
    if (raw.contains('INSUFFICIENT_ROLE')) {
      return 'No tienes permisos para ajustar inventario';
    }
    if (raw.contains('NO_CHANGE')) {
      return 'El stock contado es igual al actual';
    }
    if (raw.contains('NOTES_REQUIRED_FOR_OTHER')) {
      return 'Las notas son obligatorias para motivo "Otro"';
    }
    if (raw.contains('INVALID_COUNTED_QUANTITY')) {
      return 'Cantidad contada inválida';
    }
    if (raw.contains('REASON_REQUIRED')) {
      return 'Selecciona un motivo';
    }
    return 'Error: $raw';
  }

  @override
  Widget build(BuildContext context) {
    final delta = _delta;
    final deltaColor = delta == 0
        ? AppColors.mutedForeground
        : (delta > 0 ? Colors.green.shade700 : Colors.red.shade700);

    return AlertDialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      title: Text('Ajustar ${widget.item.name}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.inventory_2_outlined,
                      color: AppColors.mutedForeground,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Stock actual: ${widget.item.stock.toStringAsFixed(2)} ${widget.item.unit}',
                        style: TextStyle(
                          color: AppColors.foreground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _countedController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Stock contado',
                  helperText: 'Cantidad física verificada en la bodega',
                  suffixText: widget.item.unit,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: deltaColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                child: Row(
                  children: [
                    Icon(
                      delta == 0
                          ? Icons.remove
                          : (delta > 0
                                ? Icons.arrow_upward
                                : Icons.arrow_downward),
                      color: deltaColor,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Diferencia: ${delta > 0 ? '+' : ''}${delta.toStringAsFixed(2)} ${widget.item.unit}',
                      style: TextStyle(
                        color: deltaColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Motivo del ajuste',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<_AdjustReason>(
                initialValue: _selectedReason,
                isExpanded: true,
                decoration: InputDecoration(
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                  hintText: 'Selecciona un motivo',
                ),
                items: _kAdjustReasons
                    .map(
                      (r) => DropdownMenuItem(
                        value: r,
                        child: Row(
                          children: [
                            Icon(
                              r.icon,
                              size: 18,
                              color: AppColors.mutedForeground,
                            ),
                            const SizedBox(width: 10),
                            Expanded(child: Text(r.label)),
                          ],
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (r) => setState(() => _selectedReason = r),
              ),
              if (_selectedReason != null) ...[
                const SizedBox(height: 6),
                Text(
                  _selectedReason!.description,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              TextField(
                controller: _notesController,
                maxLines: 3,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: _notesRequired
                      ? 'Notas (obligatorias)'
                      : 'Notas (opcional)',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                ),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: Colors.red.shade700,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(color: Colors.red.shade700),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Guardar ajuste'),
        ),
      ],
    );
  }
}
