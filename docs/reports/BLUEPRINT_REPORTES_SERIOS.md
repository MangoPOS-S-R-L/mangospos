# Blueprint de Reportes Serios para MangoPOS

Fecha: 2026-04-11  
Estado: propuesta funcional y técnica  
Idioma: ES  

## 1. Objetivo

Definir un catálogo serio de reportes operativos y gerenciales para MangoPOS, pasando de la pantalla actual de reportes tipo resumen visual a un módulo de análisis utilizable para operación, control comercial, fiscalidad y caja.

Este blueprint parte de:

- la UI actual observada en la captura (`Resumen del Mes` + tarjetas de módulos),
- el código actual de `lib/presentation/reports/*`,
- las consultas actuales en `ReportsRepository`,
- el flujo real de caja/cierre ya implementado,
- la estructura fiscal existente (`fiscal_documents`, NCF/e-CF),
- y los requerimientos explícitos de Cristian.

## 2. Lectura de la situación actual

### 2.1 Lo que ya existe hoy

En el código actual ya hay base funcional para:

- **Ventas**
  - ventas por método de pago,
  - top productos,
  - ventas por categoría,
  - ventas por empleado,
  - ventas por zona,
  - ventas por hora.
- **Impuestos**
  - breakdown por tipo/tasa,
  - base imponible,
  - propina de ley.
- **Fiscal**
  - documentos fiscales por tipo,
  - detalle tabular de comprobantes,
  - impuestos por documento.
- **Caja / finanzas**
  - sesiones,
  - movimientos por tipo,
  - diferencia acumulada,
  - resumen de cierre.

### 2.2 Lo que falta para un módulo “serio”

La pantalla actual es buena como vista ejecutiva, pero todavía no cubre bien:

- reportes tabulares profundos con filtros avanzados,
- drilldown por recibo / comprobante,
- clasificación de descuentos vs cortesías,
- análisis de modificadores,
- reportes operativos de cierres con detalle conciliable,
- consistencia de definiciones para bruto/neto/fiscal/caja,
- ni prioridad clara de implementación por valor de negocio.

### 2.3 Dirección de producto

La captura actual sugiere una entrada simple y elegante, pero el módulo objetivo debe evolucionar a dos capas:

1. **Capa ejecutiva**: resumen visual, KPI y tendencias.  
2. **Capa analítica**: reportes tabulares exportables, con filtros, totales, subtotales y fórmulas auditables.

## 3. Principios de diseño del módulo de reportes

1. **Una sola verdad por métrica**  
   Ventas, impuestos, descuentos y caja deben tener fórmulas explícitas y consistentes.

2. **Filtros comunes y predecibles**  
   Todos los reportes deben compartir un patrón de filtros.

3. **Primero operación, luego sofisticación**  
   Priorizar reportes que un negocio usa todos los días para controlar ventas, caja y fiscal.

4. **Exportación confiable**  
   Todo reporte serio debe exportar al menos a CSV; los fiscales y de cierre también a PDF.

5. **Trazabilidad**  
   Desde un KPI o fila agregada debe ser posible llegar al documento/recibo/cierre subyacente.

## 4. Estructura objetivo del catálogo

El catálogo se agrupa en cuatro áreas:

- **Sales**
- **Commercial Control**
- **Fiscal**
- **Cash**

---

# 5. Filtros globales estándar

Estos filtros deben estar disponibles de forma consistente en casi todos los reportes.

## 5.1 Filtros base

- rango de fecha
- preset de fecha: hoy / ayer / esta semana / este mes / personalizado
- sucursal (cuando MangoPOS active multi-sucursal)
- caja / dispositivo
- empleado / cajero / mesero
- zona / salón
- tipo de venta: zona / manual / rápida / delivery / self service
- estado del documento: activo / anulado / todos

## 5.2 Filtros específicos frecuentes

- categoría
- producto
- modificador
- método de pago
- tipo de comprobante
- cliente
- turno o sesión de caja
- incluir / excluir impuestos
- incluir / excluir propina de ley

## 5.3 Reglas UX

- Los filtros deben mostrarse arriba del reporte, no escondidos.
- Debe existir botón de **Limpiar filtros**.
- Debe indicarse siempre el rango aplicado y la cantidad de registros.
- En reportes agregados, las filas deben poder ordenarse por monto, cantidad o participación.

---

# 6. Catálogo de reportes requerido

## A. SALES

### A1. Ventas por categoría

