-- =============================================================================
-- F1 Almacenes por sección — disponibilidad por área. Cierra la fase.
--
-- EL PROBLEMA:
--   `v_menu_items_stock` y `fn_recompute_menu_items_availability` suman la
--   existencia de TODAS las bodegas sin filtro. Con un solo almacén eso es
--   correcto por accidente. Con secciones activas miente en las dos
--   direcciones:
--     · un plato de Cocina se ve disponible teniendo la mercancía sólo en el
--       Almacén General, y el mesero lo vende sin que haya nada que preparar;
--     · un plato se apaga solo (auto-86) teniendo existencia justo en su
--       propia área, porque el total del negocio da cero en otra bodega.
--
-- LA CORRECCIÓN:
--   Las dos consultan la existencia de la bodega que le corresponde al
--   producto, resuelta con `fn_resolve_consumption_warehouse` — la MISMA
--   función que decide de dónde descuenta la venta. Una sola fuente de
--   verdad: lo que se muestra disponible y lo que se descuenta salen del
--   mismo lugar, o el menú y el inventario se contradicen.
--
--   Y eso incluye a los productos SIN área: en un negocio que ya trabaja por
--   bodega, el respaldo es la misma bodega por defecto que usa la venta, no
--   la suma de todas. Sin esto el grid prometía existencia que la venta no
--   podía sacar de ahí, y la bodega principal se iba a negativo con
--   mercancía sobrando en las otras. En un negocio que NO trabaja por bodega
--   el respaldo queda nulo y se sigue sumando todo, como siempre.
--
-- CON LA BANDERA APAGADA NO CAMBIA NADA:
--   el resolvedor devuelve null, el filtro `(wid is null or ...)` deja pasar
--   todas las bodegas, y el resultado es la suma de siempre.
--
-- LO QUE NO TOCA A PROPÓSITO (dos cosas que encontré mirando lo vivo):
--   1. La bodega virtual `__IN_TRANSIT__` entra en la suma cuando la bandera
--      está apagada. Es un error que ya existe —mercancía en camino contada
--      como disponible— pero arreglarlo acá cambiaría el comportamiento de
--      TODOS los negocios hoy, y esta migración se tiene que poder aplicar
--      sin que nadie note nada. Con la bandera prendida deja de pasar solo,
--      porque __IN_TRANSIT__ nunca es la bodega resuelta.
--   2. `fn_recompute_menu_items_availability` recorre productos vía
--      `recipes`. Los productos TERMINADOS con link directo
--      (`menu_items.inventory_item_id` sin receta, que es como los crea
--      20260613_0002) NO entran en ese recorrido: nunca se auto-apagan.
--      La vista sí los cubre, así que el badge "Agotado" funciona y sólo
--      falla el auto-86. Es anterior a esta fase y arreglarlo cambia
--      comportamiento en todos lados — queda documentado, no corregido.
--
-- BASADA EN LA DEFINICIÓN VIVA de producción (cotejada 2026-08-31), no en
-- la del repositorio.
--
-- REQUIERE: 20260901_0002.
--
-- SOBRE `shows_in_pos`: esta migración la LEE y la 20260901_0005 también la
-- crea. Se declara acá con `add column if not exists` para que las dos se
-- puedan aplicar en cualquier orden: la que corra primero la crea y la otra
-- no hace nada. Sin esto, aplicar 0004 antes que 0005 falla con 42703.
--
-- IDEMPOTENTE: sí. REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. La columna que esta vista necesita leer (la comparte con 0005)
-- ---------------------------------------------------------------------------

alter table public.warehouses
  add column if not exists shows_in_pos boolean not null default false;

create unique index if not exists uq_warehouses_pos_source
  on public.warehouses (business_id)
  where shows_in_pos;

-- ---------------------------------------------------------------------------
-- 1. La vista
-- ---------------------------------------------------------------------------

