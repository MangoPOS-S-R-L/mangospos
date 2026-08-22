-- =============================================================================
-- FIX: ajustar un insumo SIN fila en `inventory_stock` reventaba con
--      INVALID_QUANTITY.
--
-- SÍNTOMA (campo, 2026-08-22, Android):
--   "Ajustar GALLETAS DE COCO MARTIN PEQUEÑA" — Stock actual 0.00, contado 10,
--   Diferencia +10.00, motivo Conteo físico → al guardar:
--   PostgrestException(message: INVALID_QUANTITY, code: P0001).
--
-- CAUSA:
--   En `fn_inventory_adjust` el stock actual se lee así:
--
--     select coalesce(quantity, 0) into v_current_stock
--     from public.inventory_stock
--     where warehouse_id = ... and item_id = ...;
--
--   El `coalesce` protege contra una columna nula, NO contra CERO FILAS. En
--   PL/pgSQL un `select ... into` que no encuentra filas asigna NULL a la
--   variable. Un insumo que nunca tuvo movimiento en esa bodega no tiene fila
--   en `inventory_stock`, así que:
--
--     v_current_stock := NULL
--     v_delta         := 10 - NULL = NULL
--     if v_delta = 0  -> NULL, o sea FALSO: no salta el NO_CHANGE
--     fn_inventory_record_movement(p_quantity => NULL) -> INVALID_QUANTITY
--
--   Es decir: fallaba justo el caso más común del piso — cargar por primera
--   vez el stock de un insumo nuevo. Con stock previo (fila existente) el
--   ajuste siempre funcionó, por eso no se veía en pruebas.
--
-- ENTREGA:
--   `v_current_stock := coalesce(v_current_stock, 0);` después del select.
--   Sin fila, el stock actual es 0 y el ajuste entra como movimiento +10, que
--   es lo que el trigger `trg_inventory_stock_sync` usa para CREAR la fila.
--   El resto de la función queda idéntica a 20260513_0017.
--
-- ANTES DE APLICAR: la BD viva puede diverger del repo. Verificar con
--   select pg_get_functiondef(
--     'public.fn_inventory_adjust(uuid,uuid,uuid,numeric,text,text,numeric)'::regprocedure
--   );
--   Si el cuerpo no coincide con 20260513_0017, no aplicar a ciegas.
--
-- IDEMPOTENTE: sí (`create or replace`).
-- REVERSIBLE: sí (ver _ROLLBACK, restaura la versión con el bug).
-- =============================================================================

begin;

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

  -- SIN FILA el `into` deja la variable en NULL (el coalesce de arriba sólo
  -- cubre la columna). Un insumo que nunca se movió en esta bodega arranca en
  -- cero, no en NULL: si no, el delta sale NULL y explota más abajo.
  v_current_stock := coalesce(v_current_stock, 0);

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
  'si reason_code = other. Trata "sin fila en inventory_stock" como stock 0 '
  '(antes daba INVALID_QUANTITY al cargar por primera vez un insumo).';

commit;
