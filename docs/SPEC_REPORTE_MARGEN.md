# SPEC — Reporte de Margen / Rentabilidad por Producto y Categoría

> **Estado:** Borrador para implementar
> **Fecha:** 2026-06-01
> **Ámbito:** Sub-reporte nuevo dentro del módulo de Reportes existente que muestra
> **utilidad bruta** (venta neta − costo) y **margen %** por producto y por categoría.
> **Aplica a restaurante Y retail** — se puede entregar en `main`, no depende de la
> rama retail.

---

## 1. Por qué / valor

El módulo de Ventas ya muestra cantidad vendida y venta neta por producto, pero **no
muestra cuánto se gana**. El dueño no sabe qué productos son rentables vs cuáles
venden mucho pero dejan poco. Es el reporte que hace sentir el POS "serio" (Toast lo
tiene como *menu engineering*) y es **crítico en retail**, donde el negocio vive del
margen.

**Costo de implementación: bajo.** El RPC `get_sales_summary_v2` ya emite los campos
`cost` y `gross_profit` por producto — hoy hardcodeados en `0`
([migración 20260531_0002](../supabase/migrations/20260531_0002_sales_breakdowns_reconcile_to_collected.sql#L279-L280)).
Solo hay que cablear el costo real y exponerlo en UI.

---

## 2. Decisión de costo (importante, leer antes)

`order_items` **NO** guarda un snapshot del costo al momento de la venta
(`supabase/schema.sql` línea ~2672: tiene `product_id`, `quantity`, `unit_price`,
`total`, `product_name`, pero ningún campo de costo). El costo vive solo en
`menu_items.cost` (línea ~2895).

**Decisión MVP:** usar el **costo actual** de `menu_items.cost` × cantidad vendida.

- ✅ Pro: cero cambios de esquema, el RPC ya tiene `menu_items` (alias `mi`) en scope.
- ⚠️ Caveat: si el costo de un producto cambió después de una venta, el margen
  histórico se recalcula con el costo nuevo (no es costo-al-momento-de-venta). Para la
  mayoría de negocios es aceptable; el costo no cambia tan seguido.
- 📌 **Disclaimer obligatorio en UI:** "Margen calculado con el costo actual del
  producto" para que el dueño no lo confunda con costo histórico exacto.

**Mejora futura (fuera de este spec, decisión D-7):** snapshotear `unit_cost` en
`order_items` al cerrar la orden, para margen histórico exacto. Si se hace, el reporte
prefiere el snapshot y cae al costo actual solo cuando el snapshot es NULL (ventas
viejas). El reporte queda diseñado para soportar ambas fuentes sin recambio de UI.

---

## 3. Cambios de backend (RPC)

Modificar `get_sales_summary_v2` en una **migración aditiva nueva** (no editar la vieja;
seguir el patrón `YYYYMMDD_NNNN_*.sql` + su `_ROLLBACK.sql`, como el resto del repo).

### 3.1. CTE `product_sales_agg` — agregar costo real
El CTE ya agrupa por `product_id` y tiene `net_sales`. Sumar el costo:

```sql
-- dentro de product_sales_agg, sumar costo usando menu_items.cost
COALESCE(SUM(ia.qty * COALESCE(mi.cost, 0)), 0) AS cost_total
-- gross_profit = net_sales - cost_total
-- margin_pct   = CASE WHEN net_sales <= 0 THEN NULL ELSE gross_profit / net_sales END
```

> `mi` (menu_items) ya está disponible en la cadena de CTEs `items_*` (se usa para
> `category_name`). Si no llega hasta `items_adjusted`, propagar `mi.cost` como columna
> `unit_cost` desde el primer CTE de items para tenerlo en `product_sales_agg`.
> Si en el futuro existe `order_items.unit_cost` (snapshot), usar
> `COALESCE(oi.unit_cost, mi.cost, 0)`.

### 3.2. Reemplazar los stubs `0` en `product_sales`
En el `jsonb_build_object` de `product_sales` (líneas 279-280):

```sql
'cost',          cost_total,                              -- antes: 0
'gross_profit',  net_sales - cost_total,                  -- antes: 0
'margin_pct',    CASE WHEN net_sales <= 0 THEN NULL       -- NUEVO
                      ELSE round(((net_sales - cost_total) / net_sales) * 100, 2) END,
```

### 3.3. `sales_by_category` — agregar costo/utilidad/margen
El CTE `by_category` hoy emite `label, amount, quantity, count`. Agregar:

```sql
-- en by_category
COALESCE(SUM(ia.qty * COALESCE(mi.cost, 0)), 0) AS cost_total
-- y en el jsonb_build_object de sales_by_category:
'cost', cost_total,
'gross_profit', amount - cost_total,
'margin_pct', CASE WHEN amount <= 0 THEN NULL
                   ELSE round(((amount - cost_total)/amount)*100, 2) END
```

### 3.4. Totales de cabecera (nuevos campos top-level)
Agregar al `jsonb_build_object` raíz, para las metric cards:

```sql
'total_cost',         (SELECT COALESCE(SUM(cost_total),0) FROM product_sales_agg),
'gross_profit_total', (SELECT total_sales FROM totals)
                        - (SELECT COALESCE(SUM(cost_total),0) FROM product_sales_agg),
'margin_pct_total',   CASE WHEN (SELECT total_sales FROM totals) <= 0 THEN NULL
                        ELSE round( ... , 2) END,
```

> **Compatibilidad:** todos los campos nuevos se **agregan**; ninguno se quita ni se
> renombra. Clientes viejos que no los lean siguen funcionando. Los campos `cost` y
> `gross_profit` ya existían (valían 0), así que ni siquiera cambia la forma del JSON
> para esos.

---

## 4. Cambios de Flutter (cliente)

Seguir el camino existente del módulo de Reportes (mirror, no inventar):

### 4.1. Modelo / parsing
- En el modelo de `product_sales` (donde se parsea `cost`/`gross_profit`), leer
  `margin_pct` (nullable double) y los nuevos totales (`total_cost`,
  `gross_profit_total`, `margin_pct_total`).
- En el modelo de `sales_by_category`, agregar `cost`, `grossProfit`, `marginPct`.
- Archivos: el modelo de summary de ventas usado por
  `lib/data/repositories/reports_repository.dart` y el state en
  `lib/presentation/reports/state/reports_state.dart`.

### 4.2. Sub-reporte nuevo en el enum existente
- Agregar `byMargin` (o `rentabilidad`) al `SalesSubReport` enum
  (`lib/presentation/reports/...`), junto a `byProduct`, `byCategory`, etc.
- Render en `lib/presentation/reports/view/sales_report_view.dart`: tabla con columnas
  **Producto | Cant. | Venta neta | Costo | Utilidad | Margen %**, ordenable por margen
  y por utilidad. Toggle producto ↔ categoría.
- Reusar los widgets de tabla/cards existentes (`report_widgets.dart`); no crear stack
  nuevo.

### 4.3. Metric cards
- Agregar tarjetas a `getSalesMetricCards()` en
  `lib/presentation/reports/viewmodel/reports_viewmodel.dart`: **Utilidad bruta total**,
  **Costo total**, **Margen % total**.

### 4.4. Visualización (opcional, fase 2)
- Cuadrante "menu engineering" con `fl_chart` (eje X = volumen, eje Y = margen %),
  clasificando estrellas/vacas/perros. No bloqueante para el MVP del reporte.

### 4.5. Export
- PDF y CSV ya recorren las secciones del summary; agregar la sección de margen a
  `reports_export_service.dart` (PDF) y `reports_csv_export_service.dart` (CSV),
  reusando el patrón de las otras secciones (formato dinámico de moneda ya existe).

### 4.6. Offline
- El `ReportsOfflineCache` cachea el summary completo por rango → el margen viaja
  gratis en el mismo blob. Sin trabajo extra.

---

## 5. Criterios de aceptación

1. En un rango con ventas, el sub-reporte **Rentabilidad** lista productos con
   **Costo, Utilidad y Margen %** correctos: `utilidad = venta_neta − (cant × costo)`,
   `margen% = utilidad / venta_neta × 100`.
2. Un producto con `cost = 0` o NULL muestra utilidad = venta neta y margen 100%
   (no rompe, no divide por cero); ordenable.
3. Vista por **categoría** suma correctamente costo y utilidad de sus productos.
4. Metric cards de cabecera (Utilidad bruta total, Costo total, Margen % total)
   cuadran con la suma del detalle.
5. **Sin regresión:** los demás sub-reportes (overview, byProduct, byCategory, byHour,
   etc.) siguen mostrando lo mismo que antes; el JSON viejo no cambió de forma para
   campos preexistentes.
6. Export PDF y CSV incluyen la sección de margen con la moneda del negocio.
7. Funciona offline desde cache.
8. UI muestra el disclaimer "Margen calculado con el costo actual del producto".
9. `flutter analyze` limpio; `flutter test` verde.

---

## 6. Riesgos

- **Precisión de costo histórico** (§2). Mitigación: disclaimer + decisión D-7 futura
  para snapshot de costo.
- **Costos no cargados** → márgenes engañosos (todo "100%"). Mitigación: si un alto %
  de productos vendidos no tiene costo, mostrar aviso "Carga los costos de tus
  productos para ver márgenes reales".
- **Rendimiento del RPC** con catálogos grandes (retail). El join a `menu_items` ya
  existe; el costo es una suma más. Validar con un negocio de muchos SKUs.
- **Área sensible: fiscal.** Este reporte NO toca emisión, NCF ni `fiscal_documents`;
  es solo agregación de ventas + costo. Cero impacto fiscal.

---

## 7. Archivos a tocar (resumen)

**Backend**
- Nueva migración `supabase/migrations/YYYYMMDD_NNNN_sales_summary_margin.sql` + ROLLBACK
  (modifica `get_sales_summary_v2`).

**Flutter**
- `lib/data/repositories/reports_repository.dart` — parsing de campos nuevos
- `lib/presentation/reports/state/reports_state.dart` — modelo/estado
- `lib/presentation/reports/viewmodel/reports_viewmodel.dart` — metric cards + sub-reporte
- `lib/presentation/reports/view/sales_report_view.dart` — UI tabla margen + toggle
- `lib/presentation/reports/services/reports_export_service.dart` — sección PDF
- `lib/presentation/reports/services/reports_csv_export_service.dart` — sección CSV

**Decisión abierta**
- **D-7:** snapshot de `order_items.unit_cost` para margen histórico exacto (futuro).
