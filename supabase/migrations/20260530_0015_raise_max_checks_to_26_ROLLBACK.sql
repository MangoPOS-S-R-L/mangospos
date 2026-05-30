-- Rollback de 20260530_0015. Vuelve el límite de cuentas por orden a 5.
-- ADVERTENCIA: si ya existen órdenes con más de 5 cuentas creadas bajo el
-- tope nuevo, esas filas NO se borran; solo se vuelve a bloquear la creación
-- de nuevas cuentas por encima de 5.

begin;

create or replace function public.fn_check_max_checks()
returns trigger
language plpgsql
as $$
begin
  -- Fast fail for impossible positions.
  if coalesce(new.position, 1) > 5 then
    raise exception 'Max 5 checks per order';
  end if;

  -- Stop as soon as a 5th row exists.
  if exists (
    select 1
    from public.order_checks
    where order_id = new.order_id
    order by position
    offset 4
    limit 1
  ) then
    raise exception 'Max 5 checks per order';
  end if;

  return new;
end;
$$;

create or replace function public.fn_create_split_bill(
  p_order_id uuid,
  p_number_of_checks integer
)
returns setof public.order_checks
language plpgsql
security definer
set search_path=public
as $$
declare
  v_target integer;
  v_existing integer;
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  v_target := greatest(1, least(coalesce(p_number_of_checks, 1), 5));

  -- Serialize split operations per order.
  perform pg_advisory_xact_lock(hashtextextended(p_order_id::text, 1));

  perform 1
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  select count(*)::integer
    into v_existing
  from public.order_checks
  where order_id = p_order_id;

  if v_existing < v_target then
    insert into public.order_checks (order_id, label, position, is_closed)
    select
      p_order_id,
      case when gs = 1 then 'C1' else 'Cuenta ' || gs::text end,
      gs,
      false
    from generate_series(v_existing + 1, v_target) as gs
    on conflict (order_id, position) do nothing;
  end if;

  return query
  select *
  from public.order_checks
  where order_id = p_order_id
  order by position;
end;
$$;

grant execute on function public.fn_create_split_bill(uuid, integer) to authenticated;

commit;
