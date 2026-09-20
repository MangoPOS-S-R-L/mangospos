-- =============================================================================
-- 20260919_0002 — Registro de lo que se QUITA de una cuenta después de
--                  enviarse a cocina + reporte de comandas "desaparecidas"
-- =============================================================================
--
-- EL HUECO:
--   La comanda sale por la impresora, pero después alguien BORRA el producto
--   de la cuenta (con PIN de supervisor y un motivo). `deleteItem` hace un
--   DELETE de la fila y el motivo que pide la pantalla se descarta: no queda
--   nada. Bajarle la cantidad a una línea ya enviada deja la etiqueta
--   `[REDUCCION:motivo]` en la nota, pero la cantidad original se pierde.
--   Resultado: cocina despachó algo que ninguna cuenta tiene y no hay forma
--   de saber qué fue. Medido en el negocio 6d13ed3f (1–19 sep): 0 huérfanas,
--   0 cargadas a una orden cerrada; lo que "desaparece" es lo borrado.
--
-- QUÉ HACE:
--   1. `order_item_removals`: una fila por cada producto YA ENVIADO (no
--      'draft') que se borra, o cuya cantidad se reduce con motivo. Guarda la
--      foto del producto, de su comanda (marca de envío, área, autor), la
--      mesa, quién y cuándo.
--   2. Dos triggers en `order_items`:
--        * BEFORE DELETE: antes del borrado, porque el ON DELETE CASCADE se
--          lleva los modificadores. Se llama `trg_zz_…` para correr DESPUÉS
--          de `trg_block_item_delete_on_invoiced` (los BEFORE corren en orden
--          alfabético): si ese candado aborta, no queda registro.
--        * AFTER UPDATE OF notes: solo cuando aparece una etiqueta
--          `[REDUCCION:` NUEVA y la cantidad bajó (el único camino que la
--          escribe es la reducción con motivo de la pantalla de la mesa).
--      El registro NUNCA impide borrar ni editar: cualquier error se traga
--      con un WARNING.
--   3. `fn_note_order_item_removal`: la app lo llama DESPUÉS de borrar para
--      anotar el motivo y el operador (PIN). El borrado no cambia.
--   4. `fn_kitchen_missing_report`: las comandas "desaparecidas" de un rango:
--        * 'deleted' / 'reduced': lo del registro (desde que se aplique esta
--          migración; lo borrado antes no se puede recuperar).
--        * 'orphan', 'loaded_after_close', 'closed_check', 'charged_without':
--          productos que siguen en la base pero ninguna cuenta viva muestra
--          (misma regla que scripts/DIAGNOSTICO_comandas_sin_cuenta.sql).
--
-- BORRADO DEL USUARIO vs. REESCRITURA INTERNA:
--   Dividir la cuenta consolida filas borrándolas y volviéndolas a crear
--   (fn_consolidate_*, SECURITY DEFINER). Eso no es un borrado del usuario.
--   OJO: dentro de una función SECURITY DEFINER `current_user` es el DUEÑO
--   (postgres), así que no sirve para distinguir (probado en Postgres local).
--   Se usa la petición de PostgREST:
--     * sin JWT (SQL Editor, cron, mantenimiento)       → interno
--     * `request.path` de tabla (DELETE directo de la app) → usuario
--     * `/rpc/fn_delete_item` (borrar desde la subcuenta)  → usuario
--     * cualquier otra RPC                               → interno
--   Todo se registra; `is_user_action` y `request_path` dicen cuál fue. El
--   reporte solo muestra lo del usuario.
--
-- SEGURIDAD: tabla con RLS (lectura por negocio, sin escritura directa);
--   escriben solo el trigger y la RPC (SECURITY DEFINER). Acceso a las RPC
--   con `in (select current_user_business_ids())`, sin alias (42703).
--
-- IDEMPOTENTE. ROLLBACK: 20260919_0002_order_item_removals_ROLLBACK.sql
-- Requiere 20260919_0001 (fn_kitchen_comandas_report con void_source).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Registro
-- ---------------------------------------------------------------------------
create table if not exists public.order_item_removals (
  id                 uuid primary key default gen_random_uuid(),
  business_id        uuid not null references public.businesses(id) on delete cascade,
  order_id           uuid,
  session_id         uuid,
  check_id           uuid,
  item_id            uuid not null,
  -- 'deleted' = se borró la fila; 'reduced' = se le bajó la cantidad.
  change_type        text not null check (change_type in ('deleted', 'reduced')),
  product_id         uuid,
  product_name       text,
  -- Unidades que salieron de la cuenta.
  quantity           numeric not null,
  qty_before         numeric,
  qty_after          numeric,
  unit_price         numeric,
  notes              text,
  item_status        text,
  is_takeout         boolean not null default false,
  -- Envío a cocina efectivo: la marca del ítem o la de su original si es
  -- una fila creada al dividir la cuenta (misma regla que el reporte).
  kitchen_sent_at    timestamptz,
  sent_source        text,
  print_area_code    text,
  author_employee_id uuid,
  item_created_at    timestamptz,
  modifiers          jsonb not null default '[]'::jsonb,
  table_name         text,
  origin             text,
  removed_at         timestamptz not null default now(),
  -- La cuenta de la tablet (auth.uid()).
  removed_by         uuid,
  -- El motivo: el de la etiqueta [REDUCCION:…] o el que anota la app.
  reason             text,
  -- El operador con PIN que lo hizo (lo anota la app).
  reason_employee_id uuid,
  is_user_action     boolean not null,
  request_path       text
);

