-- =============================================================================
-- ECO BAR & LOUNGE — arreglar dos nombres y unir el histórico partido.
-- Negocio: fc3065c8-cb40-45ad-bec1-aecb388001c1
--
-- EL HALLAZGO: los dos productos que ECOBAR_1 dejó desactivados (porque ya
-- tenían ventas) NO se llaman igual que los nuevos que ocuparon su lugar:
--
--     con las ventas viejas  →  vendiéndose hoy
--     ---------------------     --------------
--     Agua Dasani                Dasani
--     Heineken                   Heiniken     ← el PDF lo escribe mal
--
-- O sea que además del histórico partido en dos, la cerveza más vendida del
-- mundo está saliendo mal escrita en cada factura y en cada comanda. El menú
-- viejo la tenía bien.
--
-- QUÉ HACE:
--   1. Corrige el nombre de los dos productos nuevos.
--   2. Con los nombres ya iguales, reapunta las 7 ventas viejas al producto
--      nuevo y borra las dos filas apagadas. El histórico por producto queda
--      en una sola línea.
--
-- El ticket ya impreso no cambia: order_items guarda product_name aparte.
-- Pega TODO de una vez en el SQL Editor de Supabase.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 0. RESPALDO de lo único que se muta: las líneas de venta y las dos filas
--    que se van a borrar.
-- ---------------------------------------------------------------------------
drop table if exists public.zzz_ecobar_unif_order_items;
create table public.zzz_ecobar_unif_order_items as
  select oi.* from public.order_items oi
   join public.menu_items mi on mi.id = oi.product_id
  where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
    and not mi.is_active;

drop table if exists public.zzz_ecobar_unif_menu_items;
create table public.zzz_ecobar_unif_menu_items as
  select * from public.menu_items
   where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
     and not is_active;


-- ---------------------------------------------------------------------------
-- 1. CORREGIR LOS NOMBRES DE LOS PRODUCTOS NUEVOS.
--    'Heiniken' es un error de tipeo del PDF; la marca es Heineken.
--    'Agua Dasani' se lee mejor que 'Dasani' en la lista, y es como el
--    negocio lo tenía antes.
-- ---------------------------------------------------------------------------
drop table if exists _fix;
create temp table _fix(como_esta text primary key, como_debe_ser text);
insert into _fix(como_esta, como_debe_ser) values
  ('Heiniken',  'Heineken'),
  ('Dasani',    'Agua Dasani');

update public.menu_items mi
   set name = f.como_debe_ser, updated_at = now()
  from _fix f
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and mi.is_active
   and mi.name = f.como_esta;


-- ---------------------------------------------------------------------------
-- 2. CORTAFUEGOS antes de tocar ventas.
--
--    Cada nombre tiene que resolver a EXACTAMENTE un producto activo. Si hay
--    dos "Heineken" encendidos, reapuntar sería una lotería y el script para.
-- ---------------------------------------------------------------------------
do $$
declare
  v_biz constant uuid := 'fc3065c8-cb40-45ad-bec1-aecb388001c1';
  r record;
  v_n int;
begin
  for r in
    select distinct mi.name
      from public.menu_items mi
     where mi.business_id = v_biz and not mi.is_active
  loop
    select count(*) into v_n
      from public.menu_items mi
     where mi.business_id = v_biz and mi.is_active and mi.name = r.name;

    if v_n = 0 then
      raise exception 'El producto apagado "%" no tiene un equivalente activo con ese nombre. Revisa el listado antes de unificar.', r.name;
    end if;

    if v_n > 1 then
      raise exception 'Hay % productos activos llamados "%". No puedo elegir a cuál mandar las ventas.', v_n, r.name;
    end if;
  end loop;
end $$;


-- ---------------------------------------------------------------------------
-- 3. REAPUNTAR LAS VENTAS al producto nuevo.
-- ---------------------------------------------------------------------------
update public.order_items oi
   set product_id = nuevo.id
  from public.menu_items viejo
  join public.menu_items nuevo
    on nuevo.business_id = viejo.business_id
   and nuevo.name = viejo.name
   and nuevo.is_active
 where oi.product_id = viejo.id
   and viejo.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and not viejo.is_active;

