-- =============================================================================
-- 20261010_0006 — T04: ediciones versionadas de cuentas y líneas
-- =============================================================================
--
-- PROBLEMA. Ninguna edición de una cuenta comparaba versiones: cada una manda
-- un valor absoluto (cantidad, notas, para llevar, descuento, extras, cuenta,
-- borrado, delivery, impuestos, cliente, nota) y gana la que llega última.
-- Dos terminales (o una respuesta perdida y su reintento) se pisaban en
-- silencio.
--
-- QUÉ HACE.
--   1. Versiones: order_items.version sube cuando cambia algo que edita el
--      operador (no con el envío a cocina ni con el cobro); orders.version
--      sube con los cambios de la cuenta (delivery, nota de venta, propina) y
--      con cada edición de nivel cuenta de esta función. Las suben
--      disparadores: cualquier escritura cambia la versión, también las de
--      versiones anteriores de la app.
--   2. fn_apply_order_edit: única entrada para editar. Toma el MISMO candado
--      que el cobro (orders FOR UPDATE), reconoce los reintentos por p_op_id
--      (devuelve el mismo resultado), rechaza la edición si la versión que el
--      operador editaba ya no es la vigente (devuelve el estado actual) y, si
--      pasa, llama la función viva de siempre. Sin versión conocida (línea
--      creada sin red) compara los valores que el operador veía (p_expected).
--      p_force aplica sobre la versión vigente: solo con la decisión explícita
--      del operador ante un conflicto.
--   3. consolidate_check: unir líneas iguales de una subcuenta se calcula
--      aquí, con lo vigente y bajo el candado (la app sumaba lo que había
--      leído y escribía la cantidad absoluta).
--   4. fn_append_session_note: la nota de la sesión solo recibe líneas de
--      auditoría (anulación, acceso a mesa ajena). Se agregan en una sola
--      sentencia; antes la app leía la nota y escribía el texto completo, y
--      dos líneas a la vez se perdían una a la otra.
--
-- No modifica las funciones de edición vivas (comparadas con pg_get_functiondef
-- el 2026-10-10): las llama tal cual. La app nueva no tiene respaldo directo:
-- sin esta migración (PGRST202) avisa «Falta actualizar el servidor».
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Versiones
-- ---------------------------------------------------------------------------
alter table public.order_items add column if not exists version bigint not null default 1;
alter table public.orders add column if not exists version bigint not null default 1;

create or replace function public.trg_order_item_version()
returns trigger
language plpgsql
as $$
begin
  if new.qty is distinct from old.qty
     or new.quantity is distinct from old.quantity
     or new.notes is distinct from old.notes
     or new.is_takeout is distinct from old.is_takeout
     or new.discounts is distinct from old.discounts
     or new.check_id is distinct from old.check_id
     or new.product_name is distinct from old.product_name
     or new.product_id is distinct from old.product_id
     or new.unit_price is distinct from old.unit_price
     or (new.status::text = 'void' and old.status::text is distinct from 'void')
  then
    new.version := old.version + 1;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_aa_order_item_version on public.order_items;
create trigger trg_aa_order_item_version
  before update on public.order_items
  for each row execute function public.trg_order_item_version();

create or replace function public.trg_order_version()
returns trigger
language plpgsql
as $$
begin
  if new.delivery_fee is distinct from old.delivery_fee
     or new.is_sales_note is distinct from old.is_sales_note
     or new.tip is distinct from old.tip
  then
    new.version := greatest(new.version, old.version + 1);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_aa_order_version on public.orders;
create trigger trg_aa_order_version
  before update on public.orders
  for each row execute function public.trg_order_version();

-- Extras: cambian la línea.
create or replace function public.trg_order_item_version_from_modifiers()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.order_items
     set version = version + 1
   where id = coalesce(new.item_id, old.item_id);
  return null;
end;
$$;

drop trigger if exists trg_zz_order_item_version_modifiers on public.order_item_modifiers;
create trigger trg_zz_order_item_version_modifiers
  after insert or update or delete on public.order_item_modifiers
  for each row execute function public.trg_order_item_version_from_modifiers();