**Objetivo**  
Entender qué categorías venden más en monto, unidades y tickets.

**Prioridad**  
**P0**

**Filtros**

- rango de fecha
- categoría
- zona
- empleado
- tipo de venta
- estado: activo / anulado / todos

**Bloques KPI**

- ventas netas
- ventas brutas
- unidades vendidas
- tickets con esa categoría
- ticket promedio
- participación % sobre ventas netas

**Columnas**

- categoría
- ventas brutas
- descuentos
- ventas netas
- unidades
- tickets
- ticket promedio
- % participación

**Fórmulas**

- ventas brutas = suma de `order_items.total` antes de anulación
- descuentos = suma de `order_items.discounts`
- ventas netas = ventas brutas - descuentos - anulaciones imputables
- ticket promedio = ventas netas / tickets
- % participación = ventas netas categoría / ventas netas total filtrada

**Fuente de datos actual**

- ya existe una versión parcial en `sales_by_category`
- hoy se apoya en `order_items` + `menu_items` + `categories`

**Notas técnicas**

- La definición debe aclarar si la categoría se calcula por ítem histórico o por categoría actual del producto.
- Recomendado: guardar snapshot de categoría/nombre en el item vendido para evitar distorsión histórica.

---

### A2. Ventas por empleado

**Objetivo**  
Medir desempeño de meseros/cajeros según ventas operadas.

**Prioridad**  
**P0**

**Filtros**

- rango de fecha
- empleado
- rol operativo (mesero/cajero)
- zona
- tipo de venta

**Bloques KPI**

- ventas netas
- cantidad de tickets
- ticket promedio
- anulaciones
- descuentos aplicados

**Columnas**

- empleado
- rol
- ventas netas
- tickets
- ticket promedio
- descuentos
- anulaciones
- % participación

**Fórmulas**

- ventas netas empleado = suma de pagos/órdenes asociadas al empleado
- ticket promedio = ventas netas / tickets
- % participación = ventas netas empleado / ventas netas total

**Fuente de datos actual**

- ya existe base en `sales_by_employee`
- usa relación `orders -> table_sessions -> waiter_user_id -> profiles`

**Notas técnicas**

- Definir regla para ventas manuales/rápidas: ¿se atribuyen al cajero autenticado o al creador de la orden?
- Recomendado separar en dos métricas:
  - empleado que atendió,
  - empleado que cobró.

---

### A3. Ventas por tipo de pago

**Objetivo**  
Ver composición de ventas por efectivo, tarjeta, transferencia y otros medios.

**Prioridad**  
**P0**

**Filtros**

- rango de fecha
- método de pago
- caja
- sesión de caja
- estado del pago
- empleado/cajero

**Bloques KPI**

- total cobrado
- transacciones
- ticket promedio por método
- % participación por método
- cambio entregado (solo efectivo)

**Columnas**

- método de pago
- monto neto cobrado
- transacciones
- ticket promedio
- cambio entregado
- % participación

**Fórmulas**

- monto neto cobrado = `payments.amount - change_amount`
- ticket promedio método = monto neto cobrado / transacciones
- % participación = monto método / total cobrado

**Fuente de datos actual**

- ya existe base fuerte en `payments` + `payment_methods`
- hoy ya se calcula neto usando `change_amount`

**Notas técnicas**

- Si un ticket puede pagarse en múltiples métodos, el reporte debe contar por pago, no por orden.
- Debe existir opción futura de “ver tickets mixtos”.

---

### A4. Ventas por recibo / comprobante

**Objetivo**  
Tener el reporte tabular principal para auditar venta por venta, con trazabilidad total.

**Prioridad**  
**P0**

**Requisito explícito obligatorio**  
**Este reporte debe soportar como mínimo los filtros: tipo de comprobante + rango de fecha.**

**Filtros**

- rango de fecha
- tipo de comprobante
- estado del comprobante: activo / anulado / todos
- NCF / número de comprobante
- cliente
- RNC/Cédula
- método de pago
- empleado
- caja / sesión

**Bloques KPI**

- cantidad de recibos/comprobantes
- subtotal
- descuentos
- impuestos
- propina de ley
- total facturado
- anulados

**Columnas**

- fecha/hora
- número de ticket o recibo
- NCF / e-CF
- tipo de comprobante
- cliente
- RNC/Cédula
- empleado
- método(s) de pago
- subtotal
- descuento
- impuesto
- propina de ley
- total
- estado
- referencia de orden / sesión / caja

