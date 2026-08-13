# PRD — Vertical Salón / Esmaltería (comisiones por empleada, turnos y certificados)

> **Estado:** Borrador para revisión
> **Fecha:** 2026-08-10
> **Dueño de producto:** Cristian Gómez
> **Origen:** Documento de requerimientos del cliente **"FUSISTEMA ESMALTERIA"**
> (secciones A–J), entregado en físico.
> **Ámbito:** Habilitar MangoPOS para salones de belleza / esmalterías / barberías /
> spas, cuyo eje operativo NO es la mesa ni la cocina sino **quién realizó cada
> servicio y cuánto se le comisiona**.

---

## 1. Resumen ejecutivo

El documento del cliente pide 10 bloques funcionales (A–J). Al contrastarlos contra
el código, **la mayoría ya existe** y es configuración, no desarrollo: facturación,
métodos de pago, descuentos, gastos de caja con recibo impreso, cuadre diario con
conteo de billetes, catálogo con código/precio/ITBIS/costo, entradas y salidas de
inventario, reporte DGII, ventas por categoría (= "departamento") e historial por
cliente.

**Lo que no existe es el corazón del negocio de un salón: la comisión por empleada.**
No hay una sola referencia a comisiones en el repositorio. Hoy la clienta saca el
reporte de servicios por empleada y calcula el porcentaje **a mano**, y luego le
resta a mano los préstamos/avances del reporte de gastos.

La buena noticia es que la mitad invisible ya está construida:

- `order_items.created_by_employee_id` existe desde el multimesero
  (`supabase/migrations/20260516_0001_multimesero_setup.sql`): **cada línea de la
  orden ya puede saber quién la hizo**.
- `fn_sales_by_waiter` ya agrupa por empleada con bruto, descuentos y neto
  (`20260516_0002`, ampliada en `20260728_0001` y `20260728_0002`).
- El **reconocimiento diferido** que necesitan los CERTIFICADOS ya está resuelto para
  el crédito en `20260725_0002_credit_sales_deferred_recognition.sql`: facturar sin
  inflar el ingreso del día. Los certificados son el mismo patrón, generalizado.

Este PRD define 4 fases. La **Fase 1 (Comisiones)** es la que entrega el valor real y
es la única que toca el camino crítico de cobro.

---

## 2. Gap analysis — documento del cliente vs. código actual

### 2.1 Ya existe (configuración, no desarrollo)

| # | Requerimiento del documento | Dónde vive hoy |
|---|---|---|
| A | Buscar cliente por teléfono; alta con nombre, apellido y celular | `lib/presentation/customers/view/customers_view.dart` (`customers.name/phone/email`) |
| B | Agregar servicios, elegir método de pago, aplicar descuentos, imprimir factura | Flujo de venta + `PaymentModal` + impresión |
| C | Gastos pagados de caja con **ticket impreso** de constancia | `lib/presentation/cashier/view/income_expense_view.dart` (imprime recibo del movimiento) |
| D | Cuadre diario: ventas por tipo de pago, gastos del día, conteo de monedas/billetes | `lib/presentation/cashier/detailed_wizard/` + conteo ciego (`blind_cash_close_dialog.dart`) |
| E | Artículos y servicios con código, nombre, precio, ITBIS sí/no y costo | `menu_items` (`sku`, `price`, `cost`) + `menu_item_taxes` |
| F | Entradas por compra, salidas por consumo interno, reporte de inventario con cantidades/precio/costo | Módulo de compras + `inventory_movements` + reporte de inventario |
| G | Registro de empleadas con nombre y código | `employees` (con PIN, roles, roster offline) |
| I.1 | Reporte del mes **por facturación** (fecha, cliente, monto, tipo de pago) | Reporte de Ventas + Comprobantes fiscales |
| I.2 | Reporte del mes **por departamento** (uñas, cejas, spa, productos) | "Ventas por categoría" — `sales_report_view.dart:304` |
| J.1 | Reporte DGII de comprobantes, exportable | Reporte "Comprobantes fiscales" + export CSV |
| J.2 | Ventas por servicio en un rango de fechas | Reporte de Ventas (filtro por producto/categoría) |
| J.3 | Historial de facturación por cliente | `customer_detail_view.dart` |

