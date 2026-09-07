-- =============================================================================
-- 20260907_0004 — Auto-86 del MODIFICADOR: si el insumo se agota, la opción
--                 sale bloqueada.
--
-- EL CASO:
--   Se acabó la caja de 12 panes integrales. El «Pan integral» tiene que dejar
--   de poderse escoger, igual que un plato se apaga solo cuando se acaba su
--   insumo. Hoy el auto-86 (20260516_0015) solo mira `recipe_ingredients` y
--   solo apaga `menu_items`: los modificadores no existían para el inventario.
--
-- POR QUÉ UNA COLUMNA NUEVA Y NO `is_active = false` COMO EN PRODUCTOS:
--   1. Un grupo obligatorio (`min_select >= 1`) al que se le esconden las
--      opciones agotadas deja al mesero sin poder completar la venta, sin
--      decirle por qué. Bloqueada y visible sí se entiende: «Pan integral —
--      Agotado».
--   2. `modifiers.is_active` es el switch MANUAL del administrador. Si el
--      trigger lo pisa, el admin lo vuelve a prender y quedan peleando.
--   Por eso `is_sold_out` es una columna aparte, derivada, que solo escribe el
--   trigger. `is_active` sigue siendo del admin.
--
-- CÓMO SE CALCULA:
--   Por cada línea de `modifier_ingredients` con cantidad POSITIVA (las
--   negativas devuelven stock, no pueden agotar nada):
--       floor( existencia_total_del_insumo / cantidad_de_la_línea )
--   Si el mínimo de eso da menos de 1 —o sea, no alcanza ni para una— la
--   opción queda agotada. Es la misma fórmula del auto-86 de productos.
--
--   La existencia se suma a nivel de NEGOCIO, no por bodega: un mismo
--   modificador («queso extra») cuelga de productos de áreas distintas y no
--   tiene un área propia de dónde agarrarse. Es una diferencia consciente con
--   `fn_recompute_menu_items_availability` de 20260901_0004.
--
-- SIN LÍNEAS DE INSUMO NO PASA NADA: un modificador que no es inventariable
--   nunca se marca agotado. El bucle no lo alcanza y su `is_sold_out` se queda
--   en false para siempre. Se sigue vendiendo igual que hoy.
--
-- EL TRIGGER ES PROPIO, NO SE TOCA EL DE PRODUCTOS: se agrega un segundo
--   trigger AFTER INSERT en `inventory_movements`. Así no hay que reescribir
--   `fn_trigger_recompute_menu_availability` (que en la base viva puede tener
--   cosas que el repo no).
--
-- REQUIERE: 20260907_0001 (modifier_ingredients).
-- IDEMPOTENTE: sí. REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

alter table public.modifiers
  add column if not exists is_sold_out boolean not null default false;

comment on column public.modifiers.is_sold_out is
  'Derivada: true cuando el inventario no alcanza para una unidad de esta '
  'opción. La escribe SOLO el auto-86 (fn_recompute_modifier_availability). '
  'is_active sigue siendo el switch manual del administrador. Un modificador '
  'sin líneas en modifier_ingredients nunca se marca agotado.';

-- Un solo modificador. Es la que llama la app al guardar sus insumos, para
-- que el sello «Agotado» aparezca sin esperar al próximo movimiento.
create or replace function public.fn_recompute_modifier_availability(
  p_modifier_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id uuid;
  v_mode text;
  v_available numeric;
  v_sold_out boolean;
  v_current boolean;
begin
  if p_modifier_id is null then
    return;
  end if;

  select m.business_id, m.is_sold_out
    into v_business_id, v_current
  from public.modifiers m
  where m.id = p_modifier_id;

  if v_business_id is null then
    return;
  end if;

  select coalesce(inventory_mode, 'none')
    into v_mode
  from public.business_settings
  where business_id = v_business_id;

  -- Negocio que no lleva inventario: nada se agota nunca. Y si venía marcado
  -- de antes (le apagaron el inventario), se libera.
  if coalesce(v_mode, 'none') = 'none' then
    if coalesce(v_current, false) then
      update public.modifiers set is_sold_out = false where id = p_modifier_id;
    end if;
    return;
  end if;

  -- Solo las líneas que DESCUENTAN (cantidad > 0) pueden agotar la opción.
  select min(
    floor(
      coalesce((
        select sum(ist.quantity)
        from public.inventory_stock ist
        where ist.item_id = mi.inventory_item_id
      ), 0) / nullif(mi.quantity, 0)
    )
  )::numeric
    into v_available
  from public.modifier_ingredients mi
  where mi.modifier_id = p_modifier_id
    and mi.inventory_item_id is not null
    and coalesce(mi.quantity, 0) > 0;

  -- v_available null = el modificador no tiene líneas que descuenten →
  -- no es inventariable → nunca se agota.
  v_sold_out := (v_available is not null and v_available < 1);

  if coalesce(v_current, false) <> v_sold_out then
    update public.modifiers
    set is_sold_out = v_sold_out
    where id = p_modifier_id;
  end if;
end;
$$;

comment on function public.fn_recompute_modifier_availability(uuid) is
  'Auto-86 de una opción: marca is_sold_out cuando el inventario no alcanza '
  'ni para una unidad. Solo cuentan las líneas con cantidad positiva. Sin '
  'líneas, nunca se agota.';

-- Todos los modificadores que usan un insumo. La llama el trigger.
create or replace function public.fn_recompute_modifiers_availability(
  p_inventory_item_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_modifier record;
begin
  if p_inventory_item_id is null then
    return;
  end if;

  for v_modifier in
    select distinct mi.modifier_id as id
    from public.modifier_ingredients mi
    where mi.inventory_item_id = p_inventory_item_id
  loop
    perform public.fn_recompute_modifier_availability(v_modifier.id);
  end loop;
end;
$$;

comment on function public.fn_recompute_modifiers_availability(uuid) is
  'Recalcula el agotado de todas las opciones que usan ese insumo. Llamada '
  'por el trigger de inventory_movements.';

create or replace function public.fn_trigger_recompute_modifier_availability()
returns trigger
language plpgsql
as $$
begin
  perform public.fn_recompute_modifiers_availability(new.item_id);
  return new;
end;
$$;

-- Trigger PROPIO, aparte del de productos (20260516_0015): así no hay que
-- reescribir aquella función, que en la base viva puede diverger del repo.
drop trigger if exists trg_movements_recompute_modifier_availability
  on public.inventory_movements;
create trigger trg_movements_recompute_modifier_availability
  after insert on public.inventory_movements
  for each row
  execute function public.fn_trigger_recompute_modifier_availability();

grant execute on function public.fn_recompute_modifier_availability(uuid)
  to authenticated, service_role;
grant execute on function public.fn_recompute_modifiers_availability(uuid)
  to authenticated, service_role;

-- Backfill: deja el estado correcto de entrada (hoy no hay líneas, así que no
-- toca nada; queda por si se aplica después de haber configurado insumos).
do $$
declare
  v_modifier record;
begin
  for v_modifier in
    select distinct mi.modifier_id as id from public.modifier_ingredients mi
  loop
    perform public.fn_recompute_modifier_availability(v_modifier.id);
  end loop;
end $$;

commit;
