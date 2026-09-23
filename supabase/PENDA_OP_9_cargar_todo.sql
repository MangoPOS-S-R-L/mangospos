-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 9: cargar TODAS las recetas
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ESCRIBE. REQUIERE haber corrido PENDA_PASO6 (tabla `_recetario_penda` y las
-- funciones `_norm` / `_penda_a_base`).
--
-- POR QUÉ SE PUEDE CARGAR SIN LA HOJA REVISADA:
--   Las recetas nacen DORMIDAS. Los 547 productos candidatos tienen
--   `is_inventory_tracked = false`, así que ninguna receta descuenta nada
--   hasta que se encienda el producto uno por uno (el paso 11 del plan).
--   O sea: cargar ahora no puede romper inventario ni disparar el auto-86.
--   La revisión se hace después, en la app, sobre recetas que ya existen —
--   que para la cocina es más fácil que revisar un CSV de 225 filas.
--
-- QUÉ NO PUEDE PASAR, por diseño:
--   * ningún producto con `inventory_item_id` recibe receta (dejaría de
--     descontarse a sí mismo). Son 14 fichas: mofongos, frozen, quipes.
--   * ninguna cantidad se escribe sin convertir a la unidad base del insumo.
--     Si no convierte, la ficha NO se carga. Nunca «asume base».
--   * la Guarnición se descarta: es un modificador y descontaría doble.
--   * las 3 fichas PLANTILLA se saltan: no tienen ingredientes reales.
--
-- EL TECHO REAL: solo 55 de las 143 fichas casan con un producto del menú, y
--   14 de esas tienen vínculo directo. Así que salen ~41 recetas. Las otras 88
--   fichas son platos que NO están en el menú (mero, cortes de res, wraps,
--   pizzas): para cargarlas habría que crear los productos, que es cambiar el
--   menú, y eso no lo hace este script.
--
-- LOS INSUMOS NUEVOS LLEVAN PREFIJO «COCINA · ».
--   No es capricho: el catálogo de 2,325 insumos es de TIENDA (snacks, dulces,
--   bebidas de reventa) y la cocina compra por fuera. Crear «COCINA · Queso»
--   al lado de «QUESO MOZZARELLA RICA lb» evita colisiones, hace buscable todo
--   el catálogo de cocina de un tirón, y deja claro qué se creó aquí.
--   Nacen con costo 0 y stock 0. El costo entra con la primera compra.
--
-- ⚠️ CON CONTEOS ABIERTOS: si la migración 20260902_0005 está aplicada, cada
--   insumo nuevo agrega una línea a las 5 sesiones abiertas. No hace daño (una
--   línea en blanco se salta al cerrar) pero los contadores de líneas suben.
--   Si preferís no tocar los conteos, correr esto DESPUÉS de cerrarlos.
--
-- IDEMPOTENTE: sí, las cuatro secciones. REVERSIBLE: sí, ver 9.7.
-- =============================================================================

-- ═══ 9.1 · CREAR LOS INSUMOS QUE FALTAN ══════════════════════════════════════
do $$
declare
  v_biz      uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_main     uuid;
  v_creados  int := 0;
  v_ya       int := 0;
  r          record;
  v_id       uuid;