create index if not exists idx_order_item_removals_business_sent
  on public.order_item_removals (business_id, kitchen_sent_at);
create index if not exists idx_order_item_removals_item
  on public.order_item_removals (item_id, removed_at desc);

alter table public.order_item_removals enable row level security;

drop policy if exists order_item_removals_select on public.order_item_removals;
create policy order_item_removals_select on public.order_item_removals
  for select to authenticated
  using (business_id in (select public.current_user_business_ids()));

grant select on public.order_item_removals to authenticated;

comment on table public.order_item_removals is
  'Productos ya enviados a cocina que se borraron de la cuenta o a los que se '
  'les redujo la cantidad (20260919_0002). Lo escribe el trigger '
  'fn_log_order_item_removal; el motivo/operador, fn_note_order_item_removal.';

-- ---------------------------------------------------------------------------
-- 2. Trigger
-- ---------------------------------------------------------------------------
create or replace function public.fn_log_order_item_removal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type      text;
  v_old_q     numeric;
  v_new_q     numeric;
  v_reason    text;
  v_path      text;
  v_via_api   boolean;
  v_user      boolean;
  v_business  uuid;
  v_obiz      uuid;
  v_session   uuid;
  v_origin    text;
  v_table     text;
  v_sent      timestamptz;
  v_source    text;
  v_area      text;
  v_author    uuid;
  v_sib_sent  timestamptz;
  v_sib_area  text;
  v_sib_auth  uuid;
  v_mods      jsonb;
