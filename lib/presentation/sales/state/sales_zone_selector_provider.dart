import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cómo se presenta el selector de zonas en "Ventas por zona".
///
/// - [carousel]: switch segmentado con las zonas una al lado de la otra,
///   desplazable en horizontal cuando hay muchas.
/// - [dropdown]: botón desplegable con la zona activa.
///
/// Es preferencia por dispositivo: en la caja de escritorio suele convenir el
/// carrusel, en una tablet angosta el desplegable.
enum SalesZoneSelectorStyle { carousel, dropdown }

const String _kSalesZoneSelectorPrefsKey = 'sales_zone_selector_style';

class SalesZoneSelectorNotifier extends Notifier<SalesZoneSelectorStyle> {
  @override
  SalesZoneSelectorStyle build() {
    unawaited(_loadFromPrefs());
    return SalesZoneSelectorStyle.carousel;
  }

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_kSalesZoneSelectorPrefsKey);
      if (saved == 'dropdown') {
        state = SalesZoneSelectorStyle.dropdown;
      } else if (saved == 'carousel') {
        state = SalesZoneSelectorStyle.carousel;
      }
    } catch (_) {
      // Sin prefs, queda en carrusel.
    }
  }

  void toggle() => _setAndPersist(
        state == SalesZoneSelectorStyle.carousel
            ? SalesZoneSelectorStyle.dropdown
            : SalesZoneSelectorStyle.carousel,
      );

  void set(SalesZoneSelectorStyle style) => _setAndPersist(style);

  void _setAndPersist(SalesZoneSelectorStyle style) {
    state = style;
    unawaited(_save(style));
  }

  Future<void> _save(SalesZoneSelectorStyle style) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kSalesZoneSelectorPrefsKey,
        style == SalesZoneSelectorStyle.dropdown ? 'dropdown' : 'carousel',
      );
    } catch (_) {
      // Ignorar fallos de persistencia.
    }
  }
}

final salesZoneSelectorProvider =
    NotifierProvider<SalesZoneSelectorNotifier, SalesZoneSelectorStyle>(
  SalesZoneSelectorNotifier.new,
);
