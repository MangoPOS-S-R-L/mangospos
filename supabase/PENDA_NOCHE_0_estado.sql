-- =============================================================================
-- LA PENDA EXPRESS · NOCHE 0 — Estado de todo ANTES de corregir
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta (Studio muestra todo el resultado).
-- Correr al EMPEZAR la noche y pegar el resultado: decide qué script va y
-- con qué números.
--
-- Lo más importante es la fila A6: cómo CIERRA de verdad el conteo en prod.
--   * «contado − snapshot»  → el cierre SUMA la diferencia al stock de hoy
--     (lo vendido y comprado después del 1-sep se respeta; cerrar dos
--     sesiones resta dos veces).
--   * «contado − stock»     → el cierre DEJA el stock en lo contado (lo movido
--     después del 1-sep se pierde).
-- La memoria tiene las dos versiones escritas; manda lo que diga la BD viva.
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
sesiones as (
  select s.*
    from public.physical_count_sessions s, biz
   where s.business_id = biz.id
     and s.status = 'in_progress'
),
lineas as (
  select l.session_id, l.item_id, l.counted_quantity
    from public.physical_count_lines l
    join sesiones s on s.id = l.session_id
),
contados as (
  select item_id, count(distinct session_id) as sesiones
    from lineas
   where counted_quantity is not null
   group by item_id
),
complete_src as (
  select pg_get_functiondef(p.oid) as src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_physical_count_complete'
   limit 1
),
wh as (
  select w.id, w.name, coalesce(w.is_active, true) as activo, coalesce(w.is_main, false) as principal,
         to_jsonb(w) ->> 'shows_in_pos' as en_pos
    from public.warehouses w, biz
   where w.business_id = biz.id
),
stock as (
  select s.warehouse_id, s.item_id, s.quantity, ii.name, coalesce(ii.cost, 0) as cost
    from public.inventory_stock s
    join wh on wh.id = s.warehouse_id
    join public.inventory_items ii on ii.id = s.item_id
),
absurdos as (
  select im.id, im.created_at, wh.name as almacen, ii.name as insumo, im.quantity,
         im.movement_type::text as tipo, im.reference_type
    from public.inventory_movements im
    join biz on biz.id = im.business_id
    join wh on wh.id = im.warehouse_id
    join public.inventory_items ii on ii.id = im.item_id
   where abs(im.quantity) >= 100000
),
proj as materialized (
  select *
    from public.fn_purchase_projection(
           '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'f0cd4394-3bd9-4889-908c-686fd9ed67d2',
           7, 30, 2, 3, null, true)
),
cmp as materialized (
  select item_id, min(last_cost_base) as mas_barato,
         max(last_cost_base) filter (where is_resolved) as del_pedido
    from public.fn_purchase_price_comparison('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', null, 90)
   group by item_id
)
select seccion, dato, valor
  from (
    -- ── A · Conteo ──────────────────────────────────────────────────────────
    select 10 as orden, 'A · Conteo' as seccion, 'A1 sesiones abiertas (contadas / líneas)' as dato,
           coalesce(string_agg(s.code || ' «' || coalesce(s.notes, 'sin área') || '» '
             || (select count(*) from lineas l where l.session_id = s.id and l.counted_quantity is not null)
             || ' / ' || (select count(*) from lineas l where l.session_id = s.id), ' · ' order by s.code),
             'ninguna') as valor
      from sesiones s
    union all
    select 11, 'A · Conteo', 'A2 congeladas el / días abiertas',
           coalesce(min((s.frozen_at at time zone 'America/Santo_Domingo')::date)::text
             || ' / ' || (now()::date - min(s.frozen_at)::date), '—')
      from sesiones s
    union all
    select 12, 'A · Conteo', 'A3 insumos contados únicos / contados en 2+ sesiones',
           count(*) || ' / ' || count(*) filter (where sesiones > 1)
      from contados
    union all
    select 13, 'A · Conteo', 'A4 almacén de las sesiones',
           coalesce(string_agg(distinct w.name, ', '), '—')
      from sesiones s join public.warehouses w on w.id = s.warehouse_id
    union all
    select 14, 'A · Conteo', 'A5 movimientos desde el congelado sobre lo contado (valor al costo)',
           count(m.id) || ' movimientos · RD$ ' || round(coalesce(sum(abs(m.quantity) * coalesce(ii.cost, 0)), 0), 2)
      from contados c
      join public.inventory_items ii on ii.id = c.item_id
      join public.inventory_movements m on m.item_id = c.item_id
       and m.created_at > (select min(frozen_at) from sesiones)
       and m.warehouse_id in (select warehouse_id from sesiones)
    union all
    select 15, 'A · Conteo', 'A6 CÓMO CIERRA en prod (línea del delta)',
           coalesce(
             (select regexp_replace(substring(src from '(?i)v_variance\s*:=\s*[^;]+;'), '\s+', ' ', 'g') from complete_src),
             (select case when src is null then 'fn_physical_count_complete NO existe' else 'no se encontró v_variance: revisar a mano' end from complete_src),
             'fn_physical_count_complete NO existe')
    union all
    select 16, 'A · Conteo', 'A7 20260902_0005 (insumo nuevo entra a conteos abiertos) — NO aplicar con conteos abiertos',
           case when exists (select 1 from pg_trigger where tgname = 'trg_inventory_items_join_open_counts' and not tgisinternal)
                then 'APLICADA' else 'sin aplicar' end
    union all
    -- ── B · Existencias ─────────────────────────────────────────────────────
    select 20, 'B · Existencias', 'B1 negativos por almacén (insumos · valor al costo)',
           coalesce(string_agg(x.name || ': ' || x.n || ' · RD$ ' || x.valor, ' | ' order by x.name), 'ninguno')
      from (
        select wh.name, count(*) as n, round(sum(abs(st.quantity) * st.cost), 2) as valor
          from stock st join wh on wh.id = st.warehouse_id
         where st.quantity < 0
         group by wh.name
      ) x
    union all
    select 21, 'B · Existencias', 'B2 existencias imposibles (≥ 100,000 unidades)',
           coalesce(string_agg(wh.name || ' · ' || st.name || ' = ' || st.quantity, ' | ' order by st.quantity desc), 'ninguna')
      from stock st join wh on wh.id = st.warehouse_id
     where st.quantity >= 100000
    union all
    select 22, 'B · Existencias', 'B3 movimientos imposibles (|cantidad| ≥ 100,000): id · fecha · almacén · insumo · cantidad · tipo/referencia',
           coalesce(string_agg(a.id::text || ' · ' || (a.created_at at time zone 'America/Santo_Domingo')::date
             || ' · ' || a.almacen || ' · ' || a.insumo || ' · ' || a.quantity || ' · ' || a.tipo || '/' || coalesce(a.reference_type, '—'),
             ' | ' order by abs(a.quantity) desc), 'ninguno')
      from absurdos a
    union all
    -- ── C · Almacenes ───────────────────────────────────────────────────────
    select 30, 'C · Almacenes', 'C1 almacenes (principal · en POS · activo · insumos con stock > 0)',
           string_agg(wh.name || ' (' || case when wh.principal then 'principal' else '—' end
             || ' · pos=' || coalesce(wh.en_pos, '?') || ' · ' || case when wh.activo then 'activo' else 'INACTIVO' end
             || ' · ' || (select count(*) from stock st where st.warehouse_id = wh.id and st.quantity > 0) || ')',
             ' | ' order by wh.principal desc, wh.name)
      from wh
    union all
    select 31, 'C · Almacenes', 'C2 bandera warehouse_sections_enabled (descontar por área)',
           coalesce((select to_jsonb(bs) ->> 'warehouse_sections_enabled'
                       from public.business_settings bs, biz where bs.business_id = biz.id limit 1), 'columna no existe')
    union all
    -- ── D · Decisiones de cocina ────────────────────────────────────────────
    select 40, 'D · Cocina', 'D1 FILETE DE PECHUGA (unidad · costo · stock por almacén)',
           coalesce((select ii.name || ' · ' || ii.unit || ' · RD$ ' || ii.cost || ' · '
                       || coalesce((select string_agg(wh.name || '=' || st.quantity, ', ') from stock st join wh on wh.id = st.warehouse_id
                                     where st.item_id = ii.id), 'sin stock')
                       from public.inventory_items ii where ii.id = '5fd1d147-6508-449e-a9c9-83c79c6a98bb'), 'no existe')
    union all
    select 41, 'D · Cocina', 'D2 insumos con stock > 0 y costo 0 (cuántos · primeros 10)',
           (select count(distinct st.item_id) from stock st where st.quantity > 0 and st.cost = 0) || ' · '
             || coalesce((select string_agg(x.name, ', ') from (
                  select distinct st.name from stock st where st.quantity > 0 and st.cost = 0 order by st.name limit 10) x), '—')
    union all
    -- ── E · Compras ─────────────────────────────────────────────────────────
    select 50, 'E · Compras', 'E1 suplidores activos / con tiempo de entrega',
           count(*) filter (where coalesce(s.is_active, true)) || ' / '
             || count(*) filter (where coalesce(s.is_active, true) and s.lead_time_days is not null)
      from public.suppliers s, biz where s.business_id = biz.id
    union all
    select 51, 'E · Compras', 'E2 vínculos insumo–suplidor activos / insumos con suplidor preferido',
           (select count(*) from public.supplier_items si, biz where si.business_id = biz.id and si.is_active) || ' / '
             || (select count(*) from public.inventory_items ii, biz where ii.business_id = biz.id
                  and coalesce(ii.is_active, true) and (to_jsonb(ii) ->> 'preferred_supplier_id') is not null)
    union all
    select 52, 'E · Compras', 'E3 pedido 7 días (Principal): con pedido / sin suplidor / existencia negativa',
           count(*) || ' / ' || count(*) filter (where supplier_id is null) || ' / ' || count(*) filter (where stock < 0)
      from proj
    union all
    select 53, 'E · Compras', 'E4 insumos cuyo suplidor del pedido está ≥ 5% sobre el más barato',
           count(*)::text
      from cmp where del_pedido is not null and mas_barato > 0 and del_pedido >= mas_barato * 1.05
    union all
    -- ── F · Duplicados pendientes de decisión ───────────────────────────────
    select 60, 'F · Duplicados', 'F1 fichas activas con esos nombres',
           coalesce(string_agg(ii.name || ' (' || ii.unit || ')', ' | ' order by ii.name), 'ninguna')
      from public.inventory_items ii, biz
     where ii.business_id = biz.id
       and coalesce(ii.is_active, true)
       and ii.name ~* '(auyama|aullama|yautia|^envio|kinder joy)'
  ) v
 order by orden;
