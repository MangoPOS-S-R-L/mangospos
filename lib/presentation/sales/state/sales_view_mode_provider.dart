import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Modo de visualización de las mesas en la pantalla "Ventas por zona".
enum SalesZoneViewMode { grid, map }

/// Controla si las mesas se muestran como cuadrícula ([SalesZoneViewMode.grid],
/// el comportamiento histórico) o como floor map ([SalesZoneViewMode.map]).
/// Persiste la preferencia en SharedPreferences, igual que el zoom.
const String _kSalesViewModePrefsKey = 'sales_zone_view_mode';

class SalesViewModeNotifier extends Notifier<SalesZoneViewMode> {
  @override
  SalesZoneViewMode build() {
    unawaited(_loadFromPrefs());
    return SalesZoneViewMode.grid;
  }

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_kSalesViewModePrefsKey);
      if (saved == 'map') {
        state = SalesZoneViewMode.map;
      } else if (saved == 'grid') {
        state = SalesZoneViewMode.grid;
      }
    } catch (_) {
      // Sin prefs, queda con default grid.
    }
  }

  void toggle() => _setAndPersist(
        state == SalesZoneViewMode.grid
            ? SalesZoneViewMode.map
            : SalesZoneViewMode.grid,
      );

  void set(SalesZoneViewMode mode) => _setAndPersist(mode);

  void _setAndPersist(SalesZoneViewMode mode) {
    state = mode;
    unawaited(_save(mode));
  }

  Future<void> _save(SalesZoneViewMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kSalesViewModePrefsKey,
        mode == SalesZoneViewMode.map ? 'map' : 'grid',
      );
    } catch (_) {
      // Ignorar fallos de persistencia.
    }
  }
}

final salesViewModeProvider =
    NotifierProvider<SalesViewModeNotifier, SalesZoneViewMode>(
  SalesViewModeNotifier.new,
);