begin
  if to_regclass('public._recetario_penda') is null then
    raise exception 'Falta el PASO 6. No se creo nada.';
  end if;

  select id into v_main from public.warehouses
   where business_id = v_biz and is_main and coalesce(is_active,true) limit 1;

  -- clasificacion: la misma del OP 5 / OP 6, aqui adentro para no depender
  create temp table _clase on commit drop as
  with ing as (
    select min(z.ingrediente)            as ingrediente,
           public._norm(min(z.ingrediente)) as n,
           min(z.unidad)                 as u_receta,
           count(distinct z.codigo)       as fichas
      from public._recetario_penda z
     group by public._norm(z.ingrediente)
  )
  select i.*,
         case
           when i.u_receta = 'c/n'                                  then 'DESCARTAR'
           when i.ingrediente ilike '%guarnic%'                     then 'DESCARTAR'
           when i.ingrediente ~* 'seg[uú]n receta|elegid|del d[ií]a|'
                                 'producto principal|sabor seg|'
                                 'syrup/topping|fruta o pulpa|'
                                 'pan seg[uú]n'                     then 'DESCARTAR'
           else 'USAR'
         end as clase
    from ing i;

  -- ¿que insumo EXISTENTE sirve? el mejor candidato que (a) no es producto
  -- terminado, (b) convierte de verdad a su unidad base.
  create temp table _mejor on commit drop as
  select c.n,
         (select i.id
            from public.inventory_items i
            left join (
              select distinct m.inventory_item_id as item_id
                from public.menu_items m
               where m.business_id = v_biz and m.inventory_item_id is not null
              union
              select distinct i2.id from public.inventory_items i2
               where i2.business_id = v_biz
                 and public._norm(i2.name) ~ '\m(EMPANADA|EMPANADAS|QUIPE|QUIPES|'
                                             'MOFONGO|MOFONGOS|CROQUETA|CROQUETAS)\M'
            ) rv on rv.item_id = i.id
           where i.business_id = v_biz and coalesce(i.is_active,true)
             and i.name not like 'COCINA · %'      -- no mirarse a si mismo
             and rv.item_id is null
             and public._penda_a_base(1, c.u_receta, i.id) is not null
             and (public._norm(i.name) = c.n
                  or public._norm(i.name) ~ ('\m' || regexp_replace(c.n,'[^A-Z0-9 ]','.','g') || '\M'))
           order by (public._norm(i.name) = c.n) desc,
                    length(public._norm(i.name)) - length(c.n),
                    i.name
           limit 1) as existente
    from _clase c
   where c.clase = 'USAR';

  for r in
    select c.ingrediente, c.u_receta, c.fichas
      from _clase c
      join _mejor m on m.n = c.n
     where c.clase = 'USAR' and m.existente is null
     order by c.fichas desc, c.ingrediente
  loop
    select id into v_id from public.inventory_items
     where business_id = v_biz
       and public._norm(name) = public._norm('COCINA · ' || r.ingrediente)
     limit 1;

    if v_id is not null then
      v_ya := v_ya + 1;
      continue;
    end if;

    insert into public.inventory_items (business_id, name, unit, cost, is_active)
    values (v_biz, 'COCINA · ' || r.ingrediente, r.u_receta, 0, true)
    returning id into v_id;

    -- fila de stock en 0 en el principal: sin ella el insumo no sale en la
    -- pantalla de inventario (la lista filtra por presencia en el almacen).
    if v_main is not null then
      insert into public.inventory_stock (warehouse_id, item_id, quantity)
      values (v_main, v_id, 0)
      on conflict (warehouse_id, item_id) do nothing;
    end if;

    v_creados := v_creados + 1;
  end loop;

  raise notice '9.1 — insumos creados: %, ya existian: %', v_creados, v_ya;
end
$$;


-- ═══ 9.2 · EL MAPEO DE INGREDIENTES ══════════════════════════════════════════
drop table if exists public._map_ingrediente;
create table public._map_ingrediente (
  ingrediente       text primary key,
  inventory_item_id uuid,
  como              text,          -- 'existente' | 'creado' | 'descartar'
  unidad_receta     text,
  fichas            int
);

insert into public._map_ingrediente (ingrediente, inventory_item_id, como, unidad_receta, fichas)
with biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
ing as (
  select min(z.ingrediente)               as ingrediente,
         public._norm(min(z.ingrediente)) as n,
         min(z.unidad)                    as u_receta,
         count(distinct z.codigo)         as fichas
    from public._recetario_penda z
   group by public._norm(z.ingrediente)
),
term as (
  select distinct m.inventory_item_id as item_id
    from public.menu_items m, biz
   where m.business_id = biz.id and m.inventory_item_id is not null
  union
  select distinct i.id from public.inventory_items i, biz
   where i.business_id = biz.id
     and public._norm(i.name) ~ '\m(EMPANADA|EMPANADAS|QUIPE|QUIPES|MOFONGO|'
                                'MOFONGOS|CROQUETA|CROQUETAS)\M'
)
select i.ingrediente,
       coalesce(ex.id, nu.id),
       case when i.u_receta = 'c/n'                    then 'descartar'
            when i.ingrediente ilike '%guarnic%'       then 'descartar'
            when i.ingrediente ~* 'seg[uú]n receta|elegid|del d[ií]a|'
                                  'producto principal|sabor seg|'
                                  'syrup/topping|fruta o pulpa|pan seg[uú]n'
                                                       then 'descartar'
            when ex.id is not null                     then 'existente'
            when nu.id is not null                     then 'creado'
            else 'descartar' end,
       i.u_receta,
       i.fichas
  from ing i
  cross join biz
  left join lateral (
    select x.id from public.inventory_items x
     where x.business_id = biz.id and coalesce(x.is_active,true)
       -- los «COCINA · » los creo 9.1 hace un momento: si los mirara aqui,
       -- «COCINA · Queso» contiene QUESO y se etiquetaria como «existente».
       -- Esos los toma el lateral `nu` de abajo, y asi la etiqueta no miente.
       and x.name not like 'COCINA · %'
       and not exists (select 1 from term t where t.item_id = x.id)
       and public._penda_a_base(1, i.u_receta, x.id) is not null
       and (public._norm(x.name) = i.n
            or public._norm(x.name) ~ ('\m' || regexp_replace(i.n,'[^A-Z0-9 ]','.','g') || '\M'))
     order by (public._norm(x.name) = i.n) desc,
              length(public._norm(x.name)) - length(i.n), x.name
     limit 1) ex on true
  left join lateral (
    select x.id from public.inventory_items x
     where x.business_id = biz.id
       and public._norm(x.name) = public._norm('COCINA · ' || i.ingrediente)
     limit 1) nu on true;