> **Configuración obligatoria, no opcional:** el ITBIS de cada servicio se define
> **solo** por el vínculo en `menu_item_taxes`. Un servicio sin vínculo factura ITBIS
> 0 en silencio. Si además la comisión se calcula sobre base sin ITBIS, un servicio
> mal configurado le paga de más a la empleada sin que nadie lo note. La carga del
> catálogo debe verificar los dos vínculos: impuesto y categoría/departamento.

### 2.2 No existe — el trabajo de este PRD

| # | Requerimiento | Estado | Fase |
|---|---|---|---|
| H | **Comisión por empleada (porcentajes)** | Cero. No hay tabla, ni regla, ni reporte. Se calcula a mano. | **F1** |
| B | Elegir **la manicurista de cada servicio** dentro de la misma factura | El dato existe (`created_by_employee_id`) pero se llena con el empleado activo; no hay selector por línea | **F1** |
| H | Descontar **préstamos/avances** de lo que se le paga a la empleada | Cero | **F1** |
| A | **Turno** impreso al recibir a la clienta | Cero | F2 |
| B | Método de pago **CERTIFICADOS**: factura y comisiona, pero no entra al ingreso del día | `gift_cards` existe pero solo se lee en Ofertas; no se puede cobrar con ella | F2 |
| C | Gastos **no pagados de caja** (banco) | Parcial: módulo de Contabilidad Fase 1 (migración sin aplicar) | F3 |
| I | **Cuadre del mes** con ingresos − gastos | Cero (los dos insumos existen por separado) | F3 |
| D | **Correo automático** al cerrar el cuadre | Cero. Requiere emisor server-side | F3 |
| A | Cumpleaños de la clienta + correos masivos | `customers` no tiene fecha de nacimiento; no hay emisor de correos | F3 |
| H | **Nómina** (sueldo, horas extras, AFP, ARS, préstamos) | PRD escrito, nada implementado — [PRD_NOMINA_LABOR.md](PRD_NOMINA_LABOR.md) | F4 |

---

## 3. Decisiones abiertas (cerrar con la clienta antes de codificar)

Cada una cambia el número que se le paga a una persona. Ninguna se asume en código:
todas viven en configuración, con el **default recomendado** ya marcado.

| # | Pregunta | Default recomendado | Por qué |
|---|---|---|---|
| D1 | ¿La comisión se calcula **con o sin ITBIS**? | **Sin ITBIS** | El ITBIS es del Estado, no ingreso del salón |
| D2 | ¿Antes o después del **descuento**? | **Después del descuento** | Si se descuenta, el salón cobra menos; la comisión sigue al ingreso real |
| D3 | ¿Los **productos** (esmaltes, etc.) comisionan igual que los servicios? | **Regla aparte por categoría**, default 0% | Vender producto no es lo mismo que ejecutarlo |
| D4 | ¿Un servicio lo pueden hacer **dos manicuristas** y se reparte? | **No en F1**: se factura en dos líneas | El reparto porcentual por línea complica el devengo; se evalúa en F2 |
| D5 | **Certificados**: ¿la comisión se gana al facturar o al redimir? | **Al facturar** | Es literalmente lo que dice el documento (sección B) |
| D6 | ¿El certificado aparece en el cuadre del día? | **Sí, como memo informativo fuera del total** | Mismo trato que ya recibe la venta a crédito |
| D7 | ¿La comisión se paga sobre lo facturado o sobre lo **cobrado**? | **Sobre lo facturado** | Coherente con D5; si mañana quieren "cobrado", es un filtro sobre el mismo snapshot |
| D8 | ¿El porcentaje puede variar **por empleada y por servicio** a la vez? | **Sí** (es el caso normal en salones) | Define la jerarquía de resolución de §4.3 |

---

## 4. Fase 1 — Motor de comisiones

### 4.1 Prerrequisito: atribución explícita por línea

Hoy `order_items.created_by_employee_id` se llena con el empleado activo al insertar
la línea (multimesero) o, como respaldo, con quien abrió la orden
(`fn_order_opener_employee_id`, `20260529_0006`). Para un restaurante eso alcanza.
**Para comisiones no**: heredar mal el empleado activo no es un dato feo en un
reporte, es dinero pagado a la persona equivocada. Ya tenemos historial de PIN
pegajoso del mesero activo arrastrándose entre operaciones.

