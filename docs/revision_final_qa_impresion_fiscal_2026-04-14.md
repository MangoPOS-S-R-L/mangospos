# Revisión final QA — impresión fiscal y consistencia de ventas

Fecha: 2026-04-14

## Qué se cerró

### 1) `PrintTicketService.generateFiscalInvoice(...)`
Se eliminó la dependencia directa de:
- `item.total`
- `order.subtotal`
- `order.tax`
- `order.total`

Ahora el ticket fiscal:
- usa la ruta canónica para montos por línea (`itemDisplayTotal(...)`) por defecto,
- resuelve subtotales/impuestos/totales desde `summarizeOrderPricing(...)` por defecto,
- acepta `taxBreakdown`/`receiptItemDisplayMode` igual que la factura estándar,
- y puede respetar snapshots históricos con `preferStoredOrderTotals` / `preferStoredItemTotals` cuando haga falta reimprimir sin reinterpretar ventas viejas.

### 2) Reimpresión de ventas en historial/caja
En `sales_history_view.dart`:
- el desglose de impuestos de reimpresión ya no confía ciegamente en tasas configuradas,
- se reconcilia con `buildOrderTaxBreakdown(...)`,
- y la reimpresión ahora activa explícitamente el modo histórico:
  - `preferStoredOrderTotals: true`
  - `preferStoredItemTotals: true`

Eso evita que una venta vieja se “recalcule” con reglas nuevas al reimprimirla.

### 3) Cobertura de prueba agregada
Se agregó `test/sales/print_ticket_service_test.dart` para cubrir:
- factura fiscal usando montos canónicos cuando `order/item` vienen desviados,
- reimpresión respetando snapshots persistidos cuando se activa el modo histórico.

## Qué validé

### Estático
- `flutter analyze` sobre:
  - `lib/services/printing/print_ticket_service.dart`
  - `lib/presentation/cashier/view/sales_history_view.dart`
  - `test/sales/order_pricing_utils_test.dart`
  - `test/sales/print_ticket_service_test.dart`
- Resultado: **sin issues**.

### Formato
- `dart format` aplicado a los archivos tocados.

### Tests
Intenté correr `flutter test` para los tests focalizados, pero el entorno devolvió un fallo del runner:
- `Resource deadlock avoided`

No parece un error del código bajo prueba sino del proceso `flutter_tester` en esta máquina/sesión. Aun así, el analyzer sí pasó y los tests nuevos quedaron compilables a nivel estático.

## Riesgos / cosas todavía sensibles

1. **Reimpresión histórica vs. cálculo canónico**
   - Para ventas nuevas, la impresión sigue el cálculo canónico.
   - Para reimpresiones históricas, ahora se puede respetar snapshot persistido.
   - Esto es intencional: evita “corregir” retroactivamente tickets viejos.

2. **Vistas informativas menores todavía con campos raw**
   - Quedan usos visuales aislados como listados/detalles que muestran `item.total` sin pasar por la ruta canónica.
   - No afectan el cierre principal de cálculo/impresión fiscal, pero conviene barrerlos en una pasada final de polish si Cristian quiere dejar el repo completamente homogéneo.

3. **`generateFiscalInvoice(...)` aparentemente tiene poco o ningún uso actual directo**
   - Igual quedó alineado, para no dejar huecos si vuelve a usarse o si algún flujo lo conecta después.

## Conclusión
El hueco principal de ventas/cálculo en impresión fiscal quedó cerrado:
- factura estándar y fiscal ya pueden imprimir desde la ruta canónica,
- reimpresiones pueden preservar snapshots históricos,
- y el desglose fiscal/reprint quedó reconciliado con `buildOrderTaxBreakdown(...)`.

Mi lectura: **sí, esto ya deja la parte pendiente de sales-calculation mucho más cerca de “ready”**. El único pendiente real que no pude sellar al 100% fue ejecutar `flutter test` por un problema del runner en el entorno, no por errores reportados del código.