create or replace view public.v_menu_items_stock
with (security_invoker = on) as
with recipe_ingredient_counts as (
  select r.menu_item_id, count(*) as ingredient_count
  from public.recipes r
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  where ri.inventory_item_id is not null
    and coalesce(ri.quantity, 0::numeric) > 0::numeric
  group by r.menu_item_id
), one_ingredient_recipes as (
  select r.menu_item_id, ri.inventory_item_id, ri.quantity as per_unit_qty
  from public.recipes r
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  join recipe_ingredient_counts c on c.menu_item_id = r.menu_item_id
  where c.ingredient_count = 1
    and ri.inventory_item_id is not null
    and coalesce(ri.quantity, 0::numeric) > 0::numeric
), item_links as (
  select menu_item_id, inventory_item_id, per_unit_qty
  from one_ingredient_recipes
  union all
  select mi_1.id, mi_1.inventory_item_id, 1::numeric
  from public.menu_items mi_1
  where mi_1.inventory_item_id is not null
    and not exists (
      select 1 from public.recipes r where r.menu_item_id = mi_1.id
    )
), business_fallback as (
  -- Bodega de respaldo para los productos que NO resuelven por área.
  --
  -- Sólo para negocios que ya trabajan por bodega —bandera de secciones
  -- prendida, o alguna bodega marcada para el punto de venta—. Ahí el
  -- respaldo es la MISMA bodega que usa la venta al descontar, así lo que
  -- se muestra y lo que se descuenta salen del mismo lugar.
  --
  -- Para todos los demás queda NULL, que significa "sumá todas las
  -- bodegas": el comportamiento de siempre, intacto.
  select
    b.id as business_id,
    case
      when coalesce(bs.warehouse_sections_enabled, false)
        or exists (
             select 1 from public.warehouses w2
              where w2.business_id = b.id and w2.shows_in_pos
           )
      then (
        select w3.id
          from public.warehouses w3
         where w3.business_id = b.id
         order by w3.is_main desc, w3.created_at asc nulls first, w3.id asc
         limit 1
      )
    end as fallback_warehouse_id
  from public.businesses b
  left join public.business_settings bs on bs.business_id = b.id
)
select
  mi.id                 as menu_item_id,
  il.inventory_item_id,
  ii.unit,
  floor(coalesce(sum(ist.quantity), 0::numeric)
        / nullif(il.per_unit_qty, 0::numeric)) as available_units,
  coalesce(sum(ist.quantity), 0::numeric)      as raw_ingredient_stock,
  il.per_unit_qty                              as ingredient_per_unit
from public.menu_items mi
join item_links il on il.menu_item_id = mi.id
join public.inventory_items ii on ii.id = il.inventory_item_id
left join business_fallback bf on bf.business_id = mi.business_id
-- La bodega que le toca a este producto. Se resuelve UNA vez por fila y con
-- el MISMO respaldo que usa la venta: si el grid mostrara la suma de todas
-- las bodegas mientras la venta descuenta de una sola, la principal se iría
-- a negativo con mercancía sobrando en las otras.
left join lateral (
  select public.fn_resolve_consumption_warehouse(
           mi.business_id, mi.id, bf.fallback_warehouse_id) as wid
) rw on true
left join public.inventory_stock ist
  on ist.item_id = il.inventory_item_id
 and (rw.wid is null or ist.warehouse_id = rw.wid)
where coalesce(mi.is_inventory_tracked, false) = true
group by mi.id, il.inventory_item_id, ii.unit, il.per_unit_qty;

grant select on public.v_menu_items_stock to authenticated;

comment on view public.v_menu_items_stock is
  'Existencia disponible por producto del menú. Con almacenes por sección '
  'activos mira la bodega del área del producto (la misma que resuelve '
  'fn_resolve_consumption_warehouse); con la bandera apagada suma todas, '
  'como siempre. F1 Almacenes por sección.';

-- ---------------------------------------------------------------------------
-- 2. El auto-86
-- ---------------------------------------------------------------------------

create or replace function public.fn_recompute_menu_items_availability(
  p_inventory_item_id uuid
) returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_menu_item record;
  v_available numeric;
  v_warehouse_id uuid;
  v_business_id uuid;
  v_fallback_warehouse_id uuid;
