-- =====================================================================
-- Fix: fn_open_manual_or_quick ignoraba la sucursal activa cuando un
-- Owner pertenece a varios negocios.
-- =====================================================================
-- Causa raíz:
--   La función resolvía `v_business_id` con:
--     select business_id from user_businesses
--     where user_id = v_user_id order by created_at limit 1;
--   Para un Owner multi-tenant esto devuelve SIEMPRE el negocio mas
--   antiguo, ignorando el `activeBusinessId` del cliente. La orden
--   Manual/Quick se crea entonces en otro tenant y el frontend la
--   rechaza despues en `_loadOrderDetail` via
--   `_assertOrderInBusinessScope`, mostrando el toast
--   "Esta orden no está disponible en este negocio".
--
-- Fix:
--   Agregamos `p_business_id uuid default null`. Si viene, se valida
--   pertenencia (anti tenant-injection) y se usa. Si no viene, se
--   conserva el comportamiento legacy para no romper clientes
--   no actualizados.
--
-- Compat:
--   Postgres no permite cambiar la firma con `create or replace`,
--   asi que dropeamos y recreamos. Recreamos los grants con la nueva
--   firma. La firma legacy queda eliminada — todos los callers del
--   repo (sales_repository.openManualOrQuick y
--   offline_pos_service._recreateRemoteOrder) se actualizan en el
--   mismo PR.
-- =====================================================================

drop function if exists public.fn_open_manual_or_quick(public.order_origin, uuid, integer);

create or replace function public.fn_open_manual_or_quick(
  p_origin public.order_origin,
  p_user_id uuid,
  p_people_count integer default 1,
  p_business_id uuid default null
) returns jsonb
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_user_id uuid := coalesce(p_user_id, auth.uid());
  v_business_id uuid;
  v_belongs boolean;
  v_table_id uuid;
  v_session_id uuid;
  v_order_id uuid;
  v_existing_session uuid;
  v_open_order_id uuid;
begin
  if v_user_id is null then
    raise exception 'fn_open_manual_or_quick: user id is required';
  end if;

  if p_business_id is not null then
    -- Validar pertenencia. Sin esto un Owner podría abrir órdenes en
    -- cualquier tenant pasando un business_id arbitrario.
    select exists(
      select 1
      from public.user_businesses
      where user_id = v_user_id
        and business_id = p_business_id
    ) into v_belongs;

    if not v_belongs then
      raise exception 'fn_open_manual_or_quick: user % does not belong to business %',
        v_user_id, p_business_id;
    end if;

    v_business_id := p_business_id;
  else
    -- Fallback legacy: usado por clientes que no fueron actualizados
    -- todavía. Elige el negocio más antiguo del usuario. Para usuarios
    -- single-tenant es correcto; para Owners multi-tenant es exactamente
    -- el comportamiento defectuoso que estamos arreglando — por eso el
    -- cliente debe pasar siempre p_business_id.
    select business_id
      into v_business_id
    from public.user_businesses
    where user_id = v_user_id
    order by created_at
    limit 1;

    if v_business_id is null then
      select bid
        into v_business_id
      from public.current_user_business_ids() as bid
      limit 1;
    end if;
  end if;

  if v_business_id is null then
    raise exception 'fn_open_manual_or_quick: no business found for user %', v_user_id;
  end if;

  v_table_id := public.fn_get_or_create_virtual_table(v_business_id, p_origin);

  -- Cierra cualquier sesion abierta previa en esta mesa virtual.
  select id
    into v_existing_session
  from public.table_sessions
  where table_id = v_table_id
    and closed_at is null
  limit 1;

  if v_existing_session is not null then
    for v_open_order_id in
      select id
      from public.orders
      where session_id = v_existing_session
        and status_ext = 'open'
    loop
      perform public.fn_close_order_and_table(v_open_order_id, 'void');
    end loop;

    update public.table_sessions
    set closed_at = now()
    where id = v_existing_session;
  end if;

  insert into public.table_sessions (table_id, opened_by, origin, waiter_user_id, people_count)
  values (v_table_id, v_user_id, p_origin, v_user_id, greatest(1, p_people_count))
  returning id into v_session_id;

  insert into public.orders (session_id, status_ext, subtotal, discounts, tax, total, total_amount)
  values (v_session_id, 'open', 0, 0, 0, 0, 0)
  returning id into v_order_id;

  insert into public.order_checks (order_id, label, position)
  values (v_order_id, 'C1', 1);

  return jsonb_build_object(
    'session_id', v_session_id,
    'order_id', v_order_id,
    'business_id', v_business_id
  );
end;
$$;

alter function public.fn_open_manual_or_quick(
  public.order_origin, uuid, integer, uuid
) owner to postgres;

grant execute on function public.fn_open_manual_or_quick(
  public.order_origin, uuid, integer, uuid
) to authenticated;
grant execute on function public.fn_open_manual_or_quick(
  public.order_origin, uuid, integer, uuid
) to service_role;

notify pgrst, 'reload schema';
