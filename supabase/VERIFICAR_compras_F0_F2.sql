-- =============================================================================
-- VERIFICAR Compras F0–F2 (20260915_0003, 0004 y 0005) — SOLO LECTURA
-- UNA sola consulta: Studio muestra todo el resultado de una vez.
-- Llama a fn_purchase_resolve_suppliers y a fn_purchase_projection (stable, no
-- escriben). No crea órdenes.
-- =============================================================================

with
fns as (
  select p.proname,
         has_function_privilege('authenticated', p.oid, 'execute') as can_exec,
         p.prosecdef
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('fn_purchase_order_create', 'fn_purchase_resolve_suppliers',
                       'fn_purchase_projection', 'fn_purchase_orders_create_batch')
),
supplier_src as (
  select coalesce(r.supplier_source, 'sin suplidor') as fuente, count(*) as insumos
    from public.fn_purchase_resolve_suppliers('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6') r
    join public.inventory_items ii on ii.id = r.item_id and coalesce(ii.is_active, true)
   group by 1
),
cost_src as (
  select coalesce(r.cost_source, 'sin costo') as fuente, count(*) as insumos
    from public.fn_purchase_resolve_suppliers('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6') r
    join public.inventory_items ii on ii.id = r.item_id and coalesce(ii.is_active, true)
   group by 1
),
-- El almacén con que abre la pantalla: el principal, si no el primero.
wh as (
  select w.id, w.name
    from public.warehouses w
   where w.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and coalesce(w.is_active, true)
     and w.name is distinct from '__IN_TRANSIT__'
   order by w.is_main desc nulls last, w.name
   limit 1
),
-- Una sola corrida de la proyección, cronometrada (t0 → resumen → t1).
proj as (
  select wh.name as almacen,
         clock_timestamp() as t0,
         (select jsonb_build_object(
                   'evaluados',       count(*),
                   'con_pedido',      count(*) filter (where x.suggested_base > 0),
                   'sin_suplidor',    count(*) filter (where x.suggested_base > 0 and x.supplier_id is null),
                   'entrega_defecto', count(*) filter (where x.suggested_base > 0 and x.lead_time_is_default),
                   'negativos',       count(*) filter (where x.stock < 0),
                   'costo',           round(coalesce(sum(x.estimated_cost), 0), 2),
                   'ventana',         round(avg(x.window_days), 1))
            from public.fn_purchase_projection(
                   '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', wh.id, 7, 30, 2, 3, null, false) x) as s,
         clock_timestamp() as t1
    from wh
)
select n, chequeo, resultado, estado
  from (
    select 1 as n, 'Funciones de compras (esperado 4)' as chequeo,
           string_agg(proname, ', ' order by proname) as resultado,
           case when count(*) = 4 then 'OK' else 'FALTA' end as estado
      from fns
    union all
    select 2, 'authenticated puede ejecutarlas',
           coalesce(string_agg(proname, ', ' order by proname) filter (where not can_exec), 'todas'),
           case when count(*) = 4 and bool_and(can_exec) then 'OK' else 'FALTA GRANT' end
      from fns
    union all
    select 3, 'SECURITY INVOKER (respetan el RLS de siempre)',
           coalesce(string_agg(proname, ', ' order by proname) filter (where prosecdef), 'todas'),
           case when bool_or(prosecdef) then 'REVISAR' else 'OK' end
      from fns
    union all
    select 4, 'purchase_orders.idempotency_key + índice único',
           case when to_regclass('public.idx_purchase_orders_idempotency') is null
                then 'sin índice' else 'con índice' end,
           case when exists (select 1 from information_schema.columns
                              where table_schema = 'public' and table_name = 'purchase_orders'
                                and column_name = 'idempotency_key')
                 and to_regclass('public.idx_purchase_orders_idempotency') is not null
                then 'OK' else 'FALTA' end
    union all
    select 5, 'inventory_items.preferred_supplier_id', '',
           case when exists (select 1 from information_schema.columns
                              where table_schema = 'public' and table_name = 'inventory_items'
                                and column_name = 'preferred_supplier_id')
                then 'OK' else 'FALTA' end
    union all
    select 6, 'Columnas de factura y empaque en órdenes (esperado 6)', count(*)::text,
           case when count(*) = 6 then 'OK' else 'FALTA' end
      from information_schema.columns
     where table_schema = 'public'
       and ((table_name = 'purchase_orders' and column_name in ('invoice_number', 'discount', 'ncf'))
         or (table_name = 'purchase_order_items' and column_name in ('discount', 'purchase_unit', 'pack_size')))
    union all
    select 7, 'Penda · de dónde sale el suplidor',
           string_agg(fuente || ' ' || insumos, ' · ' order by insumos desc), 'INFO'
      from supplier_src
    union all
    select 8, 'Penda · de dónde sale el costo',
           string_agg(fuente || ' ' || insumos, ' · ' order by insumos desc), 'INFO'
      from cost_src
    union all
    select 9, 'Penda · almacén con que abre «Pedido sugerido»', almacen, 'INFO'
      from proj
    union all
    select 10, 'Penda · 7 días: evaluados / con pedido / de esos sin suplidor / con entrega por defecto',
           (s->>'evaluados') || ' / ' || (s->>'con_pedido') || ' / ' || (s->>'sin_suplidor')
             || ' / ' || (s->>'entrega_defecto'),
           'INFO'
      from proj
    union all
    select 11, 'Penda · costo estimado del pedido · días de ventana promedio',
           (s->>'costo') || ' · ' || (s->>'ventana'), 'INFO'
      from proj
    union all
    select 12, 'Penda · insumos con existencia negativa (hacen pedir de más)', s->>'negativos',
           case when (s->>'negativos')::int > 0 then 'REVISAR' else 'OK' end
      from proj
    union all
    select 13, 'Tiempo de la proyección (ms)',
           round(extract(epoch from (t1 - t0)) * 1000)::text,
           case when t1 - t0 < interval '3 seconds' then 'OK'
                when t1 - t0 < interval '8 seconds' then 'REVISAR (cerca del límite de la app)'
                else 'LENTO (la app cortaría)' end
      from proj
    union all
    select 14, 'statement_timeout de los roles de la app',
           coalesce(string_agg(r.rolname || '=' || coalesce(
             (select split_part(c, '=', 2) from unnest(r.rolconfig) c where c like 'statement_timeout=%'),
             'sin límite propio'), ' · ' order by r.rolname), 'sin roles'),
           'INFO'
      from pg_roles r
     where r.rolname in ('anon', 'authenticated', 'authenticator')
    union all
    select 15, 'Órdenes creadas desde «Pedido sugerido» (hoy se espera 0)', count(*)::text, 'INFO'
      from public.purchase_orders po
     where po.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
       and po.idempotency_key like 'pedido-sugerido-%'
  ) v
 order by n;
