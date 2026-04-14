# Auditoría y corrección de cálculos de ventas

## Alcance revisado
- `lib/core/tax/tax_engine.dart`
- `lib/data/utils/order_pricing_utils.dart`
- `lib/presentation/sales/viewmodel/sales_viewmodel.dart`
- `lib/presentation/sales/view/table_order_screen.dart`
- `lib/presentation/sales/view/quick_sale_view.dart`
- `lib/presentation/sales/view/widgets/product_detail_modal.dart`
- `lib/presentation/cashier/view/sales_history_view.dart`
- `lib/services/printing/print_ticket_service.dart`
- `lib/presentation/sales/view/invoice_modal.dart`

## Bugs raíz encontrados
1. **Había más de un camino de cálculo activo**.
   - La UI principal, precuentas y reimpresiones volvían a reconstruir impuestos/ley desde `subtotal` con `getTaxBreakdown(...)`.
   - El cálculo canónico real ya vivía en `tax_engine.dart` + `order_pricing_utils.dart`.
   - Resultado: pantalla, checkout e impresión podían divergir cuando había descuentos, takeout, mezcla de reglas fiscales o snapshots históricos.

2. **La descomposición de impuestos/ley podía no reconciliar con el total real**.
   - Se mostraban líneas de breakdown derivadas de configuración actual, no necesariamente del cálculo efectivo por ítem.
   - Esto abría los síntomas reportados de `499.99`, `500`, diferencias de 1 centavo y ticket vs pantalla.

3. **El cálculo optimista de productos inclusivos estaba extrayendo base de más**.
   - En `sales_viewmodel.dart` el divisor para precios inclusivos volvía a sumar service fee aunque ya venía incluido en la tasa full.
   - Eso producía montos optimistas inconsistentes y drift visual antes de rehidratar desde DB.

4. **Quick sale y algunos widgets seguían mostrando/importando montos por campos locales en vez del resumen canónico**.
   - Se usaban `item.total`, `order.total` o fórmulas locales en vez de `summarizeOrderPricing(...)` / `itemDisplayTotal(...)`.

5. **La edición de producto inclusive seguía una fórmula local simplificada**.
   - El modal de detalle extraía subtotal con `1 + taxRate` en vez de usar la tasa full cuando existía snapshot fiscal completo.

## Fixes aplicados
### 1) Breakdown reconciliado y canónico
Se agregó en `order_pricing_utils.dart`:
- `buildOrderTaxBreakdown(...)`

Comportamiento:
- Parte del resumen canónico (`summarizeOrderPricing(...)`).
- Si el breakdown configurado reconcilia con el total real de impuestos + ley, se usa.
- Si difiere más de 1 centavo, hace fallback automático a líneas reconciliadas desde el resumen real (`ITBIS` / `Propina Ley`).
- Si la diferencia es de 1 centavo o menos, ajusta de forma segura la última línea para cerrar exacto.

### 2) Pantalla principal de ventas unificada
En `table_order_screen.dart`:
- Se eliminó el uso efectivo de fórmulas locales divergentes para mostrar importes por item.
- La lista, agrupaciones, precuenta y resumen lateral ahora usan:
  - `itemDisplayTotal(...)`
  - `summarizeOrderPricing(...)`
  - `buildOrderTaxBreakdown(...)`
- El total mostrado ahora sale del resumen canónico, no de recomposición paralela.

### 3) Precuenta / factura / reimpresión reconciliadas
- El flujo de impresión desde ventas ya no depende de breakdowns que puedan desviarse del cálculo efectivo.
- La reimpresión en `sales_history_view.dart` ahora reconcilia el breakdown configurado contra el resumen real antes de imprimir.
- Esto reduce diferencias entre pantalla, ticket y reimpresión histórica.

### 4) Quick sale alineado al resumen real
En `quick_sale_view.dart`:
- El total del checkout ahora se calcula con `summarizeOrderPricing(order, items)`.
- Los importes por línea usan `itemDisplayTotal(...)`.
- El `PaymentModal` recibe una copia de la orden con subtotal/impuestos/ley/total ya reconciliados.

### 5) Corrección del cálculo optimista inclusive
En `sales_viewmodel.dart`:
- Se corrigió `_estimateOptimisticItemAmounts(...)` para no duplicar la propina/ley en el divisor de precios inclusivos.
- Esto ataca directamente el patrón de drift tipo `500 -> 499.99` en altas/ediciones optimistas.

### 6) Modal de detalle de producto más fiel al snapshot fiscal
En `product_detail_modal.dart`:
- La extracción de base para ítems inclusivos ahora usa `originalTaxRate` cuando existe.
- El impuesto estimado ya no se deriva de una resta simplificada del gross completo.

## Validación realizada
### Automatizada
Se agregó:
- `test/sales/order_pricing_utils_test.dart`

Cobertura añadida:
- precio inclusivo exacto que debe quedarse en `500.00`
- reconciliación con modificadores
- fallback de breakdown cuando la configuración ya no cuadra con la venta real
- ajuste seguro de 1 centavo en breakdown configurado

### Análisis estático
Ejecutado con éxito:
- `dart analyze lib/data/utils/order_pricing_utils.dart lib/presentation/sales/view/table_order_screen.dart lib/presentation/sales/viewmodel/sales_viewmodel.dart lib/presentation/sales/view/widgets/product_detail_modal.dart lib/presentation/sales/view/quick_sale_view.dart lib/presentation/cashier/view/sales_history_view.dart test/sales/order_pricing_utils_test.dart`

Resultado:
- sin errores de compilación en los archivos tocados
- quedaron solo infos preexistentes del repo (context async, APIs deprecadas, prints viejos)

### Nota sobre tests Flutter
Intenté correr:
- `flutter test test/sales/order_pricing_utils_test.dart`

Pero la máquina devolvió un bloqueo externo del SDK Flutter:
- `Failed to open or create the artifact cache lockfile ... /Users/cristiangomez/Documents/flutter/bin/cache/lockfile`

No modifiqué el SDK ni forcé borrado del lockfile.

## Resultado esperado tras estos cambios
- pantalla principal, quick sale, precuenta, factura y reimpresión deberían reconciliar mucho mejor
- los importes inclusivos exactos deberían dejar de caer en patrones `499.99` / `500.01`
- el breakdown fiscal visible ya no debería mentir cuando la configuración actual no coincide con el cálculo real de la venta
- la impresión ahora queda mucho más alineada con el camino canónico de cálculo

## Siguiente recomendación
El siguiente paso de endurecimiento sería extender el mismo camino canónico a cualquier cálculo provisional que aún exista en split bill/local previews, para que absolutamente toda la experiencia de ventas dependa del mismo resumen reconciliado.
