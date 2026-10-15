-- Cambios de varias líneas y altas de rondas: todo o nada y replay estable.
begin;
set local lock_timeout='5s';
create table if not exists public.order_group_edit_ops(
 op_id uuid primary key,order_id uuid not null,payload jsonb not null,
 result jsonb not null,created_at timestamptz not null default now());
alter table public.order_group_edit_ops enable row level security;
revoke all on public.order_group_edit_ops from public,anon,authenticated;

-- La edición agrupada recalcula el beneficio completo después de aplicar
-- todas sus cantidades. Las ediciones individuales mantienen su protección.
do $$ declare s text; begin
 s:=pg_get_functiondef('public.fn_offer_quantity_discount()'::regprocedure);
 if position('atomic_offer_group' in s)=0 then
   s:=replace(s,'begin', E'begin\n  -- atomic_offer_group\n  if current_setting(''mangopos.atomic_offer_group'',true) = ''on'' then return new; end if;');
   execute s;
 end if;
end $$;

create or replace function public.fn_reprice_order_offer_groups(p_order_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare row public.order_items%rowtype;rule text[];k text;ids uuid[];ix integer;
 group_row record;cum numeric;benefit numeric;budget numeric;room numeric;amount numeric;
begin
   -- Recalcular ofertas de las subcuentas afectadas sobre las rondas reales.
   -- Se forman paquetes por producto, promoción, regla y precio de la venta.
   for group_row in
     select oi.check_id,oi.product_id,oi.unit_price,
       (regexp_match(oi.notes,'\[DEAL:[^\]]*\]'))[1] as marker,
       (regexp_match(oi.notes,'\[DEAL_RULE:[^\]]*\]'))[1] as rule_marker
     from order_items oi where oi.order_id=p_order_id and oi.status::text not in ('paid','void')
       and oi.notes like '%[DEAL_RULE:%' and oi.notes not like '%[CORTESIA:%'
       and not exists(select 1 from order_checks oc where oc.id=oi.check_id and oc.is_closed)
     group by 1,2,3,4,5
   loop
     select array_agg(oi.id order by oi.created_at,oi.id) into ids from order_items oi
       where oi.order_id=p_order_id and oi.check_id is not distinct from group_row.check_id
       and oi.product_id is not distinct from group_row.product_id and oi.unit_price=group_row.unit_price
       and oi.status::text not in ('paid','void') and oi.notes not like '%[CORTESIA:%'
       and position(group_row.marker in oi.notes)>0 and position(group_row.rule_marker in oi.notes)>0;
     rule:=regexp_match(group_row.rule_marker,'\[DEAL_RULE:([0-9]+):([0-9]+(?:\.[0-9]+)?)\]');
     if rule is null or rule[1]::integer<2 then raise exception 'INVALID_OFFER_RULE'; end if;
     update order_items set discounts=0 where id=any(ids);
     cum:=0; benefit:=0;
     for ix in 1..coalesce(array_length(ids,1),0) loop
       select * into row from order_items where id=ids[ix];
       cum:=cum+row.qty; budget:=floor(cum/rule[1]::numeric)*rule[2]::numeric-benefit;
       benefit:=benefit+budget;
       for k in select x::text from generate_series(ix,1,-1) x loop
         exit when budget<=0;
         select greatest(subtotal+tax-discounts,0) into room from order_items where id=ids[k::integer];
         amount:=least(budget,room);
         update order_items set discounts=round(discounts+amount,2) where id=ids[k::integer];
         budget:=budget-amount;
       end loop;
     end loop;
   end loop;
end $$;
revoke all on function public.fn_reprice_order_offer_groups(uuid) from public,anon,authenticated;

create or replace function public.fn_apply_order_item_group(
 p_op_id uuid,p_order_id uuid,p_actions jsonb,p_force boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
 biz uuid; prior record; a jsonb; args jsonb; r jsonb; source public.order_items%rowtype;
 row public.order_items%rowtype; rule text[]; k text; ids uuid[]; ix integer;
 group_row record; cum numeric; benefit numeric; budget numeric; room numeric; amount numeric;
 out_ids uuid[]:=array[]::uuid[]; original_cfg text:=current_setting('mangopos.atomic_offer_group',true);
begin
 if p_op_id is null or p_actions is null or jsonb_typeof(p_actions)<>'array' or jsonb_array_length(p_actions) not between 1 and 500 then
   raise exception 'INVALID_ITEM_GROUP' using errcode='22023';
 end if;
 select coalesce(ts.business_id,z.business_id) into biz from orders o
 join table_sessions ts on ts.id=o.session_id left join dining_tables dt on dt.id=ts.table_id
 left join zones z on z.id=dt.zone_id where o.id=p_order_id;
 if biz is null then raise exception 'ORDER_NOT_FOUND'; end if;
 if not (coalesce(auth.role(),'')='service_role' or
   (session_user in ('postgres','supabase_admin') and nullif(auth.role(),'') is null) or
   coalesce(is_member_of_business(biz),false)) then
   raise exception 'UNAUTHORIZED_BUSINESS' using errcode='42501';
 end if;
 perform 1 from orders where id=p_order_id for update;
 select * into prior from order_group_edit_ops where op_id=p_op_id;
 if found then
   if prior.order_id<>p_order_id or prior.payload<>p_actions then
     raise exception 'GROUP_OP_ID_CONFLICT' using errcode='MP430';
   end if;
   return prior.result||'{"replayed":true}'::jsonb;
 end if;
 if exists(select 1 from orders where id=p_order_id and (closed_at is not null or status_ext::text in ('paid','void'))) then
   return '{"status":"conflict","reason":"order_closed"}'::jsonb;
 end if;
 -- Una excepción/conflicto posterior revierte también las primeras líneas y
 -- sus auditorías, modificaciones de inventario y bitácoras individuales.
 begin
   perform set_config('mangopos.atomic_offer_group','on',true);
   for a in select value from jsonb_array_elements(p_actions) loop
     args:=coalesce(a->'args','{}'::jsonb);
     if a->>'kind'='add' then
       if not exists(select 1 from jsonb_array_elements(p_actions) c
          where c->>'kind'='details' and c->>'item_id'=a->>'source_id') then
         raise exception 'GROUP_ADD_SOURCE_BASE_REQUIRED' using errcode='22023';
       end if;
       select * into source from order_items where id=(a->>'source_id')::uuid and order_id=p_order_id for update;
       if not found or source.status::text in ('paid','void') or
          exists(select 1 from order_checks where id=source.check_id and is_closed) then
         r:='{"status":"conflict","reason":"item_closed"}'; raise exception using errcode='MP440';
       end if;
       if (args->>'qty')::numeric<=0 or (args->>'qty')::numeric<>trunc((args->>'qty')::numeric) then
         raise exception 'INVALID_GROUP_QUANTITY' using errcode='22023';
       end if;
       insert into order_items(id,order_id,check_id,product_id,product_name,sku,qty,quantity,
         unit_price,tax_mode,tax_rate,original_tax_rate,is_takeout,notes,status,discounts,created_by_employee_id)
       values((a->>'item_id')::uuid,p_order_id,source.check_id,source.product_id,source.product_name,source.sku,
         (args->>'qty')::numeric,(args->>'qty')::integer,source.unit_price,source.tax_mode,source.tax_rate,
         source.original_tax_rate,coalesce((args->>'is_takeout')::boolean,source.is_takeout),
         args->>'notes','draft',greatest(coalesce((args->>'discounts')::numeric,0),0),source.created_by_employee_id);
       insert into order_item_modifiers(item_id,name,qty,price,menu_item_id,modifier_id)
         select (a->>'item_id')::uuid,name,qty,price,menu_item_id,modifier_id from order_item_modifiers where item_id=source.id;
       -- Copiar el snapshot de oferta del servidor, nunca el que pudo editar
       -- un cliente. El borrador entra a cocina como una ronda nueva.
       update order_items set notes=source.notes,promotion_id=source.promotion_id where id=(a->>'item_id')::uuid;
     elsif a->>'kind' in ('details','delete') then
       r:=fn_apply_order_edit(gen_random_uuid(),p_order_id,a->>'kind',(a->>'item_id')::uuid,
         (a->>'base_version')::bigint,a->'expected',args,p_force);
       if r->>'status'<>'applied' then raise exception using errcode='MP440'; end if;
     else raise exception 'INVALID_GROUP_ACTION' using errcode='22023'; end if;
     if a->>'removal_reason' is not null and
        to_regprocedure('public.fn_note_order_item_removal(uuid,text,uuid,text,boolean)') is not null then
       perform public.fn_note_order_item_removal((a->>'item_id')::uuid,a->>'removal_reason',
         (a->>'employee_id')::uuid,a->>'reason_code',(a->>'is_waste')::boolean);
     end if;
     out_ids:=array_append(out_ids,(a->>'item_id')::uuid);
   end loop;
   perform fn_reprice_order_offer_groups(p_order_id);
   perform set_config('mangopos.atomic_offer_group',coalesce(original_cfg,''),true);
   perform fn_recalc_order_totals(p_order_id);
 exception when sqlstate 'MP440' then
   perform set_config('mangopos.atomic_offer_group',coalesce(original_cfg,''),true);
   return r;
 end;
 r:=jsonb_build_object('status','applied','versions',
   (select coalesce(jsonb_object_agg(id::text,version),'{}'::jsonb) from order_items where order_id=p_order_id));
 insert into order_group_edit_ops(op_id,order_id,payload,result) values(p_op_id,p_order_id,p_actions,r);
 return r;
end $$;
revoke all on function public.fn_apply_order_item_group(uuid,uuid,jsonb,boolean) from public,anon;
grant execute on function public.fn_apply_order_item_group(uuid,uuid,jsonb,boolean) to authenticated,service_role;
-- Los movimientos y cantidades individuales también pueden separar rondas
-- de una oferta. Recalcular por subcuenta, conservando el candado del cobro.
do $$ declare s text;needle text; begin
 s:=pg_get_functiondef('public.fn_apply_order_edit(uuid,uuid,text,uuid,bigint,jsonb,jsonb,boolean)'::regprocedure);
 if position('-- reprice_grouped_offer_rounds' in s)=0 then
   needle:='  insert into public.order_edit_ops (op_id, order_id, kind, target_id, result)';
   if position(needle in s)=0 then raise exception 'GROUP_EDIT_REPRICE_PATCH_NOT_FOUND'; end if;
   s:=replace(s,needle,$patch$  -- reprice_grouped_offer_rounds
  if v_result->>'status'='applied' and p_kind in ('qty','details','delete','move','move_batch','consolidate_check')
     and coalesce(current_setting('mangopos.atomic_offer_group',true),'') <> 'on' then
    perform public.fn_reprice_order_offer_groups(p_order_id);
    perform public.fn_recalc_order_totals(p_order_id);
    if p_target_id is not null then
      v_result:=v_result||jsonb_build_object('version',(select version from public.order_items where id=p_target_id),
        'current',(select to_jsonb(oi) from public.order_items oi where id=p_target_id));
    end if;
  end if;

$patch$||needle);
   execute s;
 end if;
end $$;
notify pgrst,'reload schema';
commit;
