// PRD 6 §6.2 — Widget reusable que muestra el equivalente USD de un
// total DOP debajo de la línea principal del total.
//
// Tipografía: ~70% del tamaño del total principal, color gris
// secundario (no resaltado). PRD §6.2.
//
// Reacciona automáticamente al provider de USD settings — si el
// admin cambia la tasa en Settings, este widget se actualiza al
// próximo rebuild sin necesidad de pasar la tasa explícita.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/pos_settings_repository.dart';
import 'usd_conversion.dart';

/// Provider que cachea las settings USD del business activo.
/// Se invalida cuando se llama a `ref.invalidate(usdSettingsProvider(...))`
/// después de guardar cambios en Settings.
final usdSettingsProvider =
    FutureProvider.family<UsdDisplaySettings, String>((ref, businessId) async {
  if (businessId.isEmpty) return const UsdDisplaySettings.disabled();
  final repo = ref.watch(posSettingsRepositoryProvider);
  return repo.getUsdDisplaySettings(businessId);
});

class UsdEquivalentLabel extends ConsumerWidget {
  const UsdEquivalentLabel({
    super.key,
    required this.businessId,
    required this.dopTotal,
    this.fontSize,
    this.alignEnd = true,
  });

  /// Business activo (para leer settings). Si está vacío, el widget
  /// renderiza SizedBox.shrink().
  final String businessId;

  /// Total en DOP a convertir.
  final double dopTotal;

  /// Override de font-size. Default ~70% del título principal.
  final double? fontSize;

  /// Si true, alinea a la derecha (común en filas de total).
  final bool alignEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (businessId.isEmpty) return const SizedBox.shrink();

    final settingsAsync = ref.watch(usdSettingsProvider(businessId));

    return settingsAsync.when(
      data: (settings) => _renderForSettings(settings),
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }

  Widget _renderForSettings(UsdDisplaySettings settings) {
    if (!settings.isUsable) return const SizedBox.shrink();
    final rate = settings.rate;
    if (rate == null) return const SizedBox.shrink();

    final equivalent = calculateUsdEquivalent(
      dopTotal: Decimal.parse(dopTotal.toStringAsFixed(2)),
      usdRate: rate,
    );
    if (equivalent == null) return const SizedBox.shrink();

    final sym = settings.symbol;
    final formatted = equivalent.toStringAsFixed(2);
    final label = settings.symbolPosition == 'after'
        ? '$formatted $sym'
        : '$sym$formatted';
    final rateLabel = 'tasa RD\$${rate.toStringAsFixed(2)}';

    final text = Text(
      'Total USD ≈ $label  ($rateLabel)',
      textAlign: alignEnd ? TextAlign.end : TextAlign.start,
      style: TextStyle(
        fontSize: fontSize ?? 13,
        color: Colors.grey[600],
        fontWeight: FontWeight.w500,
      ),
    );

    if (alignEnd) {
      return Align(
        alignment: Alignment.centerRight,
        child: text,
      );
    }
    return text;
  }
}
