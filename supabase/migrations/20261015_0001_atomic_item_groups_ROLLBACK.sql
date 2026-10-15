begin;
set local lock_timeout='5s';
drop function if exists public.fn_apply_order_item_group(uuid,uuid,jsonb,boolean);
-- La bitácora conserva los grupos aplicados para que reinstalar no los repita.
do $$ declare s text; begin
 s:=pg_get_functiondef('public.fn_offer_quantity_discount()'::regprocedure);
 s:=replace(s,E'  -- atomic_offer_group\n  if current_setting(''mangopos.atomic_offer_group'',true) = ''on'' then return new; end if;','');
 execute s;
end $$;
do $$ declare s text; a int;b int; begin
 s:=pg_get_functiondef('public.fn_apply_order_edit(uuid,uuid,text,uuid,bigint,jsonb,jsonb,boolean)'::regprocedure);
 a:=position('  -- reprice_grouped_offer_rounds' in s);
 b:=position('  insert into public.order_edit_ops (op_id, order_id, kind, target_id, result)' in s);
 if a>0 and b>a then s:=substring(s,1,a-1)||substring(s,b); execute s; end if;
end $$;
drop function if exists public.fn_reprice_order_offer_groups(uuid);
notify pgrst,'reload schema';
commit;
