-- =============================================================================
-- Salidas / Mermas con MOTIVO de catálogo.
--
-- ANTES: la pantalla "Salidas / Mermas" registraba `waste` con un texto libre
--   ("Motivo / notas", opcional) y nada más. Sin causa estructurada no hay
--   reporte de mermas por vencimiento, rotura, limpieza, etc.; y el ajuste de
--   Insumos, que sí pide motivo, no sirve para esto porque FIJA el stock a un
--   número (`fn_inventory_adjust` calcula contado − actual): una venta que
--   entre entre que se abre el diálogo y se guarda quedaría pisada.
--
-- ENTREGA: `fn_inventory_record_outflow` — una salida RELATIVA (resta la
--   cantidad, como hoy) que además deja `reason_code` en el movimiento.
--   · Reusa `fn_inventory_record_movement` (mismo camino de inserción,
--     mismos triggers, mismo control de rol y de bodega).
--   · Solo acepta los motivos que son SALIDA: breakage, expiration, cleaning,
--     theft, donation. Un conteo o una corrección no son una merma.
--   · Si el CHECK de la BD todavía no conoce el motivo ('cleaning' llega con
--     20260923_0001), la salida se registra igual y el motivo queda en la
--     nota: un CHECK desactualizado no puede impedir registrar una pérdida.
--
-- La app llama esta función y, si no existe todavía (PGRST202), cae al
-- `fn_inventory_record_movement` de siempre con el motivo en la nota.
--
-- ANTES DE APLICAR (la BD viva puede diverger del repo):
--   select pg_get_functiondef(
--     'public.fn_inventory_record_movement(uuid,uuid,uuid,public.movement_type,numeric,numeric,uuid,text,text)'::regprocedure
--   );
--   Debe devolver jsonb con la clave 'id'.
--
-- IDEMPOTENTE: sí (`create or replace`). REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

create or replace function public.fn_inventory_record_outflow(
  p_business_id uuid,
  p_warehouse_id uuid,
  p_item_id uuid,
  p_quantity numeric,
  p_reason_code text,
  p_notes text default null,
  p_cost_per_unit numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_movement_id uuid;
begin
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'INVALID_QUANTITY';
  end if;
  if p_reason_code is null
     or p_reason_code not in (
       'breakage', 'expiration', 'cleaning', 'theft', 'donation'
     ) then
    raise exception 'INVALID_OUTFLOW_REASON: %', coalesce(p_reason_code, 'null');
  end if;

  -- Rol, bodega activa e insumo del negocio los valida la función base.
  v_result := public.fn_inventory_record_movement(
    p_business_id    => p_business_id,
    p_warehouse_id   => p_warehouse_id,
    p_item_id        => p_item_id,
    p_movement_type  => 'waste'::public.movement_type,
    p_quantity       => p_quantity,
    p_cost_per_unit  => p_cost_per_unit,
    p_reference_type => 'manual_outflow',
    p_notes          => p_notes
  );

  v_movement_id := nullif(v_result->>'id', '')::uuid;
  if v_movement_id is not null then
    begin
      update public.inventory_movements
         set reason_code = p_reason_code
       where id = v_movement_id;
    exception when check_violation then
      -- CHECK viejo (sin 'cleaning'): la salida ya quedó; el motivo viaja en
      -- la nota que armó la app.
      null;
    end;
  end if;

  return v_result || jsonb_build_object('reason_code', p_reason_code);
end;
$$;

revoke all on function public.fn_inventory_record_outflow(
  uuid, uuid, uuid, numeric, text, text, numeric
) from public;
grant execute on function public.fn_inventory_record_outflow(
  uuid, uuid, uuid, numeric, text, text, numeric
) to authenticated;

notify pgrst, 'reload schema';

commit;
