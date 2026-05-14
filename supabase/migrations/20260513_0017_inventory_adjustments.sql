-- =============================================================================
-- Sprint Inventario V1.1 — Fase A: Ajustes con razón estructurada.
--
-- PROBLEMA:
--   `fn_inventory_record_movement` ya permite movimientos `adjustment`,
--   pero la "razón" del ajuste vive solo en `notes` (texto libre,
--   opcional). Esto rompe auditoría: no podemos reportar "mermas por
--   vencimiento del mes X" ni distinguir rotura accidental de robo.
--
-- ENTREGA:
--   1. Columna `inventory_movements.reason_code` con CHECK que enumera
--      las razones válidas de ajuste:
--        - `physical_count`  : conteo físico (cuadrar con realidad)
--        - `breakage`        : rotura / dañado
--        - `expiration`      : vencido
--        - `theft`           : robo / faltante sospechoso
--        - `donation`        : donación / regalo de cortesía
--        - `correction`      : corrección de error operativo
--        - `other`           : otro (con notes obligatorias)
--      Nullable para movimientos NO de ajuste (sale, purchase, etc.)
--   2. RPC `fn_inventory_adjust` que envuelve `fn_inventory_record_movement`
--      con validación:
--        - reason_code obligatorio y dentro del catálogo.
--        - Si `reason_code = 'other'`, notes obligatorias.
--        - Quantity = (counted - actual) calculado server-side para
--          evitar race conditions con stock cache.
--   3. Vista `v_inventory_adjustments_log` para reportes.
--
-- BACKWARDS-COMPATIBLE:
--   - reason_code es nullable → movimientos legacy (sales, purchases)
--     sin razón siguen funcionando.
--   - El RPC viejo (`fn_inventory_record_movement`) sigue activo y sin
--     cambios. La UI nueva llamará al RPC nuevo.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Columna reason_code en inventory_movements.
-- ---------------------------------------------------------------------------

alter table public.inventory_movements
  add column if not exists reason_code text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'inventory_movements_reason_code_check'
      and conrelid = 'public.inventory_movements'::regclass
  ) then
    alter table public.inventory_movements
      add constraint inventory_movements_reason_code_check
      check (
        reason_code is null
        or reason_code in (
          'physical_count',
          'breakage',
          'expiration',
          'theft',
          'donation',
          'correction',
          'other'
        )
      );
  end if;
end$$;

comment on column public.inventory_movements.reason_code is
  'Razón estructurada del ajuste (solo aplica a movimientos tipo '
  'adjustment / adjustment_in / adjustment_out). Permite reportes '
  'por causa: mermas por vencimiento, rotura, robo, etc.';

create index if not exists idx_inventory_movements_reason
  on public.inventory_movements (reason_code, business_id, created_at desc)
  where reason_code is not null;

-- ---------------------------------------------------------------------------
-- 2. RPC `fn_inventory_adjust` — wrapper validado.
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_adjust(
  p_business_id uuid,
  p_warehouse_id uuid,
  p_item_id uuid,
  p_counted_quantity numeric,
  p_reason_code text,
  p_notes text default null,
  p_cost_per_unit numeric default null
)
returns public.inventory_movements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current_stock numeric := 0;
  v_delta numeric;
  v_role text;
  v_movement public.inventory_movements;
  v_ref_uuid uuid;
begin
  -- Validaciones de input.
  if p_business_id is null or p_warehouse_id is null or p_item_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  if p_counted_quantity is null or p_counted_quantity < 0 then
    raise exception 'INVALID_COUNTED_QUANTITY';
  end if;
  if p_reason_code is null or btrim(p_reason_code) = '' then
    raise exception 'REASON_REQUIRED';
  end if;
  if p_reason_code = 'other' and (p_notes is null or btrim(p_notes) = '') then
    raise exception 'NOTES_REQUIRED_FOR_OTHER';
  end if;

  -- Solo owner / admin / manager pueden ajustar.
  v_role := public.user_business_role(auth.uid(), p_business_id);
  if v_role not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE: % no puede ajustar inventario', v_role;
  end if;

  -- Obtener stock actual con lock para evitar race con ventas concurrentes.
  -- inventory_stock se identifica por (warehouse_id, item_id) — no tiene
  -- business_id propio porque la bodega ya pertenece al business.
  select coalesce(quantity, 0) into v_current_stock
  from public.inventory_stock
  where warehouse_id = p_warehouse_id
    and item_id = p_item_id
  for update;

  v_delta := p_counted_quantity - v_current_stock;
  if v_delta = 0 then
    raise exception 'NO_CHANGE: stock contado igual al actual (%)', v_current_stock;
  end if;

  -- reference_id como UUID nuevo para agrupar el ajuste como evento.
  v_ref_uuid := gen_random_uuid();

  -- Insertar movimiento. Usamos el RPC existente para mantener un solo
  -- path de inserción (que dispara triggers correctamente). Named params
  -- para evitar bugs de orden (signature real: business_id, warehouse_id,
  -- item_id, movement_type, quantity, cost_per_unit, reference_id,
  -- reference_type, notes).
  perform public.fn_inventory_record_movement(
    p_business_id    => p_business_id,
    p_warehouse_id   => p_warehouse_id,
    p_item_id        => p_item_id,
    p_movement_type  => 'adjustment'::public.movement_type,
    p_quantity       => v_delta,
    p_cost_per_unit  => p_cost_per_unit,
    p_reference_id   => v_ref_uuid,
    p_reference_type => 'stock_adjustment',
    p_notes          => p_notes
  );

  -- Recuperar el movimiento recién creado para devolverlo + setear reason_code.
  select * into v_movement
  from public.inventory_movements
  where reference_id = v_ref_uuid
  order by created_at desc
  limit 1;

  -- Actualizar reason_code (el RPC base no lo soporta directamente).
  update public.inventory_movements
  set reason_code = p_reason_code
  where id = v_movement.id
  returning * into v_movement;

  return v_movement;
end;
$$;

grant execute on function public.fn_inventory_adjust(uuid, uuid, uuid, numeric, text, text, numeric)
  to authenticated;

comment on function public.fn_inventory_adjust(uuid, uuid, uuid, numeric, text, text, numeric) is
  'Ajuste de inventario con razón obligatoria. Calcula delta server-side '
  'para evitar race conditions. Valida rol manager+. Notes obligatorias '
  'si reason_code = other.';

-- ---------------------------------------------------------------------------
-- 3. Vista de log de ajustes para reportes.
-- ---------------------------------------------------------------------------

create or replace view public.v_inventory_adjustments_log as
select
  im.id              as movement_id,
  im.business_id,
  im.warehouse_id,
  w.name             as warehouse_name,
  im.item_id,
  ii.name            as item_name,
  ii.unit            as item_unit,
  im.movement_type,
  im.quantity,
  im.cost_per_unit,
  im.reason_code,
  im.notes,
  im.created_by,
  p.full_name        as created_by_name,
  im.created_at,
  im.reference_id,
  im.reference_type
from public.inventory_movements im
left join public.warehouses w on w.id = im.warehouse_id
left join public.inventory_items ii on ii.id = im.item_id
left join public.profiles p on p.id = im.created_by
where im.movement_type::text = 'adjustment'
  and im.reason_code is not null;

comment on view public.v_inventory_adjustments_log is
  'Log de ajustes de inventario con razón estructurada. Consumido '
  'por el reporte de mermas / conteos físicos.';

commit;