begin
  if p_inventory_item_id is null then
    return;
  end if;

  -- El mismo respaldo que usa la vista y la venta. Se calcula UNA vez: todos
  -- los productos de este recorrido comparten el insumo, y el insumo es de un
  -- solo negocio.
  --
  -- Sin esto, un producto sin área en un negocio que trabaja por bodega
  -- quedaría con tres criterios distintos: el grid mostrando la principal, la
  -- venta descontando de la principal, y el auto-86 mirando la suma de todas
  -- —o sea, no apagando nunca lo que el grid ya está bloqueando—.
  select ii.business_id into v_business_id
    from public.inventory_items ii
   where ii.id = p_inventory_item_id;

  if v_business_id is not null then
    select case
      when coalesce(bs.warehouse_sections_enabled, false)
        or exists (
             select 1 from public.warehouses w2
              where w2.business_id = v_business_id and w2.shows_in_pos
           )
      then (
        select w3.id
          from public.warehouses w3
         where w3.business_id = v_business_id
         order by w3.is_main desc, w3.created_at asc nulls first, w3.id asc
         limit 1
      )
    end
      into v_fallback_warehouse_id
      from public.business_settings bs
     where bs.business_id = v_business_id;

    -- Un negocio sin fila en business_settings no entra al select de arriba:
    -- igual puede tener una bodega marcada para el punto de venta.
    if v_fallback_warehouse_id is null and exists (
         select 1 from public.warehouses w2
          where w2.business_id = v_business_id and w2.shows_in_pos
       ) then
      select w3.id into v_fallback_warehouse_id
        from public.warehouses w3
       where w3.business_id = v_business_id
       order by w3.is_main desc, w3.created_at asc nulls first, w3.id asc
       limit 1;
    end if;
  end if;

  for v_menu_item in
    select distinct
      mi.id,
      mi.business_id,
      mi.is_active,
      mi.auto_disabled,
      mi.allow_negative_sale
    from public.menu_items mi
    join public.recipes r on r.menu_item_id = mi.id
    join public.recipe_ingredients ri on ri.recipe_id = r.id
    where ri.inventory_item_id = p_inventory_item_id
      and coalesce(mi.is_inventory_tracked, false) = true
  loop
    -- Productos que permiten venta en negativo: nunca los auto-desactivamos.
    -- El badge "Agotado" en la UI alerta al cajero; el conteo sigue corriendo
    -- en inventory_stock (puede ir negativo) y se salda con la próxima compra.
    if v_menu_item.allow_negative_sale = true then
      -- Si veníamos de un auto-86 anterior (antes de que se activara el
      -- flag), reactivamos para que vuelva al menú.
      if v_menu_item.auto_disabled = true and v_menu_item.is_active = false then
        update public.menu_items
        set is_active = true, auto_disabled = false
        where id = v_menu_item.id;
      end if;
      continue;
    end if;

    -- De qué bodega mirar la existencia. NULL = todas, que es lo que pasa en
    -- un negocio que no trabaja por bodega: el comportamiento histórico.
    v_warehouse_id := public.fn_resolve_consumption_warehouse(
      v_menu_item.business_id, v_menu_item.id, v_fallback_warehouse_id);

    -- Comportamiento legacy: calcula availability respetando todos los
    -- ingredientes y desactiva si alguno se agotó.
    select min(
      floor(
        coalesce((
          select sum(ist.quantity)
          from public.inventory_stock ist
          where ist.item_id = ri2.inventory_item_id
            and (v_warehouse_id is null or ist.warehouse_id = v_warehouse_id)
        ), 0) / nullif(ri2.quantity, 0)
      )
    )::numeric
      into v_available
    from public.recipes r2
    join public.recipe_ingredients ri2 on ri2.recipe_id = r2.id
    where r2.menu_item_id = v_menu_item.id
      and ri2.inventory_item_id is not null
      and coalesce(ri2.quantity, 0) > 0;

    if v_available is null or v_available <= 0 then
      if v_menu_item.is_active = true then
        update public.menu_items
        set is_active = false, auto_disabled = true
        where id = v_menu_item.id;
      end if;
    else
      if v_menu_item.auto_disabled = true and v_menu_item.is_active = false then
        update public.menu_items
        set is_active = true, auto_disabled = false
        where id = v_menu_item.id;
      end if;
    end if;
  end loop;
end;
$function$;

comment on function public.fn_recompute_menu_items_availability(uuid) is
  'Auto-86: apaga y reactiva productos según la existencia de sus '
  'ingredientes. Con almacenes por sección activos mira la bodega del área '
  'del producto; con la bandera apagada suma todas, como siempre. NO cubre '
  'productos terminados con link directo sin receta (limitación anterior a '
  'F1). F1 Almacenes por sección.';

commit;
