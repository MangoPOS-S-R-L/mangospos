-- =============================================================================
-- LA PENDA EXPRESS · ÁREAS — DESHACER el PASO A3
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ESCRIBE. Devuelve a cada producto que movió el PASO A3 el área que tenía
-- antes (su respaldo está en `_penda_area_bk`), y deja el plan sin aplicar
-- para poder correr de nuevo el PASO A2 y el A3.
--
-- Hace falta (12-oct): el A3 se corrió con el plan de la PRIMERA versión de
-- las reglas, que mandó al FoodShop los quipes, las tablas y las bruschettas
-- (son de cocina), JUGO DE LIMÓN (lo prepara el bar) y la MANTEQUILLA DORINA.
-- =============================================================================

do $$
declare
  v_n int;
begin
  if to_regclass('public._penda_area_bk') is null then
    raise exception 'No hay respaldo (_penda_area_bk): el A3 no se ha aplicado o ya se '
                    'deshizo. No se tocó nada.';
  end if;

  delete from public.menu_item_print_areas x
   using public._penda_area_bk b
   where x.menu_item_id = b.menu_item_id;

  insert into public.menu_item_print_areas (menu_item_id, print_area_id)
  select b.menu_item_id, unnest(b.areas) from public._penda_area_bk b;

  update public.menu_items m
     set print_area_code = b.print_area_code, updated_at = now()
    from public._penda_area_bk b
   where m.id = b.menu_item_id;
  get diagnostics v_n = row_count;

  update public._penda_area_plan set aplicado_en = null;
  drop table public._penda_area_bk;
  raise notice 'Deshecho: % productos volvieron a su área de antes. Ahora: PASO A2 y A3.', v_n;
end
$$;
