begin;
set local lock_timeout='5s';
do $$ declare s text; a integer; b integer; marker text; begin
  s:=pg_get_functiondef('public.fn_apply_order_item_group(uuid,uuid,jsonb,boolean)'::regprocedure);
  marker:=E'       -- end_recover_legacy_group_rule\n';
  a:=position('       -- recover_legacy_group_rule' in s); b:=position(marker in s);
  if a>0 and b>a then s:=substring(s,1,a-1)||substring(s,b+length(marker)); execute s; end if;
  s:=pg_get_functiondef('public.fn_offer_quantity_discount()'::regprocedure);
  marker:=E'  -- end_recover_legacy_sale_rule\n';
  a:=position('  -- recover_legacy_sale_rule' in s); b:=position(marker in s);
  if a>0 and b>a then s:=substring(s,1,a-1)||substring(s,b+length(marker)); execute s; end if;
end $$;
drop function if exists public.fn_legacy_offer_rule(public.order_items);
notify pgrst,'reload schema';
commit;
