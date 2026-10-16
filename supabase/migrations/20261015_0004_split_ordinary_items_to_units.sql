-- Preparar productos ordinarios como unidades independientes para subdividir.
-- Mantiene paquetes DEAL y cuentas protegidas; no modifica datos al instalar.
begin;
set local lock_timeout='5s';
create table if not exists public.bill_split_unit_function_backups(
  signature text primary key, definition text not null);
alter table public.bill_split_unit_function_backups enable row level security;
revoke all on public.bill_split_unit_function_backups from public,anon,authenticated;
insert into public.bill_split_unit_function_backups
select p.oid::regprocedure::text,pg_get_functiondef(p.oid) from pg_proc p
where p.oid in(to_regprocedure('public.fn_explode_items_to_units(uuid)'),
  to_regprocedure('public.fn_explode_items_for_split(uuid)')) on conflict do nothing;

create or replace function public.fn_explode_items_to_units(p_order_id uuid)
returns integer language plpgsql security definer set search_path=public as $$
declare
  item public.order_items%rowtype; mods jsonb; modifier jsonb; taxes jsonb; tax_row jsonb;
  units integer; idx integer; unit_id uuid; new_ids uuid[]; created_count integer:=0;
  discount numeric; tax_amount numeric; before_amount numeric; after_amount numeric;
  cfg text:=current_setting('mangopos.atomic_bill_split',true);
begin
  -- La preparación usa el mismo candado y autorización que dividir/cobrar.
  perform fn_lock_bill_split_order(p_order_id);
  if exists(select 1 from orders where id=p_order_id and
      (closed_at is not null or status_ext::text in ('paid','void')))
    or exists(select 1 from fiscal_documents where order_id=p_order_id
      and check_id is null and status::text='active') then
    raise exception 'ORDER_CLOSED';
  end if;
  perform set_config('mangopos.atomic_bill_split','on',true);
  for item in select * from order_items where order_id=p_order_id
    and status::text not in ('paid','void') and qty>1 and qty=trunc(qty)
    and qty::text not in ('NaN','Infinity','-Infinity')
    and position('[DEAL:' in coalesce(notes,''))=0
    and not fn_bill_split_check_protected(check_id)
    order by created_at,id for update loop
    units:=item.qty::integer;
    select coalesce(jsonb_agg(to_jsonb(m)),'[]') into mods
      from order_item_modifiers m where m.item_id=item.id;
    select coalesce(jsonb_agg(to_jsonb(t)),'[]') into taxes
      from order_item_tax_lines t where t.order_item_id=item.id;
    before_amount:=item.total; new_ids:=array[]::uuid[];
    for idx in 1..units loop
      -- Reparto acumulado: conserva el descuento completo sin arrastrar
      -- residuos de redondeo ni convertir extras en cantidades fraccionadas.
      discount:=(case when idx=units then coalesce(item.discounts,0)
        else round(coalesce(item.discounts,0)*idx/units,2) end)
        -round(coalesce(item.discounts,0)*(idx-1)/units,2);
      if idx=1 then
        unit_id:=item.id;
        update order_items set qty=1,quantity=1,discounts=discount where id=unit_id;
      else
        insert into order_items(order_id,check_id,product_id,product_name,sku,qty,quantity,unit_price,
          tax_mode,tax_rate,original_tax_rate,is_takeout,status,notes,discounts,created_at,
          created_by_employee_id,promotion_id,print_area_code,kitchen_sent_at,started_at,ready_at)
        values(item.order_id,item.check_id,item.product_id,item.product_name,item.sku,1,1,item.unit_price,
          item.tax_mode,item.tax_rate,item.original_tax_rate,item.is_takeout,item.status,item.notes,discount,item.created_at,
          item.created_by_employee_id,item.promotion_id,item.print_area_code,item.kitchen_sent_at,item.started_at,item.ready_at)
        returning id into unit_id;
        for modifier in select value from jsonb_array_elements(mods) loop
          insert into order_item_modifiers(item_id,name,qty,price,menu_item_id,modifier_id)
            values(unit_id,modifier->>'name',(modifier->>'qty')::numeric,(modifier->>'price')::numeric,
              (modifier->>'menu_item_id')::uuid,(modifier->>'modifier_id')::uuid);
        end loop;
        -- Algunas instalaciones no recalculan al insertar modificadores.
        update order_items set unit_price=unit_price where id=unit_id;
        created_count:=created_count+1;
      end if;
      new_ids:=array_append(new_ids,unit_id);
      if jsonb_array_length(taxes)>0 then
        delete from order_item_tax_lines where order_item_id=unit_id;
        for tax_row in select value from jsonb_array_elements(taxes) loop
          tax_amount:=(case when idx=units then (tax_row->>'amount')::numeric
            else round((tax_row->>'amount')::numeric*idx/units,2) end)
            -round((tax_row->>'amount')::numeric*(idx-1)/units,2);
          insert into order_item_tax_lines(order_item_id,tax_id,tax_name,tax_rate,amount)
            values(unit_id,(tax_row->>'tax_id')::uuid,tax_row->>'tax_name',(tax_row->>'tax_rate')::numeric,tax_amount);
        end loop;
      else
        perform fn_populate_item_tax_lines(unit_id);
      end if;
    end loop;
    select sum(total) into after_amount from order_items where id=any(new_ids);
    if abs(before_amount-after_amount)>0.01 then raise exception 'SPLIT_AMOUNT_MISMATCH'; end if;
  end loop;
  if created_count>0 then perform fn_recalc_order_totals(p_order_id); end if;
  perform set_config('mangopos.atomic_bill_split',coalesce(cfg,''),true);
  return created_count;
end $$;

create or replace function public.fn_explode_items_for_split(p_order_id uuid)
returns integer language sql security definer set search_path=public as $$
  select public.fn_explode_items_to_units(p_order_id)
$$;
revoke all on function public.fn_explode_items_to_units(uuid),public.fn_explode_items_for_split(uuid) from public,anon;
grant execute on function public.fn_explode_items_to_units(uuid),public.fn_explode_items_for_split(uuid) to authenticated,service_role;
notify pgrst,'reload schema';
commit;
