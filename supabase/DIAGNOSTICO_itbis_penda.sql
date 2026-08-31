-- DIAGNOSTICO_itbis_penda.sql
-- La API mostro facturas de LA PENDA EXPRESS con ITBIS = 0:
--   B01 100015466  BIP COMPANY SERVICES   BRUTO 2400.92  ITBIS 0.00
--   B01 100015468  EUROSUMINISTROS         BRUTO  680.34  ITBIS 0.00
--   B01 100015467  MECO ROGER DOMINICANA   BRUTO  200.00  ITBIS 36.00  <- este si
--
-- El ITBIS es CONFIGURABLE, no esta hardcodeado, asi que un 0 puede ser correcto.
-- Hay cuatro vias legitimas para que de 0:
--   a) el producto no esta vinculado en menu_item_taxes (exento a proposito)
--   b) el impuesto tiene is_active = false
--   c) las banderas apply_on_zone / apply_on_quick / apply_on_manual excluyen ese canal
--   d) el cajero quito el impuesto en esa orden (order_excluded_taxes, con auditoria)
--
-- Esta consulta mide la configuracion y separa lo EXPLICADO de lo que NO tiene explicacion.
-- Solo lee. Devuelve UNA sola tabla (Studio solo muestra el ultimo result set).
--
-- OJO con dos nombres de columna: menu_item_taxes usa item_id (NO menu_item_id) y
-- order_items referencia el producto como product_id (NO menu_item_id).

with b as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
fd as (
  select d.*
  from public.fiscal_documents d, b
  where d.business_id = b.id and d.status = 'active'
),
cero as (select * from fd where coalesce(itbis_amount,0) = 0)
select n, seccion, detalle from (

  -- 1. Como estan configurados los impuestos del negocio
  select 1 as n, 'IMPUESTOS CONFIGURADOS' as seccion,
         t.name || '  tasa=' || t.rate || '%' ||
         '  activo=' || t.is_active ||
         '  zona=' || coalesce(t.apply_on_zone::text,'?') ||
         '  rapida=' || coalesce(t.apply_on_quick::text,'?') ||
         '  manual=' || coalesce(t.apply_on_manual::text,'?') ||
         '  service_fee=' || coalesce(t.is_service_fee::text,'?') as detalle
  from public.taxes t, b where t.business_id = b.id

  -- 2. Cuantos productos cuelgan de cada impuesto
  union all
  select 2, 'PRODUCTOS POR IMPUESTO',
         t.name || ': ' || count(mit.item_id) || ' productos vinculados'
  from public.taxes t
  join b on t.business_id = b.id
  left join public.menu_item_taxes mit on mit.tax_id = t.id
  group by t.name

  -- 3. Productos sin NINGUN impuesto vinculado -> venden con ITBIS 0
  union all
  -- OJO: hay que contar productos DISTINTOS. Con el left join, un producto con dos
  -- impuestos produce dos filas, asi que count(*) da el numero de filas, no de productos.
  select 3, 'PRODUCTOS SIN IMPUESTO',
         count(distinct mi.id) filter (where mit.item_id is null) || ' de ' ||
         count(distinct mi.id) || ' productos no tienen impuesto vinculado'
  from public.menu_items mi
  join b on mi.business_id = b.id
  left join public.menu_item_taxes mit on mit.item_id = mi.id

  -- 4. Peso real del ITBIS 0 en la facturacion
  union all
  select 4, 'FACTURAS',
         (select count(*) from fd) || ' activas  |  ' ||
         (select count(*) from cero) || ' con ITBIS 0  |  ' ||
         round(100.0 * (select count(*) from cero) / nullif((select count(*) from fd),0), 1) ||
         '%  |  RD$ ' || round((select coalesce(sum(total),0) from cero), 2) || ' facturados sin ITBIS'

  -- 5. ¿Cuantas de esas se explican por configuracion?
  union all
  select 5, 'ITBIS 0 EXPLICADO',
         'por exclusion del cajero: ' ||
         (select count(*) from cero c
           where exists (select 1 from public.order_excluded_taxes oet
                          where oet.order_id = c.order_id)) ||
         '   |   marcadas exentas (tax_exempt>0): ' ||
         (select count(*) from cero where coalesce(tax_exempt,0) > 0)

  union all
  select 6, 'ITBIS 0 SIN EXPLICAR',
         (select count(*) from cero c
           where coalesce(c.tax_exempt,0) = 0
             and not exists (select 1 from public.order_excluded_taxes oet
                              where oet.order_id = c.order_id))
         || ' facturas (si es alto, la causa esta en los productos sin impuesto vinculado)'

  -- 7. Por tipo de NCF: B01 es Credito Fiscal, con RNC. Ahi el ITBIS 0 es lo mas llamativo.
  union all
  select 7, 'POR TIPO DE NCF',
         ncf_type::text || ': ' || count(*) || ' facturas, ' ||
         count(*) filter (where coalesce(itbis_amount,0) = 0) || ' sin ITBIS, RD$ ' ||
         round(sum(coalesce(itbis_amount,0)), 2) || ' declarados'
  from fd group by ncf_type

  -- 8. Que productos concretos aparecen en facturas sin ITBIS y no tienen impuesto vinculado
  -- El ORDER BY/LIMIT va DENTRO de su propia subconsulta: puesto al final de una rama de
  -- UNION ALL se aplica a la union entera y se come las demas secciones.
  union all
  select 8, 'PRODUCTOS A REVISAR', d from (
    select mi.name || ' (' || count(*) || ' lineas vendidas sin impuesto vinculado)' as d,
           count(*) as k
    from cero c
    join public.order_items oi on oi.order_id = c.order_id
    join public.menu_items mi  on mi.id = oi.product_id     -- order_items usa product_id
    left join public.menu_item_taxes mit on mit.item_id = mi.id
    where mit.item_id is null
    group by mi.name
    order by k desc
    limit 15
  ) top8
) t
order by n, detalle;
