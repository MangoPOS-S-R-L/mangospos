// Diálogo de impresión del SISTEMA (A4, carta, "Guardar como PDF"…) sin
// congelar la app en Mac ni en iPad.
//
// EL PROBLEMA (2026-09-30, «se queda congelado en la parte de impresión»):
// con maquetación dinámica (el default de `Printing.layoutPdf`), el plugin
// `printing` en macOS e iOS abre el panel y, para la vista previa, BLOQUEA el
// hilo principal (`semaphore.wait()` en PrintJob.swift) hasta que Dart le
// devuelva el PDF. Desde Flutter 3.29 (iOS) y 3.4x (macOS) el código Dart corre
// en ESE MISMO hilo (hilo de plataforma y de UI fusionados, el default). Dart
// nunca llega a armar el PDF, el hilo nunca se libera: la app queda congelada
// para siempre. Windows y Android no bloquean así.
//
// LA SALIDA: en Apple se arma el PDF UNA vez, con el formato pedido, ANTES de
// abrir el panel (`dynamicLayout: false`). Se pierde solo el re-maquetado al
// cambiar el tamaño de hoja dentro del panel de Mac/iPad; en Windows y Android
// todo sigue igual.

import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

/// ¿Esta plataforma tiene el bloqueo del panel con maquetación dinámica?
@visibleForTesting
bool osPrintNeedsStaticLayout({TargetPlatform? platform, bool? isWeb}) {
  if (isWeb ?? kIsWeb) return false;
  final p = platform ?? defaultTargetPlatform;
  return p == TargetPlatform.macOS || p == TargetPlatform.iOS;
}

/// Reemplazo de `Printing.layoutPdf` para todo el POS: úsalo SIEMPRE en vez
/// de llamar al plugin directo.
Future<bool> printWithOsDialog({
  required LayoutCallback onLayout,
  required String name,
  PdfPageFormat format = PdfPageFormat.standard,
}) {
  return Printing.layoutPdf(
    onLayout: onLayout,
    name: name,
    format: format,
    dynamicLayout: !osPrintNeedsStaticLayout(),
  );
}