**Fórmulas**

- subtotal = suma de base imponible/base comercial antes de impuestos
- descuento = suma de descuentos del ticket
- impuesto = suma de impuestos del documento
- total = subtotal - descuento + impuesto + propina de ley

**Fuente de datos actual**

- hay una base importante en `fiscal_documents`
- hoy ya existe detalle fiscal por documento en el módulo `Fiscal`
- aún falta consolidarlo como reporte comercial-fiscal central con más filtros y drilldown

**Notas técnicas**

- Debe soportar tanto tickets no fiscales como comprobantes fiscales, si el negocio usa ambos.
- Si hoy MangoPOS solo persiste `fiscal_documents` para ventas fiscales, conviene crear una capa unificada de “documento de venta” o una vista consolidada.
- Recomendado: una vista/RPC tipo `sales_documents_report` que una orden, pago, fiscal_document y caja.

---

### A5. Ventas por modificadores

**Objetivo**  
Medir qué extras/agregados generan más ingresos y uso.

**Prioridad**  
**P1**

**Filtros**

- rango de fecha
- modificador
- grupo de modificadores
- categoría del producto padre
- producto padre
- zona
- empleado

**Bloques KPI**

- ingreso por modificadores
- cantidad de usos
- ticket attach rate
- promedio por ticket

**Columnas**

- modificador
- grupo
- producto padre
- usos
- cantidad
- ingreso adicional
- tickets donde aparece
- attach rate %

**Fórmulas**

- ingreso adicional = suma de `order_item_modifiers.price * qty`
- tickets donde aparece = tickets únicos con ese modificador
- attach rate = tickets con modificador / tickets elegibles

**Fuente de datos actual**

- existe `order_item_modifiers`
- ya hay lógica de modificadores en ventas/splits, pero no reporte dedicado

**Notas técnicas**

- Muy importante distinguir entre:
  - modificadores con precio,
  - modificadores sin precio,
  - modificadores removidos/cortesía.
- Recomendado guardar `modifier_group_name` y `modifier_name` históricos en la línea vendida.

---

## B. COMMERCIAL CONTROL

### B1. Reporte de descuentos

**Objetivo**  
Controlar cuánto se está dejando de cobrar, por quién, dónde y bajo qué concepto.

**Prioridad**  
**P0**

**Filtros**

- rango de fecha
- empleado que aplicó
- motivo / tipo de descuento
- producto / categoría
- cliente
- caja / sesión
- tipo de venta

**Bloques KPI**

- monto total descontado
- tickets con descuento
- descuento promedio por ticket
- % descuento sobre venta bruta
- top empleados por descuentos

**Columnas**

- fecha/hora
- ticket / orden
- empleado
- cliente
- producto o nivel de ticket
- motivo de descuento
- monto bruto
- descuento aplicado
- monto neto
- % descuento

**Fórmulas**

- % descuento = descuento / monto bruto
- descuento promedio por ticket = total descuentos / tickets con descuento

**Fuente de datos actual**

- hoy existe `order_items.discounts`
- también hay `orders.discounts` en varias funciones/migraciones

**Implicaciones de modelo**

- Falta estandarizar si el descuento vive:
  - a nivel ítem,
  - a nivel orden,
  - o ambos.
- Debe existir **tipo de descuento** y **motivo** persistidos:
  - promoción,
  - descuento manual,
  - cupón,
  - ajuste comercial,
  - cortesía.
- Recomendado crear campos o tabla de eventos de descuento con:
  - `discount_source`,
  - `discount_reason`,
  - `applied_by_user_id`,
  - `authorization_user_id`.

---

### B2. Reporte de cortesías

**Objetivo**  
Separar claramente lo regalado por política comercial de un descuento normal.

**Prioridad**  
**P0**

**Filtros**

- rango de fecha
- empleado
- motivo de cortesía
- producto / categoría
- cliente
- zona

**Bloques KPI**

- monto total en cortesías
- unidades en cortesía
- tickets afectados
- % cortesías sobre venta bruta

**Columnas**

- fecha/hora
- ticket / orden
- producto
- categoría
- cantidad
- valor cortesía
- motivo
- empleado responsable
- autorizado por
- cliente

**Fórmulas**

- valor cortesía = valor comercial del ítem o parte cortesía
- % cortesías = valor cortesía / venta bruta

**Implicaciones de modelo**