Cambios:

1. **Selector de empleada por línea** en la pantalla de orden, visible como chip en
   cada ítem (`lib/presentation/sales/view/widgets/order_screen/order_items_list.dart`),
   editable con un toque mientras la orden esté abierta.
2. **Reasignación** de la empleada de una línea ya enviada, con permiso
   (`comisiones.reasignar`) y registro en `audit_logs`.
3. **Bloqueo de cobro** si el flag `commissions_enabled` está encendido y alguna
   línea comisionable quedó sin empleada asignada. Mensaje concreto: "Falta asignar
   quién realizó: Manicure Gel".
4. El valor por defecto del selector sigue siendo el empleado activo — se gana
   velocidad sin perder la capacidad de corregir.

### 4.2 Modelo de datos

Migración `20260810_0001_commissions_core.sql` (+ su `_ROLLBACK.sql`), idempotente.

**a) Reglas de porcentaje**

```
employee_commission_rules
  id, business_id
  employee_id     null = aplica a todas las empleadas
  menu_item_id    null = no es regla de servicio específico
  category_id     null = no es regla de departamento
  rate_type       'percent' | 'fixed'
  rate_value      numeric  (12.50 = 12.5%  |  monto fijo por unidad)
  base_override   null | 'gross' | 'net_after_discount' | 'net_ex_tax'
  effective_from  date not null
  effective_to    date null
  is_active       boolean
```

- `menu_item_id` y `category_id` son **mutuamente excluyentes** (CHECK).
- Índice único parcial por `(business_id, employee_id, menu_item_id, category_id,
  effective_from)` con `is_active` — dos reglas idénticas vigentes a la vez es un
  error de datos, no una ambigüedad a resolver en tiempo de cálculo.
- **Nunca se edita una regla vigente para "cambiar el %"**: se cierra con
  `effective_to` y se crea la siguiente. El historial es intocable.

**b) Snapshot del devengo**

```
order_item_commissions
  id, business_id
  order_item_id (unique donde status <> 'void'), order_id, check_id
  employee_id
  rule_id            (on delete set null — la regla puede desaparecer, el pago no)
  rate_type, rate_value
  base_kind, base_amount
  commission_amount
  status             'accrued' | 'paid' | 'void'
  accrued_at
  payout_id          null hasta que se liquide
```

Congelar el cálculo es el punto crítico: subir un porcentaje mañana **no puede**
mover lo ya devengado. Es el mismo criterio que ya aplicamos a las ofertas
congeladas en órdenes abiertas.

**c) Liquidación**

```
commission_payouts
  id, business_id, employee_id
  period_from, period_to
  gross_commission, deductions_total, net_amount
  status 'draft' | 'closed'
  closed_at, closed_by, notes

commission_payout_deductions
  id, payout_id
  concept        'advance' | 'loan' | 'other'
  description, amount
  cash_transaction_id  null  (enlaza el gasto de caja que originó el avance)
```

Las deducciones enlazan opcionalmente al movimiento de caja real: así el préstamo
que hoy se busca a mano en el reporte de gastos del mes queda trazado. La nómina
completa (AFP, ARS, ISR) **no** vive aquí — vive en F4.

**d) Flags y permisos**

- `business_settings.commissions_enabled boolean not null default false`
- `business_settings.commission_base text not null default 'net_ex_tax'`
  (`gross` | `net_after_discount` | `net_ex_tax`), siguiendo el patrón de
  `20260806_0001_printerless_mode.sql`: default = comportamiento actual.
- Permisos nuevos en `lib/core/security/access_control_catalog.dart`, con la
  convención existente: `comisiones.acceso`, `comisiones.configurar`,
  `comisiones.reasignar`, `comisiones.liquidar`. Solo `comisiones.acceso` entra en
  presets de cajero; configurar y liquidar son de gerencia hacia arriba.
- `business_type`: agregar `'Salón / Spa / Barbería'` al CHECK de `businesses`,
  igual que hizo retail en `20260602_0002_business_type_retail_verticals.sql`.

### 4.3 Resolución de la regla

Por cada línea se busca la regla **más específica vigente a la fecha de la orden**:

