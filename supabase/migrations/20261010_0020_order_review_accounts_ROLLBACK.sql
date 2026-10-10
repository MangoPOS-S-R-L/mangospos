-- Reversa de 20261010_0020: vuelven fn_open_table, el candado de ítems y
-- v_zone_table_status vivos del 10-oct (MP401/MP402 rechazan otra vez) y se
-- borran las funciones nuevas.
--
-- SE NIEGA si hay cuentas en revisión abiertas: con la versión anterior serían
-- una segunda orden viva en la sesión que nadie ve (la app y fn_open_table leen
-- una sola) — volvería a «desaparecer» una cuenta. Resolverlas antes
-- (fn_resolve_review_order) o no revertir.
--
-- Se CONSERVAN las columnas de orders y order_review_events: borrar la
-- identidad de las cuentas ya subidas no devuelve nada y pierde trazabilidad.
begin;

do $$
declare v_open boolean := false;
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'orders' and column_name = 'review_reason'
  ) then
    execute $q$select exists (select 1 from public.orders
                 where review_reason is not null
                   and closed_at is null
                   and status_ext not in ('paid', 'void'))$q$
       into v_open;
  end if;
  if v_open then
    raise exception 'Hay cuentas en revisión abiertas: resolverlas antes de revertir 20261010_0020.';
  end if;
end $$;

drop function if exists public.fn_open_local_table_order(text, uuid, integer, uuid);
drop function if exists public.fn_resolve_review_order(uuid, text, text);

