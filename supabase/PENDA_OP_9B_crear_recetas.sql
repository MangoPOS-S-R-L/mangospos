-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 9B: crear las recetas
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ESTO ES LO QUE FALTABA. En `PENDA_OP_9_cargar_todo.sql` la sección 9.5 quedó
-- dentro de un bloque /* */, así que ese archivo crea los insumos y los mapeos
-- pero NO las recetas. Aquí va suelta y lista: se pega y se corre, sin editar.
--
-- REQUIERE, en este orden:
--   1. `PENDA_PASO6_recetario.sql`      (tabla `_recetario_penda` + funciones)
--   2. `PENDA_OP_9_cargar_todo.sql`     (insumos + `_map_ingrediente` + `_map_producto`)
--
-- Las guardas de abajo lo verifican y abortan sin escribir nada si algo falta.
--
-- QUÉ NO PUEDE PASAR:
--   * ningún producto con `inventory_item_id` recibe receta (dejaría de
--     descontarse a sí mismo): son 14 fichas — mofongos, frozen, quipes
--   * ninguna cantidad se escribe sin convertir a la unidad base del insumo
--   * la Guarnición se descarta (es modificador, descontaría doble)
--   * las fichas PLANTILLA se saltan
--
-- TODAS LAS RECETAS NACEN DORMIDAS: `is_inventory_tracked` no se toca, así que
-- ninguna descuenta nada hasta que se encienda el producto (paso 11 del plan).
--
-- IDEMPOTENTE: sí, un producto que ya tiene receta no se toca.
-- REVERSIBLE: sí, la sección 9.7 de `PENDA_OP_9_cargar_todo.sql`.
-- =============================================================================

-- ─── GUARDAS ────────────────────────────────────────────────────────────────
do $$
declare v_n int;
begin
  if to_regclass('public._recetario_penda') is null then
    raise exception 'Falta PENDA_PASO6_recetario.sql (no existe _recetario_penda). '
                    'No se creo nada.';
  end if;
  if to_regclass('public._map_ingrediente') is null
     or to_regclass('public._map_producto') is null then
    raise exception 'Falta PENDA_OP_9_cargar_todo.sql secciones 9.1-9.3 (no existen '
                    'los mapeos). No se creo nada.';
  end if;
  select count(*) into v_n from public._map_producto where menu_item_id is not null;
  if v_n = 0 then
    raise exception 'El mapeo de productos esta vacio: ninguna ficha caso con un '
                    'producto del menu. Revisar 9.4 antes de seguir. No se creo nada.';
  end if;
  raise notice 'Guardas OK — % fichas con producto mapeado.', v_n;
end
$$;


do $$
declare
  v_biz     uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_recetas int := 0;
  v_saltan  int := 0;
  v_ingr    int := 0;
  r         record;
  v_rid     uuid;
  v_n       int;
