-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 16: arreglar lo que salió mal
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- TRES PROBLEMAS del PASO 15, dos de ellos por error mío:
--
--  (a) CINCO DESAYUNOS EN LA CATEGORÍA «CROISSANTS»
--      DESAYUNO AMERICANO · LOS 3 GOLPES · OMELETTE DE PASTRAMI ·
--      OMELETTE LIGHT · TOSTADA PENDA
--      La referencia de la categoría DESAYUNOS del recetario terminó siendo un
--      croissant, porque los croissants son los desayunos ya mapeados que más
--      se venden. Aparecerían en la pestaña equivocada del menú.
--
--  (b) DOS DUPLICADOS DE LA TABLA, contra la decisión explícita del dueño
--      Se decidió dejar la TABLA sin cargar (cuatro fichas se peleaban un solo
--      producto de 135 ventas) y mi exclusión solo cubría «4 PERSONAS». Así se
--      crearon `TABLA DE FIAMBRES - 2 PERSONAS` y `TABLA PENDA - 2 PERSONAS`
--      al lado del `TABLA PARA 2 PERSONAS` que ya existía.
--
--  (c) `CHEESEBURGER` es casi-duplicado de `CHEESE BURGER` (que existe con
--      vínculo directo). `_norm` no los unió porque uno lleva espacio.
--      Este NO se borra solo: es decisión, ver 16.4.
--
-- 16.1 diagnostica · 16.2 arregla las categorías · 16.3 borra los duplicados
-- de la TABLA · 16.4 deja a mano lo de CHEESEBURGER.
-- =============================================================================

-- ═══ 16.1 · DÓNDE VIVEN DE VERDAD LOS DESAYUNOS (leer primero) ═══════════════
--   Se mira en qué categoría están los productos de desayuno que SÍ se venden.
--   Esa es la categoría correcta para los cinco.
select c.name                                                as categoria,
       count(*)                                               as productos,
       sum((select count(*) from public.order_items oi
             where oi.product_id = m.id and oi.status <> 'void')) as lineas_vendidas,
       string_agg(m.name, ' · ' order by m.name)               as cuales
from public.menu_items m
join public.categories c on c.id = m.category_id
where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(m.is_active,true)
  and (m.name ilike '%OMELETTE%' or m.name ilike '%MANGU%'
       or m.name ilike '%DESAYUNO%' or m.name ilike '%PANCAKE%'
       or m.name ilike '%HUEVO%'    or m.name ilike '%TOSTADA%'
       or m.name ilike '%CROISSANT%'or m.name ilike '%WAFFLE%'
       or m.name ilike '%BAGEL%')
group by c.name
order by lineas_vendidas desc nulls last;


-- ═══ 16.2 · MOVER LOS CINCO DESAYUNOS ════════════════════════════════════════
--   Se los pone en la MISMA categoría donde está el omelette más vendido, que
--   es el desayuno de referencia de verdad. Si no hay ninguno, no toca nada.
do $$
declare
  v_biz uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_cat uuid;
  v_nom text;
  v_n   int;
begin
  select m.category_id, c.name into v_cat, v_nom
    from public.menu_items m
    join public.categories c on c.id = m.category_id
   where m.business_id = v_biz and coalesce(m.is_active,true)
     and m.name ilike '%OMELETTE%'
     -- OJO: `description` es NULL en los productos viejos, y
     -- `not (NULL like '...')` es NULL → la fila se cae. coalesce lo arregla.
     and coalesce(m.description,'') not like 'Creado para la receta %'
   order by (select count(*) from public.order_items oi
              where oi.product_id = m.id and oi.status <> 'void') desc
   limit 1;

  if v_cat is null then
    raise notice '16.2 — no hay ningun OMELETTE con categoria de referencia. '
                 'No se movio nada; mirar 16.1 y hacerlo a mano.';
    return;
  end if;

  update public.menu_items
     set category_id = v_cat
   where business_id = v_biz
     and description like 'Creado para la receta %'
     and category_id is distinct from v_cat
     and public._norm(name) in (
       public._norm('DESAYUNO AMERICANO'),
       public._norm('LOS 3 GOLPES'),
       public._norm('OMELETTE DE PASTRAMI'),
       public._norm('OMELETTE LIGHT'),
       public._norm('TOSTADA PENDA'));
  get diagnostics v_n = row_count;
  raise notice '16.2 — desayunos movidos a «%»: %', v_nom, v_n;
