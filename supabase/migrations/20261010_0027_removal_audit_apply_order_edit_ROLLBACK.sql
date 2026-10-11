-- Reversa de 20261010_0027: fn_log_order_item_removal vuelve a la de
-- 20260919_0002 (los borrados por fn_apply_order_edit quedan otra vez fuera
-- del reporte de Eliminaciones). Los registros corregidos por 0027 se dejan
-- como están: fueron borrados de verdad hechos por un usuario.
-- Se niega a correr si la función en vivo no es la de 0027 ni la de 0919_0002.

begin;

do $$
declare
  v_md5 text;
begin
  select md5(prosrc) into v_md5
    from pg_proc
   where oid = to_regprocedure('public.fn_log_order_item_removal()');
  if v_md5 is distinct from '7111dea2960a6a67f8f2834de8cfdcf1'
     and v_md5 is distinct from '90d9616ae8c2101123985410c5d27511' then
    raise exception 'fn_log_order_item_removal en vivo no es la de 0027 (md5 %). No se revierte.',
      coalesce(v_md5, 'no existe');
  end if;
end $$;

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

commit;
