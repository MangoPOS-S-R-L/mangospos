-- =============================================================================
-- LA PENDA EXPRESS · RECETAS — PASO R5: los huevos de verdad y 4 áreas
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ESCRIBE (recetas y áreas; NO mueve inventario). Una sola transacción.
--
-- 1. HUEVOS. El huevo de la cocina es HUEVOS FRECOS (dueño, 12-oct), que se
--    lleva por CAJA DE 30 (decidido en septiembre: 3,450 huevos = 115 cajas
--    exactas). Las recetas no lo usaban: pedían «Huevos Sorpresa» (el dulce de
--    la tienda) o uno de cinco «COCINA ·» de huevo que nunca se compraron. Por
--    eso desayunos y omelettes quedaban apagados aunque hay huevos.
--    Cada receta queda con UN renglón de HUEVOS FRECOS, en cajas:
--        2 huevos = 2 / 30 = 0.0667 caja        (1 clara = 1 huevo)
--    Si la receta ya tenía HUEVOS FRECOS, se suma ahí.
-- 2. ÁREAS (revisión M4): Desayuno Americano, Omelette de Pastrami y Omelette
--    Light estaban en BAR → COCINA. Mokaccino SD estaba en FoodShop → BAR.
--    (Croissants Plain PQ queda como está hasta saber quién lo prepara.)
--
-- Esto NO enciende recetas: las que ahora tienen huevo con existencia
-- entran en la próxima ronda de encendido.
-- =============================================================================

do $$
declare
  v_biz     uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_huevo   uuid := '3306a200-6105-456d-b1b7-54ea5603e8e7';   -- HUEVOS FRECOS
  v_coc     uuid;
  v_bar     uuid;
  v_n_rec   int;
  v_n_lin   int;
  v_n_area  int;
  v_raras   text;
begin
  ---------------------------------------------------------------------------
  -- Guardas
  ---------------------------------------------------------------------------
  if not exists (select 1 from public.inventory_items
                  where id = v_huevo and business_id = v_biz
                    and upper(name) like 'HUEVOS FRE%' and unit = 'caja') then
    raise exception 'HUEVOS FRECOS no está como se esperaba (id, nombre o unidad «caja»). '
                    'No se tocó nada.';
  end if;

  if to_regclass('public._penda_rec5_bk_lineas') is not null then
    raise exception 'El PASO R5 ya se aplicó (_penda_rec5_bk_lineas existe). No se tocó nada.';
  end if;

  select id into v_coc from public.print_areas where business_id = v_biz and upper(name) = 'COCINA' limit 1;
  select id into v_bar from public.print_areas where business_id = v_biz and upper(name) = 'BAR' limit 1;
  if v_coc is null or v_bar is null then
    raise exception 'Faltan las áreas COCINA o BAR. No se tocó nada.';
  end if;

  -- Los huevos «de mentira» tienen que estar en unidades sueltas: si alguno
  -- estuviera en g o ml, dividir entre 30 no tendría sentido.
  select string_agg(distinct i.name || ' (' || i.unit || ')', ', ') into v_raras
    from public.recipe_ingredients ri
    join public.recipes r on r.id = ri.recipe_id
    join public.menu_items m on m.id = r.menu_item_id
    join public.inventory_items i on i.id = ri.inventory_item_id
   where m.business_id = v_biz
     and i.name in ('Huevos Sorpresa','COCINA · Huevo','COCINA · Huevos enteros',
                    'COCINA · Huevo frito','COCINA · Huevo batido','COCINA · Claras de huevo')
     and i.unit not in ('ud','unidad','u','und');
  if v_raras is not null then
    raise exception 'Estos huevos no están en unidades sueltas: %. No se tocó nada.', v_raras;
  end if;

  ---------------------------------------------------------------------------
  -- 1. Huevos
  ---------------------------------------------------------------------------
  -- respaldo de TODOS los renglones de huevo que se tocan (incluido un
  -- HUEVOS FRECOS previo, que se reemplaza por el renglón sumado)
  create table public._penda_rec5_bk_lineas as
  select ri.*
    from public.recipe_ingredients ri
    join public.recipes r on r.id = ri.recipe_id
    join public.menu_items m on m.id = r.menu_item_id
    join public.inventory_items i on i.id = ri.inventory_item_id
   where m.business_id = v_biz
     and (i.name in ('Huevos Sorpresa','COCINA · Huevo','COCINA · Huevos enteros',
                     'COCINA · Huevo frito','COCINA · Huevo batido','COCINA · Claras de huevo')
          or i.id = v_huevo)
     and ri.recipe_id in (
           select ri2.recipe_id from public.recipe_ingredients ri2
             join public.inventory_items i2 on i2.id = ri2.inventory_item_id
            where i2.name in ('Huevos Sorpresa','COCINA · Huevo','COCINA · Huevos enteros',
                              'COCINA · Huevo frito','COCINA · Huevo batido',
                              'COCINA · Claras de huevo'));

  create temp table _nuevas on commit drop as
  select b.recipe_id,
         sum(case when b.inventory_item_id = v_huevo then b.quantity
                  else b.quantity / 30.0 end) as cajas
    from public._penda_rec5_bk_lineas b
   group by b.recipe_id;
  get diagnostics v_n_rec = row_count;

  delete from public.recipe_ingredients ri
   using public._penda_rec5_bk_lineas b
   where ri.id = b.id;
  get diagnostics v_n_lin = row_count;

  insert into public.recipe_ingredients (recipe_id, inventory_item_id, quantity, unit)
  select n.recipe_id, v_huevo, round(n.cajas, 4), 'caja'
    from _nuevas n;

  ---------------------------------------------------------------------------
  -- 2. Áreas
  ---------------------------------------------------------------------------
  create table public._penda_rec5_bk_areas as
  select m.id as menu_item_id, m.print_area_code,
         array(select x.print_area_id from public.menu_item_print_areas x
                where x.menu_item_id = m.id) as areas,
         case when upper(m.name) like 'MOKACCINO%' then v_bar else v_coc end as area_nueva
    from public.menu_items m
   where m.business_id = v_biz
     and (upper(m.name) in ('DESAYUNO AMERICANO','OMELETTE DE PASTRAMI','OMELETTE LIGHT')
          or upper(m.name) like 'MOKACCINO SD%')
     and exists (select 1 from public.recipes r where r.menu_item_id = m.id);

  delete from public.menu_item_print_areas x
   using public._penda_rec5_bk_areas b where x.menu_item_id = b.menu_item_id;

  insert into public.menu_item_print_areas (menu_item_id, print_area_id)
  select menu_item_id, area_nueva from public._penda_rec5_bk_areas;

  update public.menu_items m
     set print_area_code = pa.code, updated_at = now()
    from public._penda_rec5_bk_areas b
    join public.print_areas pa on pa.id = b.area_nueva
   where m.id = b.menu_item_id;
  get diagnostics v_n_area = row_count;

  raise notice 'LISTO — % recetas con huevo pasan a HUEVOS FRECOS (% renglones viejos '
               'reemplazados); % productos cambiaron de área.', v_n_rec, v_n_lin, v_n_area;