- Hoy no se ve una separación formal de cortesía vs descuento.
- Esto **no debe resolverse solo con un número negativo o un descuento más**.
- Recomendado:
  - campo booleano `is_courtesy`,
  - campo `courtesy_reason`,
  - `courtesy_authorized_by`,
  - o una tabla de `order_adjustments` tipada.

**Nota funcional**

- Si una cortesía no queda tipificada, el negocio pierde visibilidad real del costo comercial.

---

### B3. Reporte de impuestos

**Objetivo**  
Ver lo cobrado por impuestos/tasas y su base de cálculo, desde una óptica operativa.

**Prioridad**  
**P0**

**Filtros**

- rango de fecha
- tipo de impuesto
- tasa
- tipo de venta
- estado del documento

**Bloques KPI**

- total impuestos cobrados
- total propina de ley
- ventas gravadas
- ventas exentas
- tasa efectiva

**Columnas**

- impuesto
- tasa
- base imponible
- monto cobrado
- documentos/items
- % sobre base

**Fórmulas**

- % sobre base = monto impuesto / base imponible
- tasa efectiva = total impuestos / ventas gravadas

**Fuente de datos actual**

- ya existe en `getTaxSummary()`
- ya existe breakdown fiscal por tasa/nombre

**Notas técnicas**

- Conviene mostrar propina de ley separada de ITBIS, aunque ambos puedan vivir en tabla `taxes`.
- El reporte comercial y el fiscal deben compartir números, no recalcular distinto.

---

## C. FISCAL

### C1. Comprobantes fiscales emitidos

**Objetivo**  
Reporte formal de NCF/e-CF emitidos, listo para revisión administrativa/fiscal.

**Prioridad**  
**P0**

**Filtros**

- rango de fecha
- tipo de comprobante
- estado: activo / anulado
- cliente
- RNC/Cédula
- NCF exacto o rango

**Bloques KPI**

- comprobantes emitidos
- comprobantes anulados
- subtotal fiscal
- ITBIS
- propina de ley
- total fiscal

**Columnas**

- fecha emisión
- NCF
- tipo de comprobante
- cliente
- RNC/Cédula
- subtotal
- ITBIS
- otros impuestos
- propina de ley
- total
- estado

**Fórmulas**

- total fiscal = subtotal + impuestos + propina de ley
- anulados = conteo/monto de documentos no activos

**Fuente de datos actual**

- ya existe una base buena en `fiscal_documents`
- la UI actual ya muestra tabla detallada

**Notas técnicas**

- Debe poder exportarse a PDF y CSV.
- Debe permitir agrupar por tipo B01/B02/B04/E31/E32/etc.

---

### C2. Ventas por recibo / comprobante fiscal detallado

**Objetivo**  
Versión fiscal detallada del reporte transaccional, con desglose de impuestos por documento.

**Prioridad**  
**P1**

**Filtros**

- rango de fecha
- tipo de comprobante
- estado
- cliente
- RNC/Cédula

**Bloques KPI**

- total documentos
- subtotal acumulado
- total ITBIS
- total otros impuestos
- total propina de ley
- total general

**Columnas**

- NCF
- tipo
- cliente
- RNC/Cédula
- subtotal
- columna dinámica por impuesto
- propina de ley
- total
- estado
- fecha

**Fuente de datos actual**

- la UI actual ya construye columnas dinámicas por `tax_breakdown`

**Notas técnicas**

- Este reporte ya tiene buena base; es una oportunidad de entrega rápida.
- Debe alinearse con el reporte A4 y no competir con él.

---

## D. CASH

### D1. Cierres de caja

**Objetivo**  
Tener listado ejecutivo de sesiones cerradas y su resultado de cuadre.

**Prioridad**  
**P0**

**Filtros**

- rango de fecha
- caja
- cajero
- dispositivo
- estado de sesión
- con diferencia / sin diferencia

**Bloques KPI**

- sesiones abiertas
- sesiones cerradas
- monto apertura
- monto cierre
- diferencia acumulada
- diferencia promedio

**Columnas**

- fecha apertura
- fecha cierre
- caja
- dispositivo
- cajero
- monto apertura
- ventas efectivo
- entradas manuales
- salidas manuales
- esperado
- contado/reportado
- diferencia
- estado

**Fórmulas**

- esperado efectivo = apertura + ventas efectivo + depósitos - retiros - gastos
- diferencia = contado - esperado

**Fuente de datos actual**

