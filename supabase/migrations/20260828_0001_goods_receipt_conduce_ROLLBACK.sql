-- =============================================================================
-- ROLLBACK de 20260828_0001_goods_receipt_conduce.sql
--
-- QUÉ DESHACE:
--   - La bandera business_settings.require_goods_receipt (la app vuelve a
--     permitir registrar compras ya "Recibidas").
--   - El número de conduce, la nota y los snapshots de línea.
--   - La función fn_receive_purchase_order_v2 en su versión "con conduce".
--
-- QUÉ NO DESHACE (a propósito):
--   - purchase_receptions / purchase_reception_lines y sus índices: son de
--     20260811_0002. Borrarlas aquí destruiría recepciones ya registradas.
--     Para eliminarlas usa 20260811_0002_purchase_receptions_fiscal_ROLLBACK.sql.
--   - business_settings.cost_variance_threshold_pct: es de 20260811_0003.
--   - Los movimientos de inventario ya posteados. El stock que entró, entró:
--     revertirlo es un ajuste de inventario, no una migración.
--
-- OJO: tras este rollback, fn_receive_purchase_order_v2 deja de existir. Si
-- 20260812_0001 estaba aplicada y la quieres de vuelta, vuelve a correr ese
-- archivo. La app cae sola a fn_receive_purchase_order_partial (recepción sin
-- documento) cuando la v2 no está.
-- =============================================================================

begin;

drop function if exists public.fn_receive_purchase_order_v2(
  uuid, jsonb, text, uuid, uuid, jsonb, text, text
);

drop index if exists public.uq_purchase_receptions_number;

alter table public.purchase_reception_lines
  drop column if exists item_name,
  drop column if exists item_sku,
  drop column if exists item_unit,
  drop column if exists description;

alter table public.purchase_receptions
  drop column if exists reception_number,
  drop column if exists notes;

alter table public.business_settings
  drop column if exists require_goods_receipt;

commit;
