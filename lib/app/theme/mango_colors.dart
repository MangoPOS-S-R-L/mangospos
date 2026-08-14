import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

class MangoColors {
  // 🎨 Colores base
  static const primaryOrange = Color(0xFFF97316);
  static const successGreen = Color(0xFF22C55E);
  static const white = Color(0xFFFFFFFF);
  static const darkGray = Color(0xFF32363F);
  static const sidebarBg = Color(0xFFF7F7F7);

  // 🎨 Colores adicionales recomendados para UI
  /// Fondo de PANTALLA: blanco azulado #FBFCFE (ver [AppColors.background]).
  /// Es el que va en `Scaffold.backgroundColor`; [bgLight] es para bloques
  /// internos (filas, chips, campos), no para la pantalla completa.
  static const appBackground = AppColors.background;
  static const bgLight = Color(0xFFF2F2F2); // fondo suave de bloques internos
  static const muted = Color(0xFF9E9E9E); // textos secundarios
  static const cardBorder = Color(0xFFE0E0E0); // bordes suaves

  // 🎨 Acentos por categoría — usar para distinguir tipos de toggles/badges
  // que no son "área de venta" (verde) sino otros criterios.
  static const infoBlue = Color(0xFF3C83F6); // azul de información / takeout
}
