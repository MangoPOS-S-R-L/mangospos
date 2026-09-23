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


-- ═══ 7.0 · LA CONVERSIÓN (leer esto antes que nada) ══════════════════════════
--
-- `consume_inventory_from_order` descuenta `recipe_ingredients.quantity` EN LA
-- UNIDAD BASE DEL INSUMO. **IGNORA `recipe_ingredients.unit`.** Lo verificado
-- en 20260910_0002 es literal: `i.quantity * coalesce(oi.qty,...)`, sin factor.
-- En la app la conversión ocurre al GUARDAR la receta (unit_conversion.dart);
-- un cargador SQL como este tiene que hacerla él mismo.
--
-- POR QUÉ IMPORTA AQUÍ: el recetario está en g/ml y el 97.4% de los 2,294
-- insumos de La Penda tiene unidad base «unidad». Insertar 227 crudo contra un
-- insumo en «unidad» descuenta 227 pechugas por plato. Contra uno en «lb»,
-- 227 libras. No es un redondeo: es el catálogo entero en dos días.
--
-- REGLA DE ESTA FUNCIÓN: si no puede convertir, devuelve NULL y la ficha NO se
-- carga. Falla ruidosa. Nunca «asume base», que es justo lo que hacía el bug.
--
-- Para los cruces de familia (receta en g contra insumo en «unidad») usa la
-- equivalencia propia del insumo, mig 20260915_0001:
--   1 [unit] = conversion_factor [conversion_unit]   -- 1 unidad = 200 g
-- Si esa migración no está aplicada, la función lo detecta y esos cruces caen
-- en NULL, que es el comportamiento correcto: hay que llenar la equivalencia.

create or replace function public._penda_unidad(u text)
returns text language sql immutable as $fn$
  -- devuelve 'peso' | 'volumen' | 'conteo' | 'oz' (ambigua) | null
  select case lower(btrim(coalesce(u,'')))
    when 'g' then 'peso' when 'gr' then 'peso' when 'gramo' then 'peso'
    when 'gramos' then 'peso' when 'mg' then 'peso' when 'kg' then 'peso'
    when 'kilo' then 'peso' when 'kilos' then 'peso' when 'kilogramo' then 'peso'
    when 'lb' then 'peso' when 'lbs' then 'peso'
    when 'libra' then 'peso' when 'libras' then 'peso'
    when 'ml' then 'volumen' when 'cc' then 'volumen' when 'cl' then 'volumen'
    -- el «shot» del recetario es volumen: el propio papel da la equivalencia,
    -- PE-CAF-105 EXPRESO pide 36 ml por espresso y PE-CAF-107 pide «1 shot».
    when 'shot' then 'volumen' when 'shots' then 'volumen'
    when 'l' then 'volumen' when 'lt' then 'volumen' when 'litro' then 'volumen'
    when 'litros' then 'volumen' when 'gal' then 'volumen' when 'galon' then 'volumen'
    when 'ud' then 'conteo' when 'u' then 'conteo' when 'und' then 'conteo'
    when 'unidad' then 'conteo' when 'unidades' then 'conteo'
    -- la onza es AMBIGUA a proposito: el bar la escribe en volumen y la
    -- cocina en peso. Se resuelve contra la contraparte (R3, 2026-09-03).
    when 'oz' then 'oz' when 'onz' then 'oz'
    when 'onza' then 'oz' when 'onzas' then 'oz'
    else null end;
$fn$;

create or replace function public._penda_factor(u text, familia text)
returns numeric language sql immutable as $fn$
  -- cuanto de la unidad base de la familia hay en 1 [u].
  -- bases: peso = g, volumen = ml, conteo = ud.
  select case
    when familia = 'peso' then case lower(btrim(u))
      when 'g' then 1 when 'gr' then 1 when 'gramo' then 1 when 'gramos' then 1
      when 'mg' then 0.001
      when 'kg' then 1000 when 'kilo' then 1000 when 'kilos' then 1000
      when 'kilogramo' then 1000
      when 'lb' then 453.59237 when 'lbs' then 453.59237
      when 'libra' then 453.59237 when 'libras' then 453.59237
      when 'oz' then 28.349523125 when 'onz' then 28.349523125
      when 'onza' then 28.349523125 when 'onzas' then 28.349523125
      else null end
    when familia = 'volumen' then case lower(btrim(u))
      when 'ml' then 1 when 'cc' then 1 when 'cl' then 10
      when 'l' then 1000 when 'lt' then 1000
      when 'litro' then 1000 when 'litros' then 1000
      when 'gal' then 3785.41 when 'galon' then 3785.41
      when 'shot' then 36 when 'shots' then 36
      when 'oz' then 29.5735 when 'onz' then 29.5735
      when 'onza' then 29.5735 when 'onzas' then 29.5735
      else null end
    when familia = 'conteo' then 1
    else null end;
$fn$;

create or replace function public._penda_a_base(
  _cantidad numeric, _unidad_receta text, _item_id uuid)
returns numeric language plpgsql stable as $fn$
declare
  v_base text; v_cu text; v_cf numeric;
  f_rec text; f_base text; f_cu text;
  v_tiene_equiv boolean;
