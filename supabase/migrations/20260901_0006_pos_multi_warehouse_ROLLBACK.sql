-- ROLLBACK de 20260901_0006_pos_multi_warehouse.sql
--
-- Vuelve a UNA sola bodega marcada para el punto de venta, sin reparto en
-- cascada. Restaura:
--   · el resolvedor de 20260901_0005 (área → primera marcada → por defecto)
--   · la vista y el auto-86 de 20260901_0004
--   · el consumo de 20260901_0003 (una bodega por producto)
--
-- ⚠️ ANTES DE CORRER: si hay varias bodegas marcadas, el índice único no se
--   puede recrear. El primer paso DESMARCA todas menos una por negocio —la
--   principal, o la más antigua—. Lo que ya se descontó de las otras queda
--   como está: son movimientos reales, no se tocan. Pero desde ese momento
--   el punto de venta deja de ver esa existencia.

begin;

-- 1. Una sola marcada por negocio, o el índice único no entra.
update public.warehouses w
   set shows_in_pos = false
 where w.shows_in_pos
   and w.id <> (
     select w2.id from public.warehouses w2
      where w2.business_id = w.business_id and w2.shows_in_pos
      order by w2.is_main desc, w2.created_at asc nulls first, w2.id asc
      limit 1
   );

drop index if exists public.idx_warehouses_pos_source;

create unique index if not exists uq_warehouses_pos_source
  on public.warehouses (business_id)
  where shows_in_pos;

create or replace function public.fn_resolve_consumption_warehouse(
  p_business_id         uuid,
  p_menu_item_id        uuid,
  p_default_warehouse_id uuid
) returns uuid
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
    -- (1) El área del producto. Sólo si la bandera de secciones está
    -- prendida: eso cambia el menú entero de golpe y por eso va detrás de
    -- un interruptor de negocio.
    case
      when coalesce(
        (select bs.warehouse_sections_enabled
           from public.business_settings bs
          where bs.business_id = p_business_id),
        false
      ) then (
        select w.id
          from public.warehouses w
          join public.print_areas pa on pa.id = w.production_area_id
         where w.business_id = p_business_id
           and coalesce(w.is_active, true)
           and w.warehouse_type = 'production'
           and pa.id in (
             select mipa.print_area_id
               from public.menu_item_print_areas mipa
              where mipa.menu_item_id = p_menu_item_id
             union all
             -- Legacy, SÓLO si el producto no tiene filas N:M: la N:M
             -- sobrescribe al código, igual que en el ruteo de comandas.
             select pa2.id
               from public.menu_items mi
               join public.print_areas pa2
                 on pa2.business_id = mi.business_id
                and pa2.code = mi.print_area_code
              where mi.id = p_menu_item_id
                and mi.print_area_code is not null
                and not exists (
                  select 1
                    from public.menu_item_print_areas x
                   where x.menu_item_id = p_menu_item_id
                )
           )
         order by coalesce(pa.display_order, 0) asc, pa.name asc, w.id asc
         limit 1
      )
    end,

    -- (2) La bodega del punto de venta. No depende de la bandera: la casilla
    -- de esa bodega es el acto deliberado.
    (
      select w.id
        from public.warehouses w
       where w.business_id = p_business_id
         and coalesce(w.is_active, true)
         and w.shows_in_pos
       limit 1
    ),

    -- (3) Lo de siempre.
    p_default_warehouse_id
  );
$$;

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