-- UNA FILA POR CADA FORMA DEL TEXTO. El insert de arriba agrupa por nombre
-- NORMALIZADO y guarda `min(ingrediente)`, o sea UNA sola forma: el papel
-- escribe «Jamon» y «Jamón» y el mapa guardaba una. Como el cargador (9.5)
-- hace el join por el TEXTO CRUDO con INNER JOIN, la forma ausente se caia
-- SIN RUIDO: no bloqueaba la ficha y no entraba a la receta. Asi se cargo
-- SANDWICH COMPLETO sin su jamon. Aqui se agregan las formas que faltan
-- apuntando al MISMO insumo, y el join encuentra fila siempre.
insert into public._map_ingrediente
  (ingrediente, inventory_item_id, como, unidad_receta, fichas)
select distinct z.ingrediente, m.inventory_item_id, m.como, m.unidad_receta, m.fichas
  from public._recetario_penda z
  join public._map_ingrediente m
    on public._norm(m.ingrediente) = public._norm(z.ingrediente)
 where not exists (select 1 from public._map_ingrediente m2
                    where m2.ingrediente = z.ingrediente)
on conflict (ingrediente) do nothing;

-- ═══ 9.3 · EL MAPEO DE PRODUCTOS ═════════════════════════════════════════════
--   Por nombre normalizado exacto, y SOLO productos sin vinculo directo.
drop table if exists public._map_producto;
create table public._map_producto (
  codigo       text primary key,
  producto     text,
  menu_item_id uuid,
  como         text
);

insert into public._map_producto (codigo, producto, menu_item_id, como)
select r.codigo, r.producto,
       (select m.id from public.menu_items m
         where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
           and coalesce(m.is_active,true)
           and m.inventory_item_id is null            -- el candado
           and public._norm(m.name) = public._norm(r.producto)
         order by m.created_at limit 1),
       'auto'
  from (select distinct codigo, producto from public._recetario_penda) r;


-- ═══ 9.4 · QUÉ SE VA A CARGAR (leer ANTES de correr 9.5) ═════════════════════
with biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
listas as (
  select p.codigo
    from public._map_producto p
    join public.menu_items mi on mi.id = p.menu_item_id
   where p.menu_item_id is not null
     and not exists (select 1 from public._recetario_penda z
                      where z.codigo = p.codigo and z.nota like 'PLANTILLA%')
     and not exists (
       select 1 from public._recetario_penda z
       join public._map_ingrediente m on m.ingrediente = z.ingrediente
        where z.codigo = p.codigo and z.unidad <> 'c/n' and z.cantidad is not null
          and coalesce(m.como,'') <> 'descartar'
          and (m.inventory_item_id is null
               or public._penda_a_base(z.cantidad, z.unidad, m.inventory_item_id) is null))
     and exists (
       select 1 from public._recetario_penda z
       join public._map_ingrediente m on m.ingrediente = z.ingrediente
        where z.codigo = p.codigo and z.unidad <> 'c/n' and z.cantidad is not null
          and m.inventory_item_id is not null and coalesce(m.como,'') <> 'descartar')
)
select seccion, dato, valor from (
  select 1 as orden, 'J1 resumen' as seccion, dato, valor from (
    select 'fichas cargables AHORA' as dato, count(*)::text as valor from listas
    union all select 'fichas con producto en el menú',
      (select count(*)::text from public._map_producto where menu_item_id is not null)
    union all select 'fichas SIN producto (no se cargan)',
      (select count(*)::text from public._map_producto where menu_item_id is null)
    union all select 'insumos creados con prefijo COCINA ·',
      (select count(*)::text from public.inventory_items i, biz
        where i.business_id = biz.id and i.name like 'COCINA · %')
    union all select 'ingredientes mapeados a un insumo EXISTENTE',
      (select count(*)::text from public._map_ingrediente where como = 'existente')
    union all select 'ingredientes mapeados al insumo CREADO',
      (select count(*)::text from public._map_ingrediente where como = 'creado')
    union all select 'ingredientes descartados (c/n, guarnición, genéricos)',
      (select count(*)::text from public._map_ingrediente where como = 'descartar')
  ) x
  union all
  select 2, 'J2 se carga', z.producto,
         count(*) filter (where z.unidad <> 'c/n' and z.cantidad is not null) ||
         ' ingredientes · ficha ' || z.codigo
    from public._recetario_penda z
   where z.codigo in (select codigo from listas)
   group by z.producto, z.codigo
  union all
  select 3, 'J3 NO se carga · falta producto', p.codigo, p.producto
    from public._map_producto p where p.menu_item_id is null
  union all
  select 4, 'J4 NO se carga · algo no convierte', p.codigo,
         p.producto || '  →  ' ||
         (select string_agg(z.ingrediente || ' (' || z.cantidad || ' ' || z.unidad || ')', ', ')
            from public._recetario_penda z
            join public._map_ingrediente m on m.ingrediente = z.ingrediente
           where z.codigo = p.codigo and z.unidad <> 'c/n' and z.cantidad is not null
             and coalesce(m.como,'') <> 'descartar'
             and (m.inventory_item_id is null
                  or public._penda_a_base(z.cantidad, z.unidad, m.inventory_item_id) is null))
    from public._map_producto p
   where p.menu_item_id is not null and p.codigo not in (select codigo from listas)
) todo
order by orden, dato;


