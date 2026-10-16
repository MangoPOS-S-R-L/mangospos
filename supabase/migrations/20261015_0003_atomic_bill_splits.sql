-- División completa: mismo candado que cobros, idempotencia y aislamiento
-- por negocio. No modifica ventas ni comprobantes al instalarse.
begin;
set local lock_timeout='5s';
create table if not exists public.bill_split_ops(
  op_id uuid primary key, order_id uuid not null, payload jsonb not null,
  result jsonb not null, created_at timestamptz not null default now());
alter table public.bill_split_ops enable row level security;
revoke all on public.bill_split_ops from public,anon,authenticated;
create table if not exists public.bill_split_function_backups(
  signature text primary key, definition text not null);
alter table public.bill_split_function_backups enable row level security;
revoke all on public.bill_split_function_backups from public,anon,authenticated;
insert into public.bill_split_function_backups
select p.oid::regprocedure::text,pg_get_functiondef(p.oid)
from pg_proc p where p.oid in (
  to_regprocedure('public.fn_split_items_equally(uuid,integer)'),
  to_regprocedure('public.fn_auto_close_empty_subcheck()'),
  to_regprocedure('public.fn_reprice_order_offer_groups(uuid)'))
on conflict do nothing;

create or replace function public.fn_lock_bill_split_order(p_order_id uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare biz uuid;
begin
  select coalesce(ts.business_id,z.business_id) into biz from orders o
    join table_sessions ts on ts.id=o.session_id
    left join dining_tables dt on dt.id=ts.table_id left join zones z on z.id=dt.zone_id
    where o.id=p_order_id;
  if biz is null then raise exception 'ORDER_NOT_FOUND'; end if;
  if not (coalesce(auth.role(),'')='service_role' or
      (session_user in ('postgres','supabase_admin') and nullif(auth.role(),'') is null) or
      coalesce(is_member_of_business(biz),false)) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode='42501';
  end if;
  perform 1 from orders where id=p_order_id for update;
  return biz;
end $$;
revoke all on function public.fn_lock_bill_split_order(uuid) from public,anon,authenticated;

create or replace function public.fn_bill_split_check_protected(p_check_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select p_check_id is not null and (
    exists(select 1 from order_checks where id=p_check_id and is_closed) or
    exists(select 1 from order_items where check_id=p_check_id and status::text='paid') or
    exists(select 1 from fiscal_documents where check_id=p_check_id and status::text='active') or
    exists(select 1 from payments where check_id=p_check_id and status::text='completed'))
$$;
revoke all on function public.fn_bill_split_check_protected(uuid) from public,anon,authenticated;

-- Una cuenta con comprobante/pago está protegida aunque un cliente antiguo
-- haya dejado is_closed=false. Recalcular otra subcuenta no la reinterpreta.
do $$ declare s text; needle text; begin
  s:=pg_get_functiondef('public.fn_reprice_order_offer_groups(uuid)'::regprocedure);
  if position('-- bill_split_financial_protection' in s)=0 then
    needle:='and not exists(select 1 from order_checks oc where oc.id=oi.check_id and oc.is_closed)';
    if position(needle in s)=0 then raise exception 'BILL_SPLIT_REPRICE_PATCH_NOT_FOUND'; end if;
    s:=replace(s,needle,E'-- bill_split_financial_protection\n       and not public.fn_bill_split_check_protected(oi.check_id)');
    execute s;
  end if;
end $$;

-- Evitar cierres transitorios mientras se intercambian productos entre cuentas.
-- Al terminar solo se cierran los orígenes que realmente quedaron vacíos.
do $$ declare s text; begin
  if to_regprocedure('public.fn_auto_close_empty_subcheck()') is not null then
    s:=pg_get_functiondef('public.fn_auto_close_empty_subcheck()'::regprocedure);
    if position('-- atomic_bill_split' in s)=0 then
      s:=regexp_replace(s,'\mbegin\M',E'begin\n  -- atomic_bill_split\n  if current_setting(''mangopos.atomic_bill_split'',true) = ''on'' then return coalesce(new,old); end if;','i');
      execute s;
    end if;
  end if;
end $$;

create or replace function public.fn_finish_bill_split(p_order_id uuid,p_sources uuid[])
returns void language plpgsql security definer set search_path=public as $$
begin
  perform fn_reprice_order_offer_groups(p_order_id);
  perform fn_recalc_order_totals(p_order_id);
  update order_checks c set is_closed=true,closed_at=now()
    where c.order_id=p_order_id and c.id=any(p_sources) and c.position>1 and not c.is_closed
      and not exists(select 1 from order_items i where i.check_id=c.id and i.status::text not in ('paid','void'));
end $$;
revoke all on function public.fn_finish_bill_split(uuid,uuid[]) from public,anon,authenticated;

-- También protege a clientes anteriores que aún llaman esta firma.
create or replace function public.fn_split_items_equally(p_order_id uuid,p_people integer)
returns setof public.order_checks language plpgsql security definer set search_path=public as $$
declare
  item public.order_items%rowtype; ch public.order_checks%rowtype; tax_snapshot jsonb; tax_row jsonb;
  targets uuid[]:=array[]::uuid[]; sources uuid[]; pos integer:=2; idx integer;
  current_idx integer:=1; in_current integer:=0; target_qty integer; total_qty numeric;
  item_qty integer; remaining integer; chunk integer; new_id uuid; first_chunk boolean;
  discount numeric; discount_left numeric; normal_before numeric; normal_after numeric;
  cfg text:=current_setting('mangopos.atomic_bill_split',true);
  offer_cfg text:=current_setting('mangopos.atomic_offer_group',true);
begin
  perform fn_lock_bill_split_order(p_order_id);
  if p_people is null or p_people not between 2 and 4 then raise exception 'PEOPLE_OUT_OF_RANGE'; end if;
  if exists(select 1 from orders where id=p_order_id and (closed_at is not null or status_ext::text in ('paid','void')))
    or exists(select 1 from fiscal_documents where order_id=p_order_id and check_id is null and status::text='active')
    then raise exception 'ORDER_CLOSED'; end if;
  if exists(select 1 from order_items i where i.order_id=p_order_id and i.status::text not in ('paid','void')
    and fn_bill_split_check_protected(i.check_id)) then raise exception 'CHECK_CLOSED'; end if;
  if exists(select 1 from order_items i join order_checks c on c.id=i.check_id
    where i.order_id=p_order_id and i.status::text not in ('paid','void') and c.position>1)
    then raise exception 'ACTIVE_SPLIT_EXISTS'; end if;
  if exists(select 1 from order_items where order_id=p_order_id and status::text not in ('paid','void')
    and (qty is null or qty<=0 or qty<>trunc(qty) or qty::text in ('NaN','Infinity','-Infinity')))
    then raise exception 'FRACTIONAL_QTY_NOT_ALLOWED'; end if;
  select coalesce(sum(qty),0),array_agg(distinct check_id),coalesce(sum(total) filter(
    where position('[DEAL:' in coalesce(notes,''))=0),0)
    into total_qty,sources,normal_before from order_items
    where order_id=p_order_id and status::text not in ('paid','void');
  if total_qty<p_people then raise exception 'NOT_ENOUGH_ITEMS'; end if;
  if mod(total_qty,p_people)<>0 then raise exception 'NON_DIVISIBLE_QTY'; end if;
  target_qty:=total_qty::integer/p_people;
  for idx in 1..p_people loop
    loop
      if pos>26 then raise exception 'MAX_CHECKS_REACHED'; end if;
      select * into ch from order_checks where order_id=p_order_id and position=pos for update;
      if not found then
        targets:=array_append(targets,fn_get_or_create_check(p_order_id,pos)); exit;
      elsif not fn_bill_split_check_protected(ch.id) then
        targets:=array_append(targets,ch.id); exit;
      end if;
      pos:=pos+1;
    end loop;
    pos:=pos+1;
  end loop;
  perform set_config('mangopos.atomic_bill_split','on',true);
  perform set_config('mangopos.atomic_offer_group','on',true);
  for item in select * from order_items where order_id=p_order_id and status::text not in ('paid','void')
    order by created_at,id for update loop
    select coalesce(jsonb_agg(to_jsonb(t)),'[]') into tax_snapshot
      from order_item_tax_lines t where t.order_item_id=item.id;
    item_qty:=item.qty::integer; remaining:=item_qty; discount_left:=coalesce(item.discounts,0); first_chunk:=true;
    if position('[DEAL:' in coalesce(item.notes,''))>0 then
      -- Cada ronda de oferta conserva su identidad, cantidad y estado.
      if in_current>0 and in_current+item_qty>target_qty and current_idx<p_people then
        current_idx:=current_idx+1;in_current:=0;
      end if;
      update order_items set check_id=targets[current_idx] where id=item.id;
      in_current:=in_current+item_qty;
      if in_current>=target_qty and current_idx<p_people then current_idx:=current_idx+1;in_current:=0; end if;
      continue;
    end if;
    while remaining>0 loop
      if in_current>=target_qty and current_idx<p_people then current_idx:=current_idx+1;in_current:=0; end if;
      chunk:=case when current_idx=p_people then remaining else least(remaining,target_qty-in_current) end;
      discount:=case when chunk=remaining then discount_left else round(item.discounts*chunk/item_qty,2) end;
      if first_chunk then
        update order_items set qty=chunk,quantity=chunk,discounts=discount,check_id=targets[current_idx] where id=item.id;
        new_id:=item.id; first_chunk:=false;
      else
        insert into order_items(order_id,check_id,product_id,product_name,sku,qty,quantity,unit_price,
          tax_mode,tax_rate,original_tax_rate,is_takeout,status,notes,discounts,created_at,created_by_employee_id,promotion_id)
        values(p_order_id,targets[current_idx],item.product_id,item.product_name,item.sku,chunk,chunk,item.unit_price,
          item.tax_mode,item.tax_rate,item.original_tax_rate,item.is_takeout,item.status,item.notes,discount,
          item.created_at,item.created_by_employee_id,item.promotion_id) returning id into new_id;
        -- Los extras se definen POR UNIDAD; copiar sus identidades y cantidades.
        insert into order_item_modifiers(item_id,name,qty,price,menu_item_id,modifier_id)
          select new_id,name,qty,price,menu_item_id,modifier_id from order_item_modifiers where item_id=item.id;
      end if;
      -- Incluir extras incluso en instalaciones sin trigger de recálculo de modifiers.
      update order_items set unit_price=unit_price where id=new_id;
      if jsonb_array_length(tax_snapshot)>0 then
        delete from order_item_tax_lines where order_item_id=new_id;
        for tax_row in select value from jsonb_array_elements(tax_snapshot) loop
          insert into order_item_tax_lines(order_item_id,tax_id,tax_name,tax_rate,amount)
            values(new_id,(tax_row->>'tax_id')::uuid,tax_row->>'tax_name',(tax_row->>'tax_rate')::numeric,
              round((tax_row->>'amount')::numeric*chunk/item_qty,2));
        end loop;
      else
        perform fn_populate_item_tax_lines(new_id);
      end if;
      remaining:=remaining-chunk; discount_left:=discount_left-discount; in_current:=in_current+chunk;
    end loop;
  end loop;
  if exists(select 1 from unnest(targets) t(id) where not exists(select 1 from order_items
    where check_id=t.id and status::text not in ('paid','void'))) then raise exception 'OFFER_PACKAGES_NOT_DIVISIBLE'; end if;
  select coalesce(sum(total),0) into normal_after from order_items where order_id=p_order_id
    and status::text not in ('paid','void') and position('[DEAL:' in coalesce(notes,''))=0;
  if abs(normal_before-normal_after)>0.01 then raise exception 'SPLIT_AMOUNT_MISMATCH'; end if;
  perform fn_finish_bill_split(p_order_id,sources);
  perform set_config('mangopos.atomic_bill_split',coalesce(cfg,''),true);
  perform set_config('mangopos.atomic_offer_group',coalesce(offer_cfg,''),true);
  return query select * from order_checks where id=any(targets) order by position;
end $$;
revoke all on function public.fn_split_items_equally(uuid,integer) from public,anon;
grant execute on function public.fn_split_items_equally(uuid,integer) to authenticated,service_role;

create or replace function public.fn_apply_bill_split(
  p_op_id uuid,p_order_id uuid,p_assignments jsonb default '[]',p_checks jsonb default '[]',
  p_deleted_check_ids uuid[] default '{}',p_base_version bigint default null,
  p_equal_people integer default null,p_force boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  biz uuid; prior record; payload jsonb; r jsonb; a jsonb; c jsonb; expected jsonb;
  item public.order_items%rowtype; check_row public.order_checks%rowtype;
  target uuid; pos integer; sources uuid[]; cid uuid; row_version bigint; existing_check boolean;
  cfg text:=current_setting('mangopos.atomic_bill_split',true);
  offer_cfg text:=current_setting('mangopos.atomic_offer_group',true);
begin
  if p_op_id is null or jsonb_typeof(p_assignments) is distinct from 'array'
    or jsonb_typeof(p_checks) is distinct from 'array' or p_deleted_check_ids is null
    or jsonb_array_length(p_assignments)>5000 or jsonb_array_length(p_checks)>25 then
    raise exception 'INVALID_BILL_SPLIT' using errcode='22023'; end if;
  biz:=fn_lock_bill_split_order(p_order_id);
  payload:=jsonb_build_object('assignments',p_assignments,'checks',p_checks,'deleted',p_deleted_check_ids,
    'base_version',p_base_version,'equal_people',p_equal_people,'force',p_force);
  select * into prior from bill_split_ops where op_id=p_op_id;
  if found then
    if prior.order_id<>p_order_id or prior.payload<>payload then raise exception 'SPLIT_OP_ID_CONFLICT' using errcode='MP430'; end if;
    return prior.result||'{"replayed":true}'::jsonb;
  end if;
  select version into row_version from orders where id=p_order_id;
  if exists(select 1 from orders where id=p_order_id and (closed_at is not null or status_ext::text in ('paid','void')))
    or exists(select 1 from fiscal_documents where order_id=p_order_id and check_id is null and status::text='active')
    then return '{"status":"conflict","reason":"order_closed"}'; end if;
  if not coalesce(p_force,false) and p_base_version is not null and p_base_version<>row_version
    then return '{"status":"conflict","reason":"stale_version"}'; end if;
  if (select count(*)<>count(distinct value->>'item_id') from jsonb_array_elements(p_assignments)) or
     (select count(*)<>count(distinct value->>'position') from jsonb_array_elements(p_checks)) then
    raise exception 'DUPLICATE_SPLIT_ENTRY' using errcode='22023'; end if;
  -- Subtransacción: cualquier conflicto posterior revierte también checks,
  -- traslados, datos fiscales, auditorías y versiones de filas anteriores.
  begin
    perform set_config('mangopos.atomic_bill_split','on',true);
    perform set_config('mangopos.atomic_offer_group','on',true);
    select array_agg(distinct check_id) into sources from order_items where order_id=p_order_id
      and id in(select (value->>'item_id')::uuid from jsonb_array_elements(p_assignments));
    for c in select value from jsonb_array_elements(p_checks) loop
      pos:=(c->>'position')::integer;
      if pos is null or pos not between 2 and 26 then raise exception 'INVALID_CHECK_POSITION' using errcode='22023'; end if;
      select * into check_row from order_checks where order_id=p_order_id and position=pos for update;
      existing_check:=found;
      if existing_check then
        if nullif(c->>'id','') is null or check_row.id is distinct from (c->>'id')::uuid then
          r:='{"status":"conflict","reason":"check_exists"}'; raise exception using errcode='MP441'; end if;
        if fn_bill_split_check_protected(check_row.id) then
          r:='{"status":"conflict","reason":"check_closed"}'; raise exception using errcode='MP441'; end if;
      else
        if nullif(c->>'id','') is not null then
          r:='{"status":"conflict","reason":"check_closed"}'; raise exception using errcode='MP441'; end if;
        target:=fn_get_or_create_check(p_order_id,pos);
        select * into check_row from order_checks where id=target;
      end if;
      if coalesce((c->>'write_metadata')::boolean,false) then
        expected:=c->'expected_metadata';
        if not coalesce(p_force,false) and existing_check and (expected is null or expected<>jsonb_build_object(
          'customer_id',check_row.customer_id,'customer_name',check_row.customer_name,
          'customer_rnc',check_row.customer_rnc,'requested_ncf_type',check_row.requested_ncf_type)) then
          r:='{"status":"conflict","reason":"stale_version"}'; raise exception using errcode='MP441'; end if;
        if nullif(c->>'customer_id','') is not null and not exists(select 1 from customers
          where id=(c->>'customer_id')::uuid and business_id=biz) then
          raise exception 'CUSTOMER_OUT_OF_SCOPE' using errcode='42501'; end if;
        update order_checks set customer_id=nullif(c->>'customer_id','')::uuid,
          customer_name=nullif(btrim(c->>'customer_name'),''),customer_rnc=nullif(btrim(c->>'customer_rnc'),''),
          requested_ncf_type=normalize_ncf_type(c->>'requested_ncf_type') where id=check_row.id;
      end if;
    end loop;
    for a in select value from jsonb_array_elements(p_assignments) loop
      select * into item from order_items where id=(a->>'item_id')::uuid and order_id=p_order_id for update;
      if not found then r:='{"status":"conflict","reason":"item_missing"}'; raise exception using errcode='MP441'; end if;
      if item.status::text in ('paid','void') or fn_bill_split_check_protected(item.check_id) then
        r:='{"status":"conflict","reason":"item_closed"}'; raise exception using errcode='MP441'; end if;
      if not coalesce(p_force,false) then
        expected:=a->'expected';
        if a->>'base_version' is not null then
          if item.version<>(a->>'base_version')::bigint then r:='{"status":"conflict","reason":"stale_version"}'; raise exception using errcode='MP441'; end if;
        elsif expected is null or jsonb_typeof(expected)<>'object' or
          item.qty is distinct from (expected->>'qty')::numeric or
          nullif(btrim(item.notes),'') is distinct from nullif(btrim(expected->>'notes'),'') or
          item.discounts is distinct from (expected->>'discounts')::numeric or
          item.is_takeout is distinct from (expected->>'is_takeout')::boolean or
          item.check_id is distinct from (a->>'source_check_id')::uuid then
          r:='{"status":"conflict","reason":"stale_version"}'; raise exception using errcode='MP441'; end if;
      end if;
      pos:=(a->>'target_position')::integer;
      if pos is null or pos not between 1 and 26 then raise exception 'INVALID_CHECK_POSITION' using errcode='22023'; end if;
      target:=fn_get_or_create_check(p_order_id,pos);
      if fn_bill_split_check_protected(target) then
        -- La principal lógica puede quedar sin check físico si C1 ya se cobró.
        if pos=1 then target:=null;
        else r:='{"status":"conflict","reason":"check_closed"}'; raise exception using errcode='MP441'; end if;
      end if;
      update order_items set check_id=target,
        notes=case when coalesce(item.notes,'') not like '%[DEAL_RULE:%'
          and fn_legacy_offer_rule(item) is not null then
          concat_ws(E'\n',nullif(item.notes,''),fn_legacy_offer_rule(item)) else item.notes end
        where id=item.id;
    end loop;
    foreach cid in array p_deleted_check_ids loop
      select * into check_row from order_checks where id=cid and order_id=p_order_id for update;
      if not found or check_row.position<=1 or fn_bill_split_check_protected(cid) then
        r:='{"status":"conflict","reason":"check_closed"}'; raise exception using errcode='MP441'; end if;
      if exists(select 1 from order_items where check_id=cid) then
        r:='{"status":"conflict","reason":"check_not_empty"}'; raise exception using errcode='MP441'; end if;
      delete from order_checks where id=cid;
    end loop;
    if p_equal_people is not null then perform fn_split_items_equally(p_order_id,p_equal_people); end if;
    perform fn_finish_bill_split(p_order_id,sources);
    perform set_config('mangopos.atomic_bill_split',coalesce(cfg,''),true);
    perform set_config('mangopos.atomic_offer_group',coalesce(offer_cfg,''),true);
  exception when sqlstate 'MP441' then
    return r;
  end;
  r:=jsonb_build_object('status','applied','version',(select version from orders where id=p_order_id),
    'versions',(select coalesce(jsonb_object_agg(id::text,version),'{}') from order_items where order_id=p_order_id));
  insert into bill_split_ops(op_id,order_id,payload,result) values(p_op_id,p_order_id,payload,r);
  return r;
end $$;
revoke all on function public.fn_apply_bill_split(uuid,uuid,jsonb,jsonb,uuid[],bigint,integer,boolean) from public,anon;
grant execute on function public.fn_apply_bill_split(uuid,uuid,jsonb,jsonb,uuid[],bigint,integer,boolean) to authenticated,service_role;
notify pgrst,'reload schema';
commit;
