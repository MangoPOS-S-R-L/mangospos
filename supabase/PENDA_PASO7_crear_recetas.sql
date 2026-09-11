-- =============================================================================
-- LA PENDA EXPRESS · PASO 7 — Asignar las recetas a los productos
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- REQUIERE: haber corrido el PASO 6 (la tabla _recetario_penda y _norm).
--
-- LA IDEA: separar el trabajo HUMANO del mecanico.
--   7.1  Crea DOS tablas de mapeo y las prellena con lo que empareja solo.
--   7.2  Te muestra lo que falta mapear -> lo corriges a mano con UPDATE.
--   7.3  Crea las recetas, pero SOLO las fichas 100% mapeadas.
--   7.4  Verifica.  7.5  Deshacer.
--
-- Podes correr 7.3 las veces que quieras: es idempotente y cada vez levanta
-- las fichas que hayan quedado completas desde la ultima corrida.
--
-- TRES REGLAS QUE APLICA:
--   1. Las fichas PLANTILLA se descartan: no tienen ingredientes reales.
--   2. Las lineas 'c/n' (aceite para freir) se SALTAN: recipe_ingredients
--      exige cantidad y "cuanto necesario" no es una cantidad. No bloquean
--      la ficha; simplemente no se costean por porcion.
--   3. Un producto que YA tiene receta no se toca.
-- =============================================================================


-- ═══ 7.1 · Las tablas de mapeo ═══════════════════════════════════════════════

-- (a) ingrediente del papel -> insumo del sistema
drop table if exists public._map_ingrediente;
create table public._map_ingrediente (
  ingrediente       text primary key,
  inventory_item_id uuid,
  como              text            -- 'auto' | 'mano' | 'descartar'
);

insert into public._map_ingrediente (ingrediente, inventory_item_id, como)
select r.ingrediente,
       -- max() no existe para uuid: se toma el primero por nombre.
       -- Si no hubo match, array_agg da {NULL} y [1] es NULL. Correcto.
       (array_agg(i.id order by i.name))[1],
       case when count(i.id) = 0 then null
            when count(i.id) = 1 then 'auto'
            else 'auto-AMBIGUO' end
from (select distinct ingrediente from public._recetario_penda) r
left join public.inventory_items i
       on i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and coalesce(i.is_active, true)
      and public._norm(i.name) = public._norm(r.ingrediente)
group by r.ingrediente;

-- (b) producto del papel -> producto del menu
drop table if exists public._map_producto;
create table public._map_producto (
  codigo       text primary key,
  producto     text not null,
  menu_item_id uuid,
  como         text
);

insert into public._map_producto (codigo, producto, menu_item_id, como)
select r.codigo, r.producto,
       (array_agg(m.id order by m.is_active desc, m.created_at))[1],
       case when count(m.id) = 0 then null
            when count(m.id) = 1 then 'auto'
            else 'auto-AMBIGUO' end
from (select distinct codigo, producto from public._recetario_penda) r
left join public.menu_items m
       on m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and public._norm(m.name) = public._norm(r.producto)
group by r.codigo, r.producto;


-- ═══ 7.2 · QUÉ FALTA MAPEAR ═════════════════════════════════════════════════

-- (a) el tablero
select
  (select count(*) from public._map_producto)                                  as fichas,
  (select count(*) from public._map_producto where menu_item_id is not null)    as productos_ok,
  (select count(*) from public._map_producto where menu_item_id is null)        as productos_SIN_MAPEAR,
  (select count(*) from public._map_producto where como = 'auto-AMBIGUO')       as productos_ambiguos,
  (select count(*) from public._map_ingrediente)                                as ingredientes,
  (select count(*) from public._map_ingrediente where inventory_item_id is not null) as insumos_ok,
  (select count(*) from public._map_ingrediente where inventory_item_id is null
                                                  and coalesce(como,'') <> 'descartar') as insumos_SIN_MAPEAR,
  (select count(*) from public._map_ingrediente where como = 'auto-AMBIGUO')      as insumos_ambiguos;

-- (b) los ingredientes sin mapear, por cuánto pesan
select m.ingrediente,
       count(distinct r.codigo)  as en_cuantas_fichas,
       min(r.unidad)             as unidad_receta,
       string_agg(distinct r.nota, ' / ') filter (where r.nota <> '') as nota
from public._map_ingrediente m
join public._recetario_penda r on r.ingrediente = m.ingrediente
where m.inventory_item_id is null and coalesce(m.como,'') <> 'descartar'
group by m.ingrediente
order by count(distinct r.codigo) desc, m.ingrediente;

-- (c) los productos sin mapear
select p.codigo, p.producto,
       (select string_agg(distinct nota,' / ') from public._recetario_penda z
         where z.codigo = p.codigo and z.nota <> '') as nota
from public._map_producto p
where p.menu_item_id is null
order by p.codigo;

-- (d) CÓMO CORREGIR A MANO — plantillas listas para copiar:
--
--   update public._map_ingrediente
--      set inventory_item_id = 'PEGA-AQUI-EL-UUID', como = 'mano'
--    where ingrediente = 'Chivo limpio';
--
--   -- un ingrediente que no se descuenta (sal, agua de coccion, hielo...):
--   update public._map_ingrediente set como = 'descartar'
--    where ingrediente in ('Sal y pimienta','Agua de coccion');
--
--   update public._map_producto
--      set menu_item_id = 'PEGA-AQUI-EL-UUID', como = 'mano'
--    where codigo = 'PE-PF-062';
--
--   -- para buscar el uuid:
--   select id, name, unit, cost from public.inventory_items
--    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--      and name ilike '%chivo%' order by name;