create or replace function public.consume_inventory_from_order(_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_default_warehouse_id uuid;
  v_business_id uuid;
  v_mode text;
  v_pair record;
  v_note text;
begin
  select ts.business_id
    into v_business_id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  where o.id = _order_id
  limit 1;

  if v_business_id is null then
    return;
  end if;

  select coalesce(inventory_mode, 'none')
    into v_mode
  from public.business_settings
  where business_id = v_business_id;

  if coalesce(v_mode, 'none') = 'none' then
    return;
  end if;

  -- La bodega de siempre: sigue siendo el destino cuando el producto no
  -- tiene área, cuando el área no tiene almacén, o cuando la bandera de
  -- secciones está apagada.
  select w.id
    into v_default_warehouse_id
  from public.warehouses w
  where w.business_id = v_business_id
  order by w.is_main desc, w.created_at asc nulls first, w.id asc
  limit 1;

  if v_default_warehouse_id is null then
    return;
  end if;

  for v_pair in
    with expected as (
      -- (1) Productos normales con receta (NO combos).
      select
        i.inventory_item_id,
        coalesce(
          public.fn_resolve_consumption_warehouse(
            v_business_id, oi.product_id, null),
          v_default_warehouse_id
        ) as warehouse_id,
        i.quantity * coalesce(oi.qty, oi.quantity::numeric, 0) as q
      from public.order_items oi
      join public.menu_items mi on mi.id = oi.product_id
      join public.recipes r on r.menu_item_id = oi.product_id
      join public.recipe_ingredients i on i.recipe_id = r.id
      where oi.order_id = _order_id
        and oi.product_id is not null
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and coalesce(mi.is_inventory_tracked, false) = true
        and coalesce(mi.item_type, '') <> 'combo'
        and i.inventory_item_id is not null

      union all

      -- (1b) Productos TERMINADOS con link directo (SIN receta).
      select
        mi.inventory_item_id,
        coalesce(
          public.fn_resolve_consumption_warehouse(
            v_business_id, oi.product_id, null),
          v_default_warehouse_id
        ),
        coalesce(oi.qty, oi.quantity::numeric, 0)
      from public.order_items oi
      join public.menu_items mi on mi.id = oi.product_id
      where oi.order_id = _order_id
        and oi.product_id is not null
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and coalesce(mi.is_inventory_tracked, false) = true
        and mi.inventory_item_id is not null
        and coalesce(mi.item_type, '') <> 'combo'
        and not exists (
          select 1 from public.recipes r where r.menu_item_id = mi.id
        )

      union all

      -- (2) Componentes de combo. El área la manda el COMPONENTE —es lo que
      -- se prepara—; si el componente no tiene área, se prueba con la del
      -- combo antes de caer en la bodega por defecto.
      select
        i.inventory_item_id,
        coalesce(
          public.fn_resolve_consumption_warehouse(
            v_business_id, oim.menu_item_id, null),
          public.fn_resolve_consumption_warehouse(
            v_business_id, oi.product_id, null),
          v_default_warehouse_id
        ),
        i.quantity
          * coalesce(oim.qty, 1)
          * coalesce(oi.qty, oi.quantity::numeric, 0)
      from public.order_items oi
      join public.menu_items combo_mi
        on combo_mi.id = oi.product_id and combo_mi.item_type = 'combo'
      join public.order_item_modifiers oim
        on oim.item_id = oi.id and oim.menu_item_id is not null
      join public.menu_items comp_mi on comp_mi.id = oim.menu_item_id
      join public.recipes r on r.menu_item_id = oim.menu_item_id
      join public.recipe_ingredients i on i.recipe_id = r.id
      where oi.order_id = _order_id
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and coalesce(comp_mi.is_inventory_tracked, false) = true
        and i.inventory_item_id is not null
    ),
    expected_agg as (
      select inventory_item_id, warehouse_id, sum(q) as expected
      from expected
      where inventory_item_id is not null
        and warehouse_id is not null
      group by inventory_item_id, warehouse_id
    ),
    -- Lo ya movido por ESTA orden, por par. Es lo que hace idempotente a la
    -- función: se la puede llamar mil veces y solo escribe la diferencia.
    already as (
      select
        im.item_id            as inventory_item_id,
        im.warehouse_id,
        coalesce(-sum(im.quantity), 0) as consumed
      from public.inventory_movements im
      where im.reference_id = _order_id
        and im.reference_type = 'order'
        and im.movement_type = 'sale'
      group by im.item_id, im.warehouse_id
    )
    select
      coalesce(e.inventory_item_id, a.inventory_item_id) as item_id,
      coalesce(e.warehouse_id, a.warehouse_id)           as warehouse_id,
      coalesce(e.expected, 0) - coalesce(a.consumed, 0)  as delta
    from expected_agg e
    full outer join already a
      on a.inventory_item_id = e.inventory_item_id
     and a.warehouse_id      = e.warehouse_id
  loop
    if v_pair.delta = 0
       or v_pair.item_id is null
       or v_pair.warehouse_id is null then
      continue;
    end if;

    v_note := case when v_pair.delta > 0 then 'Auto-consumo por venta'
                   else 'Devolución por cancelación/edición' end;

    insert into public.inventory_movements (
      business_id,
      warehouse_id,
      item_id,
      movement_type,
      quantity,
      reference_id,
      reference_type,
      notes
    )
    values (
      v_business_id,
      v_pair.warehouse_id,
      v_pair.item_id,
      'sale',
      -v_pair.delta,
      _order_id,
      'order',
      v_note
    );
  end loop;
end;
$function$;

-- 2. Las funciones nuevas quedan sin usuarios: se van.
drop function if exists public.fn_pos_stock_warehouses(uuid, uuid);
drop function if exists public.fn_resolve_area_warehouse(uuid, uuid);

commit;
