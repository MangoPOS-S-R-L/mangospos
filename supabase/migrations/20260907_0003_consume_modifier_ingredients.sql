-- =============================================================================
-- 20260907_0003 — el consumo de inventario ahora expande los MODIFICADORES
--
-- ⚠️  NO APLICAR SIN COTEJAR PRIMERO LA DEFINICIÓN VIVA.
--     La base de producción diverge del repositorio. Correr antes:
--
--       select pg_get_functiondef(
--         'public.consume_inventory_from_order(uuid)'::regprocedure);
--
--     (o directamente supabase/PREFLIGHT_modificadores_insumos.sql, que lo
--     hace junto con el resto de los chequeos) y comparar con lo de abajo. Si
--     la viva tiene algo que esta versión no, hay que traerlo acá ANTES de
--     aplicar o se pierde en silencio.
--
-- QUÉ CAMBIA — DOS COSAS:
--
--   (A) RAMA NUEVA (3): los modificadores vendidos que tengan líneas en
--       `modifier_ingredients` ahora descuentan. Cantidad esperada =
--          cantidad de la línea × qty del modificador × qty del renglón.
--       La bodega la decide el PRODUCTO PADRE (el extra se prepara donde se
--       prepara el plato), con el mismo resolvedor que la rama (1).
--
--       NO se exige `is_inventory_tracked` en el producto padre: configurar
--       una línea de insumo en el modificador YA es la declaración explícita
--       de que esa opción mueve stock. El negocio que no lleva inventario
--       sigue protegido por el corte de `inventory_mode = 'none'` de arriba.
--
--   (B) EL ESPERADO SE RECORTA A 0 POR PAR (insumo, bodega).
--       Las líneas de modificador llevan SIGNO: «Sin queso» es −0.05 kg y su
--       trabajo es ANULAR lo que la receta base iba a descontar. Si alguien
--       configura un negativo sobre un producto que no consume ese insumo, el
--       esperado del par se iría a negativo y la función INVENTARÍA STOCK que
--       nadie compró. Con el `greatest(..., 0)` el peor caso es «no descontó»,
--       nunca «apareció mercancía».
--       Para las ramas viejas no cambia nada: sus cantidades son siempre ≥ 0.
--
-- LO QUE NO CAMBIA: la reconciliación. La función sigue siendo idempotente —
--   compara el esperado contra lo ya movido por ESTA orden y escribe solo la
--   diferencia. Editar la orden (quitar el «sin queso», anular un renglón)
--   corrige el stock solo, con un movimiento de vuelta.
--
-- REQUIERE: 20260907_0001 (tabla) y 20260907_0002 (columna).
-- IDEMPOTENTE: sí (create or replace).
-- REVERSIBLE: sí (ver _ROLLBACK — restaura la versión de 20260901_0003).
-- =============================================================================

begin;

-- Compatibilidad hacia atrás: si esta base todavía NO tiene almacenes por
-- sección (20260901_0002), el resolvedor no existe y la función de abajo no
-- compilaría. Creamos un stub que devuelve NULL — exactamente lo que devuelve
-- el resolvedor real con la bandera apagada, o sea: todo cae en la bodega por
-- defecto, que es el comportamiento histórico. Cuando se aplique 20260901_0002
-- su `create or replace` reemplaza este stub (misma firma, mismos nombres de
-- parámetro).
do $guard$
begin
  if to_regprocedure(
       'public.fn_resolve_consumption_warehouse(uuid,uuid,uuid)') is null then
    execute $f$
      create function public.fn_resolve_consumption_warehouse(
        p_business_id          uuid,
        p_menu_item_id         uuid,
        p_default_warehouse_id uuid
      ) returns uuid
      language sql
      immutable
      as $body$ select null::uuid $body$;
    $f$;

    execute $f$
      comment on function public.fn_resolve_consumption_warehouse(uuid,uuid,uuid)
        is 'STUB creado por 20260907_0003 porque la base no tenía almacenes '
           'por sección. Devuelve NULL = usar la bodega por defecto. '
           '20260901_0002 lo reemplaza con el resolvedor real.'
    $f$;
  end if;
end
$guard$;

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

      union all

      -- (3) MODIFICADORES con insumos propios (20260907_0001). Cantidad CON
      -- SIGNO: «Queso extra» suma, «Sin queso» resta lo que la receta base
      -- del producto iba a descontar. La bodega la manda el producto padre.
      select
        ming.inventory_item_id,
        coalesce(
          public.fn_resolve_consumption_warehouse(
            v_business_id, oi.product_id, null),
          v_default_warehouse_id
        ),
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
    expected_agg as (
      -- greatest(..., 0): una línea de modificador negativa puede ANULAR el
      -- consumo de la receta base, pero jamás darlo vuelta y crear stock.
      select
        inventory_item_id,
        warehouse_id,
        greatest(sum(q), 0) as expected
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

comment on function public.consume_inventory_from_order(uuid) is
  'Reconcilia el consumo de inventario de una orden por par (insumo, '
  'bodega). Expande: recetas de producto, productos terminados con link '
  'directo, componentes de combo y MODIFICADORES con insumos propios '
  '(modifier_ingredients, con cantidad firmada para el «sin queso» y el '
  'cambio de pan). El esperado por par se recorta a 0: un negativo mal '
  'configurado deja de descontar, nunca crea stock. Idempotente: solo '
  'escribe la diferencia contra lo ya movido.';

commit;
