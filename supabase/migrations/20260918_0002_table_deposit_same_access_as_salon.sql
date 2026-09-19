-- =============================================================================
-- 20260918_0002 — El saldo de mesa se ve con el MISMO acceso que el salón
-- =============================================================================
--
-- OJO — ESTO ES PREVENTIVO, NO ES LA CAUSA DEL REPORTE DEL 2026-09-18:
--   El reporte fue "la cajera no ve el abono desde el salón". Pero esa cajera
--   SÍ cobraba contra el saldo, y el cobro usa el mismo filtro de acceso que
--   el badge: su acceso en BD estaba bien. La causa real estaba en la app (el
--   saldo del salón se cacheaba toda la sesión, y la vista de plano no tenía
--   badge). Esta migración cierra otro caso, real pero distinto: usuarios
--   vinculados al negocio SOLO por `memberships`. Opcional.
--
-- CASO QUE CUBRE:
--   Un usuario vinculado solo por `memberships` ve las mesas pero no el saldo,
--   ni en el salón ni al cobrar (no le aparece "Saldo mesa").
--
-- CAUSA:
--   La 0007 filtró todas las lecturas del abono con
--   `user_has_business_access()`, que solo mira `user_businesses` y
--   `businesses.owner_id`. El salón (mesas, zonas, órdenes) filtra con
--   `current_user_business_ids()`, que además acepta `memberships`
--   (20260708_0001). Una cajera vinculada al negocio solo por `memberships`
--   ve las mesas y cobra normal, pero el servidor le devuelve CERO saldos — y
--   la app lo lee como "esta mesa no tiene abono", sin error. El dueño pasa
--   por `owner_id` y por eso a él sí le salía.
--
--   Reproducido en local: cajera solo en memberships → `ve_las_mesas = true`,
--   `fn_table_deposit_balances` = 0 filas, `fn_table_deposit_balance_for_order`
--   = null.
--
-- FIX:
--   Toda LECTURA del abono usa el mismo criterio que el salón: quien ve las
--   mesas ve su saldo. Las ESCRITURAS no se tocan: cargar/devolver/mover sigue
--   siendo solo dueño/admin (`fn_table_deposit_can_manage`, 0008).
--
--   NO se cambia `user_has_business_access()`: la usan ~95 lugares y
--   ampliarla abriría acceso en todo el sistema.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. ¿Puede esta persona VER el saldo? = ¿puede ver las mesas?
-- ---------------------------------------------------------------------------

create or replace function public.fn_table_deposit_can_view(
  p_business_id uuid
) returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select p_business_id is not null
     and p_business_id in (select public.current_user_business_ids());
$$;

comment on function public.fn_table_deposit_can_view(uuid) is
  'Quien ve las mesas ve su saldo: mismo criterio que el RLS del salón '
  '(current_user_business_ids, que incluye memberships). Solo lectura: '
  'cargar saldo va por fn_table_deposit_can_manage.';

grant execute on function public.fn_table_deposit_can_view(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. RLS de las dos tablas
-- ---------------------------------------------------------------------------

drop policy if exists tda_select on public.table_deposit_accounts;
create policy tda_select on public.table_deposit_accounts
  for select to authenticated
  using (public.fn_table_deposit_can_view(business_id));

drop policy if exists tdm_select on public.table_deposit_movements;
create policy tdm_select on public.table_deposit_movements
  for select to authenticated
  using (public.fn_table_deposit_can_view(business_id));

-- ---------------------------------------------------------------------------
-- 3. Lecturas: mismos cuerpos que la 0007, solo cambia el filtro de acceso
-- ---------------------------------------------------------------------------

-- Badge del salón (cuadrícula y plano).
create or replace function public.fn_table_deposit_balances(
  p_business_id uuid
) returns table (
  table_id       uuid,
  table_code     text,
  table_label    text,
  zone_id        uuid,
  balance        numeric,
  holder_name    text,
  last_movement_at timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $$
  select
    a.table_id,
    dt.code,
    coalesce(dt.label, dt.code),
    dt.zone_id,
    a.balance,
    a.holder_name,
    a.last_movement_at
  from public.table_deposit_accounts a
  join public.dining_tables dt on dt.id = a.table_id
  where a.business_id = p_business_id
    and a.balance > 0
    and public.fn_table_deposit_can_view(p_business_id)
  order by a.last_movement_at desc nulls last;
$$;

-- Cobro: decide si aparece "Saldo mesa".
create or replace function public.fn_table_deposit_balance_for_order(
  p_order_id uuid
) returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'table_id', ts.table_id,
    'table_label', coalesce(dt.label, dt.code),
    'balance', coalesce(a.balance, 0),
    'holder_name', a.holder_name,
    'account_id', a.id
  )
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  join public.dining_tables dt on dt.id = ts.table_id
  join public.zones z on z.id = dt.zone_id
  left join public.table_deposit_accounts a on a.table_id = ts.table_id
  where o.id = p_order_id
    and public.fn_table_deposit_can_view(z.business_id)
  limit 1;
$$;

-- Factura / reimpresión: "SALDO RESTANTE".
create or replace function public.fn_table_deposit_for_payment(
  p_payment_id uuid
) returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'applied', abs(m.amount),
    'balance_after', m.balance_after,
    'table_id', m.table_id,
    'created_at', m.created_at
  )
  from public.table_deposit_movements m
  where m.payment_id = p_payment_id
    and m.type = 'consumption'
    and public.fn_table_deposit_can_view(m.business_id)
  limit 1;
$$;

create or replace function public.fn_table_deposit_for_order(
  p_order_id uuid
) returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'applied', coalesce(sum(abs(m.amount)), 0),
    'balance_after', (
      select m2.balance_after
      from public.table_deposit_movements m2
      where m2.order_id = p_order_id
        and m2.type = 'consumption'
      order by m2.created_at desc
      limit 1
    ),
    'table_id', (
      select m3.table_id
      from public.table_deposit_movements m3
      where m3.order_id = p_order_id
        and m3.type = 'consumption'
      limit 1
    )
  )
  from public.table_deposit_movements m
  where m.order_id = p_order_id
    and m.type = 'consumption'
    and public.fn_table_deposit_can_view(m.business_id);
$$;

commit;

-- =============================================================================
-- VERIFICACIÓN (una sola consulta; cambia el nombre del negocio)
--
--   Lista a TODOS los usuarios del negocio y dice si hoy ven el saldo. Antes
--   de esta migración, quien sale con `solo_memberships = true` no lo veía.
--
--   with b as (
--     select id from public.businesses where business_name ilike '%ECO%' limit 1
--   ),
--   usuarios as (
--     select ub.user_id from public.user_businesses ub, b where ub.business_id = b.id
--     union
--     select m.user_id  from public.memberships m, b      where m.business_id  = b.id
--     union
--     select bz.owner_id from public.businesses bz, b     where bz.id = b.id
--   )
--   select
--     coalesce(p.email, u.user_id::text)                         as usuario,
--     (select ub.role from public.user_businesses ub, b
--       where ub.user_id = u.user_id and ub.business_id = b.id)   as rol,
--     not exists (select 1 from public.user_businesses ub, b
--                  where ub.user_id = u.user_id and ub.business_id = b.id)
--       and not exists (select 1 from public.businesses bz, b
--                  where bz.id = b.id and bz.owner_id = u.user_id) as solo_memberships
--   from usuarios u
--   left join public.profiles p on p.id = u.user_id
--   order by solo_memberships desc, usuario;
-- =============================================================================