begin
  for r in
    select p.codigo, p.menu_item_id
      from public._map_producto p
      join public.menu_items mitem on mitem.id = p.menu_item_id
     where p.menu_item_id is not null
       -- CANDADO: un producto con vinculo directo deja de descontarse a si
       -- mismo si le ponemos receta (`consume_inventory_from_order` usa el
       -- vinculo solo cuando NO hay receta).
       and mitem.inventory_item_id is null
       and not exists (select 1 from public._recetario_penda z
                        where z.codigo = p.codigo and z.nota like 'PLANTILLA%')
       -- TODOS los ingredientes resueltos y convertibles, o la ficha no entra
       and not exists (
         select 1 from public._recetario_penda z
         join public._map_ingrediente m on m.ingrediente = z.ingrediente
          where z.codigo = p.codigo and z.unidad <> 'c/n' and z.cantidad is not null
            and coalesce(m.como,'') <> 'descartar'
            and (m.inventory_item_id is null
                 or public._penda_a_base(z.cantidad, z.unidad, m.inventory_item_id) is null))
       -- y que quede al menos uno que descuente
       and exists (
         select 1 from public._recetario_penda z
         join public._map_ingrediente m on m.ingrediente = z.ingrediente
          where z.codigo = p.codigo and z.unidad <> 'c/n' and z.cantidad is not null
            and m.inventory_item_id is not null and coalesce(m.como,'') <> 'descartar')
     order by p.codigo
  loop
    if exists (select 1 from public.recipes where menu_item_id = r.menu_item_id) then
      v_saltan := v_saltan + 1;
      continue;
    end if;

    insert into public.recipes (menu_item_id, yield_quantity, instructions)
    values (r.menu_item_id, 1,
            'Recetario Estandar de Cocina, agosto 2026 — ficha ' || r.codigo ||
            ' (cargada automaticamente, SIN revisar por cocina)')
    returning id into v_rid;

    -- la cantidad va CONVERTIDA a la unidad base del insumo: es en esa unidad
    -- que el motor descuenta. `unit` guarda la unidad base, no la del papel.
    insert into public.recipe_ingredients (recipe_id, inventory_item_id, quantity, unit)
    select v_rid,
           m.inventory_item_id,
           public._penda_a_base(z.cantidad, z.unidad, m.inventory_item_id),
           ii.unit
      from public._recetario_penda z
      join public._map_ingrediente m on m.ingrediente = z.ingrediente
      join public.inventory_items ii on ii.id = m.inventory_item_id
     where z.codigo = r.codigo
       and z.unidad <> 'c/n'
       and z.cantidad is not null
       and m.inventory_item_id is not null
       and coalesce(m.como,'') <> 'descartar';

    get diagnostics v_n = row_count;
    v_ingr := v_ingr + v_n;
    v_recetas := v_recetas + 1;
  end loop;

  raise notice '9.5 — recetas creadas: % (% ingredientes) · ya tenian receta: %',
    v_recetas, v_ingr, v_saltan;
  raise notice 'TODAS DORMIDAS: ningun producto se encendio. Revisar en la app '
               'antes de prender el inventario producto por producto.';
end
$$;

-- ─── VERIFICAR ──────────────────────────────────────────────────────────────
--   1) las recetas que quedaron, con la cantidad YA convertida
select m.name                                       as producto,
       count(ri.*)                                   as ingredientes,
       coalesce(m.is_inventory_tracked,false)        as encendido,
       string_agg(i.name || ' ' || round(ri.quantity,4) || ' ' || ri.unit,
                  '  ·  ' order by i.name)           as receta
from public.recipes r
join public.menu_items m          on m.id = r.menu_item_id
join public.recipe_ingredients ri on ri.recipe_id = r.id
join public.inventory_items i     on i.id = ri.inventory_item_id
where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
group by m.id, m.name, m.is_inventory_tracked
order by m.name;

--   2) TIENE QUE DAR CERO FILAS: ninguna receta sobre un producto con vinculo
--      directo. Si sale algo, ese producto dejo de descontarse a si mismo.
select m.name, i.name as insumo_ligado
from public.recipes r
join public.menu_items m      on m.id = r.menu_item_id
join public.inventory_items i on i.id = m.inventory_item_id
where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and m.inventory_item_id is not null;

--   3) TIENE QUE DAR CERO FILAS: cantidades sospechosas. Gramos convertidos a
--      libras o litros nunca deberian pasar de unas pocas unidades por plato.
select m.name as producto, i.name as insumo, i.unit, ri.quantity
from public.recipe_ingredients ri
join public.recipes r         on r.id = ri.recipe_id
join public.menu_items m      on m.id = r.menu_item_id
join public.inventory_items i on i.id = ri.inventory_item_id
where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and i.unit in ('lb','kg','L','gal') and ri.quantity > 20
order by ri.quantity desc;

--   4) que NINGUNA quedo encendida
select count(*) as recetas_encendidas_OJO
from public.recipes r
join public.menu_items m on m.id = r.menu_item_id
where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(m.is_inventory_tracked,false);
