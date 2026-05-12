-- ============================================================================
-- Refactor retroactivo de a0bb5c4f-8e57-4347-b088-4080a04e8e1e (v2)
-- ============================================================================
--
-- Estado descubierto al correr v1:
--   - La orden YA TENÍA un check (count=1) con los 2 items adentro.
--   - Pero los 2 payments completed tenían check_id NULL.
--   → Necesitamos un segundo check para que ambos payments puedan coexistir
--     bajo el unique index nuevo.
--
-- Plan:
--   1) Tomar el check existente como C1. Mover Item 1 (Marea Dulce 23:43)
--      al final si no está ya, asegurar que C1 tenga sólo Item 1.
--   2) Crear C2 nuevo. Mover Item 2 (Marea Dulce 01:43) a C2.
--   3) Asignar Payment 1 (625) → C1 (lleva el NCF B0200001856).
--   4) Asignar Payment 2 (550) → C2 (sin NCF — bug separado).
--
-- Idempotente: si ya hay 2 checks con sus payments asignados, no hace nada.
-- ============================================================================

begin;

do $$
declare
  v_order_id uuid := 'a0bb5c4f-8e57-4347-b088-4080a04e8e1e';
  v_item_1_id uuid := '22c6993d-bb5d-44f9-9de1-2d1b1a68d517'; -- @ 23:43
  v_item_2_id uuid := 'd9416a5f-cc06-422b-bde5-937c89111816'; -- @ 01:43
  v_payment_1_id uuid := 'dd584d8d-d85e-48ef-a4a6-280845ad445b'; -- 625
  v_payment_2_id uuid := '18980924-bd8f-4459-8e8e-d4a1f6953cbe'; -- 550
  v_check_1_id uuid;
  v_check_2_id uuid;
  v_existing_check_count int;
begin
  -- Estado actual: ¿cuántos checks tiene la orden?
  select count(*) into v_existing_check_count
  from public.order_checks where order_id = v_order_id;

  if v_existing_check_count = 0 then
    -- No hay checks: creamos los 2.
    insert into public.order_checks (
      order_id, label, position, is_closed,
      subtotal, discounts, tax, total
    )
    values (
      v_order_id, 'C1', 1, true,
      488.28, 0, 87.89, 625
    )
    returning id into v_check_1_id;
  elsif v_existing_check_count = 1 then
    -- Hay 1 check: lo usamos como C1, lo cerramos y le ponemos los totales
    -- aproximados de Item 1.
    select id into v_check_1_id
    from public.order_checks
    where order_id = v_order_id
    limit 1;

    update public.order_checks
    set label = 'C1',
        position = 1,
        is_closed = true,
        subtotal = 488.28,
        discounts = 0,
        tax = 87.89,
        total = 625
    where id = v_check_1_id;
  else
    raise notice 'Order % already has % checks. Verificar manualmente.',
      v_order_id, v_existing_check_count;
    return;
  end if;

  raise notice 'Check 1 (existente o nuevo): %', v_check_1_id;

  -- Crear check 2 si no existe ya (después de la anterior pueden ser 2).
  select count(*) into v_existing_check_count
  from public.order_checks
  where order_id = v_order_id;

  if v_existing_check_count < 2 then
    insert into public.order_checks (
      order_id, label, position, is_closed,
      subtotal, discounts, tax, total
    )
    values (
      v_order_id, 'C2', 2, true,
      429.69, 0, 77.34, 550
    )
    returning id into v_check_2_id;
    raise notice 'Check 2 creado: %', v_check_2_id;
  else
    -- Ya hay 2 checks; tomar el segundo (position=2 o el que no es C1).
    select id into v_check_2_id
    from public.order_checks
    where order_id = v_order_id and id <> v_check_1_id
    limit 1;
    raise notice 'Check 2 ya existía: %', v_check_2_id;
  end if;

  -- Reasignar items
  update public.order_items
  set check_id = v_check_1_id
  where id = v_item_1_id and order_id = v_order_id;

  update public.order_items
  set check_id = v_check_2_id
  where id = v_item_2_id and order_id = v_order_id;

  -- Reasignar payments (siempre, aunque ya tuvieran check_id, sobrescribimos
  -- para garantizar la asignación correcta).
  update public.payments
  set check_id = v_check_1_id
  where id = v_payment_1_id and order_id = v_order_id;

  update public.payments
  set check_id = v_check_2_id
  where id = v_payment_2_id and order_id = v_order_id;

  -- Verificación
  perform 1
  from public.order_items
  where order_id = v_order_id and check_id is null;
  if found then
    raise exception 'Algunos items quedaron sin check_id en %', v_order_id;
  end if;

  perform 1
  from public.payments
  where order_id = v_order_id and status = 'completed' and check_id is null;
  if found then
    raise exception 'Algunos payments completed quedaron sin check_id en %', v_order_id;
  end if;
end$$;

-- Verificación final
select 'order_checks' as t, count(*) as cnt
from public.order_checks where order_id = 'a0bb5c4f-8e57-4347-b088-4080a04e8e1e'
union all
select 'items_with_check', count(*)
from public.order_items
where order_id = 'a0bb5c4f-8e57-4347-b088-4080a04e8e1e' and check_id is not null
union all
select 'payments_completed_with_check', count(*)
from public.payments
where order_id = 'a0bb5c4f-8e57-4347-b088-4080a04e8e1e'
  and status = 'completed'
  and check_id is not null
union all
select 'distinct_check_ids_in_payments', count(distinct check_id)
from public.payments
where order_id = 'a0bb5c4f-8e57-4347-b088-4080a04e8e1e'
  and status = 'completed';
-- Esperado:
--   order_checks                   = 2
--   items_with_check               = 2
--   payments_completed_with_check  = 2
--   distinct_check_ids_in_payments = 2  ← clave para que el unique index pase

commit;
-- O `rollback;` si la verificación da otra cosa.
