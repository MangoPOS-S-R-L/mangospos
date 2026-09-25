-- ============================================================================
-- MAX PÍCAME EL POLLO — ROLLBACK de IMPORT_COMPLETO.sql
-- Business d16497fa-4853-41e3-8566-4d0565511f37
--   * "Pechurrina 3 Piezas" vuelve a llamarse "Pechurina" (es la de antes,
--     con ventas) y se le quita el acompañamiento;
--   * "POLLO FRITO" se reactiva;
--   * los otros 11 se borran con sus impuestos, área, menú y acompañamiento.
--     ABORTA si alguno ya se vendió: en ese caso desactívalo en la app;
--   * el grupo "Acompañamiento" se borra si ya nadie lo usa.
-- ============================================================================

begin;

create or replace function pg_temp.norm(t text) returns text
language sql immutable as $f$
  select translate(lower(regexp_replace(btrim(t), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')
$f$;

do $$
declare
  v_business uuid := 'd16497fa-4853-41e3-8566-4d0565511f37';
  v_n        int;
  v_list     text;
begin
  create temp table _mx_rb on commit drop as
  select mi.id, mi.name
  from public.menu_items mi
  where mi.business_id = v_business
    and pg_temp.norm(mi.name) in (
      'pollo frito 2 piezas', 'pollo frito 3 piezas', 'pollo frito 4 piezas',
      'pollo frito 6 piezas', 'pollo frito 8 piezas', 'pollo frito 10 piezas',
      'pollo frito 12 piezas', 'pollo frito 16 piezas',
      'pechurrina 4 piezas', 'pechurrina 6 piezas', 'pechurrina 8 piezas');

  select count(*), string_agg(i.name, ', ') into v_n, v_list
  from _mx_rb i
  where exists (select 1 from public.order_items oi where oi.product_id = i.id);
  if v_n > 0 then
    raise exception 'ABORTADO: % productos ya tienen ventas (%). Desactívalos en vez de borrarlos.',
      v_n, v_list;
  end if;

  delete from public.menu_item_groups      x using _mx_rb i where x.menu_item_id = i.id;
  delete from public.menu_item_links       x using _mx_rb i where x.item_id      = i.id;
  delete from public.menu_item_print_areas x using _mx_rb i where x.menu_item_id = i.id;
  delete from public.menu_item_taxes       x using _mx_rb i where x.item_id      = i.id;
  delete from public.menu_items           mi using _mx_rb i where mi.id          = i.id;

  -- La Pechurina de antes.
  delete from public.menu_item_groups y
  using public.menu_items mi, public.modifier_groups g
  where y.menu_item_id = mi.id and y.group_id = g.id
    and mi.business_id = v_business and pg_temp.norm(mi.name) = 'pechurrina 3 piezas'
    and g.business_id = v_business and pg_temp.norm(g.name) = 'acompanamiento';
  update public.menu_items set name = 'Pechurina', updated_at = now()
  where business_id = v_business and pg_temp.norm(name) = 'pechurrina 3 piezas';

  update public.menu_items set is_active = true, updated_at = now()
  where business_id = v_business and pg_temp.norm(name) = 'pollo frito';

  delete from public.modifiers m
  using public.modifier_groups g
  where m.group_id = g.id and g.business_id = v_business
    and pg_temp.norm(g.name) = 'acompanamiento'
    and not exists (select 1 from public.menu_item_groups y where y.group_id = g.id);
  delete from public.modifier_groups g
  where g.business_id = v_business and pg_temp.norm(g.name) = 'acompanamiento'
    and not exists (select 1 from public.menu_item_groups y where y.group_id = g.id);

  raise notice 'Rollback: % productos borrados, Pechurina restaurada, POLLO FRITO reactivado.',
    (select count(*) from _mx_rb);
end $$;

commit;