| Prioridad | Regla | Ejemplo |
|---|---|---|
| 1 | empleada + servicio | María en Manicure Gel: 20% |
| 2 | empleada + departamento | María en Spa: 15% |
| 3 | empleada (default suyo) | María: 10% |
| 4 | servicio (todas) | Pedicure: 12% |
| 5 | departamento (todas) | Productos: 5% |
| 6 | negocio (default general) | 10% |

Sin regla aplicable → comisión 0 con `rule_id = null`. Empate imposible por el
índice único; ante dos vigencias solapadas gana la de `effective_from` más reciente.

### 4.4 Base de cálculo

Según `commission_base` (o el `base_override` de la regla):

- `gross` = `unit_price × qty`
- `net_after_discount` = `subtotal − discounts`
- `net_ex_tax` (recomendada) = `subtotal − discounts`, ya sin ITBIS; en ítems
  `tax_mode = 'inclusive'` hay que **desmontar** el impuesto antes de comisionar.

El caso inclusivo es el que produce errores silenciosos: si el servicio está marcado
inclusivo pero sin impuesto vinculado, `net_ex_tax` termina igual al bruto y la
comisión sale inflada. La prueba de aceptación tiene que cubrirlo explícitamente.

### 4.5 Cuándo se devenga

**Sin triggers en el camino del POS** — misma regla que fijamos para contabilidad.

1. Al cerrar/cobrar la orden, el cliente llama
   `fn_accrue_order_commissions(p_order_id)`, idempotente por `order_item_id`.
2. Anular un ítem o una orden marca sus filas como `void` (nunca las borra).
3. **Respaldo por lote**: `fn_backfill_commissions(business_id, from, to)` recorre
   órdenes cerradas sin devengo y las completa. Esto es obligatorio, no opcional:
   la app es offline-first y la llamada del paso 1 puede no ocurrir. El backfill
   resuelve la regla por **fecha de la orden**, así que converge al mismo número.
4. Liquidar un `payout` pasa sus filas de `accrued` a `paid`. Una fila `paid` no se
   recalcula nunca.

### 4.6 Reportes

1. **Comisiones por empleada** (rango de fechas): servicios realizados, base, %,
   comisión. Expandible al detalle línea por línea, con export CSV.
2. **Liquidación**: comisión bruta − avances/préstamos = neto a pagar, imprimible y
   exportable. Es el insumo directo del volante de nómina de F4.
3. Añadir la columna de comisión al reporte "Ventas por mesero" existente, que en
   este vertical se rotula **"Ventas por empleada"** según `business_type`.

### 4.7 Criterios de aceptación (F1)

- Una factura con 3 servicios de 2 manicuristas distintas genera 3 filas de comisión
  con la empleada correcta cada una.
- Cambiar un porcentaje hoy no altera ni un centavo de lo devengado ayer.
- Anular una factura pone su comisión en `void` y la saca del reporte.
- Un ítem con descuento comisiona sobre el neto (D2) y sin ITBIS (D1), tanto en
  `exclusive` como en `inclusive`.
- Con `commissions_enabled = false` nada cambia en la app: ni UI, ni RPC, ni cobro.
- Órdenes cobradas offline y sincronizadas después quedan devengadas tras correr el
  backfill, con el mismo monto que si hubieran estado en línea.
- El reporte de liquidación cuadra contra "Ventas por empleada" del mismo rango.

---

## 5. Fase 2 — Turnos y certificados

### 5.1 Turnos (documento, sección A)

- `orders.turn_number int` + `fn_next_turn_number(business_id, date)` — secuencia
  diaria por negocio, reiniciada cada día.
- Al registrar/buscar a la clienta por teléfono se abre el turno y se **imprime un
  ticket compacto** (turno, clienta, hora, espacio para que la manicurista anote los
  servicios) por la vía de impresión existente. Respeta `printerless_mode`: sin
  impresora, se muestra en pantalla.
- Al facturar, se busca por número de turno.
- Flag `turns_enabled`. El modo de venta base es **Venta rápida** (mostrador); mesas,
  zonas, KDS y comandas quedan apagados por feature flags — ya son configurables.

### 5.2 Certificados de regalo (documento, sección B)

Generalizar el patrón ya probado en `20260725_0002` para el crédito:

- `payment_methods.is_deferred_income boolean not null default false`.
- `fn_get_cash_session_summary` y `fn_dashboard_kpis` excluyen del ingreso del día
  **cualquier** método con esa marca (no solo `code = 'credit'` hardcodeado) y lo
  exponen aparte como memo (D6).
