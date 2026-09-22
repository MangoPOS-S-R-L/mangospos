-- =============================================================================
-- 20260920_0002 — Motivo del borrado con MERMA o DEVOLUCIÓN al inventario
-- =============================================================================
--
-- EL PROBLEMA (medido en El Prodigio, 19-20 sep):
--   Al borrar un producto YA ENVIADO a cocina, el trigger de inventario
--   (20260517_0002) siempre devuelve el stock: mete "Devolución por
--   cancelación/edición" y el sistema queda diciendo que la botella está.
--   Si el bar ya la sirvió, esa botella no está, y la diferencia aparece
--   semanas después en el conteo como merma sin dueño.
--
-- CÓMO LO RESUELVEN LOS POS GRANDES (Toast, Aloha, Micros):
--   No le preguntan al cajero un sí/no suelto: le dan una LISTA CORTA DE
--   MOTIVOS, y cada motivo trae marcado de antemano si descuenta inventario
--   (merma) o si lo devuelve. El dueño decide una vez, en frío; el reporte
--   agrupa por motivo, que es como se revisa esto a diario.
--
-- QUÉ HACE ESTA MIGRACIÓN:
--   1. `order_item_removal_reasons`: el catálogo por negocio, con 5 motivos
--      sembrados. Mismo patrón que `cash_transaction_reasons`.
--   2. `order_item_removals` gana `reason_code`, `is_waste` y `waste_booked`.
--   3. `fn_book_removal_waste`: cuando el borrado es MERMA, mete un
--      movimiento `waste` que cancela la devolución. Neto: el stock queda
--      consumido y la salida queda visible con su costo.
--   4. `fn_note_order_item_removal` (ya existía) ahora recibe el motivo y la
--      marca de merma, y dispara el punto 3.
--
-- POR QUÉ NO SE APAGA EL TRIGGER QUE DEVUELVE:
--   `consume_inventory_from_order` RECALCULA el consumo de la orden cada vez
--   que se la toca y es idempotente: si no devolviera aquí, devolvería en la
--   siguiente edición de esa cuenta. Meter la merma como movimiento propio es
--   estable, y además deja el rastro de POR QUÉ salió.
--
-- LÍMITE CONOCIDO (a propósito, v1): la merma expande RECETA y PRODUCTO
--   TERMINADO con enlace directo (`menu_items.inventory_item_id`), que es lo
--   que cubre botellas y platos. NO expande componentes de combo ni insumos
--   de modificadores. Y solo descuenta si hay evidencia de que esa orden
--   devolvió ese insumo: sin devolución no hay nada que cancelar y no se
--   toca el stock.
--
-- IDEMPOTENTE. ROLLBACK: 20260920_0002_removal_reasons_and_waste_ROLLBACK.sql
-- Requiere 20260919_0002 (order_item_removals).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Catálogo de motivos
-- ---------------------------------------------------------------------------
create table if not exists public.order_item_removal_reasons (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  code        text not null,
  label       text not null,
  -- true  = MERMA: el producto salió y no vuelve al inventario.
  -- false = se devuelve al inventario (no llegó a prepararse).
  is_waste    boolean not null default false,
  is_active   boolean not null default true,
  position    integer not null default 0,
  created_at  timestamptz not null default now(),
  unique (business_id, code)
);

alter table public.order_item_removal_reasons enable row level security;

drop policy if exists order_item_removal_reasons_select
  on public.order_item_removal_reasons;
create policy order_item_removal_reasons_select
  on public.order_item_removal_reasons
  for select to authenticated
  using (business_id in (select public.current_user_business_ids()));

grant select on public.order_item_removal_reasons to authenticated;

-- Los 5 de arranque, para cada negocio. `on conflict do nothing` los deja
-- intactos si ya se editaron.
insert into public.order_item_removal_reasons
  (business_id, code, label, is_waste, position)
select b.id, v.code, v.label, v.is_waste, v.position
from public.businesses b
cross join (values
  ('typo',      'Error de digitación',        false, 1),
  ('changed',   'El cliente cambió de opinión', false, 2),
  ('table',     'Se cambió de mesa',          false, 3),
  ('prepared',  'Ya preparado, se botó',      true,  4),
  ('damaged',   'Producto en mal estado',     true,  5)
) as v(code, label, is_waste, position)
on conflict (business_id, code) do nothing;

comment on table public.order_item_removal_reasons is
  'Motivos para quitar un producto de la cuenta (20260920_0002). `is_waste` '
  'decide si el inventario se descuenta (merma) o se devuelve.';

-- ---------------------------------------------------------------------------
-- 2. El registro guarda el motivo elegido y qué se hizo con el inventario
-- ---------------------------------------------------------------------------
alter table public.order_item_removals
  add column if not exists reason_code text;
alter table public.order_item_removals
  add column if not exists is_waste boolean;
alter table public.order_item_removals
  add column if not exists waste_booked boolean not null default false;

comment on column public.order_item_removals.is_waste is
  'true = el producto salió y NO volvió al inventario (merma). false = se '
  'devolvió. null = la app no lo indicó (build viejo).';