-- ═══ 9.5 · CREAR LAS RECETAS ═════════════════════════════════════════════════
--   Descomentar y correr cuando 9.4 se vea bien. Idempotente: un producto que
--   ya tiene receta no se toca.
/*
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
*/


-- ═══ 9.6 · VERIFICAR ═════════════════════════════════════════════════════════
/*
select m.name                                       as producto,
       count(ri.*)                                   as ingredientes,
       coalesce(m.is_inventory_tracked,false)        as encendido,
       string_agg(i.name || ' ' || round(ri.quantity,4) || ' ' || ri.unit,
                  ' · ' order by i.name)             as receta
from public.recipes r
join public.menu_items m       on m.id = r.menu_item_id
join public.recipe_ingredients ri on ri.recipe_id = r.id
join public.inventory_items i  on i.id = ri.inventory_item_id
where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
group by m.id, m.name, m.is_inventory_tracked
order by m.name;

-- Tiene que devolver CERO: ninguna receta sobre un producto con vinculo directo.
select m.name, i.name as insumo_ligado
from public.recipes r
join public.menu_items m      on m.id = r.menu_item_id
join public.inventory_items i on i.id = m.inventory_item_id
where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and m.inventory_item_id is not null;

-- Y CERO: ninguna cantidad sospechosa. Un ingrediente en gramos convertido a
-- libras nunca deberia pasar de unas pocas unidades.
select m.name as producto, i.name as insumo, i.unit, ri.quantity
from public.recipe_ingredients ri
join public.recipes r         on r.id = ri.recipe_id
join public.menu_items m      on m.id = r.menu_item_id
join public.inventory_items i on i.id = ri.inventory_item_id
where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and i.unit in ('lb','kg','L','gal') and ri.quantity > 20
order by ri.quantity desc;
*/


-- ═══ 9.7 · DESHACER ══════════════════════════════════════════════════════════
--   Borra SOLO lo que creo este script: las recetas marcadas «cargada
--   automaticamente» y los insumos «COCINA · » que no tengan movimientos.
/*
begin;

delete from public.recipe_ingredients ri
 using public.recipes r, public.menu_items m
 where ri.recipe_id = r.id and r.menu_item_id = m.id
   and m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and r.instructions like '%cargada automaticamente%';

delete from public.recipes r
 using public.menu_items m
 where r.menu_item_id = m.id
   and m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and r.instructions like '%cargada automaticamente%';

-- los insumos solo si estan limpios: sin movimientos, sin stock, sin receta
delete from public.inventory_stock st
 using public.inventory_items i
 where st.item_id = i.id
   and i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and i.name like 'COCINA · %'
   and coalesce(st.quantity,0) = 0
   and not exists (select 1 from public.inventory_movements im where im.item_id = i.id)
   and not exists (select 1 from public.recipe_ingredients ri where ri.inventory_item_id = i.id);

delete from public.inventory_items i
 where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and i.name like 'COCINA · %'
   and not exists (select 1 from public.inventory_movements im where im.item_id = i.id)
   and not exists (select 1 from public.inventory_stock st where st.item_id = i.id)
   and not exists (select 1 from public.recipe_ingredients ri where ri.inventory_item_id = i.id);

commit;
*/