- La comisión **sí** se devenga (D5): el motor de F1 no mira el método de pago.
- Redención contra `gift_cards` / `gift_card_transactions`, que ya existen, con
  validación de saldo y vencimiento.

> ⚠️ Antes de recrear `fn_get_cash_session_summary` o `fn_dashboard_kpis`, verificar
> con `pg_get_functiondef` que la versión viva coincide con la del repo. La BD de
> producción diverge de las migraciones y estas dos funciones ya fueron reescritas
> más de una vez.

---

## 6. Fase 3 — Cuadre mensual, correo y CRM

- **Cuadre del mes** (I PLUS): ingresos (pagos no diferidos + abonos recibidos)
  menos gastos (movimientos de caja + gastos registrados fuera de caja), por mes y
  por departamento. Se apoya en el módulo de Contabilidad Fase 1
  ([PRD_CONTABILIDAD.md](PRD_CONTABILIDAD.md), migración `20260805_0001` sin aplicar).
- **Gastos fuera de caja** (C PLUS): registrar gastos pagados por banco/transferencia
  que hoy no existen porque todo movimiento cuelga de una sesión de caja.
- **Correo al cerrar el cuadre** (D) y **correos masivos + cumpleaños** (A PLUS):
  ambos requieren un emisor server-side (Edge Function + proveedor SMTP). La app no
  tiene hoy ninguna capacidad de envío de correo — es la única pieza de este PRD con
  dependencia de infraestructura externa, y por eso va al final.
- `customers.birth_date date` para el saludo automático con descuento.

---

## 7. Fase 4 — Nómina

Sin PRD nuevo: se ejecuta [PRD_NOMINA_LABOR.md](PRD_NOMINA_LABOR.md), que ya cubre
fichaje, TSS/AFP/ARS, ISR, regalía y volantes. Este PRD solo aporta el enganche:
**la comisión liquidada de F1 entra como devengado del período**, y los avances ya
deducidos no se descuentan dos veces.

---

## 8. Lo que este PRD deliberadamente NO hace

- No reparte una comisión entre dos empleadas en la misma línea (D4).
- No calcula nómina, TSS ni ISR — eso es F4.
- No crea un módulo de citas/reservas: ya existe [PRD_RESERVAS.md](PRD_RESERVAS.md)
  y el turno de un salón sin cita previa es otra cosa.
- No toca `is_service_fee` (regla del dueño: activarlo produce factura doble).
- No bifurca la app: un salón es MangoPOS con mesas/cocina apagadas, comisiones
  encendidas y `business_type` de salón.

---

## 9. Riesgos

| Riesgo | Mitigación |
|---|---|
| Atribución heredada del empleado activo paga a la persona equivocada | Selector explícito por línea + bloqueo de cobro sin asignar + auditoría de reasignaciones |
| Cambiar un % recalcula el pasado | Snapshot congelado en `order_item_commissions`; las reglas se versionan, no se editan |
| Servicio sin impuesto vinculado infla la base `net_ex_tax` | Validación en la carga del catálogo + prueba de aceptación del caso inclusivo |
| Devengo perdido por operación offline | `fn_backfill_commissions` por rango, determinista por fecha de orden |
| Recrear funciones de caja/dashboard sobre una BD divergente | `pg_get_functiondef` antes de aplicar; migración con ROLLBACK |
| Doble descuento de un avance (aquí y en nómina) | El avance deducido queda enlazado y marcado; F4 lo respeta |

---

## 10. Puesta en marcha (negocio piloto)

1. `business_type = 'Salón / Spa / Barbería'`; apagar mesas, KDS y comandas; dejar
   **Venta rápida** encendida.
2. Cargar departamentos como categorías (uñas, cejas, spa, productos) y los servicios
   con código, precio, costo y **vínculo de ITBIS verificado**.
3. Cargar empleadas con su PIN y su porcentaje por defecto; luego las excepciones por
   servicio o departamento.
4. Encender `commissions_enabled` y fijar `commission_base` según D1/D2.
5. Correr una semana en paralelo con el cálculo manual de la clienta y comparar el
   reporte de liquidación contra su hoja. Ese cuadre es la condición de salida de F1.
