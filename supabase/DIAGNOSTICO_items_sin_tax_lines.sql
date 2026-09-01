-- DIAGNOSTICO_items_sin_tax_lines.sql
-- Por que hay order_items SIN filas en order_item_tax_lines.
--
-- CONTEXTO: el feed y el e-CF calculan el impuesto recorriendo order_item_tax_lines. Un item
-- sin lineas aporta cero y su impuesto se pierde del desglose. En LA PENDA EXPRESS eso afecta
-- a 931 documentos (8,5%).
--
-- Ya se descarto la causa obvia: el JOHNNIE WALKER GOLD LABEL RESERVE (item de la factura
-- B0200157234, 1.538,46 de impuesto sin lineas) SI tiene sus dos impuestos vinculados en
-- menu_item_taxes, igual que el MOFONGO de la misma orden que si genero lineas.
-- O sea el hueco esta en el camino de ESCRITURA, no en la configuracion del producto.
--
-- Solo lee. Devuelve UNA sola tabla.

with b as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
it as (
  select oi.id, oi.order_id, oi.product_id, oi.check_id, oi.status::text as status,
         coalesce(oi.tax,0) as tax, coalesce(oi.tax_rate,0) as tax_rate,
         oi.created_at,
         (tl.order_item_id is not null) as tiene_lineas,
         exists (select 1 from public.menu_item_taxes m where m.item_id = oi.product_id) as producto_configurado
  from public.order_items oi
  join public.orders o        on o.id  = oi.order_id
  join public.table_sessions s on s.id = o.session_id
  left join public.zones z     on z.id = (select dt.zone_id from public.dining_tables dt where dt.id = s.table_id)
  left join lateral (select 1 as order_item_id from public.order_item_tax_lines t
                      where t.order_item_id = oi.id limit 1) tl on true
  where coalesce(s.business_id, z.business_id) = (select id from b)
),
sin as (select * from it where not tiene_lineas and tax > 0)
select n, seccion, detalle from (

  select 1 as n, 'RESUMEN' as seccion,
         (select count(*) from it) || ' items en total  |  ' ||
         (select count(*) from it where not tiene_lineas) || ' sin lineas  |  ' ||
         (select count(*) from sin) || ' sin lineas PERO con impuesto cobrado' as detalle

  union all
  select 2, 'IMPUESTO QUE SE PIERDE',
         'RD$ ' || round((select coalesce(sum(tax),0) from sin), 2) ||
         '  (de RD$ ' || round((select coalesce(sum(tax),0) from it), 2) || ' cobrado en total)'

  union all
  select 3, '¿EL PRODUCTO ESTABA CONFIGURADO?',
         'si: ' || (select count(*) from sin where producto_configurado) ||
         '   no: ' || (select count(*) from sin where not producto_configurado) ||
         '   <- si la mayoria dice SI, la causa no es la configuracion'

  union all
  select 4, 'POR ESTADO DEL ITEM  ' || status,
         count(*) || ' items, RD$ ' || round(sum(tax),2) || ' de impuesto sin lineas'
  from sin group by status

  union all
  select 5, 'POR MES  ' || to_char(date_trunc('month', created_at at time zone 'America/Santo_Domingo'), 'YYYY-MM'),
         count(*) || ' items sin lineas, RD$ ' || round(sum(tax),2)
  from sin group by 1, date_trunc('month', created_at at time zone 'America/Santo_Domingo')

  union all
  select 6, '¿ESTAN EN SUBCUENTA?',
         'con check_id: ' || (select count(*) from sin where check_id is not null) ||
         '   sin check_id: ' || (select count(*) from sin where check_id is null)

  union all
  select 7, 'PRODUCTOS MAS AFECTADOS', d from (
    select mi.name || ' (' || count(*) || ' veces, RD$ ' || round(sum(s.tax),2) || ')' as d,
           count(*) as k
    from sin s join public.menu_items mi on mi.id = s.product_id
    group by mi.name order by k desc limit 10
  ) t7
) t
order by n, seccion, detalle;