begin
  if _cantidad is null or _item_id is null then return null; end if;

  v_tiene_equiv := exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='inventory_items'
       and column_name='conversion_factor');

  if v_tiene_equiv then
    execute 'select unit, conversion_unit, conversion_factor
               from public.inventory_items where id = $1'
       into v_base, v_cu, v_cf using _item_id;
  else
    execute 'select unit, null::text, null::numeric
               from public.inventory_items where id = $1'
       into v_base, v_cu, v_cf using _item_id;
  end if;
  if v_base is null then return null; end if;

  -- MISMA UNIDAD, sin vueltas: si la receta pide en la unidad base del insumo
  -- el numero ya esta bien. Hace falta para las unidades que el conversor no
  -- conoce (rebanada, lonja, manojo, bolsa): coinciden y no hay nada que
  -- convertir, pero sin esto caerian en NULL y bloquearian la ficha.
  if lower(btrim(_unidad_receta)) = lower(btrim(v_base)) then
    return round(_cantidad, 6);
  end if;

  f_rec  := public._penda_unidad(_unidad_receta);
  f_base := public._penda_unidad(v_base);
  if f_rec is null or f_base is null then return null; end if;

  -- la onza toma la familia de su contraparte; sola, es volumen
  if f_rec = 'oz' then
    f_rec := case when f_base in ('peso','volumen') then f_base else 'volumen' end;
  end if;
  if f_base = 'oz' then
    f_base := case when f_rec in ('peso','volumen') then f_rec else 'volumen' end;
  end if;

  -- (1) misma familia: regla de tres y ya
  if f_rec = f_base then
    return round(_cantidad
           * public._penda_factor(_unidad_receta, f_rec)
           / nullif(public._penda_factor(v_base, f_base), 0), 6);
  end if;

  -- (2) familias distintas: solo la salva la equivalencia propia del insumo,
  --     1 [unit] = conversion_factor [conversion_unit]
  if v_cf is null or v_cf <= 0 or v_cu is null then return null; end if;
  f_cu := public._penda_unidad(v_cu);
  if f_cu = 'oz' then f_cu := f_rec; end if;
  if f_cu is null or f_cu <> f_rec then return null; end if;

  return round(_cantidad
         * public._penda_factor(_unidad_receta, f_rec)
         / nullif(public._penda_factor(v_cu, f_cu), 0)
         / v_cf, 6);
end;
$fn$;

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

-- La GUARNICION no va dentro de la receta: se elige por el grupo de
-- modificadores GUARNICIONES (tostones / papas / yuquitas / ensalada verde /
-- vegetales salteados) y se cobra aparte. Las 22 fichas que la meten dentro
-- del plato descontarian DOS VECES, asi que esas lineas se descartan de
-- entrada. No bloquean la ficha: simplemente no se costean ahi.
update public._map_ingrediente
   set como = 'descartar'
 where ingrediente ilike '%guarnic%';


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


-- (e) LO QUE BLOQUEA POR UNIDAD — ingredientes mapeados que NO se pueden
--     convertir a la unidad base de su insumo. Cada uno frena su ficha entera.
--     Se arregla de UNA de estas dos formas:
--       (i)  cambiando la unidad base del insumo a la familia correcta
--            -- OJO: no con un conteo abierto, y no re-convierte recetas ya
--            -- guardadas (ver project_inventory_unit_conversion, R2)
--       (ii) llenando la equivalencia propia (mig 20260915_0001):
--            update public.inventory_items
--               set conversion_unit = 'g', conversion_factor = 200
--             where id = '...';   -- 1 unidad = 200 g
select mi.ingrediente,
       ii.name                                   as insumo,
       ii.unit                                   as unidad_base,
       string_agg(distinct z.unidad, '/')        as pide_la_ficha,
       count(distinct z.codigo)                  as fichas_frenadas,
       string_agg(distinct z.codigo, ', ' order by z.codigo) as cuales
from public._map_ingrediente mi
join public.inventory_items ii on ii.id = mi.inventory_item_id
join public._recetario_penda z on z.ingrediente = mi.ingrediente
where mi.inventory_item_id is not null
  and coalesce(mi.como,'') <> 'descartar'
  and z.unidad <> 'c/n'
  and z.cantidad is not null
  and public._penda_a_base(z.cantidad, z.unidad, mi.inventory_item_id) is null
group by mi.ingrediente, ii.name, ii.unit
order by count(distinct z.codigo) desc, mi.ingrediente;


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
    join public.menu_items mitem on mitem.id = p.menu_item_id
    where p.menu_item_id is not null
      -- CANDADO DEL VINCULO DIRECTO: `consume_inventory_from_order` solo usa
      -- `menu_items.inventory_item_id` cuando el producto NO tiene receta
      -- (`not exists recipes`). Ponerle receta a una botella la saca de esa
      -- rama y pasa a descontar ingredientes en vez de la botella: deja de
      -- descontarse a si misma. Esos productos NO llevan receta.
      and mitem.inventory_item_id is null
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
      -- ...y que TODOS se puedan convertir a la unidad base de su insumo.
      -- Sin esto se cargaria «227» contra un insumo en «unidad» y cada plato
      -- descontaria 227 pechugas. Falla ruidosa: la ficha se queda afuera.
      and not exists (
        select 1
        from public._recetario_penda z
        join public._map_ingrediente mi on mi.ingrediente = z.ingrediente
        where z.codigo = p.codigo
          and z.unidad <> 'c/n'
          and z.cantidad is not null
          and mi.inventory_item_id is not null
          and coalesce(mi.como,'') <> 'descartar'
          and public._penda_a_base(z.cantidad, z.unidad, mi.inventory_item_id) is null)
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

    -- la cantidad va CONVERTIDA a la unidad base del insumo, porque es en
    -- esa unidad que el motor descuenta (ver 7.0). `unit` se guarda como la
    -- unidad base y no como la del papel: el numero ya no esta en gramos.
    insert into public.recipe_ingredients (recipe_id, inventory_item_id, quantity, unit)
    select v_rid,
           mi.inventory_item_id,
           public._penda_a_base(z.cantidad, z.unidad, mi.inventory_item_id),
           ii.unit
    from public._recetario_penda z
    join public._map_ingrediente mi on mi.ingrediente = z.ingrediente
    join public.inventory_items ii on ii.id = mi.inventory_item_id
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