end
$$;


-- ═══ 16.3 · BORRAR LOS DOS DUPLICADOS DE LA TABLA ════════════════════════════
--   Solo los que creó el PASO 15, solo si nunca se vendieron, y con su receta.
do $$
declare
  v_biz uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_n   int := 0;
  rec   record;
begin
  for rec in
    select m.id, m.name
      from public.menu_items m
     where m.business_id = v_biz
       and m.description like 'Creado para la receta %'
       and m.name ilike '%TABLA%'
       and not exists (select 1 from public.order_items oi where oi.product_id = m.id)
  loop
    delete from public.recipe_ingredients ri
     using public.recipes r
     where ri.recipe_id = r.id and r.menu_item_id = rec.id;
    delete from public.recipes where menu_item_id = rec.id;
    update public._map_producto set menu_item_id = null, como = 'auto'
     where menu_item_id = rec.id;
    delete from public.menu_item_taxes where item_id = rec.id;
    delete from public.menu_item_print_areas where menu_item_id = rec.id;
    delete from public.menu_items where id = rec.id;
    v_n := v_n + 1;
    raise notice '  borrado: %', rec.name;
  end loop;
  raise notice '16.3 — duplicados de TABLA borrados: % (la decision fue dejarla sin cargar)', v_n;
end
$$;


-- ═══ 16.4 · VERIFICAR, y lo de CHEESEBURGER ══════════════════════════════════
--   (1) los productos creados, ya con su categoría corregida
select c.name as categoria, count(*) as productos,
       string_agg(m.name, ' · ' order by m.name) as cuales
from public.menu_items m
left join public.categories c on c.id = m.category_id
where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and m.description like 'Creado para la receta %'
group by c.name order by c.name;

--   (2) NOMBRES CASI IGUALES en el catálogo — el caso CHEESEBURGER y cualquier
--       otro que se haya colado. Un espacio de diferencia y `_norm` no los une.
--       Decidí NO borrarlos solo: puede que el plato hecho en casa y el
--       comprado hecho convivan a propósito.
select nuevo.name                                as creado_por_el_paso_15,
       viejo.name                                as ya_existia,
       round(similarity(public._norm(nuevo.name),
                        public._norm(viejo.name))::numeric, 2) as parecido,
       (viejo.inventory_item_id is not null)      as el_viejo_tiene_vinculo,
       (select count(*) from public.order_items oi
         where oi.product_id = viejo.id and oi.status <> 'void') as ventas_del_viejo
from public.menu_items nuevo
join public.menu_items viejo
  on viejo.business_id = nuevo.business_id
 and viejo.id <> nuevo.id
 -- 0.55 y no 0.70: «CHEESEBURGER» vs «CHEESE BURGER» se parecen menos de lo
 -- que uno cree, porque el espacio cambia varios trigramas.
 and similarity(public._norm(nuevo.name), public._norm(viejo.name)) > 0.55
where nuevo.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and nuevo.description like 'Creado para la receta %'
  and coalesce(viejo.description,'') not like 'Creado para la receta %'
order by parecido desc;

-- Para borrar uno de esos casi-duplicados, por nombre y solo si nunca se vendió:
/*
do $$
declare v_id uuid;
begin
  select id into v_id from public.menu_items
   where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and description like 'Creado para la receta %'
     and public._norm(name) = public._norm('CHEESEBURGER')   -- <<< cambiar aqui
     and not exists (select 1 from public.order_items oi where oi.product_id = id);
  if v_id is null then raise notice 'No existe o ya se vendio. Nada que borrar.'; return; end if;
  delete from public.recipe_ingredients ri using public.recipes r
   where ri.recipe_id = r.id and r.menu_item_id = v_id;
  delete from public.recipes where menu_item_id = v_id;
  update public._map_producto set menu_item_id = null, como = 'auto' where menu_item_id = v_id;
  delete from public.menu_item_taxes where item_id = v_id;
  delete from public.menu_item_print_areas where menu_item_id = v_id;
  delete from public.menu_items where id = v_id;
  raise notice 'Borrado.';
end $$;
*/
