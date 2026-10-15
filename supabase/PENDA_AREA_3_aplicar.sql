-- =============================================================================
-- LA PENDA EXPRESS · ÁREAS — PASO A3: APLICAR el cambio de área
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ESCRIBE. Aplica EXACTAMENTE lo que el PASO A2 dejó en `_penda_area_plan`,
-- en una sola transacción.
--
-- A cada producto que cambia:
--   · le deja UNA sola fila en menu_item_print_areas, la del área nueva
--     (la N:M es la que manda en la caja y en las comandas);
--   · le pone menu_items.print_area_code = código del área nueva (el que
--     usan las comandas fuera de línea);
--   · le pone updated_at = now(), para que los equipos vean que el catálogo
--     cambió y lo vuelvan a bajar.
--
-- EFECTO INMEDIATO: la comanda de esos productos sale en la impresora del
-- área nueva (FoodShop → CAJA). El DESCUENTO por área recién cambia cuando
-- se corra PENDA_ACT_3_encender.sql.
-- =============================================================================

do $$
declare
  v_biz  uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_n    int;
begin
  if to_regclass('public._penda_area_plan') is null then
    raise exception 'No hay plan. Correr PENDA_AREA_2_preparar.sql primero.';
  end if;

  select count(*) into v_n from public._penda_area_plan where aplicado_en is not null;
  if v_n > 0 then
    raise exception 'El cambio de área YA se aplicó (% productos). No se repite.', v_n;
  end if;

  -- Si alguien le cambió el área a un producto después del plan, el plan
  -- está viejo para ese producto.
  select count(*) into v_n
    from public._penda_area_plan p
    join public.menu_items m on m.id = p.menu_item_id
   where p.area_nueva_id is not null
     and coalesce(
           (select string_agg(pa.name, ' + ' order by pa.name)
              from public.menu_item_print_areas x
              join public.print_areas pa on pa.id = x.print_area_id
             where x.menu_item_id = m.id),
           (select pa.name from public.print_areas pa
             where pa.business_id = m.business_id and pa.code = m.print_area_code
             limit 1),
           '(sin área)') <> p.area_hoy;
  if v_n > 0 then
    raise exception '% productos cambiaron de área después de armar el plan. Volver a '
                    'correr el PASO A2. No se tocó nada.', v_n;
  end if;

  if to_regclass('public._penda_area_bk') is not null then
    raise exception 'Ya existe _penda_area_bk: hay una corrida anterior sin deshacer. '
                    'No se tocó nada.';
  end if;

  -- Respaldo: cómo estaba cada producto que cambia
  create table public._penda_area_bk as
  select m.id as menu_item_id, m.print_area_code, m.updated_at,
         array(select x.print_area_id from public.menu_item_print_areas x
                where x.menu_item_id = m.id) as areas
    from public.menu_items m
    join public._penda_area_plan p on p.menu_item_id = m.id
   where p.area_nueva_id is not null;

  delete from public.menu_item_print_areas x
   using public._penda_area_plan p
   where x.menu_item_id = p.menu_item_id and p.area_nueva_id is not null;

  insert into public.menu_item_print_areas (menu_item_id, print_area_id)
  select p.menu_item_id, p.area_nueva_id
    from public._penda_area_plan p
   where p.area_nueva_id is not null;

  update public.menu_items m
     set print_area_code = pa.code,
         updated_at      = now()
    from public._penda_area_plan p
    join public.print_areas pa on pa.id = p.area_nueva_id
   where m.id = p.menu_item_id;
  get diagnostics v_n = row_count;

  update public._penda_area_plan
     set aplicado_en = now()
   where area_nueva_id is not null;

  raise notice 'LISTO — % productos cambiaron de área.', v_n;
end
$$;


-- ═══ VERIFICAR (una sola consulta) ══════════════════════════════════════════
--   ESPERADO: todo lo del plan en su área nueva (columna «distinto» = 0).
select p.area_nueva,
       count(*)                                                        as productos,
       count(*) filter (where pa.id is distinct from p.area_nueva_id
                           or m.print_area_code is distinct from pa2.code) as distinto
  from public._penda_area_plan p
  join public.menu_items m on m.id = p.menu_item_id
  left join public.menu_item_print_areas x on x.menu_item_id = m.id
  left join public.print_areas pa  on pa.id = x.print_area_id
  left join public.print_areas pa2 on pa2.id = p.area_nueva_id
 where p.area_nueva_id is not null
 group by p.area_nueva
 order by p.area_nueva;


-- ═══ DESHACER ═══════════════════════════════════════════════════════════════
/*
do $$
begin
  delete from public.menu_item_print_areas x
   using public._penda_area_bk b
   where x.menu_item_id = b.menu_item_id;

  insert into public.menu_item_print_areas (menu_item_id, print_area_id)
  select b.menu_item_id, unnest(b.areas) from public._penda_area_bk b;

  update public.menu_items m
     set print_area_code = b.print_area_code, updated_at = now()
    from public._penda_area_bk b
   where m.id = b.menu_item_id;

  update public._penda_area_plan set aplicado_en = null;
  drop table public._penda_area_bk;
  raise notice 'Deshecho: las áreas quedaron como antes.';
end $$;
*/
