# Caja + Cierre de Caja a Ciegas (Flutter Material 3)

## Dependencias usadas
- `flutter_riverpod`: manejo de estado del flujo de cierre.
- `intl`: formato de moneda `RD$` y fecha/hora.
- `esc_pos_utils_plus`: generación de comandos ESC/POS.
- `pdf`: generación de ticket fallback en PDF.
- `printing`: vista previa/imprimir PDF cuando no hay térmica disponible.

## Cómo ejecutar
1. Instalar dependencias:
   - `flutter pub get`
2. Ejecutar app:
   - `flutter run -d chrome` (web) o dispositivo desktop/móvil.

## Cómo probar
1. Correr pruebas de caja:
   - `flutter test test/cashier`
2. Verificar análisis:
   - `flutter analyze lib/presentation/cashier test/cashier`
3. QA manual ventas/caja:
   - revisar `docs/QA_VENTAS_Y_CAJA_CHECKLIST.md`

## Impresión (real + fallback)
- Flujo principal:
  - `CashClosePrintService` intenta imprimir por impresora térmica (ESC/POS) usando impresoras configuradas en DB.
  - Si no hay impresora conectada/disponible, usa fallback con `Printing.layoutPdf`.
- Ticket objetivo:
  - ancho 80mm, fuente monoespaciada, secciones: conteo, comparación, totales, estado y estadísticas.

## Decisiones clave de arquitectura
- Estado y lógica desacoplados:
  - Modelo/cálculos: `lib/presentation/cashier/state/blind_cash_close_models.dart`
  - Estado del flujo: `lib/presentation/cashier/viewmodel/blind_cash_close_viewmodel.dart`
  - Formateo: `lib/presentation/cashier/state/cash_close_formatters.dart`
- UI modular:
  - `lib/presentation/cashier/view/cashier_view.dart`
  - `lib/presentation/cashier/widgets/blind_cash_close_dialog.dart`
  - `lib/presentation/cashier/widgets/denomination_counter_row.dart`
  - `lib/presentation/cashier/widgets/numpad_widget.dart`
  - `lib/presentation/cashier/widgets/close_summary_table.dart`
- Impresión desacoplada:
  - `lib/presentation/cashier/services/print_service.dart`
- Integración de datos:
  - Se obtiene resumen de sesión y pagos reales.
  - Si no hay datos suficientes, usa fallback demo solicitado:
    - `expectedCash=28500`, `expectedCard=12500`, `expectedTransfer=4200`, `totalSales=45200`, `transactionCount=28`.
