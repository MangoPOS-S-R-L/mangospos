// Selector de PAÍS del negocio. La moneda base se DERIVA del país elegido
// (ver lib/core/business/country_profile.dart) y se muestra antes de guardar.
// MODO LEGACY: persiste SOLO `business_settings.currency_code` (la columna
// `country_code` aún no existe en la BD viva). Luego invalida el provider de
// moneda para que toda la app tome el cambio sin reiniciar.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/utils/app_toast.dart';

import '../../../../app/theme/mango_colors.dart';
import '../../../../core/business/country_profile.dart';
import '../../../../core/currency/business_currency_provider.dart';
import '../../../../data/repositories/pos_settings_repository.dart';

class BusinessCurrencySettingsCard extends ConsumerStatefulWidget {
  const BusinessCurrencySettingsCard({super.key, required this.businessId});

  final String businessId;

  @override
  ConsumerState<BusinessCurrencySettingsCard> createState() =>
      _BusinessCurrencySettingsCardState();
}

class _BusinessCurrencySettingsCardState
    extends ConsumerState<BusinessCurrencySettingsCard> {
  String _countryCode = 'DO';
  bool _isLoading = true;
  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final code = await ref
          .read(posSettingsRepositoryProvider)
          .getCountryCode(widget.businessId);
      if (!mounted) return;
      setState(() {
        _countryCode =
            CountryProfile.catalog.containsKey(code) ? code : 'DO';
        _isLoading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error cargando el país: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await ref.read(posSettingsRepositoryProvider).setBusinessCountry(
            businessId: widget.businessId,
            countryCode: _countryCode,
          );
      // Toda la app lee la moneda vía businessCurrencyProvider — invalidarlo
      // hace que reportes, recibos y dashboards tomen la nueva moneda al vuelo.
      ref.invalidate(businessCurrencyProvider(widget.businessId));
      if (!mounted) return;
      AppToast.success(context, 'País y moneda actualizados.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Error guardando: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = CountryProfile.fromCode(_countryCode);
    final currency = profile.currency;
    return Container(
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Row(
              children: const [
                Icon(Icons.public,
                    color: MangoColors.primaryOrange, size: 22),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'País y moneda del negocio',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: MangoColors.darkGray,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Elige el país: la moneda en la que se cobra y se '
                        'reporta se ajusta automáticamente.',
                        style:
                            TextStyle(fontSize: 12, color: MangoColors.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _countryCode,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'País',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final c in CountryProfile.all)
                        DropdownMenuItem(
                          value: c.code,
                          child: Text(
                            '${c.name} — ${c.currency.symbol} (${c.currencyCode})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _isSaving
                        ? null
                        : (v) {
                            if (v != null) setState(() => _countryCode = v);
                          },
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Moneda: ${currency.name} (${currency.code}) · '
                    'Ejemplo: ${currency.formatAmount(1234.56)}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: MangoColors.darkGray,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
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
                  onPressed: (_isSaving || _isLoading) ? null : _save,
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
      ),
    );
  }
}
