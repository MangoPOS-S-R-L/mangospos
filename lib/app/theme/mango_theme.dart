// Theme global de MangoPOS. Centraliza:
//   - Colores primario/éxito/peligro.
//   - Radios de botones (10) y diálogos (16).
//   - Fondo blanco en todos los Dialog/AlertDialog/BottomSheet/Snackbar.
//   - Botones sin elevación, sin fully-rounded.
//
// Esto reemplaza el ThemeData mínimo que solo seteaba primaryColor — antes
// Material 3 inventaba defaults morados con esquinas circulares.
//
// USO:
//   MaterialApp.router(
//     theme: buildMangoTheme(),
//     ...
//   )

import 'package:flutter/material.dart';

import 'mango_colors.dart';
import 'mango_styles.dart';

ThemeData buildMangoTheme() {
  const primary = MangoColors.primaryOrange;
  const success = MangoColors.successGreen;
  const danger = Color(0xFFDC2626);
  const surface = Colors.white;
  const onSurface = Color(0xFF1F2937);
  const muted = Color(0xFF6B7280);
  const border = Color(0xFFE5E7EB);

  final colorScheme = const ColorScheme.light(
    primary: primary,
    onPrimary: Colors.white,
    secondary: success,
    onSecondary: Colors.white,
    error: danger,
    onError: Colors.white,
    surface: surface,
    onSurface: onSurface,
    surfaceTint: surface, // evita el tinte morado de Material 3.
    outline: border,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    primaryColor: primary,
    scaffoldBackgroundColor: surface,
    canvasColor: surface,
    splashFactory: InkRipple.splashFactory,

    // ---------------------------------------------------------------
    // Diálogos: fondo blanco limpio, sin sombra ni tint.
    // El barrier (modalBarrierColor) ya da suficiente separación visual.
    // ---------------------------------------------------------------
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: surface,
      elevation: 0,
      shadowColor: Colors.transparent,
      shape: MangoRadius.shapeModal,
      titleTextStyle: const TextStyle(
        color: onSurface,
        fontSize: 18,
        fontWeight: FontWeight.w800,
      ),
      contentTextStyle: const TextStyle(
        color: onSurface,
        fontSize: 14,
      ),
    ),

    // ---------------------------------------------------------------
    // BottomSheets, Drawers, PopupMenu: blanco + radius 16/10.
    // Sin sombra para mantener un look plano y limpio.
    // ---------------------------------------------------------------
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: surface,
      modalBackgroundColor: surface,
      modalBarrierColor: const Color(0x66000000),
      elevation: 0,
      shadowColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: surface,
      surfaceTintColor: surface,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: surface,
      shape: MangoRadius.shapeCard,
      elevation: 2,
      shadowColor: const Color(0x14000000),
    ),

    // ---------------------------------------------------------------
    // Botones: SIEMPRE radius 10, naranja para filled/elevated.
    // ---------------------------------------------------------------
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: MangoRadius.shapeButton,
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: MangoRadius.shapeButton,
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: primary,
        shape: MangoRadius.shapeButton,
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: onSurface,
        side: const BorderSide(color: border),
        shape: MangoRadius.shapeButton,
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),

    // ---------------------------------------------------------------
    // AppBar: blanco con texto dark, no morado.
    // ---------------------------------------------------------------
    appBarTheme: const AppBarTheme(
      backgroundColor: surface,
      foregroundColor: onSurface,
      surfaceTintColor: surface,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      titleTextStyle: TextStyle(
        color: onSurface,
        fontSize: 16,
        fontWeight: FontWeight.w800,
      ),
      iconTheme: IconThemeData(color: onSurface),
    ),

    // ---------------------------------------------------------------
    // Inputs: radius 10, borde gris, focus naranja.
    // ---------------------------------------------------------------
    inputDecorationTheme: InputDecorationTheme(
      filled: false,
      isDense: true,
      labelStyle: const TextStyle(color: muted),
      hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: MangoRadius.borderInput,
        borderSide: const BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: MangoRadius.borderInput,
        borderSide: const BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: MangoRadius.borderInput,
        borderSide: const BorderSide(color: primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: MangoRadius.borderInput,
        borderSide: const BorderSide(color: danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: MangoRadius.borderInput,
        borderSide: const BorderSide(color: danger, width: 1.5),
      ),
    ),

    // ---------------------------------------------------------------
    // Cards: blancos, radius 12, sin sombra fuerte.
    // ---------------------------------------------------------------
    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: surface,
      elevation: 0.5,
      shape: MangoRadius.shapeCard,
      margin: EdgeInsets.zero,
    ),

    // ---------------------------------------------------------------
    // Otros: switches/checkboxes/radios usan el naranja del primary.
    // ---------------------------------------------------------------
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.white : muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? primary
            : const Color(0xFFD1D5DB),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? primary : null,
      ),
      side: const BorderSide(color: muted),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? primary : muted,
      ),
    ),

    // ---------------------------------------------------------------
    // SnackBars: blanco/oscuro coherente.
    // ---------------------------------------------------------------
    snackBarTheme: SnackBarThemeData(
      backgroundColor: const Color(0xFF1F2937),
      contentTextStyle: const TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: MangoRadius.shapeButton,
    ),

    // ---------------------------------------------------------------
    // Divider, list tiles, etc.
    // ---------------------------------------------------------------
    dividerTheme: const DividerThemeData(
      color: border,
      thickness: 1,
      space: 1,
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: muted,
      textColor: onSurface,
    ),
  );
}