CREATE OR REPLACE FUNCTION public.fn_open_table(p_table_id uuid, p_user_id uuid, p_people_count integer DEFAULT 1, p_opened_by_employee_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_session_id uuid;
  v_order_id uuid;
  v_user_id uuid;
  v_business_id uuid;
begin
  if p_table_id is null then
    raise exception 'TABLE_ID_REQUIRED';
  end if;

  if auth.uid() is not null and p_user_id is not null and p_user_id <> auth.uid() then
    raise exception 'INVALID_USER_CONTEXT';
  end if;

  v_user_id := coalesce(auth.uid(), p_user_id);

  if v_user_id is null then
    raise exception 'USER_REQUIRED';
  end if;

  -- Validar que el empleado pertenece al business de la mesa si se pasó.
  if p_opened_by_employee_id is not null then
    select z.business_id
      into v_business_id
    from public.dining_tables t
    join public.zones z on z.id = t.zone_id
    where t.id = p_table_id;

    if v_business_id is null then
      raise exception 'TABLE_BUSINESS_NOT_FOUND';
    end if;

    if not exists (
      select 1 from public.employees e
      where e.id = p_opened_by_employee_id
        and e.business_id = v_business_id
        and e.status = 'active'
    ) then
      raise exception 'EMPLOYEE_NOT_IN_BUSINESS';
    end if;
  end if;

  perform public.fn_require_open_cash_session(v_user_id);

  -- Serialize by table to avoid double-open races.
  perform pg_advisory_xact_lock(hashtextextended(p_table_id::text, 0));

  select ts.id
    into v_session_id
  from public.table_sessions ts
  where ts.table_id = p_table_id
    and ts.closed_at is null
  order by ts.opened_at desc
  limit 1;

  if v_session_id is null then
    insert into public.table_sessions (
      table_id, opened_by, origin, waiter_user_id, people_count,
      opened_by_employee_id
    )
    values (
      p_table_id, v_user_id, 'dine_in', v_user_id,
      greatest(1, coalesce(p_people_count, 1)),
      p_opened_by_employee_id
    )
    returning id into v_session_id;
  end if;

  update public.dining_tables
     set state = 'occupied'
   where id = p_table_id
     and state is distinct from 'occupied';

  select o.id
    into v_order_id
  from public.orders o
  where o.session_id = v_session_id
    and o.closed_at is null
    and o.status_ext not in ('paid', 'void')
  order by o.created_at desc
  limit 1;

  if v_order_id is null then
    insert into public.orders (session_id, status_ext, subtotal, discounts, tax, total, total_amount)
    values (v_session_id, 'open', 0, 0, 0, 0, 0)
    returning id into v_order_id;

    insert into public.order_checks (order_id, label, position)
    values (v_order_id, 'C1', 1)
    on conflict (order_id, position) do nothing;
  end if;

  return jsonb_build_object('session_id', v_session_id, 'order_id', v_order_id);
end;
$function$;

create or replace function public.fn_block_items_on_closed_order()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_state text;
begin
  if new.order_id is null then
    return new;
  end if;

  -- Camino normal (99.99% de los inserts): una lectura por PK y afuera. El
  -- reanimador solo se invoca cuando la orden REALMENTE está cerrada, así el
  -- split de cuentas (que inserta decenas de filas) no paga nada extra.
  if not exists (
    select 1 from public.orders o
     where o.id = new.order_id
       and o.closed_at is not null
  ) then
    return new;
  end if;

  v_state := public.fn_reopen_orphan_order(new.order_id, 'order_item_insert');

  if v_state in ('revived', 'not_closed') then
    return new;
  elsif v_state = 'settled' then
    raise exception 'Esta cuenta ya fue cobrada. Abre la mesa otra vez para cargar productos nuevos.'
      using errcode = 'MP401';
  elsif v_state = 'table_taken' then
    raise exception 'La mesa ya se abrió en otra cuenta. Carga el producto en la cuenta activa.'
      using errcode = 'MP402';
  else
    raise exception 'La orden ya no existe.'
      using errcode = 'MP403';
  end if;
end;
$function$;

alter function public.fn_block_items_on_closed_order() owner to postgres;

drop function if exists public.fn_move_closed_order_to_review(uuid);
drop function if exists public.fn_late_items_review_order(uuid);

-- La vista pierde dos columnas: CREATE OR REPLACE no puede quitarlas. Se
-- copian permisos y opciones, se recrea y se reaplican.
create temp table _vzts_restore (stmt text) on commit drop;
insert into _vzts_restore
select format('grant %s on public.v_zone_table_status to %s', g.privilege_type,
              case when g.grantee = 'PUBLIC' then 'public' else quote_ident(g.grantee) end)
  from information_schema.role_table_grants g
 where g.table_schema = 'public' and g.table_name = 'v_zone_table_status';
insert into _vzts_restore
select format('alter view public.v_zone_table_status set (%s)', array_to_string(c.reloptions, ', '))
  from pg_class c
 where c.oid = 'public.v_zone_table_status'::regclass
   and c.reloptions is not null;

drop view public.v_zone_table_status;

CREATE VIEW public.v_zone_table_status AS
 SELECT t.id AS table_id,
    z.id AS zone_id,
    z.name AS zone_name,
    z.business_id,
    t.code,
    t.label,
    t.shape,
    t.capacity,
    t.state,
    s.id AS session_id,
    s.opened_by,
    s.opened_at,
    s.waiter_user_id,
    s.customer_name,
    s.people_count,
    COALESCE(( SELECT NULLIF(split_part(btrim(e.first_name), ' '::text, 1), ''::text) AS "nullif"
           FROM public.employees e
          WHERE e.id = s.opened_by_employee_id), ( SELECT NULLIF(split_part(btrim(e.first_name), ' '::text, 1), ''::text) AS "nullif"
           FROM public.employees e
          WHERE e.user_id = s.waiter_user_id AND e.business_id = z.business_id
         LIMIT 1), ( SELECT NULLIF(split_part(btrim(p.full_name), ' '::text, 1), ''::text) AS "nullif"
           FROM public.profiles p
          WHERE p.id = s.waiter_user_id), ( SELECT NULLIF(split_part(btrim(e.first_name), ' '::text, 1), ''::text) AS "nullif"
           FROM public.employees e
          WHERE e.user_id = s.opened_by AND e.business_id = z.business_id
         LIMIT 1), ( SELECT NULLIF(split_part(btrim(p.full_name), ' '::text, 1), ''::text) AS "nullif"
           FROM public.profiles p
          WHERE p.id = s.opened_by)) AS waiter_name,
    auth.uid() IS NOT NULL AND auth.uid() = COALESCE(s.waiter_user_id, s.opened_by) AS is_own,
        CASE
            WHEN s.opened_at IS NOT NULL AND s.closed_at IS NULL THEN EXTRACT(epoch FROM now() - s.opened_at)::integer / 60
            ELSE NULL::integer
        END AS minutes_open,
    COALESCE(( SELECT count(*) AS count
           FROM public.orders o
          WHERE o.session_id = s.id), 0::bigint) AS orders_count,
    COALESCE(( SELECT round(sum(
                CASE
                    WHEN oi.tax_mode = 'inclusive'::text THEN oi.unit_price * COALESCE(oi.qty, oi.quantity, 1::numeric) + COALESCE(( SELECT sum(m.price * m.qty) AS sum
                       FROM public.order_item_modifiers m
                      WHERE m.item_id = oi.id), 0::numeric) - COALESCE(oi.discounts, 0::numeric)
                    ELSE oi.total
                END), 2) AS round
           FROM public.order_items oi
             JOIN public.orders o2 ON o2.id = oi.order_id
          WHERE o2.session_id = s.id AND o2.closed_at IS NULL AND (o2.status_ext <> ALL (ARRAY['paid'::public.order_status, 'void'::public.order_status])) AND (oi.status <> ALL (ARRAY['paid'::public.item_status, 'void'::public.item_status]))), 0::numeric) AS total,
        CASE
            WHEN s.precheck_printed_at IS NOT NULL AND s.closed_at IS NULL THEN 'paying'::text
            ELSE NULL::text
        END AS status
   FROM public.dining_tables t
     JOIN public.zones z ON z.id = t.zone_id
     LEFT JOIN LATERAL ( SELECT s2.id,
            s2.table_id,
            s2.opened_by,
            s2.opened_at,
            s2.closed_at,
            s2.customer_name,
            s2.note,
            s2.origin,
            s2.waiter_user_id,
            s2.people_count,
            s2.business_id,
            s2.customer_id,
            s2.delivery_type,
            s2.opened_by_employee_id,
            s2.precheck_printed_at,
            s2.delivery_address
           FROM public.table_sessions s2
          WHERE s2.table_id = t.id AND s2.closed_at IS NULL
          ORDER BY s2.opened_at DESC
         LIMIT 1) s ON true;

do $$
declare r record;
begin
  for r in select stmt from _vzts_restore loop
    execute r.stmt;
  end loop;
end $$;

commit;
