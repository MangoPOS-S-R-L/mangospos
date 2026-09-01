-- DIAGNOSTICO_items_sin_tax_lines_2.sql
-- Segunda vuelta. La primera mostro que 1.064 de 1.066 items sin lineas tienen check_id,
-- pero eso solo significa algo si la mayoria de los items NO lo tiene. Aqui va la linea base.
--
-- Y separa las dos poblaciones, que tienen causas distintas:
--   A) 894 items cuyo producto HOY no tiene impuesto vinculado -> probable cambio de
--      configuracion DESPUES de la venta: oi.tax conserva lo cobrado, las lineas se
--      borraron o nunca se rehicieron.
--   B) 172 items cuyo producto SI esta configurado -> hueco real en la escritura.
--      Ahi esta el JOHNNIE WALKER de la factura B0200157234.
-- Solo lee. Devuelve UNA sola tabla.

with b as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
it as (
  select oi.id, oi.product_id, oi.check_id, oi.status::text as status,
         coalesce(oi.tax,0) as tax, oi.created_at,
         (tl.x is not null) as tiene_lineas,
         exists (select 1 from public.menu_item_taxes m where m.item_id = oi.product_id) as cfg
  from public.order_items oi
  join public.orders o         on o.id = oi.order_id
  join public.table_sessions s on s.id = o.session_id
  left join public.zones z on z.id = (select dt.zone_id from public.dining_tables dt where dt.id = s.table_id)
  left join lateral (select 1 as x from public.order_item_tax_lines t where t.order_item_id = oi.id limit 1) tl on true
  where coalesce(s.business_id, z.business_id) = (select id from b)
)
select n, seccion, detalle from (

  -- LA LINEA BASE que faltaba
  select 1 as n, 'LINEA BASE: ¿cuantos items tienen check_id?' as seccion,
         count(*) filter (where check_id is not null) || ' de ' || count(*) ||
         ' (' || round(100.0*count(*) filter (where check_id is not null)/nullif(count(*),0),1) || '%)' ||
         '   <- si es casi 100%, el dato del check_id NO explica nada' as detalle
  from it

  union all
  select 2, 'SIN LINEAS, comparado',
         'con check_id: ' || round(100.0*count(*) filter (where not tiene_lineas and check_id is not null)
                                   / nullif(count(*) filter (where check_id is not null),0), 2) || '% de los que tienen check' ||
         '   |   sin check_id: ' || round(100.0*count(*) filter (where not tiene_lineas and check_id is null)
                                   / nullif(count(*) filter (where check_id is null),0), 2) || '% de los que no'
  from it

  -- GRUPO A: producto sin impuesto vinculado hoy
  union all
  select 3, 'GRUPO A (producto SIN vinculo hoy)',
         count(*) || ' items, RD$ ' || round(sum(tax),2) || ' de impuesto'
  from it where not tiene_lineas and tax > 0 and not cfg

  union all
  select 4, 'GRUPO A: productos distintos',
         count(distinct product_id) || ' productos distintos involucrados'
  from it where not tiene_lineas and tax > 0 and not cfg

  -- GRUPO B: producto configurado, la escritura fallo
  union all
  select 5, 'GRUPO B (producto CONFIGURADO)',
         count(*) || ' items, RD$ ' || round(sum(tax),2) || ' de impuesto  <- hueco real'
  from it where not tiene_lineas and tax > 0 and cfg

  union all
  select 6, 'GRUPO B por mes ' || to_char(date_trunc('month', created_at at time zone 'America/Santo_Domingo'),'YYYY-MM'),
         count(*) || ' items, RD$ ' || round(sum(tax),2)
  from it where not tiene_lineas and tax > 0 and cfg
  group by 1, date_trunc('month', created_at at time zone 'America/Santo_Domingo')

  union all
  select 7, 'GRUPO B por estado ' || status,
         count(*) || ' items'
  from it where not tiene_lineas and tax > 0 and cfg
  group by status

  union all
  select 8, 'GRUPO B: ¿en subcuenta?',
         'con check_id: ' || count(*) filter (where check_id is not null) ||
         '   sin check_id: ' || count(*) filter (where check_id is null)
  from it where not tiene_lineas and tax > 0 and cfg
) t
order by n, seccion;
