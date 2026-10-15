-- =============================================================================
-- Carriles de venta rápida / manual por negocio (SOLO LECTURA)
-- =============================================================================
-- fn_sales_virtual_open (20261009_0004) da a cada venta rápida su propio carril
-- ('quick', 'quick#2'… 'quick#50'). Con 50 ventas sin cobrar el negocio ya no
-- puede abrir otra: «no hay carril libre» → en la app «No hay una orden activa».
--
-- Una sola tabla (el SQL Editor solo muestra el último resultado).
--   abiertas          ventas vivas en carriles (tope 50)
--   vacias_liberables sin productos, sin pagos y con más de 20 min → las libera
--                     cleanup_empty_quick_sale_lanes_all_businesses.sql
--   vacias_recientes  sin productos pero con menos de 20 min (en uso, no tocar)
--   con_productos     tienen productos: NO se tocan; cobrarlas o anularlas
--   revisar           sin productos vivos pero con ítems pagados o pagos
-- Hora en República Dominicana.
-- =============================================================================
with vivas as (
  select z.business_id,
         split_part(dt.code, '#', 1) as tipo,
         o.id as order_id,
         o.created_at,
         exists (
           select 1 from public.order_items oi
            where oi.order_id = o.id and oi.status::text not in ('void', 'paid')
         ) as con_productos,
         exists (
           select 1 from public.order_items oi
            where oi.order_id = o.id and oi.status::text = 'paid'
         ) or exists (
           select 1 from public.payments p
            where p.order_id = o.id and p.status not in ('cancelled', 'refunded')
         ) as con_pagos,
         coalesce((
           select sum(oi.total) from public.order_items oi
            where oi.order_id = o.id and oi.status::text not in ('void', 'paid')
         ), 0) as monto
    from public.zones z
    join public.dining_tables dt on dt.zone_id = z.id
    join public.table_sessions ts on ts.table_id = dt.id and ts.closed_at is null
    join public.orders o on o.session_id = ts.id
   where z.name in ('Ventas rapidas', 'Ventas manuales')
     and dt.code ~ '^(quick|manual)(#[0-9]+)?$'
     and o.closed_at is null
     and o.status_ext::text not in ('paid', 'void')
)
select b.business_name as negocio,
       coalesce(b.branch_name, '') as sucursal,
       case v.tipo when 'quick' then 'Venta rápida' else 'Venta manual' end as tipo,
       case
         when count(*) >= 50 then 'LLENO'
         when count(*) >= 40 then 'casi lleno'
         else ''
       end as estado,
       count(*) as abiertas,
       count(*) filter (where not v.con_productos and not v.con_pagos
                          and coalesce(v.created_at, 'epoch'::timestamptz) < now() - interval '20 minutes')
         as vacias_liberables,
       count(*) filter (where not v.con_productos and not v.con_pagos
                          and coalesce(v.created_at, 'epoch'::timestamptz) >= now() - interval '20 minutes')
         as vacias_recientes,
       count(*) filter (where v.con_productos) as con_productos,
       round(sum(v.monto) filter (where v.con_productos), 2) as monto_con_productos,
       count(*) filter (where not v.con_productos and v.con_pagos) as revisar,
       to_char(min(v.created_at) at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') as mas_vieja,
       to_char(max(v.created_at) at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') as mas_reciente,
       v.business_id
  from vivas v
  join public.businesses b on b.id = v.business_id
 group by b.business_name, b.branch_name, v.tipo, v.business_id
 order by count(*) desc, b.business_name;
