import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Factor de zoom para grids de la pantalla de ventas (catalogo de productos +
/// grid de mesas). Se aplica multiplicando los tamanos base (`maxCrossAxisExtent`,
/// `mainAxisExtent`, iconos, avatares) para que el cajero pueda ajustar la
/// densidad de la UI a su preferencia.
///
/// Rango: 0.7 (compacto) a 1.5 (grande). Step: 0.1.
/// Persiste en SharedPreferences para recordar la preferencia entre sesiones.
const double salesZoomMin = 0.7;
const double salesZoomMax = 1.5;
const double salesZoomStep = 0.1;
const double salesZoomDefault = 1.0;
const String _kSalesZoomPrefsKey = 'sales_zoom_factor';

class SalesZoomNotifier extends Notifier<double> {
  @override
  double build() {
    // Carga async desde prefs sin bloquear el primer render.
    unawaited(_loadFromPrefs());
    return salesZoomDefault;
  }

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_kSalesZoomPrefsKey);
      if (saved != null && saved >= salesZoomMin && saved <= salesZoomMax) {
        state = saved;
      }
    } catch (_) {
      // Sin prefs disponibles, queda con default 1.0.
    }
  }

  /// Incrementa el zoom en `salesZoomStep` (clamp en max).
  void zoomIn() => _setAndPersist((state + salesZoomStep).clamp(
        salesZoomMin,
        salesZoomMax,
      ));

  /// Decrementa el zoom en `salesZoomStep` (clamp en min).
  void zoomOut() => _setAndPersist((state - salesZoomStep).clamp(
        salesZoomMin,
        salesZoomMax,
      ));

  /// Vuelve a 1.0.
  void reset() => _setAndPersist(salesZoomDefault);

  void _setAndPersist(double value) {
    // Redondear a 1 decimal para evitar drift floating-point.
    final rounded = double.parse(value.toStringAsFixed(1));
    state = rounded;
    unawaited(_save(rounded));
  }

  Future<void> _save(double value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSalesZoomPrefsKey, value);
    } catch (_) {
      // Ignorar fallos de persistencia; el state en memoria sigue activo.
    }
  }
}

final salesZoomProvider =
    NotifierProvider<SalesZoomNotifier, double>(SalesZoomNotifier.new);