-- ---------------------------------------------------------------------------
-- 3. La merma: cancela la devolución que hizo el trigger
-- ---------------------------------------------------------------------------
create or replace function public.fn_book_removal_waste(p_removal_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r       public.order_item_removals%rowtype;
  v_count integer := 0;
begin
  select * into r
  from public.order_item_removals
  where id = p_removal_id;

  if not found or coalesce(r.waste_booked, false) or r.product_id is null then
    return 0;
  end if;

  -- Lo que hay que sacar = receta o enlace directo del producto × unidades
  -- quitadas, SOLO donde esta orden devolvió ese insumo (si no devolvió, no
  -- hay nada que cancelar y no se toca el stock).
  with esperado as (
    -- (a) Producto con receta.
    select ri.inventory_item_id,
           ri.quantity * r.quantity as qty
    from public.recipes rec
    join public.recipe_ingredients ri on ri.recipe_id = rec.id
    where rec.menu_item_id = r.product_id
      and ri.inventory_item_id is not null
    union all
    -- (b) Producto terminado con enlace directo y sin receta (las botellas).
    select mi.inventory_item_id, r.quantity
    from public.menu_items mi
    where mi.id = r.product_id
      and mi.inventory_item_id is not null
      and not exists (
        select 1 from public.recipes rec2 where rec2.menu_item_id = mi.id
      )
  ),
  agrupado as (
    select inventory_item_id, sum(qty) as qty
    from esperado
    where qty > 0
    group by inventory_item_id
  ),
  -- La devolución que dejó el trigger para esta orden: de ahí salen la
  -- bodega y el costo, para que la merma golpee exactamente donde volvió.
  devuelto as (
    select distinct on (im.item_id)
      im.item_id, im.warehouse_id, im.cost_per_unit
    from public.inventory_movements im
    where im.reference_id = r.order_id
      and im.reference_type = 'order'
      and im.movement_type = 'sale'
      and im.quantity > 0
      and im.created_at >= r.removed_at - interval '5 minutes'
      and im.created_at <= r.removed_at + interval '30 minutes'
    order by im.item_id, im.created_at desc
  )
  insert into public.inventory_movements (
    business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_id, reference_type, notes
  )
  select
    r.business_id, d.warehouse_id, a.inventory_item_id, 'waste',
    -a.qty, d.cost_per_unit, r.order_id, 'order_item_removal',
    'Merma: ' || coalesce(nullif(trim(r.reason), ''), 'producto quitado')
      || ' (' || coalesce(r.product_name, 'producto') || ')'
  from agrupado a
  join devuelto d on d.item_id = a.inventory_item_id;

  get diagnostics v_count = row_count;

  -- Solo se marca cuando de verdad se descontó. Si no se descontó nada
  -- (producto sin inventario, o la devolución todavía no estaba escrita),
  -- queda en false y un reintento puede hacerlo.
  if v_count > 0 then
    update public.order_item_removals
       set waste_booked = true
     where id = r.id;
  end if;

  return v_count;
end;
$$;

comment on function public.fn_book_removal_waste(uuid) is
  'Convierte en MERMA un producto quitado de la cuenta: mete el movimiento '
  'waste que cancela la devolución del trigger de inventario. Idempotente.';

-- ---------------------------------------------------------------------------
-- 4. La app anota motivo + merma en la misma llamada
-- ---------------------------------------------------------------------------
-- Se dropea la firma de 3 argumentos: con las dos vivas, PostgREST no sabría
-- cuál llamar (PGRST203).
drop function if exists public.fn_note_order_item_removal(uuid, text, uuid);
drop function if exists public.fn_note_order_item_removal(uuid, text, uuid, text, boolean);

create function public.fn_note_order_item_removal(
  p_item_id     uuid,
  p_reason      text    default null,
  p_employee_id uuid    default null,
  p_reason_code text    default null,
  p_is_waste    boolean default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id       uuid;
  v_business uuid;
begin
  select r.id, r.business_id
    into v_id, v_business
  from public.order_item_removals r
  where r.item_id = p_item_id
    and r.business_id in (select public.current_user_business_ids())
    -- La cola offline puede borrar horas después; no más de 3 días.
    and r.removed_at > now() - interval '3 days'
  order by r.removed_at desc
  limit 1;

  if v_id is null then
    return false;
  end if;

  -- Solo completa lo que falta: no pisa un motivo ya escrito.
  update public.order_item_removals r
     set reason = coalesce(
           r.reason,
           nullif(left(trim(coalesce(p_reason, '')), 500), '')
         ),
         reason_code = coalesce(r.reason_code, nullif(trim(coalesce(p_reason_code, '')), '')),
         is_waste = coalesce(r.is_waste, p_is_waste),
         reason_employee_id = coalesce(
           r.reason_employee_id,
           (select e.id from public.employees e
             where e.id = p_employee_id and e.business_id = v_business)
         )
   where r.id = v_id;

  -- Merma: el stock NO vuelve.
  if coalesce(p_is_waste, false) then
    perform public.fn_book_removal_waste(v_id);
  end if;

  return true;
end;
$$;

grant execute on function
  public.fn_note_order_item_removal(uuid, text, uuid, text, boolean)
  to authenticated;
grant execute on function public.fn_book_removal_waste(uuid) to authenticated;

notify pgrst, 'reload schema';

commit;

-- =============================================================================
-- VERIFICACIÓN (después de aplicar; UNA sola fila):
--
--   select
--     (select count(*) from public.order_item_removal_reasons)          as motivos,
--     (select count(*) from public.order_item_removal_reasons
--       where is_waste)                                                 as de_merma,
--     (select count(*) from information_schema.columns
--       where table_name = 'order_item_removals'
--         and column_name in ('reason_code', 'is_waste', 'waste_booked')) as columnas,
--     (select count(*) from pg_proc where proname = 'fn_book_removal_waste') as fn;
--
--   Esperado: motivos = 5 × negocios, de_merma = 2 × negocios,
--             columnas = 3, fn = 1.
-- =============================================================================
