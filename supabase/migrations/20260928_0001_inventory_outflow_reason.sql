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
-- REVISIÓN 2026-09-30 (auditoría de Salidas/Mermas; la migración aún no se
-- había aplicado, por eso se corrige aquí mismo y no en otra):
--   · p_reference_id = llave de la operación que genera la app (una por
--     diálogo). Si la salida ya se registró con esa llave, devuelve la misma
--     sin volver a restar. Antes, una respuesta perdida (timeout de 30 s con
--     el guardado ya hecho) + el reintento restaban DOS veces.
--   · Costo: si la app no lo manda, se toma el costo del insumo. Antes quedaba
--     NULL y el kardex valoraba la merma en 0 mientras el conduce impreso sí
--     mostraba costo.
--   · Se quita la firma vieja de 7 parámetros (por si ya se había aplicado):
--     dos funciones con el mismo nombre confunden a PostgREST.
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

drop function if exists public.fn_inventory_record_outflow(
  uuid, uuid, uuid, numeric, text, text, numeric
);

create or replace function public.fn_inventory_record_outflow(
  p_business_id uuid,
  p_warehouse_id uuid,
  p_item_id uuid,
  p_quantity numeric,
  p_reason_code text,
  p_notes text default null,
  p_cost_per_unit numeric default null,
  p_reference_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_movement_id uuid;
  v_existing public.inventory_movements;
  v_item_cost numeric;
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

  -- Reintento de la MISMA salida (respuesta perdida, cola offline): se
  -- devuelve la que ya quedó. El candado serializa dos envíos simultáneos.
  if p_reference_id is not null then
    perform pg_advisory_xact_lock(
      hashtextextended('manual_outflow:' || p_reference_id::text, 0));
    select * into v_existing
      from public.inventory_movements m
     where m.business_id = p_business_id
       and m.item_id = p_item_id
       and m.reference_type = 'manual_outflow'
       and m.reference_id = p_reference_id
     limit 1;
    if found then
      return jsonb_build_object(
        'id', v_existing.id,
        'business_id', v_existing.business_id,
        'warehouse_id', v_existing.warehouse_id,
        'item_id', v_existing.item_id,
        'movement_type', v_existing.movement_type,
        'quantity', v_existing.quantity,
        'created_at', v_existing.created_at,
        'reason_code', p_reason_code,
        'replayed', true
      );
    end if;
  end if;

  -- Rol, bodega activa e insumo del negocio los valida la función base.
  v_result := public.fn_inventory_record_movement(
    p_business_id    => p_business_id,
    p_warehouse_id   => p_warehouse_id,
    p_item_id        => p_item_id,
    p_movement_type  => 'waste'::public.movement_type,
    p_quantity       => p_quantity,
    p_cost_per_unit  => p_cost_per_unit,
    p_reference_id   => p_reference_id,
    p_reference_type => 'manual_outflow',
    p_notes          => p_notes
  );

  v_movement_id := nullif(v_result->>'id', '')::uuid;
  if v_movement_id is not null then
    -- Sin costo de la app: el del insumo, para que el kardex valore la merma.
    select ii.cost into v_item_cost
      from public.inventory_items ii
     where ii.id = p_item_id and ii.business_id = p_business_id;
    update public.inventory_movements
       set cost_per_unit = v_item_cost
     where id = v_movement_id
       and cost_per_unit is null
       and v_item_cost is not null;

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

  return v_result || jsonb_build_object('reason_code', p_reason_code, 'replayed', false);
end;
$$;

revoke all on function public.fn_inventory_record_outflow(
  uuid, uuid, uuid, numeric, text, text, numeric, uuid
) from public;
revoke all on function public.fn_inventory_record_outflow(
  uuid, uuid, uuid, numeric, text, text, numeric, uuid
) from anon;
grant execute on function public.fn_inventory_record_outflow(
  uuid, uuid, uuid, numeric, text, text, numeric, uuid
) to authenticated;

notify pgrst, 'reload schema';

commit;