- `cash_register_sessions`
- `cash_transactions`
- `fn_get_cash_session_summary()`
- pantalla `CashClosuresView` ya resuelve gran parte del detalle

**Notas técnicas**

- Este reporte debe ser conciliable con el cierre a ciegas, no solo visual.
- Debe existir resaltado claro para sobrantes/faltantes.

---

### D2. Detalle de cierre / cuadre

**Objetivo**  
Abrir una sesión específica y entender exactamente cómo se compone el cierre.

**Prioridad**  
**P0**

**Filtros**

- sesión de caja
- caja
- cajero
- rango de fecha

**Bloques KPI**

- apertura
- ventas efectivo
- ventas tarjeta
- ventas transferencia
- depósitos
- retiros
- gastos
- esperado efectivo
- esperado total
- reportado efectivo
- reportado tarjeta
- reportado transferencia
- diferencia
- transacciones

**Columnas / secciones**

1. **Cabecera de sesión**
   - id sesión
   - caja
   - dispositivo
   - cajero
   - hora apertura/cierre

2. **Ventas por medio**
   - efectivo
   - tarjeta
   - transferencia
   - total ventas todos los medios

3. **Movimientos manuales**
   - depósitos
   - retiros
   - gastos
   - otros ingresos

4. **Conteo/reportado**
   - efectivo reportado
   - tarjeta reportada
   - transferencia reportada
   - total reportado

5. **Resultado del cuadre**
   - esperado efectivo
   - esperado tarjeta
   - esperado transferencia
   - esperado total
   - diferencia por medio
   - diferencia total

**Fórmulas**

- esperado efectivo = `start_amount + cash_sales_net + deposits - withdrawals - expenses`
- esperado total = esperado efectivo + esperado tarjeta + esperado transferencia
- diferencia total = total reportado - esperado total
- diferencia efectivo = efectivo reportado - esperado efectivo

**Fuente de datos actual**

- existe una base muy avanzada en `fn_get_cash_session_summary()` y `CashClosuresView`

**Notas técnicas**

- Hoy parte del breakdown reportado parece parsearse desde `notes`; eso no escala.
- Recomendado persistir columnas estructuradas en `cash_register_sessions` para:
  - `reported_cash`,
  - `reported_card`,
  - `reported_transfer`,
  - `reported_total`.

---

# 7. Prioridad de implementación recomendada

## Fase 1 — P0 inmediato

1. Ventas por categoría  
2. Ventas por empleado  
3. Ventas por tipo de pago  
4. Ventas por recibo / comprobante  
5. Descuentos  
6. Cortesías  
7. Impuestos  
8. Cierres de caja  
9. Detalle de cierre / cuadre  
10. Comprobantes fiscales emitidos

## Fase 2 — P1

1. Ventas por modificadores  
2. Versión fiscal avanzada por comprobante con columnas dinámicas  
3. Drilldown desde agregados a ticket  
4. Comparativos vs período anterior

## Fase 3 — P2

1. Tendencias por hora/día/semana  
2. KPIs comparativos por sucursal  
3. Alertas automáticas por anomalías de descuentos/caja  
4. Dashboards por rol

---

# 8. Implicaciones de modelo de datos

## 8.1 Descuentos y cortesías

### Situación

Hay rastros de `discounts` en `order_items` y en `orders`, pero no se ve una taxonomía fuerte.

### Requerido

Se necesita distinguir claramente:

- descuento promocional,
- descuento manual,
- cupón,
- cortesía,
- ajuste comercial,
- nota de crédito / reverso.

### Recomendación

Agregar una estructura tipada, idealmente:

- tabla `order_adjustments` o equivalente, con:
  - `id`
  - `order_id`
  - `order_item_id` nullable
  - `adjustment_type` (`discount`, `courtesy`, `coupon`, `credit_note`, etc.)
  - `reason_code`
  - `reason_label`
  - `amount`
  - `applied_by_user_id`
  - `authorized_by_user_id`
  - `created_at`

Esto evita mezclar todo en un solo número `discounts` sin contexto.

## 8.2 Modificadores

### Situación

Existe `order_item_modifiers`, suficiente para empezar.

### Requerido

Para reportes fuertes conviene asegurar snapshot histórico de:

- nombre del grupo,
- nombre del modificador,
- qty,
- precio,
- relación con el producto padre.

## 8.3 Recibos / documentos de venta

### Situación

