# PRD — Ofertas, Combos y Reducción de Inventario por Oferta

- **Estado:** Borrador para aprobación
- **Fecha:** 2026-06-04
- **Rama objetivo:** `feature/ofertas-combos-inventario` (no trabajar en `main`)
- **Áreas tocadas:** ventas (mesas/zonas + venta rápida + retail), promociones, combos, inventario, reportes
- **Autor:** Equipo MangoPOS (con Claude)

---

## 1. Resumen ejecutivo

Hoy MangoPOS tiene la **base** de promociones y combos, pero está **incompleta y fragmentada**:

- Las **ofertas** (incluida "compra X paga Y" / BOGO) solo se auto-aplican en el flujo de **mesas/zonas**, no en **venta rápida** ni **retail**.
- Los **combos** se definen y se venden como un producto, pero **NO descuentan el inventario de sus componentes**.
- No existe un **reporte de ventas por oferta**; la atribución de qué venta usó qué promo es un marcador frágil en texto (`notes`).

Este PRD cubre cerrar esos huecos para que: (a) las ofertas creadas en configuración **apliquen en todos los flujos de venta**, (b) los combos **aparezcan como producto** y **descuenten inventario por componente**, (c) "4 y paga 3" **reduzca 4** del stock (ya funciona; se valida), y (d) exista un **reporte que marque las ventas hechas por oferta**.

---

## 2. Objetivos y no-objetivos

### 2.1 Objetivos
1. Las ofertas creadas en **Configuración → Promociones** se **aplican automáticamente** en **ventas por zonas/mesas**, **venta rápida** y **retail**.
2. Los **combos** creados en **Configuración → Combos** se **ven y venden como producto** en zonas/mesas **y** venta rápida.
3. Al vender un combo, el inventario **descuenta cada componente** (y, si el componente tiene receta, sus insumos).
4. En ofertas de cantidad ("4 y paga 3"), el inventario **reduce la cantidad entregada (4)**, no la cobrada (3). *(Ya es el comportamiento actual; se valida y se blinda.)*
5. **Reporte "Ventas por oferta"**: identifica y agrupa las ventas en las que se aplicó una promo/combo.
6. **Atribución confiable** de promo a nivel de línea de venta (reemplazar el marcador en `notes`).

### 2.2 No-objetivos (fuera de alcance de esta versión)
- Cupones y gift cards integrados al checkout (hoy son módulos separados; se dejan como están).
- Motor de reglas de promo "stackables" complejas más allá de lo ya soportado.
- Cambiar el momento de deducción de inventario (sigue siendo al **enviar a cocina** / confirmación).
- Rediseño visual del módulo de promos/combos.

---

## 3. Estado actual (línea base verificada en código)

