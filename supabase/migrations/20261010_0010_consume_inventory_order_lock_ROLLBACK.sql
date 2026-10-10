-- Reversa de 20261010_0010: quita el envoltorio con candado y devuelve su
-- nombre a la función viva (consume_inventory_from_order_unlocked).
begin;
do $$
declare
  v_current text;
begin
  if to_regprocedure('public.consume_inventory_from_order_unlocked(uuid)') is null then
    return;  -- no aplicada
  end if;
  select p.prosrc into v_current
    from pg_proc p
   where p.oid = to_regprocedure('public.consume_inventory_from_order(uuid)');
  if v_current is not null and v_current not like '%consume_inventory_from_order_unlocked%' then
    raise exception 'consume_inventory_from_order ya no es el envoltorio de 20261010_0010: '
                    'revisar a mano. No se revirtió nada.';
  end if;
  drop function if exists public.consume_inventory_from_order(uuid);
  alter function public.consume_inventory_from_order_unlocked(uuid)
    rename to consume_inventory_from_order;
end $$;
commit;
