import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cantidad de mesas por fila en el grid de "Ventas por zona".
///
/// [salesTableColumnsAuto] (0) mantiene el comportamiento histórico: el grid
/// calcula cuántas mesas caben según el ancho disponible y el zoom. Cualquier
/// otro valor FUERZA esa cantidad de columnas — el card se encoge por debajo
/// de su ancho ideal si hace falta (los textos ya truncan con ellipsis), que
/// es justo lo que el usuario pide cuando dice "quiero 8 por fila".
///
/// Es una preferencia por dispositivo (SharedPreferences), igual que el zoom
/// y el modo de vista: cada tablet del salón puede tener su densidad.
const int salesTableColumnsAuto = 0;
const int salesTableColumnsMin = 1;
const int salesTableColumnsMax = 12;

const String _kSalesTableColumnsPrefsKey = 'sales_table_columns';

class SalesTableColumnsNotifier extends Notifier<int> {
  @override
  int build() {
    // Carga async desde prefs sin bloquear el primer render.
    unawaited(_loadFromPrefs());
    return salesTableColumnsAuto;
  }

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(_kSalesTableColumnsPrefsKey);
      if (saved == null) return;
      if (saved == salesTableColumnsAuto ||
          (saved >= salesTableColumnsMin && saved <= salesTableColumnsMax)) {
        state = saved;
      }
    } catch (_) {
      // Sin prefs disponibles, queda en automático.
    }
  }

  /// [value] = [salesTableColumnsAuto] para volver al cálculo automático.
  void set(int value) {
    final normalized = value == salesTableColumnsAuto
        ? salesTableColumnsAuto
        : value.clamp(salesTableColumnsMin, salesTableColumnsMax);
    if (normalized == state) return;
    state = normalized;
    unawaited(_save(normalized));
  }

  void reset() => set(salesTableColumnsAuto);

  Future<void> _save(int value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSalesTableColumnsPrefsKey, value);
    } catch (_) {
      // Ignorar fallos de persistencia; el state en memoria sigue activo.
    }
  }
}

final salesTableColumnsProvider =
    NotifierProvider<SalesTableColumnsNotifier, int>(
  SalesTableColumnsNotifier.new,
);