-- Los modifiers, por si alguno apuntaba a la fila vieja.
update public.order_item_modifiers om
   set menu_item_id = nuevo.id
  from public.menu_items viejo
  join public.menu_items nuevo
    on nuevo.business_id = viejo.business_id
   and nuevo.name = viejo.name
   and nuevo.is_active
 where om.menu_item_id = viejo.id
   and viejo.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and not viejo.is_active;


-- ---------------------------------------------------------------------------
-- 4. BORRAR LAS FILAS APAGADAS que ya no sostienen nada.
--    El not exists es el seguro: si algo quedó colgando, la fila se queda.
-- ---------------------------------------------------------------------------
delete from public.menu_items mi
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and not mi.is_active
   and not exists (select 1 from public.order_items oi where oi.product_id = mi.id)
   and not exists (select 1 from public.order_item_modifiers om where om.menu_item_id = mi.id);


-- ---------------------------------------------------------------------------
-- 5. RESULTADO.
-- ---------------------------------------------------------------------------
-- 5a. Los dos nombres, ya corregidos y con su histórico completo.
select mi.name                                          as producto,
       c.name                                           as categoria,
       mi.price,
       (select count(*) from public.order_items oi
         where oi.product_id = mi.id)                    as ventas_atribuidas
  from public.menu_items mi
  left join public.categories c on c.id = mi.category_id
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and mi.name in ('Heineken', 'Agua Dasani')
 order by mi.name;

-- 5b. No debe quedar ningún producto apagado.
select count(*) as productos_apagados_restantes
  from public.menu_items
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and not is_active;

-- 5c. Ninguna venta puede haber quedado sin producto.
select count(*) as lineas_sin_producto
  from public.order_items oi
 where oi.product_id is null
   and exists (select 1 from public.zzz_ecobar_unif_order_items b where b.id = oi.id);

-- 5d. El chequeo completo de siempre: las cinco de la derecha en 0.
select count(*)                                                    as productos_activos,
       count(*) filter (where not exists (
         select 1 from public.menu_item_taxes t
          join public.taxes tx on tx.id = t.tax_id and tx.name ilike '%itbis%'
         where t.item_id = menu_items.id))                          as SIN_ITBIS,
       count(*) filter (where not exists (
         select 1 from public.menu_item_taxes t
          join public.taxes tx on tx.id = t.tax_id and tx.name ilike '%ley%'
         where t.item_id = menu_items.id))                          as SIN_LEY,
       count(*) filter (where print_area_code is null)              as SIN_AREA,
       count(*) filter (where not exists (
         select 1 from public.menu_item_links l
          where l.item_id = menu_items.id))                         as SIN_MENU,
       count(*) filter (where tax_mode <> 'exclusive')              as TAX_MODE_MALO
  from public.menu_items
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and is_active;


-- ---------------------------------------------------------------------------
-- 6. Si algo salió torcido, esto lo devuelve:
--
--    insert into public.menu_items
--    select * from public.zzz_ecobar_unif_menu_items on conflict (id) do nothing;
--
--    update public.order_items oi set product_id = b.product_id
--      from public.zzz_ecobar_unif_order_items b where b.id = oi.id;
--
--    update public.menu_items mi set name = 'Heiniken'
--     where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
--       and mi.is_active and mi.name = 'Heineken';
--    update public.menu_items mi set name = 'Dasani'
--     where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
--       and mi.is_active and mi.name = 'Agua Dasani';
--
--    OJO: el respaldo NO incluye los vínculos de impuestos/área/menú de las
--    filas borradas, pero esas filas estaban apagadas y no se vendían, así
--    que no hace falta reponerlos.
--
-- Cuando todo esté bien:
--   drop table if exists public.zzz_ecobar_unif_order_items;
--   drop table if exists public.zzz_ecobar_unif_menu_items;
-- ---------------------------------------------------------------------------
