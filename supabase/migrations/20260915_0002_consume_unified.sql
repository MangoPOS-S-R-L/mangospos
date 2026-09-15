-- =============================================================================
-- 20260915_0002 — consume_inventory_from_order UNIFICADA
--
-- EL RIESGO QUE RESUELVE:
--   El repositorio tenía DOS ramas de esta función que salían de la misma
--   base (20260901_0003, consumo por área) y ninguna traía lo de la otra:
--     A) 20260901_0006  varias bodegas alimentan la POS: el consumo reparte
--                       en cascada sobre las bodegas marcadas.
--     B) 20260907_0003  los modificadores descuentan sus insumos, con signo.
--        20260910_0002  una orden anulada devuelve lo consumido.
--   Aplicar una rama encima de la otra BORRABA en silencio lo de la otra. Y
--   20260910_0002 nombra `modifier_ingredients` sin candado: aplicada sin
--   20260907_0001, la POS no puede guardar pedidos (plpgsql resuelve las
--   tablas al EJECUTAR, no al crear).
--
-- QUÉ HACE — una sola versión con la ESTRUCTURA de A y las piezas de B:
--   · cada renglón lleva su producto → área → bodega; sin área, cascada (A);
--   · rama (3): modificadores con insumos, cantidad CON SIGNO; el área la
--     manda el producto padre (B);
--   · el esperado se recorta a 0 por par: un «sin queso» anula lo de la
--     receta, nunca crea stock (B);
--   · orden anulada = esperado vacío → devuelve lo consumido (B), más el
--     trigger en `orders` que lo dispara al anular o al resucitar.
--
--   Y un blindaje que ninguna rama tenía: si `status` o `status_ext` vinieran
--   en NULL, la orden NO se da por anulada. En 20260910_0002,
--   `'open' = 'canceled' or NULL = 'void'` daba NULL y `not NULL` vaciaba el
--   esperado. En la base viva NO pasó nunca: las dos columnas son NOT NULL
--   con default 'open' (verificado 2026-09-15: 0 de 189,283 órdenes). Queda
--   como defensa, por si algún día se relaja la columna.
--
-- APLICADA EN PRODUCCIÓN 2026-09-15: pg_get_functiondef de la viva = el
--   CREATE de este archivo (largo 10823 · md5 f19c45889141, idéntico en
--   Postgres 15 local). Verificación posterior:
--   supabase/VERIFICAR_20260915_0002_consumo.sql.
--
-- REEMPLAZA a 20260907_0003 y a la parte de consumo de 20260910_0002.
--   Esas dos y 20260901_0006 traen ahora una guardia: si la función viva ya
--   tiene la otra rama (o es esta), se SALTAN el reemplazo en vez de borrarlo.
--
-- REQUIERE (la guardia de abajo lo verifica; si falta algo NO aplica nada):
--   20260613_0001 (menu_items.inventory_item_id)
--   20260901_0005 (warehouses.shows_in_pos)
--   20260901_0006 (fn_resolve_area_warehouse)
--   20260907_0001 (modifier_ingredients)
--   20260907_0002 (order_item_modifiers.modifier_id)
--
-- ORDEN: lo que falte de 20260901_0004 → 0005 → 0006, 20260907_0001 → 0002,
--   ESTA, y después 20260907_0004. Antes de aplicar: bloque 1 de
--   supabase/DIAGNOSTICO_sistema_listo_recetas.sql.
--
-- PRUEBA: supabase/tests/consume_unificada_local_test.sh (Postgres 15 local).
--
-- IDEMPOTENTE: sí. REVERSIBLE: sí (_ROLLBACK restaura la versión A).
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- Guardia de requisitos: si falta una pieza, la función quedaría creada y
-- reventaría en la primera venta. Mejor no aplicar nada.
do $guard$
declare
  v_missing text[] := array[]::text[];
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'menu_items'
       and column_name = 'inventory_item_id') then
    v_missing := array_append(v_missing, '20260613_0001 (menu_items.inventory_item_id)');
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'warehouses'
       and column_name = 'shows_in_pos') then
    v_missing := array_append(v_missing, '20260901_0005 (warehouses.shows_in_pos)');
  end if;

  if not exists (
    select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_resolve_area_warehouse') then
    v_missing := array_append(v_missing, '20260901_0006 (fn_resolve_area_warehouse)');
  end if;

  if to_regclass('public.modifier_ingredients') is null then
    v_missing := array_append(v_missing, '20260907_0001 (modifier_ingredients)');
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'order_item_modifiers'
       and column_name = 'modifier_id') then
    v_missing := array_append(v_missing, '20260907_0002 (order_item_modifiers.modifier_id)');
  end if;

  if to_regtype('public.order_status') is null or not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'orders'
       and column_name = 'status_ext') then
    v_missing := array_append(v_missing, 'orders.status_ext (public.order_status)');
  end if;

  if array_length(v_missing, 1) is not null then
    raise exception 'No se aplicó nada. Falta aplicar antes: %',
      array_to_string(v_missing, '; ');
  end if;
