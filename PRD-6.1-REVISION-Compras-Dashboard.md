# PRD 6.1 — Revisión contra el backend real (agosto 2026)

**Estado:** corrige el borrador 0.1 del PRD 6.1. El análisis de brechas original
se hizo contra el espejo de 13 migraciones de `mango_dashboard`; este documento
lo rehace contra el libro mayor real (`mangospos/supabase/migrations`, ~250
migraciones) y ajusta el plan. Las migraciones de F1 ya están escritas
(`20260811_0001..0003`, con ROLLBACK, byte-idénticas en ambos repos).

## 1. Brechas del PRD que YA estaban resueltas

| El PRD asumía que faltaba | Ya existe en el backend |
|---|---|
| Tabla de suplidores con RNC | `suppliers` (schema base) + FK `purchase_orders.supplier_id` |
| Recepción parcial | `fn_receive_purchase_order_partial` (20260514_0005) — por línea, recalcula estado de la PO |
| Costo promedio ponderado | `fn_recompute_item_cost_weighted_avg` (20260516_0004) + recost por último precio (20260714_0001) |
| Recepción libre sin OC | `direct_receipts` + RPC atómica (20260514_0007) |
| Unidad de compra vs. venta | `inventory_items.purchase_unit` + `pack_size` (20260608_0002) — el ledger opera en unidad base |
| ITBIS por línea de compra | `purchase_order_items.tax_rate` (default 18) |
| Conteos cíclicos ciegos | `physical_count` (20260516_0011) + blind recount (20260801_0002) |
| Reglas de reorden | `reorder_suggestions` (20260516_0016) |
| Kardex | vista `v_inventory_movements_with_balance` (20260514_0005) |

## 2. Brechas reales (lo que sí hay que construir)

1. **Bloque fiscal de la compra** (NCF, ITBIS facturado, retenciones ISR/ISC,
   propina legal) → resuelto en `20260811_0002` con `purchase_receptions` +
   `purchase_reception_lines`.
2. **Costo real facturado por línea** con variación vs. la OC y aprobación
   sobre umbral → columnas en `purchase_reception_lines` +
   `business_settings.cost_variance_threshold_pct` (`20260811_0003`).
3. **Idempotencia de recepción** → `idempotency_key` único por negocio +
   índice único parcial en `inventory_movements` para
   `reference_type='purchase_reception_line'` (`20260811_0002`).
4. **RPC `fn_receive_purchase_order_v2`** (F3) → se construye SOBRE
   `fn_receive_purchase_order_partial` (mismo formato de líneas jsonb),
   añadiendo costo real, fiscal, variación e idempotencia. Contrato:
   - `pg_advisory_xact_lock(hashtextextended(business_id||':'||idem_key, 0))`
     al entrar (patrón 20260509_0007).
   - Clave ya existente → reconstruir la respuesta desde las filas y devolver
     `"replayed": true` (patrón fn_process_payment_v3, 20260509_0001). Nunca
     se guarda un blob de respuesta: se deriva del estado.
   - Clave + efectos commitean en UNA transacción.
   - Variación > umbral sin `approved_by` → si quien recibe puede aprobar,
     auto-aprobación en bitácora; si no, error `COST_VARIANCE_UNAPPROVED`.
5. **Exportación 606** (F7) → sigue siendo brecha; nada en `accounting_core`.
6. **Multi-código de barras por variante** → sigue siendo brecha (evaluar si
   v1 lo necesita; los lotes fase 1 ya existen).

## 3. Fases ajustadas

- **F1** = migraciones `20260811_0001..0003` (hechas) + CRUD de suplidor en el
  dashboard (columnas nuevas: tax_id_type, whatsapp, payment_terms_days).
- **F3** = RPC v2 según el contrato de arriba + golden tests (parcial,
  sobrante, stock cero/negativo, reenvío triple con la misma clave).
- **F4** = pantalla de recepción (sin cambios vs. PRD).
- **F5 y F6** pasan de "construir" a "conectar la UI del dashboard a los RPCs
  y vistas que ya existen" (conteos ciegos, reorden). Baja el costo estimado.
- **F7** (606) sin cambios.

## 4. Decisiones tomadas en esta revisión

- **Acceso del dashboard**: `manager` ya entra (role_mapper del dashboard),
  con UI restringida — sin Productos/Ofertas/Suscripción ni forzar cierre de
  caja. Cubre `compras.recibir` para manager sin motor de permisos nuevo.
- **Fuente de verdad de migraciones**: `mangospos/supabase/migrations` es el
  libro mayor; toda migración compartida se commitea byte-idéntica en ambos
  repos. Verificación: `diff -q` entre carpetas debe dar vacío para los
  archivos compartidos (19 hoy).
- **Suplidores**: la RLS existente deja la escritura en owner/admin
  (`sup_admin`); manager crea POs y recibe, pero no crea suplidores en v1.
- **Umbral de variación** vive en `business_settings` (patrón
  `cash_variance_alert_threshold`), no en `businesses`.
