# Revisión post-fix de cálculos de ventas

## Qué ahora sí se ve corregido
- **Camino canónico de cálculo** mucho mejor centralizado en `lib/data/utils/order_pricing_utils.dart` usando `summarizeOrderPricing(...)`, `itemDisplayTotal(...)` y `buildOrderTaxBreakdown(...)`.
- **Pantalla de venta / mesa** (`lib/presentation/sales/view/table_order_screen.dart`) ya quedó bastante alineada con ese camino canónico para subtotal, descuentos, breakdown fiscal y total final.
- **Quick sale** (`lib/presentation/sales/view/quick_sale_view.dart`) ya no depende del `order.total` crudo; ahora paga con una orden reconciliada.
- **Modal de producto** (`lib/presentation/sales/view/widgets/product_detail_modal.dart`) ya usa `originalTaxRate` para desglosar ítems inclusivos, lo cual reduce el drift típico de `0.01`.
- **Precuenta / factura / reimpresión** quedaron mejor amarradas al cálculo real:
  - `lib/services/printing/print_ticket_service.dart`
  - `lib/presentation/sales/view/invoice_modal.dart`
  - `lib/presentation/cashier/view/sales_history_view.dart`
- **Riesgo de breakdown mentiroso** bajó bastante: si la configuración fiscal actual no reconcilia con la venta real, ahora hay fallback al resumen canónico.

## Fix pequeño adicional que sí apliqué en esta revisión
### Split bill seguía atrasado respecto al resto del fix
Encontré un hueco todavía real en split bill y lo corregí:

- `lib/presentation/split_bill/viewmodel/split_bill_viewmodel.dart`
  - el recálculo local de checks usaba una estimación burda (`total / 1.18`)
  - ahora recalcula con `summarizeOrderPricing(...)`
  - además, la consolidación local ahora **sí distingue modificadores**, para no fusionar líneas distintas por error

- `lib/presentation/split_bill/widgets/split_bill_modal.dart`
  - los precios por línea ahora salen de `itemDisplayTotal(...)`
  - esto alinea mejor la UI de split bill con quick sale / mesa / impresión

## Lo que todavía veo riesgoso o incompleto
1. **Factura fiscal todavía usa montos raw**
   - Archivo: `lib/services/printing/print_ticket_service.dart`
   - Área: `generateFiscalInvoice(...)`
   - Sigue imprimiendo con `order.subtotal`, `order.tax`, `order.serviceFee`, `order.total` e `item.total` en vez del resumen canónico.
   - Si el flujo fiscal se usa en producción, todavía puede quedar desalineado contra pantalla / factura normal / reimpresión.

2. **Split bill aún tiene cobertura débil, aunque ya quedó mejor**
   - Archivos:
     - `lib/presentation/split_bill/viewmodel/split_bill_viewmodel.dart`
     - `lib/presentation/split_bill/widgets/split_bill_modal.dart`
   - Mejoró el recálculo local, pero sigue faltando validación fuerte de punta a punta con:
     - descuentos por item
     - modificadores con precio
     - takeout mezclado con consumo en salón
     - checks parciales pagados y reimpresos

3. **Riesgo residual de 1 centavo en escenarios históricos / snapshots viejos**
   - Archivos/áreas a vigilar:
     - `lib/presentation/cashier/view/sales_history_view.dart`
     - `lib/services/printing/print_ticket_service.dart`
     - `lib/presentation/sales/view/invoice_modal.dart`
   - La reconciliación mejoró mucho, pero ventas históricas con snapshots fiscales viejos o con configuración actual distinta pueden seguir depender de fallbacks. Eso hay que probar manualmente con casos reales guardados, no solo con ventas nuevas.

4. **La UI depende de que el caller pase una orden reconciliada al pago**
   - Archivos/áreas:
     - `lib/presentation/payments/widgets/payment_modal.dart`
     - callers en `quick_sale_view.dart` y `table_order_screen.dart`
   - Hoy los callers principales ya lo hacen mejor, pero si aparece otro caller que pase la orden cruda, puede reintroducir divergencia sin tocar el modal.

5. **Cobertura automatizada todavía insuficiente para shipping**
   - Sí hay tests nuevos en `test/sales/order_pricing_utils_test.dart`, pero cubren utilidades, no todos los flujos visuales / impresión / split bill.
   - `dart analyze` pasó sin errores en los archivos revisados; quedaron solo infos preexistentes/deprecaciones.
   - `dart test` no corrió ese archivo porque el repo no expone `package:test` en ese entrypoint.
   - En el intento previo, `flutter test` estaba bloqueado por lock del SDK Flutter. O sea: la validación automatizada todavía no es suficiente para declarar esto cerrado sola.

## Archivos / zonas exactas que yo vigilaría antes de shipping
- `lib/data/utils/order_pricing_utils.dart`
- `lib/presentation/sales/viewmodel/sales_viewmodel.dart`
- `lib/presentation/sales/view/table_order_screen.dart`
- `lib/presentation/sales/view/quick_sale_view.dart`
- `lib/presentation/sales/view/invoice_modal.dart`
- `lib/presentation/cashier/view/sales_history_view.dart`
- `lib/services/printing/print_ticket_service.dart`
- `lib/presentation/split_bill/viewmodel/split_bill_viewmodel.dart`
- `lib/presentation/split_bill/widgets/split_bill_modal.dart`

## Escenarios manuales obligatorios antes de salir
1. **Venta nueva en mesa, precio inclusivo exacto**
   - producto con precio redondo tipo `500.00`
   - confirmar que pantalla, modal de pago, factura y ticket imprimen `500.00`, no `499.99/500.01`

2. **Venta con modificadores cobrables**
   - 1 producto + varios modifiers con precio
   - verificar subtotal, ITBIS, ley y total en:
     - carrito
     - pago
     - factura modal
     - ticket impreso
     - reimpresión desde historial

3. **Descuento por item y/o cortesía parcial**
   - validar que el breakdown fiscal y el total final sigan reconciliando
   - revisar especialmente impresión y reimpresión

4. **Takeout mezclado con consumo en salón**
   - una misma orden con items para llevar y items con ley
   - validar que la propina de ley solo afecte lo correcto

5. **Quick sale**
   - crear venta rápida con item inclusivo y con modifiers
   - pagar e imprimir
   - confirmar que coincide con historial/reimpresión

6. **Split bill manual**
   - mover items entre subcuentas
   - usar items iguales con modificadores distintos
   - confirmar que no se fusionen mal y que cada subcuenta mantenga total correcto

7. **Split bill + pago parcial por check**
   - pagar una subcuenta, dejar otra abierta
   - revisar factura del check pagado, total restante en la cuenta y reimpresión posterior

8. **Venta histórica reimpresa con configuración fiscal distinta a la actual**
   - caso real viejo si existe
   - verificar que el fallback no cambie el total visible/impreso

9. **Factura fiscal / NCF**
   - flujo específico de `generateFiscalInvoice(...)`
   - porque este es el punto que todavía veo más sospechoso

## Veredicto
La corrección principal va en buena dirección y ya cubre bastante mejor subtotal, modifiers, descuentos, impuestos, ley, total final, quick sale, mesa, historial y reimpresión.

**Pero no lo marcaría “100% cerrado” sin correr los escenarios manuales de split bill y factura fiscal.**

Si esos dos frentes pasan, el riesgo residual baja bastante. Si fallan, el siguiente lugar a intervenir no sería la UI general sino **split bill restante** y **`generateFiscalInvoice(...)`**.