begin
  begin
    -- Lo que nunca salió a cocina se quita como del carrito: no se registra.
    if old.status::text = 'draft' then
      if tg_op = 'DELETE' then
        return old;
      end if;
      return new;
    end if;

    v_old_q := coalesce(nullif(old.qty, 0), old.quantity::numeric, 1);
    v_path := nullif(current_setting('request.path', true), '');

    if tg_op = 'DELETE' then
      v_type := 'deleted';
      v_new_q := 0;
      v_via_api := coalesce(
        nullif(current_setting('request.jwt.claims', true), ''),
        nullif(current_setting('request.jwt.claim.role', true), '')
      ) is not null;
      v_user := v_via_api and (
        v_path is null                       -- PostgREST sin request.path
        or v_path not like '%/rpc/%'         -- DELETE directo a la tabla
        or v_path like '%/rpc/fn_delete_item'
      );
    else
      v_new_q := coalesce(nullif(new.qty, 0), new.quantity::numeric, 1);
      if v_new_q >= v_old_q - 0.0001 then
        return new;
      end if;
      -- Solo la reducción con motivo: una etiqueta [REDUCCION: NUEVA.
      if (length(coalesce(new.notes, ''))
            - length(replace(coalesce(new.notes, ''), '[REDUCCION:', '')))
         <= (length(coalesce(old.notes, ''))
            - length(replace(coalesce(old.notes, ''), '[REDUCCION:', ''))) then
        return new;
      end if;
      v_type := 'reduced';
      v_user := true;
      select nullif(trim(t.m[1]), '')
        into v_reason
      from regexp_matches(new.notes, '\[REDUCCION:([^\]]*)\]', 'g')
             with ordinality as t(m, n)
      order by t.n desc
      limit 1;
    end if;

    -- Mesa y negocio. Si la orden ya no existe (borrado en cascada), queda
    -- el negocio del ítem.
    v_business := old.business_id;
    select
      o.session_id,
      o.business_id,
      ts.origin::text,
      case
        when dt.id is not null then coalesce(dt.label, dt.code, 'Mesa')
        when ts.origin::text = 'manual' then 'Venta manual'
        when ts.origin::text in ('quick', 'quick_sale') then 'Venta rápida'
        else 'Venta'
      end
      into v_session, v_obiz, v_origin, v_table
    from public.orders o
    left join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt  on dt.id = ts.table_id
    where o.id = old.order_id;
    v_business := coalesce(v_business, v_obiz);
    if v_business is null then
      if tg_op = 'DELETE' then
        return old;
      end if;
      return new;
    end if;

    -- Envío efectivo: la marca propia o la del original (dividir la cuenta
    -- crea filas sin marca, sin área y sin autor).
    v_sent := old.kitchen_sent_at;
    v_source := case when old.kitchen_sent_at is not null then 'stamp' end;
    v_area := old.print_area_code;
    v_author := old.created_by_employee_id;
    if v_sent is null then
      select s.kitchen_sent_at, s.print_area_code, s.created_by_employee_id
        into v_sib_sent, v_sib_area, v_sib_auth
      from public.order_items s
      where s.order_id = old.order_id
        and s.id <> old.id
        and s.kitchen_sent_at is not null
        and s.product_id is not distinct from old.product_id
        and s.created_at = old.created_at
      order by s.kitchen_sent_at
      limit 1;
      if v_sib_sent is not null then
        v_sent := v_sib_sent;
        v_source := 'split';
        v_area := v_sib_area;
        v_author := coalesce(v_author, v_sib_auth);
      end if;
    end if;

    select coalesce(
             jsonb_agg(
               jsonb_build_object('name', m.name, 'qty', coalesce(m.qty, 1))
               order by m.name
             ),
             '[]'::jsonb
           )
      into v_mods
    from public.order_item_modifiers m
    where m.item_id = old.id;

    insert into public.order_item_removals (
      business_id, order_id, session_id, check_id, item_id, change_type,
      product_id, product_name, quantity, qty_before, qty_after, unit_price,
      notes, item_status, is_takeout, kitchen_sent_at, sent_source,
      print_area_code, author_employee_id, item_created_at, modifiers,
      table_name, origin, removed_by, reason, is_user_action, request_path
    )
    values (
      v_business, old.order_id, v_session, old.check_id, old.id, v_type,
      old.product_id, old.product_name::text, v_old_q - v_new_q, v_old_q,
      v_new_q, old.unit_price, old.notes, old.status::text,
      coalesce(old.is_takeout, false), v_sent, v_source, v_area, v_author,
      old.created_at, coalesce(v_mods, '[]'::jsonb), v_table, v_origin,
      auth.uid(), v_reason, v_user, v_path
    );
  exception when others then
    -- El registro jamás puede impedir borrar o editar un producto.
    raise warning 'fn_log_order_item_removal: % (%)', sqlerrm, sqlstate;
  end;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

comment on function public.fn_log_order_item_removal() is
  'Trigger de order_items (20260919_0002): registra en order_item_removals '
  'cada producto ya enviado que se borra o se reduce con motivo. Nunca aborta.';

drop trigger if exists trg_zz_log_order_item_delete on public.order_items;
create trigger trg_zz_log_order_item_delete
  before delete on public.order_items
  for each row
  execute function public.fn_log_order_item_removal();

drop trigger if exists trg_zz_log_order_item_reduction on public.order_items;
create trigger trg_zz_log_order_item_reduction
  after update of notes on public.order_items
  for each row
  when (
    new.notes is distinct from old.notes
    and coalesce(new.notes, '') like '%[REDUCCION:%'
  )
  execute function public.fn_log_order_item_removal();

-- ---------------------------------------------------------------------------
-- 3. Motivo y operador (la app lo llama después de borrar)
-- ---------------------------------------------------------------------------
create or replace function public.fn_note_order_item_removal(
  p_item_id     uuid,
  p_reason      text default null,
  p_employee_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id       uuid;
  v_business uuid;
begin
  select r.id, r.business_id
    into v_id, v_business
  from public.order_item_removals r
  where r.item_id = p_item_id
    and r.business_id in (select public.current_user_business_ids())
    -- La cola offline puede borrar horas después; no más de 3 días.
    and r.removed_at > now() - interval '3 days'
  order by r.removed_at desc
  limit 1;

  if v_id is null then
    return false;
  end if;

  -- Solo completa lo que falta: no pisa un motivo ya escrito.
  update public.order_item_removals r
     set reason = coalesce(
           r.reason,
           nullif(left(trim(coalesce(p_reason, '')), 500), '')
         ),
         reason_employee_id = coalesce(
           r.reason_employee_id,
           (select e.id from public.employees e
             where e.id = p_employee_id and e.business_id = v_business)
         )
   where r.id = v_id;
  return true;
end;
$$;

grant execute on function public.fn_note_order_item_removal(uuid, text, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Reporte de comandas desaparecidas
-- ---------------------------------------------------------------------------
drop function if exists public.fn_kitchen_missing_report(uuid, timestamptz, timestamptz);

create function public.fn_kitchen_missing_report(
  p_business_id uuid,
  p_from        timestamptz,
  p_to          timestamptz
)
returns table (
  -- Mismas columnas que fn_kitchen_comandas_report…
  item_id           uuid,
  order_id          uuid,
  kitchen_sent_at   timestamptz,
  item_created_at   timestamptz,
  product_id        uuid,
  product_name      text,
  quantity          numeric,
  notes             text,
  status            text,
  is_takeout        boolean,
  table_name        text,
  origin            text,
  item_author       text,
  opener_name       text,
  area_codes        text[],
  area_names        text[],
  modifiers         jsonb,
  unit_price        numeric,
  is_courtesy       boolean,
  order_status      text,
  order_closed_at   timestamptz,
  session_closed_at timestamptz,
  sent_source       text,
  is_zero_value     boolean,
  void_note         text,
  void_at           timestamptz,
  void_source       text,
  -- …más cómo desapareció:
  --   'deleted'            se borró de la cuenta
  --   'reduced'            se le bajó la cantidad (quantity = lo quitado)
  --   'orphan'             orden viva con la mesa cerrada
  --   'loaded_after_close' se cargó después de cerrar/anular la orden
  --   'closed_check'       quedó en una subcuenta cerrada
  --   'charged_without'    la orden se cobró sin este producto
  missing_kind      text,
  removed_at        timestamptz,
  removed_reason    text,
  -- El operador con PIN, o la cuenta de la tablet si la app no lo anotó.
  removed_by        text,
  qty_before        numeric,
  qty_after         numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if p_business_id is null then
    raise exception 'BUSINESS_ID_REQUIRED';
  end if;
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'INVALID_RANGE';
  end if;
  if not (p_business_id in (select public.current_user_business_ids())) then
    raise exception 'UNAUTHORIZED_BUSINESS';
  end if;

  return query
  -- A. Lo que se quitó de la cuenta después de enviarse (el registro).
  select
    r.item_id,
    r.order_id,
    r.kitchen_sent_at,
    r.item_created_at,
    r.product_id,
    coalesce(r.product_name, 'Producto'),
    r.quantity,
    r.notes,
    coalesce(r.item_status, ''),
    r.is_takeout,
    coalesce(r.table_name, 'Venta'),
    r.origin,
    nullif(trim(concat_ws(' ', e.first_name, e.last_name)), ''),
    coalesce(
      nullif(trim(concat_ws(' ', oe.first_name, oe.last_name)), ''),
      nullif(trim(pw.full_name), '')
    ),
    coalesce(nm.codes, legacy.codes, array[]::text[]),
    coalesce(nm.names, legacy.names, array[]::text[]),
    r.modifiers,
    r.unit_price,
    false,
    case
      when o.status_ext::text = 'void' then 'canceled'
      when o.status_ext::text = 'paid' then 'paid'
      else o.status::text
    end,
    o.closed_at,
    ts.closed_at,
    coalesce(r.sent_source, 'stamp'),
    false,
    null::text,
    null::timestamptz,
    null::text,
    r.change_type,
    r.removed_at,
    r.reason,
    coalesce(
      nullif(trim(concat_ws(' ', re.first_name, re.last_name)), ''),
      nullif(trim(rp.full_name), '')
    ),
    r.qty_before,
    r.qty_after
  from public.order_item_removals r
  left join public.orders o          on o.id = r.order_id
  left join public.table_sessions ts on ts.id = coalesce(r.session_id, o.session_id)
  left join public.employees e       on e.id = r.author_employee_id
  left join public.employees oe      on oe.id = ts.opened_by_employee_id
  left join public.profiles pw       on pw.id = ts.waiter_user_id
  left join public.employees re      on re.id = r.reason_employee_id
  left join public.profiles rp       on rp.id = r.removed_by
  left join lateral (
    select
      array_agg(pa.code order by pa.name, pa.code) as codes,
      array_agg(pa.name order by pa.name, pa.code) as names
    from public.menu_item_print_areas mipa
    join public.print_areas pa on pa.id = mipa.print_area_id
    where mipa.menu_item_id = r.product_id
      and pa.is_active
      and pa.business_id = r.business_id
  ) nm on true
  left join lateral (
    select array[pa.code] as codes, array[pa.name] as names
    from public.print_areas pa
    where pa.code = r.print_area_code
      and pa.business_id = r.business_id
      and pa.is_active
    limit 1
  ) legacy on nm.codes is null
  where r.business_id = p_business_id
    and r.is_user_action
    and r.kitchen_sent_at >= p_from
    and r.kitchen_sent_at <  p_to

  union all

  -- B. Sigue en la base, pero ninguna cuenta viva lo muestra.
  select f.*, null::timestamptz, null::text, null::text, null::numeric, null::numeric
  from (
    select
      k.*,
      case
        when k.order_closed_at is not null
             and k.item_created_at > k.order_closed_at
          then 'loaded_after_close'
        -- Anulada a propósito: el producto ya estaba cuando se anuló.
        when k.order_status = 'canceled' then null
        when k.order_closed_at is null and k.order_status <> 'paid'
             and k.session_closed_at is not null
          then 'orphan'
        when k.order_closed_at is null and k.order_status <> 'paid'
             and oi.check_id is not null
             and not exists (
               select 1 from public.order_checks c
               where c.id = oi.check_id and not c.is_closed
             )
          then 'closed_check'
        when k.order_closed_at is not null or k.order_status = 'paid'
          then 'charged_without'
      end as missing_kind
    from public.fn_kitchen_comandas_report(p_business_id, p_from, p_to) k
    left join public.order_items oi on oi.id = k.item_id
    where k.status not in ('paid', 'void')
      and not k.is_courtesy
      and not k.is_zero_value
  ) f
  where f.missing_kind is not null

  order by 3, 1;
end;
$$;

comment on function public.fn_kitchen_missing_report(uuid, timestamptz, timestamptz) is
  'Comandas "desaparecidas" (20260919_0002): lo quitado de la cuenta después '
  'de enviarse (order_item_removals) y lo enviado que ninguna cuenta viva '
  'muestra. Mismas columnas que fn_kitchen_comandas_report + missing_kind.';

grant execute on function public.fn_kitchen_missing_report(uuid, timestamptz, timestamptz)
  to authenticated;

notify pgrst, 'reload schema';

commit;

-- =============================================================================
-- VERIFICACIÓN (después de aplicar; UNA sola fila):
--
--   select
--     to_regclass('public.order_item_removals') is not null           as tabla,
--     (select count(*) from pg_trigger
--       where tgname in ('trg_zz_log_order_item_delete',
--                        'trg_zz_log_order_item_reduction')
--         and not tgisinternal)                                        as triggers,
--     (select count(*) from pg_proc
--       where proname in ('fn_note_order_item_removal',
--                         'fn_kitchen_missing_report'))                 as funciones;
--
--   Esperado: tabla = true, triggers = 2, funciones = 2.
-- =============================================================================
