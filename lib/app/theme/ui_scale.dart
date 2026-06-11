import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Escala global de la interfaz.
///
/// Para equipos de **alta densidad** (ej. Toast Flex TT200 — 14" 1920×1080,
/// ~157 DPI) donde el SO reporta un viewport lógico grande y la UI a 1× se ve
/// físicamente pequeña. Como Flutter solo ve el tamaño LÓGICO, no se puede
/// distinguir esa pantalla de un monitor de escritorio 1920×1080 por código,
/// así que la escala se elige manualmente en Configuración → Pantalla y se
/// guarda por dispositivo (no se sincroniza).
enum UiScaleOption {
  verySmall(0.8, 'Muy pequeño'),
  small(0.9, 'Pequeño'),
  normal(1.0, 'Normal'),
  intermediate(1.1, 'Intermedio'),
  large(1.2, 'Grande'),
  veryLarge(1.3, 'Muy grande'),
  extraLarge(1.4, 'Extra grande');

  const UiScaleOption(this.factor, this.label);

  /// Factor de zoom uniforme aplicado a TODA la UI (texto, botones, paddings,
  /// touch targets).
  final double factor;

  /// Etiqueta para el selector en Configuración.
  final String label;
}

/// Estado persistente del [UiScaleOption]. Carga async desde SharedPreferences
/// (un breve frame en `normal` al arrancar es aceptable para un ajuste).
class UiScaleController extends StateNotifier<UiScaleOption> {
  UiScaleController() : super(UiScaleOption.normal) {
    _load();
  }

  // Guardamos por NOMBRE (no por índice) para no romper la selección si se
  // reordenan o agregan opciones al enum.
  static const _prefKey = 'ui_scale_option_v2';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(_prefKey);
      if (name != null) {
        for (final opt in UiScaleOption.values) {
          if (opt.name == name) {
            state = opt;
            break;
          }
        }
      }
    } catch (_) {
      // Sin prefs / error → queda en normal.
    }
  }

  Future<void> set(UiScaleOption option) async {
    state = option;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, option.name);
    } catch (_) {}
  }
}

final uiScaleProvider = StateNotifierProvider<UiScaleController, UiScaleOption>(
  (ref) => UiScaleController(),
);

/// Aplica un zoom uniforme a [child] según [factor].
///
/// Técnica: le presentamos a la app un viewport lógico más chico
/// (`size / factor`) y rasterizamos ese canvas al tamaño físico real con un
/// [FittedBox]. Así escala todo por igual —incluidos los tamaños hardcodeados
/// en píxeles por igual— y el hit-testing se mantiene alineado (FittedBox transforma los
/// punteros). Los insets/padding se dividen por el factor para que la
/// evitación del teclado quede correcta.
class UiScaleWrapper extends StatelessWidget {
  const UiScaleWrapper({super.key, required this.factor, required this.child});

  final double factor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (factor == 1.0) return child;
    final mq = MediaQuery.of(context);
    final inv = 1 / factor;
    final scaled = Size(mq.size.width * inv, mq.size.height * inv);
    return MediaQuery(
      data: mq.copyWith(
        size: scaled,
        viewInsets: mq.viewInsets * inv,
        viewPadding: mq.viewPadding * inv,
        padding: mq.padding * inv,
        systemGestureInsets: mq.systemGestureInsets * inv,
      ),
      child: FittedBox(
        fit: BoxFit.fill,
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: scaled.width,
          height: scaled.height,
          child: child,
        ),
      ),
    );
  }
}