-- ═══ 7.3 · CREAR LAS RECETAS (escribe) ═══════════════════════════════════════
--   Solo levanta las fichas 100% mapeadas. Las demas las deja y te dice
--   cuantas quedaron. Correlo de nuevo cuando mapees mas.
do $$
declare
  v_biz     uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_recetas int := 0;
  v_ingr    int := 0;
  v_saltan  int := 0;
  r         record;
  v_rid     uuid;
begin
  if to_regclass('public._recetario_penda') is null
     or to_regclass('public._map_ingrediente') is null then
    raise exception 'Falta el PASO 6 o el 7.1. No se creo nada.';
  end if;

  for r in
    -- fichas candidatas: mapeadas, sin PLANTILLA, y con TODOS sus
    -- ingredientes resueltos (mapeados o marcados 'descartar' o 'c/n')
    select p.codigo, p.menu_item_id
    from public._map_producto p
    where p.menu_item_id is not null
      and not exists (select 1 from public._recetario_penda z
                       where z.codigo = p.codigo and z.nota like 'PLANTILLA%')
      and not exists (
        select 1
        from public._recetario_penda z
        join public._map_ingrediente mi on mi.ingrediente = z.ingrediente
        where z.codigo = p.codigo
          and z.unidad <> 'c/n'
          and mi.inventory_item_id is null
          and coalesce(mi.como,'') <> 'descartar')
      -- y que quede al menos un ingrediente que si descuenta
      and exists (
        select 1
        from public._recetario_penda z
        join public._map_ingrediente mi on mi.ingrediente = z.ingrediente
        where z.codigo = p.codigo and z.unidad <> 'c/n'
          and mi.inventory_item_id is not null
          and coalesce(mi.como,'') <> 'descartar')
  loop
    if exists (select 1 from public.recipes where menu_item_id = r.menu_item_id) then
      v_saltan := v_saltan + 1;
      continue;
    end if;

    insert into public.recipes (menu_item_id, yield_quantity, instructions)
    values (r.menu_item_id, 1,
            'Recetario Estandar de Cocina, agosto 2026 — ficha ' || r.codigo)
    returning id into v_rid;

    insert into public.recipe_ingredients (recipe_id, inventory_item_id, quantity, unit)
    select v_rid, mi.inventory_item_id, z.cantidad, z.unidad
    from public._recetario_penda z
    join public._map_ingrediente mi on mi.ingrediente = z.ingrediente
    where z.codigo = r.codigo
      and z.unidad <> 'c/n'
      and z.cantidad is not null
      and mi.inventory_item_id is not null
      and coalesce(mi.como,'') <> 'descartar';

    get diagnostics v_ingr = row_count;
    v_recetas := v_recetas + 1;
  end loop;

  raise notice 'Recetas creadas: %  ·  ya tenian receta: %', v_recetas, v_saltan;
end
$$;


-- ═══ 7.4 · VERIFICAR ═════════════════════════════════════════════════════════
select
  count(distinct r.id)                        as recetas,
  count(ri.*)                                 as ingredientes,
  round(avg(x.n), 1)                          as promedio_por_receta,
  count(distinct r.id) filter (where x.n = 0) as recetas_VACIAS
from public.recipes r
join public.menu_items m on m.id = r.menu_item_id
                        and m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
left join public.recipe_ingredients ri on ri.recipe_id = r.id
left join lateral (select count(*) n from public.recipe_ingredients z
                    where z.recipe_id = r.id) x on true;

-- Las que quedaron pendientes y por qué
select p.codigo, p.producto,
       case when p.menu_item_id is null then 'producto sin mapear'
            when exists (select 1 from public._recetario_penda z
                          where z.codigo = p.codigo and z.nota like 'PLANTILLA%')
              then 'PLANTILLA — no tiene ingredientes reales'
            when exists (select 1 from public._recetario_penda z
                         join public._map_ingrediente mi on mi.ingrediente = z.ingrediente
                          where z.codigo = p.codigo and z.unidad <> 'c/n'
                            and mi.inventory_item_id is null
                            and coalesce(mi.como,'') <> 'descartar')
              then 'le falta mapear insumo(s)'
            when exists (select 1 from public.recipes rc where rc.menu_item_id = p.menu_item_id)
              then 'ya tenia receta'
            else '?' end                                as motivo
from public._map_producto p
where not exists (
  select 1 from public.recipes rc
   where rc.menu_item_id = p.menu_item_id
     and rc.instructions like '%' || p.codigo || '%')
order by 3, 1;


-- ═══ 7.5 · DESHACER ══════════════════════════════════════════════════════════
--   Borra SOLO las recetas creadas por este script (van marcadas en
--   instructions). No toca ninguna otra.
/*
delete from public.recipe_ingredients ri
 using public.recipes r
 where ri.recipe_id = r.id
   and r.instructions like 'Recetario Estandar de Cocina, agosto 2026%';

delete from public.recipes r
 where r.instructions like 'Recetario Estandar de Cocina, agosto 2026%';
*/
