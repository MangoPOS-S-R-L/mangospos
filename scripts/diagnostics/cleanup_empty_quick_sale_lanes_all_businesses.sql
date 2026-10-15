-- =============================================================================
-- Liberar carriles de venta rápida / manual VACÍOS — todos los negocios
-- =============================================================================
-- Regla del dueño (11-oct): «las ventas rápidas deben liberarse si no hay
-- productos». Hace, solo sobre los carriles ('quick', 'quick#N', 'manual',
-- 'manual#N'), lo mismo que el cron fn_release_empty_tables(20):
--   · anula ('void') las ventas SIN productos (todo ítem en 'void' o ninguno),
--     SIN pagos y con más de 20 min;
--   · cierra su sesión si ya no le queda ninguna venta viva y deja el carril
--     'available'.
-- NO toca: ventas con productos, con ítems pagados o con pagos; ventas de
-- menos de 20 min (pueden estar en uso); mesas de salón, delivery, carritos
-- retail ni ventas offline ('quick-<id>').
-- Mesa por mesa con el mismo candado que la apertura y el cron (si una caja
-- está abriendo en ese carril, se salta). Si un carril da error, se deshace
-- solo ese carril, se sigue con los demás y el error sale en el resultado.
--
-- Seguro de correr varias veces. Pegar TODO en el SQL Editor; el resultado es
-- una sola tabla con lo liberado por negocio y la fila TOTAL.
-- Antes/después: review_quick_sale_lanes_all_businesses.sql
-- =============================================================================

drop table if exists _carriles_liberados;
create temp table _carriles_liberados (business_id uuid, tipo text, order_id uuid, error text);

do $$
declare
  v_cutoff constant timestamptz := now() - interval '20 minutes';
  v_table uuid;
begin
  for v_table in
    select distinct dt.id
      from public.zones z
      join public.dining_tables dt on dt.zone_id = z.id
      join public.table_sessions ts on ts.table_id = dt.id and ts.closed_at is null
     where z.name in ('Ventas rapidas', 'Ventas manuales')
       and dt.code ~ '^(quick|manual)(#[0-9]+)?$'
     order by dt.id
  loop
    if not pg_try_advisory_xact_lock(hashtextextended(v_table::text, 0)) then
      continue;
    end if;

    begin
      -- Paso 1 (dentro del candado): anular las ventas vacías.
      with anuladas as (
        update public.orders o
           set status_ext = 'void',
               closed_at = now()
          from public.table_sessions ts
          join public.dining_tables dt on dt.id = ts.table_id
          join public.zones z on z.id = dt.zone_id
         where ts.id = o.session_id
           and ts.table_id = v_table
           and ts.closed_at is null
           and o.closed_at is null
           and o.status_ext::text not in ('paid', 'void')
           and coalesce(o.created_at, 'epoch'::timestamptz) < v_cutoff
           and not exists (
             select 1 from public.order_items oi
              where oi.order_id = o.id and oi.status::text <> 'void'
           )
           and not exists (
             select 1 from public.payments p
              where p.order_id = o.id and p.status not in ('cancelled', 'refunded')
           )
        returning z.business_id, split_part(dt.code, '#', 1), o.id
      )
      insert into _carriles_liberados (business_id, tipo, order_id)
      select * from anuladas;

      -- Paso 2: cerrar la sesión que ya no tiene ventas vivas y liberar el carril.
      with cerradas as (
        update public.table_sessions ts
           set closed_at = now()
         where ts.table_id = v_table
           and ts.closed_at is null
           and coalesce(ts.opened_at, 'epoch'::timestamptz) < v_cutoff
           and not exists (
             select 1 from public.orders o
              where o.session_id = ts.id
                and o.closed_at is null
                and o.status_ext::text not in ('paid', 'void')
           )
        returning ts.table_id
      )
      update public.dining_tables dt
         set state = 'available'
       where dt.id in (select table_id from cerradas)
         and dt.state <> 'available';
    exception when others then
      insert into _carriles_liberados (business_id, tipo, error)
      select z.business_id, split_part(dt.code, '#', 1), sqlstate || ': ' || sqlerrm
        from public.dining_tables dt
        join public.zones z on z.id = dt.zone_id
       where dt.id = v_table;
    end;
  end loop;
end $$;

select negocio, sucursal, tipo, liberadas, siguen_abiertas, carriles_con_error, error, business_id
  from (
    select 0 as orden,
           b.business_name as negocio,
           coalesce(b.branch_name, '') as sucursal,
           case l.tipo when 'quick' then 'Venta rápida' else 'Venta manual' end as tipo,
           count(l.order_id) as liberadas,
           (select count(*)
              from public.zones z
              join public.dining_tables dt on dt.zone_id = z.id
              join public.table_sessions ts on ts.table_id = dt.id and ts.closed_at is null
              join public.orders o on o.session_id = ts.id
             where z.business_id = l.business_id
               and z.name in ('Ventas rapidas', 'Ventas manuales')
               and dt.code ~ ('^' || l.tipo || '(#[0-9]+)?$')
               and o.closed_at is null
               and o.status_ext::text not in ('paid', 'void')) as siguen_abiertas,
           count(l.error) as carriles_con_error,
           min(l.error) as error,
           l.business_id
      from _carriles_liberados l
      join public.businesses b on b.id = l.business_id
     group by b.business_name, b.branch_name, l.tipo, l.business_id
    union all
    select 1, 'TOTAL', '', '',
           (select count(order_id) from _carriles_liberados), null,
           (select count(error) from _carriles_liberados), null, null
  ) x
 order by orden, liberadas desc, negocio;
