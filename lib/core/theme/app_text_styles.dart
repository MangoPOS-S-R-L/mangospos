import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Estilos de texto específicos para TableCard
/// Basados en Plus Jakarta Sans
/// Documentación: DISENO_CARDS_MESAS.txt Sección 8
class AppTextStyles {
  AppTextStyles._();

  /// Fuente base del proyecto - Plus Jakarta Sans
  static TextStyle get _baseStyle => GoogleFonts.plusJakartaSans();

  // ========== ESTILOS PARA TABLE CARD ==========

  /// Código de mesa: "SP01", "TR03"
  /// Size: 20px, Weight: 700 (Bold), Line height: 28px
  static TextStyle get tableCode => _baseStyle.copyWith(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    height: 1.4, // 28px / 20px
  );

  /// Estado: "Disponible", "Ocupado"
  /// Size: 12px, Weight: 600 (SemiBold), Line height: 16px
  static TextStyle get tableStatus => _baseStyle.copyWith(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 1.33, // 16px / 12px
  );

  /// Total de la mesa: "RD$ 2,850"
  /// Size: 14px, Weight: 700 (Bold), Line height: 20px
  static TextStyle get tableTotal => _baseStyle.copyWith(
    fontSize: 14,
    fontWeight: FontWeight.w700,
    height: 1.43, // 20px / 14px
  );

  /// Métricas (invitados y tiempo): "4", "45:23"
  /// Size: 14px, Weight: 400 (Regular), Line height: 20px
  static TextStyle get tableMetrics => _baseStyle.copyWith(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.43,
  );

  /// Nombre del mesero: "Ana Pérez"
  /// Size: 12px, Weight: 400 (Regular), Line height: 16px
  static TextStyle get tableWaiter => _baseStyle.copyWith(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.33,
  );

  /// Badge "Tu mesa"
  /// Size: 10px, Weight: 700 (Bold)
  static TextStyle get tableBadge =>
      _baseStyle.copyWith(fontSize: 10, fontWeight: FontWeight.w700);

  /// Texto para mesa disponible: "Toca para asignar"
  /// Size: 14px, Weight: 500 (Medium), Line height: 20px
  static TextStyle get tableEmptyPrompt => _baseStyle.copyWith(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.43,
  );
}
