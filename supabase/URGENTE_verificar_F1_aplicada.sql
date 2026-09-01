-- =============================================================================
-- ⚠️ VERIFICAR AHORA: 20260901_0003 está aplicada en producción.
--
-- POR QUÉ IMPORTA:
--   `consume_inventory_from_order` ahora LLAMA a
--   `fn_resolve_consumption_warehouse` (migración 0002). PostgreSQL NO
--   valida las referencias dentro del cuerpo de una función plpgsql al
--   crearla: las resuelve en tiempo de EJECUCIÓN.
--
--   Si la 0003 se aplicó y la 0002 NO, la función existe pero revienta la
--   primera vez que alguien agrega un ítem a una orden — y como el trigger
--   de `order_items` la invoca dentro de la misma transacción, el ítem NO
--   SE GUARDA. La POS deja de tomar pedidos.
--
--   Correr esto ANTES de abrir mañana.
-- =============================================================================

select
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'fn_resolve_consumption_warehouse'
  ) as resolvedor_existe,          -- TIENE que ser true

  (select count(*) from pg_trigger
    where tgname in ('trg_order_items_reconcile_inventory_upd',
                     'trg_order_items_reconcile_inventory_del')
      and not tgisinternal
  ) as triggers_que_la_invocan,    -- esperado: 2

  (select coalesce(inventory_mode, 'none')
     from public.business_settings
    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6')
    as modo_inventario,

  (select coalesce(warehouse_sections_enabled, false)
     from public.business_settings
    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6')
    as bandera_secciones;          -- TIENE que ser false todavía
