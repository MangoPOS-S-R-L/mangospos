-- =============================================================================
-- 20260914_0050 — Lease del Hub Local: failover MANUAL sin venta doble (H7)
-- =============================================================================
--
-- Numerada en el rango 0050+ a propósito: el dueño y el asistente trabajan en
-- paralelo el mismo día y los dos empezaban a contar desde 0001, lo que ya
-- provocó dos colisiones de número el 2026-09-07.
--
-- EL PROBLEMA QUE CIERRA
--   Con el Hub replicando su op-log a un respaldo, el siguiente paso es poder
--   PROMOVER ese respaldo cuando el Hub se rompe. Pero este sistema no tiene
--   idempotencia del lado del servidor: ni columnas con el id offline de cada
--   operación, ni parámetros en las RPC de replay (verificado contra el schema).
--   La deduplicación vive en el disco de cada equipo. Si el respaldo se promueve
--   y el Hub viejo VUELVE, los dos suben las mismas operaciones y Supabase las
--   aplica dos veces: venta doble, inventario doble y NCF doble.
--
-- LA SOLUCIÓN: un solo dueño del uplink, decidido en el servidor
--   Una fila por negocio con el equipo que tiene derecho a subir (`device_id`) y
--   una época que sube en cada traspaso. Antes de subir, el equipo confirma que
--   la lease es suya. Como subir exige internet, la lease se consulta justo
--   cuando haría falta — no agrega ninguna dependencia de red nueva.
--
--   - Sin fila: el primero que sube se queda con ella (instalaciones existentes
--     siguen funcionando sin tocar nada).
--   - La fila es de este equipo: puede subir.
--   - La fila es de OTRO equipo: NO sube. Si viene con p_force (el botón
--     "Promover este equipo a Hub"), se la quita y sube la época.
--
--   No vence sola, a propósito: el failover es MANUAL. Un vencimiento
--   automático haría que un corte de Wi-Fi de minutos le pasara el control al
--   respaldo con el Hub vivo — exactamente la partición que esto quiere evitar.
--
-- QUÉ NO TOCA
--   Ninguna función de ventas, pagos ni fiscal. Es una tabla nueva y una RPC
--   nueva; el camino de cobro no cambia. Por eso es seguro frente a la
--   divergencia conocida entre la BD viva y el repo.
-- =============================================================================

begin;

create table if not exists public.hub_leases (
  business_id uuid primary key
    references public.businesses(id) on delete cascade,
  device_id   text        not null,
  epoch       bigint      not null default 1,
  acquired_at timestamptz not null default now(),
  acquired_by uuid
);

comment on table public.hub_leases is
  'Qué equipo tiene derecho a subir el op-log del Hub Local de cada negocio. '
  'Evita que, tras promover un respaldo, dos equipos suban las mismas '
  'operaciones (venta/NCF doble). Solo se toca vía fn_hub_lease_acquire.';

-- Sin policies: nadie la lee ni la escribe directo; solo la RPC security
-- definer, que valida la pertenencia al negocio.
alter table public.hub_leases enable row level security;

create or replace function public.fn_hub_lease_acquire(
  p_business_id uuid,
  p_device_id   text,
  p_force       boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row  public.hub_leases%rowtype;
  v_prev text;
begin
  if p_device_id is null or btrim(p_device_id) = '' then
    raise exception 'device_id requerido' using errcode = '22023';
  end if;

  -- Mismo access check que las RPC de reportes. El alias EXPLÍCITO de columna es
  -- obligatorio: sin él current_user_business_ids() rompe con 42703 para
  -- authenticated (y nunca para service_role, por eso no se ve en pruebas).
  if auth.role() != 'service_role' then
    if not exists (
      select 1 from public.current_user_business_ids() as c(business_id)
      where c.business_id = p_business_id
    ) then
      raise exception 'access denied' using errcode = '42501';
    end if;
  end if;

  -- FOR UPDATE: dos equipos confirmando a la vez tienen que serializarse, o los
  -- dos podrían creer que la lease es suya.
  select * into v_row
    from public.hub_leases
   where business_id = p_business_id
   for update;

  if not found then
    insert into public.hub_leases
      (business_id, device_id, epoch, acquired_at, acquired_by)
    values
      (p_business_id, p_device_id, 1, now(), auth.uid())
    on conflict (business_id) do nothing;

    -- Si otra sesión la creó en el mismo instante, el insert no hizo nada: se
    -- relee y se decide con la fila real.
    select * into v_row
      from public.hub_leases
     where business_id = p_business_id
     for update;
  end if;

  if v_row.device_id = p_device_id then
    return jsonb_build_object(
      'held', true,
      'device_id', v_row.device_id,
      'epoch', v_row.epoch
    );
  end if;

  if p_force then
    v_prev := v_row.device_id;
    update public.hub_leases
       set device_id   = p_device_id,
           epoch       = epoch + 1,
           acquired_at = now(),
           acquired_by = auth.uid()
     where business_id = p_business_id
    returning * into v_row;

    return jsonb_build_object(
      'held', true,
      'device_id', v_row.device_id,
      'epoch', v_row.epoch,
      'taken_from', v_prev
    );
  end if;

  return jsonb_build_object(
    'held', false,
    'device_id', v_row.device_id,
    'epoch', v_row.epoch
  );
end;
$function$;

revoke all on function public.fn_hub_lease_acquire(uuid, text, boolean)
  from public;
grant execute on function public.fn_hub_lease_acquire(uuid, text, boolean)
  to authenticated, service_role;

comment on function public.fn_hub_lease_acquire(uuid, text, boolean) is
  'Confirma o toma la lease del Hub Local. Sin p_force: devuelve held=true si '
  'la lease es de este equipo o no existía (y la crea); held=false si es de '
  'otro. Con p_force (promoción manual): se la queda y sube la época.';

commit;
