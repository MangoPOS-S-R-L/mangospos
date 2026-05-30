-- =============================================================================
-- Migración: raise_max_checks_to_26
--
-- Sube el límite de cuentas por orden de 5 a 26.
--
-- Motivo (sesión 2026-05-30):
-- El cajero necesita dividir una mesa grande en hasta 25 sub-cuentas. Hoy el
-- trigger `fn_check_max_checks` bloquea al llegar a 5 cuentas (C1 principal +
-- 4 sub-cuentas visibles), tirando 'Max 5 checks per order'.
--
-- Nuevo tope: 26 cuentas = C1 (principal/pool) + 25 sub-cuentas (C2..C26).
--
-- Qué cambia:
--   1. fn_check_max_checks  → trigger BEFORE INSERT en order_checks. Antes
--      rechazaba position > 5 y la 6ta fila; ahora position > 26 y la 27ma.
--   2. fn_create_split_bill → cap de creación masiva. Antes least(..., 5),
--      ahora least(..., 26). (Esta función no tiene callers en la app hoy
--      —el modal crea sub-cuentas una por una— pero la subimos por
--      consistencia para que no quede un tope viejo escondido.)
--
-- NO cambia la división "en partes iguales" (fn_split_items_equally), que
-- mantiene su límite propio de 2-4 personas a propósito.
--
-- Nota: el CREATE TRIGGER que ata fn_check_max_checks a order_checks vive en
-- el baseline del esquema; aquí solo redefinimos el cuerpo de la función vía
-- CREATE OR REPLACE, así que el trigger existente toma la nueva lógica sin
-- necesidad de re-crearlo.
-- =============================================================================

begin;

create or replace function public.fn_check_max_checks()
returns trigger
language plpgsql
as $$
begin
  -- Fast fail for impossible positions. 26 = C1 principal + 25 sub-cuentas.
  if coalesce(new.position, 1) > 26 then
    raise exception 'Max 26 checks per order';
  end if;

  -- Stop as soon as a 26th row already exists (this insert would be the 27th).
  if exists (
    select 1
    from public.order_checks
    where order_id = new.order_id
    order by position
    offset 25
    limit 1
  ) then
    raise exception 'Max 26 checks per order';
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

  v_target := greatest(1, least(coalesce(p_number_of_checks, 1), 26));

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
