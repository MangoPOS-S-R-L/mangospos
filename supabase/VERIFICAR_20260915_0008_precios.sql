-- =============================================================================
-- VERIFICAR 20260915_0008 (Compras F4, precios) — SOLO LECTURA
-- UNA sola consulta. No recibe mercancía ni cambia precios.
-- =============================================================================

with
fns as (
  select p.proname,
         p.prosecdef,
         has_function_privilege('authenticated', p.oid, 'execute') as app_puede
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('fn_purchase_price_comparison', 'fn_supplier_items_learn_from_receipt',
                       'fn_supplier_items_price_stamp', 'fn_supplier_items_relearn',
                       'fn_supplier_items_relearn_on_cancel')
),
trg as (
  select t.tgname, c.relname
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and not t.tgisinternal
     and t.tgname in ('trg_inventory_movements_learn_supplier_price', 'trg_supplier_items_price_stamp',
                      'trg_direct_receipts_relearn_supplier_price', 'trg_purchase_receptions_relearn_supplier_price',
                      'trg_purchase_orders_relearn_supplier_price')
),
si as (
  select si.*
    from public.supplier_items si
   where si.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
),
cmp as materialized (
  select *
    from public.fn_purchase_price_comparison('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', null, 90)
),
por_insumo as (
  select item_id,
         count(*) filter (where last_cost_base is not null)                    as con_precio,
         min(last_cost_base)                                                   as mas_barato,
         max(last_cost_base) filter (where is_resolved)                        as del_pedido
    from cmp
   group by item_id
)
select n, chequeo, resultado, estado
  from (
    select 1 as n, 'Funciones (esperado 5)' as chequeo,
           string_agg(proname, ', ' order by proname) as resultado,
           case when count(*) = 5 then 'OK' else 'FALTA' end as estado
      from fns
    union all
    select 2, 'Triggers (esperado 5)',
           string_agg(relname || '.' || tgname, ', ' order by relname),
           case when count(*) = 5 then 'OK' else 'FALTA' end
      from trg
    union all
    select 3, 'La app lee el comparador pero NO llama relearn ni los triggers',
           string_agg(proname || '=' || app_puede, ' · ' order by proname),
           case when bool_or(proname = 'fn_purchase_price_comparison' and app_puede)
                 and not bool_or(proname = 'fn_supplier_items_relearn' and app_puede)
                then 'OK' else 'REVISAR' end
      from fns
    union all
    select 4, 'supplier_items.last_price_at y last_price_source',
           count(*)::text,
           case when count(*) = 2 then 'OK' else 'FALTA' end
      from information_schema.columns
     where table_schema = 'public' and table_name = 'supplier_items'
       and column_name in ('last_price_at', 'last_price_source')
    union all
    select 5, 'Penda · vínculos insumo–suplidor (activos / total)',
           count(*) filter (where is_active) || ' / ' || count(*), 'INFO'
      from si
    union all
    select 6, 'Penda · de dónde sale el precio de lista (recepción / manual / sin precio)',
           count(*) filter (where last_price_source = 'recepcion') || ' / '
             || count(*) filter (where last_price_source = 'manual') || ' / '
             || count(*) filter (where last_price is null),
           'INFO'
      from si
    union all
    select 7, 'Penda · pares insumo × suplidor en el comparador (90 d)', count(*)::text, 'INFO'
      from cmp
    union all
    select 8, 'Penda · insumos con precio de 2 suplidores o más', count(*)::text, 'INFO'
      from por_insumo where con_precio >= 2
    union all
    select 9, 'Penda · insumos cuyo suplidor del pedido está ≥ 5% sobre el más barato', count(*)::text, 'INFO'
      from por_insumo where del_pedido is not null and mas_barato > 0 and del_pedido >= mas_barato * 1.05
  ) v
 order by n;