end
$guard$;

create or replace function public.consume_inventory_from_order(_order_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
-- UNIFICADA 20260915_0002 · cascada multi-bodega (20260901_0006) +
-- modificadores con insumos (20260907_0003) + orden anulada (20260910_0002).
-- Las guardias de las migraciones viejas buscan esta marca: no borrarla.
declare
  v_default_warehouse_id uuid;
  v_business_id uuid;
  v_mode text;
  v_pool uuid[];
  v_pair record;
  v_note text;
  v_order_voided boolean;
begin
  -- El estado de la orden entra en la misma consulta que ya se hacía: una
  -- orden anulada tiene que llegar a «esperado = 0», no saltarse el trabajo.
  -- Cada comparación va con coalesce: un NULL no puede dar por anulada una
  -- orden viva.
  select
    ts.business_id,
    coalesce(o.status = 'canceled', false)
      or coalesce(o.status_ext = 'void'::public.order_status, false)
    into v_business_id, v_order_voided
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  where o.id = _order_id
  limit 1;

  if v_business_id is null then
    return;
  end if;

  v_order_voided := coalesce(v_order_voided, false);

  select coalesce(inventory_mode, 'none')
    into v_mode
  from public.business_settings
  where business_id = v_business_id;

  if coalesce(v_mode, 'none') = 'none' then
    return;
  end if;

  select w.id
    into v_default_warehouse_id
  from public.warehouses w
  where w.business_id = v_business_id
  order by w.is_main desc, w.created_at asc nulls first, w.id asc
  limit 1;

  if v_default_warehouse_id is null then
    return;
  end if;

  -- La cascada: las bodegas marcadas, la principal primero. Si no hay
  -- ninguna marcada, la cascada es la bodega de siempre y todo se comporta
  -- como antes.
  select array_agg(w.id order by w.is_main desc,
                                 w.created_at asc nulls first,
                                 w.id asc)
    into v_pool
  from public.warehouses w
  where w.business_id = v_business_id
    and coalesce(w.is_active, true)
    and w.shows_in_pos;

  if v_pool is null or array_length(v_pool, 1) is null then
    v_pool := array[v_default_warehouse_id];
  end if;

  for v_pair in
    with expected_rows as (
      -- (1) Productos normales con receta (NO combos).
      select
        i.inventory_item_id,
        oi.product_id                                   as menu_item_id,
        null::uuid                                      as fallback_menu_item_id,
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
        oi.product_id,
        null::uuid,
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

      -- (2) Componentes de combo. El área la manda el COMPONENTE; si no
      -- tiene, se prueba con la del combo.
      select
        i.inventory_item_id,
        oim.menu_item_id,
        oi.product_id,
        i.quantity * coalesce(oim.qty, 1)
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

      union all

      -- (3) MODIFICADORES con insumos propios (20260907_0001). Cantidad CON
      -- SIGNO: «Queso extra» suma, «Sin queso» resta lo que la receta base
      -- iba a descontar. El área la manda el PRODUCTO PADRE: el extra se
      -- prepara donde se prepara el plato. No exige `is_inventory_tracked`:
      -- configurar una línea de insumo en el modificador YA declara que mueve
      -- stock; el negocio sin inventario sigue protegido por `inventory_mode`.
      select
        ming.inventory_item_id,
        oi.product_id,
        null::uuid,
        ming.quantity
          * coalesce(oim.qty, 1)
          * coalesce(oi.qty, oi.quantity::numeric, 0)
      from public.order_items oi
      join public.order_item_modifiers oim
        on oim.item_id = oi.id and oim.modifier_id is not null
      join public.modifier_ingredients ming
        on ming.modifier_id = oim.modifier_id
      where oi.order_id = _order_id
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and ming.inventory_item_id is not null
    ),
    rows_resolved as (
      select
        er.inventory_item_id,
        er.q,
        coalesce(
          public.fn_resolve_area_warehouse(v_business_id, er.menu_item_id),
          public.fn_resolve_area_warehouse(
            v_business_id, er.fallback_menu_item_id)
        ) as area_wid
      from expected_rows er
      -- Una orden anulada no espera NADA: deja vacío este lado de la
      -- reconciliación y el delta contra `already` devuelve el stock. No es
      -- un corte, es un objetivo.
      where not v_order_voided
    ),
    -- Lo que sale de una bodega concreta porque el producto tiene área.
    -- greatest(..., 0): una línea de modificador negativa puede ANULAR el
    -- consumo de la receta, pero jamás darlo vuelta y crear stock.
    expected_area as (
      select inventory_item_id, area_wid as warehouse_id,
             greatest(sum(q), 0) as qty
      from rows_resolved
      where area_wid is not null
      group by 1, 2
    ),
    -- Lo que no tiene área y hay que repartir en la cascada. Mismo recorte.
    expected_pool as (
      select inventory_item_id, greatest(sum(q), 0) as qty
      from rows_resolved
      where area_wid is null
      group by 1
    ),
    -- Lo que ESTA orden ya movió, por par. Es lo que la hace idempotente.
    already as (
      select
        im.item_id      as inventory_item_id,
        im.warehouse_id,
        coalesce(-sum(im.quantity), 0) as qty
      from public.inventory_movements im
      where im.reference_id = _order_id
        and im.reference_type = 'order'
        and im.movement_type = 'sale'
      group by 1, 2
    ),
    -- Cupo de cada bodega de la cascada: la existencia COMO SI esta orden no
    -- hubiera pasado, menos lo que ya se reservó por área en esa bodega.
    pool_cap as (
      select
        p.inventory_item_id,
        u.wid,
        u.ord,
        greatest(0,
          coalesce((
            select s.quantity from public.inventory_stock s
             where s.item_id = p.inventory_item_id and s.warehouse_id = u.wid
          ), 0)
          + coalesce((
            select a.qty from already a
             where a.inventory_item_id = p.inventory_item_id
               and a.warehouse_id = u.wid
          ), 0)
          - coalesce((
            select ea.qty from expected_area ea
             where ea.inventory_item_id = p.inventory_item_id
               and ea.warehouse_id = u.wid
          ), 0)
        ) as cap,
        p.qty as needed
      from expected_pool p
      cross join lateral unnest(v_pool) with ordinality as u(wid, ord)
    ),
    -- La cascada propiamente dicha: cada bodega toma lo que puede de lo que
    -- quedó, y la última absorbe el excedente (es la que queda debiendo).
    pool_final as (
      select
        inventory_item_id,
        wid as warehouse_id,
        greatest(0, least(cap, needed - prev_cap))
        + case when ord = last_ord and needed > total_cap
               then needed - total_cap else 0 end as qty
      from (
        select
          c.*,
          coalesce(sum(c.cap) over (
            partition by c.inventory_item_id order by c.ord
            rows between unbounded preceding and 1 preceding), 0) as prev_cap,
          sum(c.cap) over (partition by c.inventory_item_id)      as total_cap,
          max(c.ord) over (partition by c.inventory_item_id)      as last_ord
        from pool_cap c
      ) w
    ),
    -- A dónde tiene que llegar cada par al final de la reconciliación.
    desired as (
      select inventory_item_id, warehouse_id, sum(qty) as qty
      from (
        select inventory_item_id, warehouse_id, qty from expected_area
        union all
        select inventory_item_id, warehouse_id, qty from pool_final
      ) z
      where warehouse_id is not null and qty <> 0
      group by 1, 2
    )
    select
      coalesce(d.inventory_item_id, a.inventory_item_id) as item_id,
      coalesce(d.warehouse_id, a.warehouse_id)           as warehouse_id,
      coalesce(d.qty, 0) - coalesce(a.qty, 0)            as delta
    from desired d
    full outer join already a
      on a.inventory_item_id = d.inventory_item_id
     and a.warehouse_id      = d.warehouse_id
  loop
    if v_pair.delta = 0
       or v_pair.item_id is null
       or v_pair.warehouse_id is null then
      continue;
    end if;

    v_note := case
                when v_pair.delta > 0 then 'Auto-consumo por venta'
                when v_order_voided   then 'Devolución por anulación de la orden'
                else 'Devolución por cancelación/edición'
              end;

    insert into public.inventory_movements (
      business_id, warehouse_id, item_id, movement_type,
      quantity, reference_id, reference_type, notes
    )
    values (
      v_business_id, v_pair.warehouse_id, v_pair.item_id, 'sale',
      -v_pair.delta, _order_id, 'order', v_note
    );
  end loop;
end;
$function$;

comment on function public.consume_inventory_from_order(uuid) is
  'UNIFICADA (20260915_0002). Reconcilia el consumo de inventario de una '
  'orden por par (insumo, bodega). Expande recetas, productos terminados con '
  'link directo, componentes de combo y modificadores con insumos (con '
  'signo, recortado a 0 por par). La bodega sale del área del producto; sin '
  'área, reparte en cascada entre las bodegas marcadas. Una orden ANULADA '
  'espera cero y devuelve lo consumido. Idempotente.';

-- ---------------------------------------------------------------------------
-- El disparador de 20260910_0002. Sin esto, anular una orden no devolvería
-- nada hasta que alguien tocara un renglón — que es justo lo que no pasa.
-- ---------------------------------------------------------------------------

create or replace function public.fn_orders_reconcile_inventory_on_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.consume_inventory_from_order(NEW.id);
  return NEW;
end;
$$;

comment on function public.fn_orders_reconcile_inventory_on_status() is
  'Trigger en orders: reconcilia inventario cuando la orden ENTRA o SALE del '
  'estado anulado. Al anular devuelve el stock consumido; si resucita, lo '
  'vuelve a descontar. Se apoya en la idempotencia de '
  'consume_inventory_from_order.';

drop trigger if exists trg_orders_reconcile_inventory_on_status on public.orders;

create trigger trg_orders_reconcile_inventory_on_status
  after update of status, status_ext on public.orders
  for each row
  when (
    (OLD.status is distinct from NEW.status
     or OLD.status_ext is distinct from NEW.status_ext)
    and (
      -- entra a anulada...
      NEW.status = 'canceled' or NEW.status_ext = 'void'::public.order_status
      -- ...o sale de anulada.
      or OLD.status = 'canceled' or OLD.status_ext = 'void'::public.order_status
    )
  )
  execute function public.fn_orders_reconcile_inventory_on_status();

comment on trigger trg_orders_reconcile_inventory_on_status on public.orders is
  'Devuelve el inventario al anular la orden y lo vuelve a descontar si la '
  'orden resucita. Ver 20260910_0002 y 20260915_0002.';

commit;

notify pgrst, 'reload schema';