Existe `fiscal_documents`, pero no necesariamente una capa única para todo ticket vendido.

### Requerido

Unificar la visión transaccional del reporte A4:

- orden,
- pago,
- documento fiscal,
- caja,
- empleado,
- cliente.

### Recomendación

Crear:

- una vista SQL o RPC tipo `report_sales_documents`,
- o un agregado backend que consolide ticket comercial + documento fiscal.

## 8.4 Cierre / cuadre de caja

### Situación

El cierre tiene buena lógica, pero parte del breakdown reportado parece extraerse de texto libre (`notes`).

### Requerido

Persistencia estructurada del conteo reportado por medio.

### Recomendación

Agregar en `cash_register_sessions`:

- `reported_cash`
- `reported_card`
- `reported_transfer`
- `reported_other`
- `reported_total`
- `close_notes`

## 8.5 Snapshot histórico

Para reportes confiables, el sistema debe preferir datos históricos de venta y no depender de catálogos vivos.

Recomendado conservar en la línea vendida:

- nombre del producto vendido,
- categoría al momento de venta,
- empleado responsable,
- nombres de modificadores,
- nombre del método de pago,
- tasa(s) aplicadas al momento.

---

# 9. Estructura UX recomendada del módulo

## 9.1 Landing de reportes

Mantener una portada tipo la captura actual, pero más orientada a operación:

- Resumen del período
- Accesos a Sales / Commercial Control / Fiscal / Cash
- KPIs del día/semana/mes
- botón de exportación general solo si tiene sentido

## 9.2 Vista interna de cada reporte

Cada reporte debe seguir este patrón:

1. título + descripción breve  
2. barra de filtros  
3. KPIs superiores  
4. gráfico opcional  
5. tabla principal  
6. totales/subtotales  
7. exportación CSV/PDF

## 9.3 Drilldown

Obligatorio en:

- ventas por categoría → ver tickets
- ventas por empleado → ver tickets
- descuentos → ver tickets / items
- cierres de caja → ver detalle de sesión
- comprobantes → ver documento

---

# 10. Recomendación de implementación técnica

## 10.1 En el frontend

Refactorizar el módulo actual de `reports` para separar:

- reportes ejecutivos agregados,
- reportes tabulares analíticos,
- reportes fiscales,
- reportes de caja.

En vez de tener solo una categoría genérica por pantalla, introducir un catálogo explícito de reportes con metadatos:

- id
- grupo
- título
- descripción
- filtros habilitados
- exportaciones soportadas
- prioridad

## 10.2 En backend / consultas

Crear consultas dedicadas para cada reporte P0, en vez de forzar un único summary gigante.

Mínimo recomendado:

- `get_sales_by_category_report`
- `get_sales_by_employee_report`
- `get_sales_by_payment_method_report`
- `get_sales_documents_report`
- `get_discounts_report`
- `get_courtesies_report`
- `get_taxes_report`
- `get_cash_closures_report`
- `get_cash_closure_detail_report`
- `get_fiscal_documents_report`

## 10.3 Exportación

- CSV para todos los reportes tabulares
- PDF para fiscales y cierres
- totales exportados deben coincidir exactamente con pantalla

---

# 11. Entregable funcional mínimo aceptable

Para considerar que MangoPOS ya tiene un módulo de reportes “serio”, el MVP debe incluir al menos:

- ventas por categoría,
- ventas por empleado,
- ventas por tipo de pago,
- ventas por recibo/comprobante,
- descuentos,
- cortesías,
- impuestos,
- cierres de caja,
- detalle de cierre/cuadre,
- comprobantes fiscales.

Y además:

- filtros consistentes,
- tablas exportables,
- fórmulas claras,
- trazabilidad a ticket/documento,
- separación explícita entre descuento y cortesía,
- y soporte obligatorio de **tipo de comprobante + rango de fecha** para ventas por recibo/comprobante.

---

# 12. Conclusión

MangoPOS ya tiene base real para arrancar fuerte en reportes, especialmente en:

- ventas agregadas,
- fiscal,
- impuestos,
- caja.

El salto pendiente no es “hacer otra pantalla bonita”, sino consolidar un sistema de reportes con:

- definiciones contables claras,
- filtros operativos,
- tablas auditables,
- y modelo de datos suficiente para descuentos, cortesías y modificadores.

La ruta correcta es atacar primero el núcleo P0 de operación diaria y fiscal, y dejar comparativos y analítica avanzada para la siguiente fase.