end
$$;


-- ═══ VERIFICAR (una sola consulta) ══════════════════════════════════════════
--   ESPERADO: ningún renglón con los huevos viejos; cada receta con huevo
--   muestra cuántos huevos descuenta (cajas × 30); las 4 áreas nuevas.
select 'huevos' as que, m.name ||
         case when coalesce(m.is_inventory_tracked, false) then ' [ENCENDIDA]' else '' end as dato,
       regexp_replace(round(ri.quantity, 4)::text, '\.?0+$', '') || ' caja = '
       || regexp_replace(round(ri.quantity * 30, 1)::text, '\.?0+$', '') || ' huevo(s)' as valor
  from public.recipe_ingredients ri
  join public.recipes r on r.id = ri.recipe_id
  join public.menu_items m on m.id = r.menu_item_id
 where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and ri.inventory_item_id = '3306a200-6105-456d-b1b7-54ea5603e8e7'
union all
select 'huevos viejos que quedan (debe ser 0)', '', count(*)::text
  from public.recipe_ingredients ri
  join public.inventory_items i on i.id = ri.inventory_item_id
 where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and i.name in ('Huevos Sorpresa','COCINA · Huevo','COCINA · Huevos enteros',
                  'COCINA · Huevo frito','COCINA · Huevo batido','COCINA · Claras de huevo')
union all
select 'área', m.name, pa.name
  from public._penda_rec5_bk_areas b
  join public.menu_items m on m.id = b.menu_item_id
  join public.print_areas pa on pa.id = b.area_nueva
order by 1, 2;


-- ═══ DESHACER ═══════════════════════════════════════════════════════════════
/*
do $$
begin
  delete from public.recipe_ingredients ri
   where ri.inventory_item_id = '3306a200-6105-456d-b1b7-54ea5603e8e7'
     and ri.recipe_id in (select recipe_id from public._penda_rec5_bk_lineas);
  insert into public.recipe_ingredients select * from public._penda_rec5_bk_lineas;

  delete from public.menu_item_print_areas x
   using public._penda_rec5_bk_areas b where x.menu_item_id = b.menu_item_id;
  insert into public.menu_item_print_areas (menu_item_id, print_area_id)
  select b.menu_item_id, unnest(b.areas) from public._penda_rec5_bk_areas b;
  update public.menu_items m set print_area_code = b.print_area_code, updated_at = now()
    from public._penda_rec5_bk_areas b where m.id = b.menu_item_id;

  drop table public._penda_rec5_bk_lineas;
  drop table public._penda_rec5_bk_areas;
  raise notice 'Deshecho.';
end $$;
*/