### 3.1 Ofertas / promociones
- **Tipos soportados:** `percentage`, `fixed`, `bogo`, `bundle_price` — constraint en [`20260327_0010_menu_engine_promos_combos.sql:160`](../supabase/migrations/20260327_0010_menu_engine_promos_combos.sql).
- **BOGO ("compra X paga Y")** con campos `buy_quantity` / `pay_quantity` / `reward_quantity`. Se aplica en [`sales_viewmodel.dart:3557-3584`](../lib/presentation/sales/viewmodel/sales_viewmodel.dart#L3557): agrupa por `buyQty`, ordena por precio asc y descuenta los más baratos. **Solo modifica `order_items.discounts`, nunca `qty`.**
- **Creación:** Configuración → Promociones (`AppRoutes.promosCenter`); `createPromotion` sí persiste `auto_apply` ([`promos_repository.dart:107`](../lib/data/repositories/promos_repository.dart#L107)).
- **Motor de auto-aplicación:** `_applyAutomaticPromotionsIfNeeded()` se invoca **una sola vez**, al cargar la orden en el flujo de mesas/zonas — [`sales_viewmodel.dart:3208`](../lib/presentation/sales/viewmodel/sales_viewmodel.dart#L3208).
- **Atribución actual (frágil):** la promo aplicada se marca en `order_items.notes` con `[PROMO_AUTO:promo-id]` (`_buildAutoPromoNotes`). No hay columna dedicada ni reporte.

### 3.2 Combos
- Un combo es un `menu_items` con `item_type = 'combo'`. Define grupos/ítems seleccionables: tablas `combo_groups` y `combo_group_items` — [`20260327_0010_...sql:88,110`](../supabase/migrations/20260327_0010_menu_engine_promos_combos.sql#L88).
- CRUD en [`combos_repository.dart`](../lib/data/repositories/combos_repository.dart). Creación en Configuración → Combos (`AppRoutes.menuCombos`).
- **Venta:** se agrega como **una línea** (`order_item` con `product_id` = combo) y los componentes elegidos se guardan como **modifiers** — [`table_order_screen.dart:703-712`](../lib/presentation/sales/view/table_order_screen.dart#L703).
- **Venta rápida:** `quick_sale_view` **no maneja combos** ni corre el motor de ofertas.

### 3.3 Inventario
- Se descuenta al **enviar a cocina / confirmar** (`fn_confirm_order_to_kitchen` → `consume_inventory_from_order()`), no al pagar. Llamado desde [`sales_repository.dart:1519`](../lib/data/repositories/sales_repository.dart#L1519).
- **Fórmula:** `sum(recipe_ingredients.quantity * coalesce(order_items.qty, quantity, 0))` — [`20260517_0002_...sql:100`](../supabase/migrations/20260517_0002_inventory_revert_on_cancel.sql#L100). Usa la **cantidad pedida** (`qty`), expandida por receta.
- **Gates:** `business_settings.inventory_mode = 'advanced'` y `menu_items.is_inventory_tracked = true`.
- **Recetas/BOM:** `recipes` + `recipe_ingredients` vinculan producto → **insumos**, NO producto → **otros productos**. Por eso un combo (sin receta propia) **no descuenta nada de sus componentes**. Confirmado: `consume_inventory_from_order` no tiene conciencia de combos.

### 3.4 Conclusión de la línea base
- "4 paga 3 → reduce 4": **ya funciona** (la promo no toca `qty`, el inventario usa `qty`).
- Huecos reales: (1) ofertas no aplican fuera de mesas, (2) combos no descuentan inventario por componente, (3) combos no se venden en venta rápida, (4) no hay reporte ni atribución limpia.

---

## 4. Requisitos funcionales

| ID | Requisito | Origen |
|----|-----------|--------|
| R1 | Las ofertas creadas en configuración aplican en zonas/mesas, venta rápida y retail | Cliente |
| R2 | Combos se ven y venden como producto en zonas/mesas **y** venta rápida | Cliente |
| R3 | Vender un combo descuenta el inventario de cada componente (y sus insumos) | Cliente |
| R4 | En "X paga Y" el inventario reduce X (entregado), no Y (cobrado) | Cliente |
| R5 | Reporte que marque/agrupe las ventas hechas por oferta | Cliente |
| R6 | Atribución confiable promo→línea de venta (base de R1 y R5) | Técnico |

---

## 5. Diseño técnico

### 5.1 Atribución de oferta (cimiento de R1 + R5)
- Agregar columna **`order_items.promotion_id uuid null`** (FK a `promotions`), poblada cuando una promo se aplica a la línea.
- Migrar el motor para escribir `promotion_id` en vez del marcador en `notes` (se puede mantener `notes` por compatibilidad temporal).
- Beneficio: aplicar y reportar usan una fuente de verdad estructurada, no parsing de texto.

### 5.2 Motor de ofertas en todos los flujos (R1)
- Extraer/compartir `_applyAutomaticPromotionsIfNeeded()` de modo que también corra en:
  - **Venta rápida** (`quick_sale_view` / su viewmodel).
  - **Retail** (`retail_carts_provider`).
- Disparador: al cambiar el contenido del carrito (igual que hoy en mesas tras `load`).

### 5.3 Combos como producto en ambos flujos (R2)
- Reutilizar el diálogo de selección de combo (`_ComboSelectionDialog`) en **venta rápida**, no solo en `table_order_screen`.
- Asegurar que los combos (`item_type='combo'`) aparezcan en el catálogo de ambos flujos.

### 5.4 Inventario por componente de combo (R3)
- Extender `consume_inventory_from_order()` para que, cuando la línea sea `item_type='combo'`, **expanda sus componentes** (desde los modifiers/`combo_group_items` seleccionados) y descuente:
  - el inventario de cada componente con `is_inventory_tracked`, **y/o**
  - los insumos de la receta de cada componente, según corresponda.
- Migración **aditiva + ROLLBACK** (patrón del repo). Mantener compatibilidad total con productos no-combo (restaurante actual).

### 5.5 "X paga Y" reduce X (R4)
- No requiere cambio funcional (la promo no toca `qty`). Se agrega **validación/QA** y, si se desea, una nota explícita en el modelo para blindar el invariante.

### 5.6 Reporte "Ventas por oferta" (R5)
- Query/RPC que agrupe ventas pagadas por `promotion_id`: por oferta → unidades, monto descontado, total vendido, # de transacciones, rango de fechas.
- Pantalla de reporte en el módulo de reportes (o subpantalla del centro de promos).

---

## 6. Áreas sensibles (precaución explícita)
- **Inventario compartido**: la extensión de `consume_inventory_from_order` toca una función central de restaurante. Debe ser aditiva y no alterar el cálculo de productos normales.
- **Doble descuento**: cuidar que combo NO descuente a la vez la línea-combo y los componentes (el combo no debe tener receta propia, o gateamos por `item_type`).
- **Reconciliación**: los triggers de revert/edición ([`20260517_0002`](../supabase/migrations/20260517_0002_inventory_revert_on_cancel.sql)) deben seguir cuadrando con la expansión de combos.
- **Offline**: la deducción corre en el replay del RPC al sincronizar; la lógica nueva debe ser idempotente igual que la actual.
- **Motor de ofertas en venta rápida**: no debe introducir bucles de re-render ni doble aplicación (mismo cuidado que el flujo de mesas).

---

## 7. Fases de entrega

### Fase 0 — Rama + cimientos
- Crear rama `feature/ofertas-combos-inventario`.
- Migración aditiva `order_items.promotion_id` (+ ROLLBACK).
- Validar "4 paga 3 → reduce 4" end-to-end (con `inventory_mode='advanced'` + `is_inventory_tracked`).

### Fase 1 — Ofertas aplican en todos los flujos (R1, R6)
- Motor compartido + cableado en venta rápida y retail.
- Escribir `promotion_id` al aplicar.

### Fase 2 — Combos en venta rápida + inventario por componente (R2, R3)
- Selección de combo en venta rápida.
- Extender `consume_inventory_from_order` para expandir componentes. Migración + ROLLBACK.

### Fase 3 — Reporte "Ventas por oferta" (R5)
- Query/RPC de atribución + pantalla de reporte.

### Fase 4 — Tipos de oferta nuevos (a definir)
- Mecánicas adicionales según prioridad del negocio.

---

## 8. Criterios de aceptación / QA

- [ ] Oferta creada en Configuración aplica en mesa/zona, venta rápida y retail.
- [ ] "4 paga 3": cobra 3, **inventario baja 4** (verificado en `inventory_movements`).
- [ ] Combo vendido en venta rápida funciona igual que en mesas.
- [ ] Vender un combo **descuenta el inventario de cada componente**; cancelar/editar lo **devuelve** correctamente.
- [ ] Productos normales (restaurante) descuentan inventario **exactamente igual que antes** (sin regresión).
- [ ] Reporte "Ventas por oferta" muestra unidades, descuento y total por promo, y cuadra con las ventas reales.
- [ ] Funciona offline (deducción y atribución se replayan al sincronizar).

---

## 9. Riesgos y mitigaciones

| Riesgo | Mitigación |
|--------|-----------|
| Regresión en inventario de restaurante | Migración aditiva, gate por `item_type='combo'`, QA de no-regresión |
| Doble descuento combo (línea + componentes) | Combo sin receta propia; expansión solo por componentes |
| Bucle de re-render al aplicar ofertas en venta rápida | Reusar el mismo patrón anti-glitch del flujo de mesas |
| Atribución inconsistente offline | `promotion_id` viaja en el payload y se replaya idempotente |
| Migración rompe esquema compartido | Siempre con `_ROLLBACK.sql`; revisar antes de aplicar a Supabase |

---

## 10. Estimación de esfuerzo (orden de magnitud)

| Fase | Esfuerzo relativo |
|------|-------------------|
| Fase 0 — cimientos | Bajo |
| Fase 1 — ofertas en todos los flujos | Medio |
| Fase 2 — combos + inventario | Alto (toca inventario) |
| Fase 3 — reporte | Medio |
| Fase 4 — tipos nuevos | A definir |

---

## 11. Preguntas abiertas
1. En un combo, ¿el inventario debe descontar los **componentes como productos terminados**, sus **insumos de receta**, o ambos según el tipo de componente?
2. ¿El reporte vive en el módulo de **Reportes** o como subpantalla del **Centro de Promos**?
3. ¿Qué tipos de oferta nuevos prioriza el negocio para la Fase 4?