-- ---------------------------------------------------------------------------
-- 2. Operaciones ya aplicadas (reintentos)
-- ---------------------------------------------------------------------------
create table if not exists public.order_edit_ops (
  op_id      uuid primary key,
  order_id   uuid not null,
  kind       text not null,
  target_id  uuid,
  result     jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_order_edit_ops_order on public.order_edit_ops (order_id);
alter table public.order_edit_ops enable row level security;
revoke all on public.order_edit_ops from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. La entrada única
-- ---------------------------------------------------------------------------
create or replace function public.fn_apply_order_edit(
  p_op_id        uuid,
  p_order_id     uuid,
  p_kind         text,
  p_target_id    uuid default null,
  p_base_version bigint default null,
  p_expected     jsonb default null,
  p_args         jsonb default '{}'::jsonb,
  p_force        boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order      public.orders%rowtype;
  v_item       public.order_items%rowtype;
  v_business   uuid;
  v_existing   public.order_edit_ops%rowtype;
  v_args       jsonb := coalesce(p_args, '{}'::jsonb);
  v_line_kind  boolean;
  v_result     jsonb;
  v_conflict   text;
  v_key        text;
  v_value      jsonb;
  v_entry      jsonb;
  v_ids        uuid[];
  v_new_version bigint;
  v_group      record;
  v_merged     integer := 0;
  v_kept       jsonb := '{}'::jsonb;
  v_removed    jsonb := '[]'::jsonb;
begin
  if p_op_id is null then
    raise exception 'EDIT_OP_ID_REQUIRED' using errcode = '22004';
  end if;
  if p_kind not in (
    'qty', 'notes', 'details', 'discount', 'discount_notes', 'takeout',
    'modifiers', 'move', 'delete', 'move_batch', 'consolidate_check',
    'delivery_fee', 'excluded_taxes', 'order_takeout',
    'session_customer', 'check_customer'
  ) then
    raise exception 'EDIT_KIND_UNKNOWN: %', p_kind using errcode = '22023';
  end if;
  v_line_kind := p_kind in (
    'qty', 'notes', 'details', 'discount', 'discount_notes', 'takeout',
    'modifiers', 'move', 'delete'
  );

  select coalesce(ts.business_id, z.business_id) into v_business
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z on z.id = dt.zone_id
   where o.id = p_order_id;
  if v_business is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;
  if not (
    coalesce(auth.role(), '') = 'service_role'
    or (session_user in ('postgres', 'supabase_admin') and nullif(auth.role(), '') is null)
    or coalesce(public.is_member_of_business(v_business), false)
  ) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;

  -- El mismo candado que el cobro (fn_process_payment_v3): una edición y un
  -- cobro de la misma cuenta van en fila.
  select * into v_order from public.orders where id = p_order_id for update;

  -- Reintento de la misma operación: mismo resultado, sin aplicar dos veces.
  select * into v_existing from public.order_edit_ops where op_id = p_op_id;
  if found then
    if v_existing.order_id <> p_order_id
       or v_existing.kind <> p_kind
       or v_existing.target_id is distinct from p_target_id then
      raise exception 'EDIT_OP_ID_CONFLICT' using errcode = 'MP430';
    end if;
    return v_existing.result || jsonb_build_object('replayed', true);
  end if;

  if v_order.closed_at is not null
     or v_order.status_ext::text in ('paid', 'void') then
    v_result := jsonb_build_object('status', 'conflict', 'reason', 'order_closed',
                                   'current_version', v_order.version);
  elsif v_line_kind then
    if p_target_id is null then
      raise exception 'EDIT_TARGET_REQUIRED' using errcode = '22004';
    end if;
    select * into v_item
      from public.order_items
     where id = p_target_id and order_id = p_order_id
     for update;
    if not found then
      v_result := case when p_kind = 'delete'
        -- Otro equipo ya la quitó: la intención se cumplió.
        then jsonb_build_object('status', 'applied', 'reason', 'already_deleted')
        else jsonb_build_object('status', 'conflict', 'reason', 'item_missing')
      end;
    elsif v_item.status::text in ('paid', 'void') then
      v_result := jsonb_build_object('status', 'conflict', 'reason', 'item_closed',
                                     'current_version', v_item.version,
                                     'current', to_jsonb(v_item));
    else
      if not coalesce(p_force, false) then
        if p_base_version is not null then
          if v_item.version <> p_base_version then
            v_conflict := 'stale_version';
          end if;
        elsif p_expected is not null and jsonb_typeof(p_expected) = 'object' then
          for v_key, v_value in select * from jsonb_each(p_expected) loop
            if (to_jsonb(v_item) -> v_key) is distinct from v_value then
              v_conflict := 'stale_value';
            end if;
          end loop;
        else
          raise exception 'EDIT_BASE_REQUIRED' using errcode = '22004';
        end if;
      end if;

      if v_conflict is not null then
        v_result := jsonb_build_object('status', 'conflict', 'reason', v_conflict,
                                       'current_version', v_item.version,
                                       'current', to_jsonb(v_item));
      else
        case p_kind
          when 'qty' then
            perform public.fn_update_item_qty(p_target_id, (v_args ->> 'qty')::numeric);
          when 'notes' then
            perform public.fn_update_item_notes(p_target_id, v_args ->> 'notes');
          when 'details' then
            perform public.fn_update_item_details(
              p_target_id, v_args ->> 'product_name', (v_args ->> 'qty')::numeric,
              coalesce((v_args ->> 'is_takeout')::boolean, false),
              (v_args ->> 'discounts')::numeric, v_args ->> 'notes');
          when 'discount' then
            perform public.fn_update_item_discount(p_target_id, (v_args ->> 'discounts')::numeric);
          when 'discount_notes' then
            perform public.fn_update_item_discount_and_notes(
              p_target_id, (v_args ->> 'discounts')::numeric, v_args ->> 'notes');
          when 'takeout' then
            perform public.fn_toggle_item_takeout(
              p_target_id, coalesce((v_args ->> 'is_takeout')::boolean, false));
          when 'modifiers' then
            perform public.fn_replace_order_item_modifiers(
              p_target_id, coalesce(v_args -> 'modifiers', '[]'::jsonb));
          when 'move' then
            perform public.fn_move_item_to_check(
              p_target_id, (v_args ->> 'check_position')::integer);
          when 'delete' then
            perform public.fn_delete_item(p_target_id);
        end case;

        select version into v_new_version from public.order_items where id = p_target_id;
        v_result := jsonb_build_object(
          'status', 'applied',
          'version', v_new_version,
          'current', (select to_jsonb(oi) from public.order_items oi where oi.id = p_target_id)
        );
      end if;
    end if;
  elsif p_kind = 'move_batch' then
    -- Cada línea con su versión: [{"id": …, "version": …}].
    for v_entry in select * from jsonb_array_elements(coalesce(v_args -> 'items', '[]'::jsonb)) loop
      select * into v_item
        from public.order_items
       where id = (v_entry ->> 'id')::uuid and order_id = p_order_id
       for update;
      if not found or v_item.status::text in ('paid', 'void') then
        v_conflict := 'item_missing';
      elsif not coalesce(p_force, false)
            and v_item.version is distinct from (v_entry ->> 'version')::bigint then
        v_conflict := 'stale_version';
      end if;
      v_ids := array_append(v_ids, (v_entry ->> 'id')::uuid);
    end loop;
    if v_conflict is not null then
      v_result := jsonb_build_object('status', 'conflict', 'reason', v_conflict);
    else
      perform public.fn_move_items_to_check_batch(
        v_ids, (v_args ->> 'check_position')::integer);
      v_result := jsonb_build_object(
        'status', 'applied',
        'versions', (select jsonb_object_agg(oi.id::text, oi.version)
                       from public.order_items oi where oi.id = any(v_ids)));
    end if;
  elsif p_kind = 'consolidate_check' then
    -- Une las líneas iguales de una subcuenta con lo que hay AHORA, bajo el
    -- candado de la orden (antes el equipo sumaba lo que había leído y
    -- escribía la cantidad absoluta: pisaba un cambio de otro equipo). Mismo
    -- criterio que tenía la app: producto, nombre, sku, precio, para llevar,
    -- estado y nota; las líneas con extras no se unen; la primera queda.
    if p_target_id is null then
      raise exception 'EDIT_TARGET_REQUIRED' using errcode = '22004';
    end if;
    if not exists (
      select 1 from public.order_checks c
       where c.id = p_target_id and c.order_id = p_order_id
    ) then
      raise exception 'CHECK_OUT_OF_SCOPE' using errcode = '42501';
    end if;
    perform 1 from public.order_items
      where check_id = p_target_id and order_id = p_order_id
      for update;
    for v_group in
      select array_agg(oi.id order by oi.created_at, oi.id) as ids,
             sum(coalesce(oi.qty, oi.quantity, 1)) as sum_qty,
             sum(coalesce(oi.discounts, 0)) as sum_discounts
        from public.order_items oi
       where oi.check_id = p_target_id
         and oi.order_id = p_order_id
         and oi.status::text not in ('paid', 'void')
         and not exists (select 1 from public.order_item_modifiers m where m.item_id = oi.id)
       group by oi.product_id, oi.product_name, oi.sku, oi.unit_price,
                oi.is_takeout, oi.status, coalesce(oi.notes, '')
      having count(*) > 1
    loop
      perform public.fn_consolidate_keeper_atomic(
        v_group.ids[1],
        v_group.ids[2:],
        case when coalesce((v_args ->> 'normalize_qty_to_integer')::boolean, false)
             then round(v_group.sum_qty) else v_group.sum_qty end,
        v_group.sum_discounts);
      v_merged := v_merged + cardinality(v_group.ids) - 1;
      v_kept := v_kept || jsonb_build_object(
        v_group.ids[1]::text,
        (select oi.version from public.order_items oi where oi.id = v_group.ids[1]));
      v_removed := v_removed || to_jsonb(v_group.ids[2:]);
    end loop;
    -- Versiones de las que quedan y las que se unieron: el equipo las adopta
    -- (son cambios suyos, no de otro).
    v_result := jsonb_build_object('status', 'applied', 'merged', v_merged,
                                   'versions', v_kept, 'removed', v_removed);
  else
    -- Nivel cuenta: la versión de la orden.
    if not coalesce(p_force, false) then
      if p_base_version is null then
        raise exception 'EDIT_BASE_REQUIRED' using errcode = '22004';
      end if;
      if v_order.version <> p_base_version then
        v_conflict := 'stale_version';
      end if;
    end if;
    if v_conflict is not null then
      v_result := jsonb_build_object('status', 'conflict', 'reason', v_conflict,
                                     'current_version', v_order.version,
                                     'current', to_jsonb(v_order));
    else
      case p_kind
        when 'delivery_fee' then
          perform public.fn_set_delivery_fee(p_order_id, (v_args ->> 'amount')::numeric);
        when 'excluded_taxes' then
          perform public.fn_set_order_excluded_taxes(
            p_order_id,
            array(select jsonb_array_elements_text(coalesce(v_args -> 'tax_ids', '[]'::jsonb))::uuid),
            nullif(v_args ->> 'employee_id', '')::uuid);
        when 'order_takeout' then
          perform public.fn_mark_order_takeout(
            p_order_id, coalesce((v_args ->> 'is_takeout')::boolean, false));
        when 'session_customer' then
          perform public.fn_assign_customer_to_session(
            v_order.session_id, nullif(v_args ->> 'customer_id', '')::uuid,
            v_args ->> 'customer_name');
        when 'check_customer' then
          if not exists (
            select 1 from public.order_checks c
             where c.id = p_target_id and c.order_id = p_order_id
          ) then
            raise exception 'CHECK_OUT_OF_SCOPE' using errcode = '42501';
          end if;
          update public.order_checks
             set customer_id = nullif(v_args ->> 'customer_id', '')::uuid,
                 customer_name = nullif(v_args ->> 'customer_name', ''),
                 customer_rnc = case when v_args ? 'customer_rnc'
                                     then nullif(v_args ->> 'customer_rnc', '')
                                     else customer_rnc end
           where id = p_target_id;
      end case;

      update public.orders set version = version + 1
       where id = p_order_id
      returning version into v_new_version;
      v_result := jsonb_build_object('status', 'applied', 'version', v_new_version);
    end if;
  end if;

  insert into public.order_edit_ops (op_id, order_id, kind, target_id, result)
  values (p_op_id, p_order_id, p_kind, p_target_id, v_result);
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Líneas de auditoría en la nota de la sesión
-- ---------------------------------------------------------------------------
create or replace function public.fn_append_session_note(
  p_session_id uuid,
  p_line       text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business uuid;
  v_line     text := nullif(trim(coalesce(p_line, '')), '');
begin
  if v_line is null then
    return;
  end if;
  select coalesce(ts.business_id, z.business_id) into v_business
    from public.table_sessions ts
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z on z.id = dt.zone_id
   where ts.id = p_session_id;
  if v_business is null then
    raise exception 'SESSION_NOT_FOUND';
  end if;
  if not (
    coalesce(auth.role(), '') = 'service_role'
    or (session_user in ('postgres', 'supabase_admin') and nullif(auth.role(), '') is null)
    or coalesce(public.is_member_of_business(v_business), false)
  ) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;
  update public.table_sessions
     set note = case when nullif(trim(coalesce(note, '')), '') is null then v_line
                     else note || E'\n' || v_line end
   where id = p_session_id;
end;
$$;

revoke all on function public.fn_append_session_note(uuid, text) from public, anon;
grant execute on function public.fn_append_session_note(uuid, text) to authenticated, service_role;

revoke all on function public.fn_apply_order_edit(uuid, uuid, text, uuid, bigint, jsonb, jsonb, boolean) from public, anon;
grant execute on function public.fn_apply_order_edit(uuid, uuid, text, uuid, bigint, jsonb, jsonb, boolean) to authenticated, service_role;
revoke all on function public.trg_order_item_version_from_modifiers() from public, anon, authenticated;

comment on function public.fn_apply_order_edit(uuid, uuid, text, uuid, bigint, jsonb, jsonb, boolean) is
  'T04 (20261010_0006): única entrada para editar cuentas y líneas. Candado de la orden (el del cobro), reintentos por op_id, rechazo de versiones viejas; llama las funciones de edición vivas.';

commit;
