// Design system tokens de MangoPOS — botones, diálogos, radios.
//
// REGLAS:
//   - Botones primarios: naranja (`MangoColors.primaryOrange`).
//   - Botones de éxito/confirmación: verde (`MangoColors.successGreen`).
//   - Botones destructivos: rojo (#DC2626 / #EF4444).
//   - Border radius siempre 10 para botones — NUNCA fully rounded (999).
//   - Modales/diálogos: fondo blanco siempre.
//   - Cards: radius 12-14, NO 20+, NO 999.
//
// USO TÍPICO:
//   FilledButton(
//     style: MangoButtonStyles.primary(),
//     onPressed: ...,
//     child: const Text('Guardar'),
//   )
//
// Para diálogos:
//   showDialog(
//     builder: (ctx) => AlertDialog(
//       backgroundColor: MangoModalStyle.backgroundColor,
//       shape: MangoModalStyle.shape,
//       ...
//     ),
//   )

import 'package:flutter/material.dart';

import 'mango_colors.dart';

/// Radios estandarizados del design system.
class MangoRadius {
  /// Botones, chips, pills. SIEMPRE 10. Nunca 999.
  static const button = 10.0;

  /// Cards y contenedores secundarios.
  static const card = 12.0;

  /// Modales y diálogos (un poco más generoso para que se vean elegantes).
  static const modal = 16.0;

  /// Badges pequeños (esquinas leves).
  static const badge = 8.0;

  /// Inputs (TextField, dropdowns, etc.).
  static const input = 10.0;

  // ----- BorderRadius helpers (versión geometría) -----

  static BorderRadius get borderButton =>
      BorderRadius.circular(button);
  static BorderRadius get borderCard =>
      BorderRadius.circular(card);
  static BorderRadius get borderModal =>
      BorderRadius.circular(modal);
  static BorderRadius get borderBadge =>
      BorderRadius.circular(badge);
  static BorderRadius get borderInput =>
      BorderRadius.circular(input);

  // ----- RoundedRectangleBorder helpers (para `shape:` directo) -----

  static RoundedRectangleBorder get shapeButton =>
      RoundedRectangleBorder(borderRadius: borderButton);
  static RoundedRectangleBorder get shapeCard =>
      RoundedRectangleBorder(borderRadius: borderCard);
  static RoundedRectangleBorder get shapeModal =>
      RoundedRectangleBorder(borderRadius: borderModal);
}

/// Estilos de botón listos para usar. Garantizan consistencia visual.
class MangoButtonStyles {
  /// Botón primario naranja. Para acciones principales (Guardar, Aplicar,
  /// Confirmar la operación principal).
  static ButtonStyle primary({double? minHeight}) {
    return FilledButton.styleFrom(
      backgroundColor: MangoColors.primaryOrange,
      foregroundColor: Colors.white,
      shape: MangoRadius.shapeButton,
      elevation: 0,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      minimumSize: minHeight != null ? Size.fromHeight(minHeight) : null,
    );
  }

  /// Botón verde de éxito/confirmación final. Para "Pagar", "Completar",
  /// "Finalizar". Más fuerte semánticamente que el naranja primario.
  static ButtonStyle success({double? minHeight}) {
    return FilledButton.styleFrom(
      backgroundColor: MangoColors.successGreen,
      foregroundColor: Colors.white,
      shape: MangoRadius.shapeButton,
      elevation: 0,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      minimumSize: minHeight != null ? Size.fromHeight(minHeight) : null,
    );
  }

  /// Botón rojo destructivo. Para "Eliminar", "Anular", "Borrar".
  static ButtonStyle danger({double? minHeight}) {
    return FilledButton.styleFrom(
      backgroundColor: const Color(0xFFDC2626),
      foregroundColor: Colors.white,
      shape: MangoRadius.shapeButton,
      elevation: 0,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      minimumSize: minHeight != null ? Size.fromHeight(minHeight) : null,
    );
  }

  /// Botón secundario con borde (outlined). Para acciones alternativas
  /// como "Cancelar", "Revisar de nuevo", etc.
  static ButtonStyle secondary({double? minHeight}) {
    return OutlinedButton.styleFrom(
      foregroundColor: MangoColors.darkGray,
      side: const BorderSide(color: Color(0xFFE5E7EB)),
      shape: MangoRadius.shapeButton,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      minimumSize: minHeight != null ? Size.fromHeight(minHeight) : null,
    );
  }

  /// Botón outlined con tinte naranja. Para acciones secundarias que aún
  /// están relacionadas con el flujo principal (ej. "Reimprimir").
  static ButtonStyle outlinedPrimary({double? minHeight}) {
    return OutlinedButton.styleFrom(
      foregroundColor: MangoColors.primaryOrange,
      side: const BorderSide(color: MangoColors.primaryOrange),
      shape: MangoRadius.shapeButton,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      minimumSize: minHeight != null ? Size.fromHeight(minHeight) : null,
    );
  }
}

/// Helpers para diálogos y modales. Forzan fondo blanco + radius 16.
class MangoModalStyle {
  /// Color de fondo de cualquier modal/diálogo. Siempre blanco.
  static const Color backgroundColor = Colors.white;

  /// Surface tint (Material 3) — también blanco para que no agregue tint.
  static const Color surfaceTintColor = Colors.white;

  /// Forma estándar de modales y diálogos.
  static RoundedRectangleBorder get shape => MangoRadius.shapeModal;
}
