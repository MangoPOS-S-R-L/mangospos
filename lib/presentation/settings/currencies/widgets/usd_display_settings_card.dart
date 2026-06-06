// PRD 6 §6.1 — Sub-sección "Moneda Secundaria (Display)" para la
// pantalla de Impuestos y Moneda.
//
// Permite al admin/dueño:
//   - Activar/desactivar el módulo USD display-only
//   - Configurar la tasa de cambio manualmente
//   - Ver la última actualización
//   - Recibir aviso visual cuando la tasa tiene >7 días sin actualizar
//
// NO cambia precios de productos, NO procesa pagos en USD. Solo controla
// si se muestra el equivalente USD debajo del total en checkout/recibos.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../app/theme/mango_colors.dart';
import '../../../../data/repositories/pos_settings_repository.dart';

class UsdDisplaySettingsCard extends ConsumerStatefulWidget {
  const UsdDisplaySettingsCard({super.key, required this.businessId});

  final String businessId;

  @override
  ConsumerState<UsdDisplaySettingsCard> createState() =>
      _UsdDisplaySettingsCardState();
}

class _UsdDisplaySettingsCardState
    extends ConsumerState<UsdDisplaySettingsCard> {
  final _rateController = TextEditingController();
  final _symbolController = TextEditingController(text: 'US\$');
  bool _enabled = false;
  String _symbolPosition = 'before';
  DateTime? _rateUpdatedAt;
  bool _isLoading = true;
  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _rateController.dispose();
    _symbolController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);
    try {
      final settings = await ref
          .read(posSettingsRepositoryProvider)
          .getUsdDisplaySettings(widget.businessId);
      if (!mounted) return;
      setState(() {
        _enabled = settings.enabled;
        _symbolController.text = settings.symbol;
        _rateController.text =
            settings.rate?.toString() ?? '';
        _symbolPosition = settings.symbolPosition;
        _rateUpdatedAt = settings.rateUpdatedAt;
        _isLoading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error cargando configuración: $e';
        _isLoading = false;
      });
    }
  }

  /// PRD §6.1: si toggle ON + rate invalida → bloquea con error.
  String? _validateRate() {
    if (!_enabled) return null; // toggle off → no validar
    final raw = _rateController.text.trim();
    if (raw.isEmpty) {
      return 'Debe ingresar una tasa de cambio válida.';
    }
    final parsed = Decimal.tryParse(raw);
    if (parsed == null) return 'Formato inválido. Ej: 60.50';
    if (parsed < Decimal.parse('1.0') ||
        parsed > Decimal.parse('999.9999')) {
      return 'La tasa debe estar entre 1.00 y 999.9999';
    }
    return null;
  }

  Future<void> _save() async {
    final rateError = _validateRate();
    if (rateError != null) {
      setState(() => _error = rateError);
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      final rate = _enabled && _rateController.text.trim().isNotEmpty
          ? Decimal.parse(_rateController.text.trim())
          : null;

      final settings = UsdDisplaySettings(
        enabled: _enabled,
        symbol: _symbolController.text.trim().isEmpty
            ? 'US\$'
            : _symbolController.text.trim(),
        rate: rate,
        rateUpdatedAt: null, // trigger en DB lo pone solo
        symbolPosition: _symbolPosition,
      );

      await ref
          .read(posSettingsRepositoryProvider)
          .setUsdDisplaySettings(
            businessId: widget.businessId,
            settings: settings,
          );

      if (!mounted) return;
      await _loadSettings(); // recarga para tomar el `usd_rate_updated_at`
      if (!mounted) return;
      AppToast.success(context, 'Configuración USD guardada.');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error guardando: $e';
      });
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  bool get _isRateStale {
    if (!_enabled) return false;
    final updated = _rateUpdatedAt;
    if (updated == null) return false;
    return DateTime.now().difference(updated).inDays > 7;
  }

  int? get _daysSinceUpdate {
    final updated = _rateUpdatedAt;
    if (updated == null) return null;
    return DateTime.now().difference(updated).inDays;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return _buildShell(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        ],
      );
    }

    return _buildShell(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Row(
            children: [
              const Icon(
                Icons.currency_exchange,
                color: MangoColors.primaryOrange,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Moneda Secundaria (Display)',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: MangoColors.darkGray,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Muestra el equivalente USD del total en checkout y recibos. '
                      'NO procesa pagos en USD — solo display.',
                      style: TextStyle(
                        fontSize: 12,
                        color: MangoColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              Switch.adaptive(
                value: _enabled,
                onChanged: (v) => setState(() {
                  _enabled = v;
                  if (!v) _error = null;
                }),
                activeThumbColor: MangoColors.primaryOrange,
              ),
            ],
          ),
        ),
        if (_enabled) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Banner amarillo si tasa stale (>7 días) — PRD §6.1
                if (_isRateStale) ...[
                  _StaleRateBanner(days: _daysSinceUpdate ?? 0),
                  const SizedBox(height: 12),
                ],
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: _LabeledField(
                        label: 'Tasa de cambio (RD\$ por 1 USD)',
                        helper: 'Ej: 60.50',
                        child: TextField(
                          controller: _rateController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.]'),
                            ),
                          ],
                          decoration: const InputDecoration(
                            hintText: '60.50',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _LabeledField(
                        label: 'Símbolo',
                        helper: 'Max 5 caracteres',
                        child: TextField(
                          controller: _symbolController,
                          maxLength: 5,
                          decoration: const InputDecoration(
                            hintText: 'US\$',
                            border: OutlineInputBorder(),
                            isDense: true,
                            counterText: '',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _LabeledField(
                        label: 'Posición del símbolo',
                        helper: _symbolPosition == 'before'
                            ? 'US\$ 89.26'
                            : '89.26 US\$',
                        child: DropdownButtonFormField<String>(
                          initialValue: _symbolPosition,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'before',
                              child: Text('Antes (US\$ 89.26)'),
                            ),
                            DropdownMenuItem(
                              value: 'after',
                              child: Text('Después (89.26 US\$)'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) {
                              setState(() => _symbolPosition = v);
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _LabeledField(
                        label: 'Última actualización',
                        helper: _rateUpdatedAt == null
                            ? 'Sin guardar aún'
                            : _formatUpdatedAt(_rateUpdatedAt!),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: MangoColors.bgLight,
                            border: Border.all(
                              color: MangoColors.cardBorder,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _rateUpdatedAt == null
                                ? '—'
                                : DateFormat(
                                    'dd/MM/yyyy HH:mm',
                                  ).format(_rateUpdatedAt!.toLocal()),
                            style: const TextStyle(
                              fontSize: 14,
                              color: MangoColors.darkGray,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: MangoColors.primaryOrange,
                  foregroundColor: MangoColors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: _isSaving ? null : _save,
                icon: _isSaving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save, size: 18),
                label: Text(_isSaving ? 'Guardando...' : 'Guardar'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildShell({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  String _formatUpdatedAt(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Hace segundos';
    if (diff.inHours < 1) return 'Hace ${diff.inMinutes} min';
    if (diff.inDays < 1) return 'Hace ${diff.inHours}h';
    return 'Hace ${diff.inDays} días';
  }
}

class _StaleRateBanner extends StatelessWidget {
  const _StaleRateBanner({required this.days});

  final int days;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.12),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: Colors.amber, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'La tasa USD no se actualiza desde hace $days días. '
              'Considera revisarla para reflejar el cambio actual.',
              style: const TextStyle(
                fontSize: 12,
                color: MangoColors.darkGray,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({
    required this.label,
    required this.child,
    this.helper,
  });

  final String label;
  final Widget child;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: MangoColors.darkGray,
          ),
        ),
        const SizedBox(height: 6),
        child,
        if (helper != null) ...[
          const SizedBox(height: 4),
          Text(
            helper!,
            style: const TextStyle(
              fontSize: 11,
              color: MangoColors.muted,
            ),
          ),
        ],
      ],
    );
  }
}
