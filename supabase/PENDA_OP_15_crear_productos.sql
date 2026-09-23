-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 15: crear los productos que
-- faltan, INACTIVOS, para que sus recetas se puedan cargar
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- DECISIÓN DEL DUEÑO (23-09): crearlos **inactivos y en precio 0**, con
-- categoría, área de impresión e impuesto COPIADOS de un producto hermano.
-- Cuando la cocina lance el plato le pone precio y lo activa desde la app, y la
-- receta ya está puesta.
--
-- POR QUÉ INACTIVOS Y NO ACTIVOS EN 0:
--   un producto activo en precio 0 se puede vender en 0. Inactivo no aparece en
--   la POS, así que no hay forma de cobrarlo mal. El precio se pone una sola vez
--   el día que se lance.
--
-- POR QUÉ SE COPIA LA CONFIGURACIÓN Y NO SE DEJA VACÍA — dos trampas conocidas
-- de este repo:
--   * un producto SIN vínculo en `menu_item_taxes` factura **ITBIS 0**. Esa
--     tabla es la única fuente del impuesto; no hay default que lo salve.
--   * un producto SIN área de impresión **no imprime comanda**. La cocina no se
--     entera del pedido.
--   Crear 35 productos así sería peor que no tenerlos.
--
-- DE DÓNDE SALE LA CONFIGURACIÓN: de un producto de REFERENCIA por cada
--   categoría del recetario — el que ya está mapeado a una ficha de esa misma
--   categoría y más se ha vendido. Si la categoría no tiene ninguno mapeado, se
--   cae a PLATOS FUERTES; si tampoco, esa ficha NO se crea y se reporta.
--   La sección 15.1 muestra la referencia elegida ANTES de crear nada.
--
-- LO QUE NO SE CREA, por decisión: TABLA PARA 4 PERSONAS. Cuatro fichas se
--   pelean el producto de 2 personas (TABLA DE FIAMBRES 2 y 4, TABLA PENDA 2
--   y 4) y se resolvió dejarlas sin cargar.
--
-- REQUIERE: PASO 6 + OP 9 corridos. DESPUÉS: `PENDA_OP_9B_crear_recetas.sql`
-- (no hace falta tocarlo: no filtra por `is_active`).
--
-- IDEMPOTENTE: sí, por nombre. REVERSIBLE: sí (15.5).
-- =============================================================================

-- ═══ 15.1 · LA REFERENCIA POR CATEGORÍA (leer ANTES de crear) ════════════════
-- TABLA, no vista: una vista sobre `_recetario_penda` hace que volver a correr
-- el PASO 6 falle con «cannot drop table because other objects depend on it»,
-- y el PASO 6 se vuelve a correr cada vez que se toca el conversor.
drop table if exists public._ref_categoria;
create table public._ref_categoria as
with biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
-- productos ya mapeados a una ficha, con su categoría del recetario
mapeados as (
  select distinct z.categoria, m.id as menu_item_id, m.category_id,
         (select count(*) from public.order_items oi
           where oi.product_id = m.id and oi.status <> 'void') as lineas
    from public._map_producto p
    join public._recetario_penda z on z.codigo = p.codigo
    join public.menu_items m on m.id = p.menu_item_id
   cross join biz
   where p.menu_item_id is not null and m.business_id = biz.id
     and m.category_id is not null
),
-- el mas vendido de cada categoria es la referencia
mejor as (
  select categoria, menu_item_id, category_id, lineas,
         row_number() over (partition by categoria order by lineas desc, menu_item_id) as rn
    from mapeados
)
select categoria, menu_item_id as ref_menu_item_id, category_id, lineas as ref_lineas
  from mejor where rn = 1;

select r.categoria,
       c.name                                         as categoria_del_pos,
       m.name                                         as producto_de_referencia,
       r.ref_lineas                                   as lineas_vendidas,
       coalesce(m.print_area_code, '(sin código)')    as area_code,
       coalesce((select string_agg(pa.name, ' · ')
                   from public.menu_item_print_areas x
                   join public.print_areas pa on pa.id = x.print_area_id
                  where x.menu_item_id = m.id), '(sin filas)') as areas_tabla,
       coalesce((select string_agg(t.name, ' · ')
                   from public.menu_item_taxes mt
                   join public.taxes t on t.id = mt.tax_id
                  where mt.item_id = m.id), '⚠ SIN IMPUESTO') as impuestos
from public._ref_categoria r
join public.menu_items m on m.id = r.ref_menu_item_id
left join public.categories c on c.id = r.category_id
order by r.categoria;


-- ─── y QUÉ se va a crear (la misma condición que usa 15.2) ───────────────────
select z.categoria,
       count(*)                                                as productos,
       string_agg(z.producto, E'\n' order by z.producto)        as cuales
from (select distinct z.codigo, z.producto, z.categoria from public._recetario_penda z
      join public._map_producto p on p.codigo = z.codigo
     where p.menu_item_id is null
       and not exists (select 1 from public._recetario_penda z2
                        where z2.codigo = z.codigo and z2.nota like 'PLANTILLA%')
       and exists (select 1 from public._recetario_penda z3
                   join public._map_ingrediente mi on mi.ingrediente = z3.ingrediente
                    where z3.codigo = z.codigo and z3.unidad <> 'c/n'
                      and z3.cantidad is not null and mi.inventory_item_id is not null
                      and coalesce(mi.como,'') <> 'descartar')
       and z.producto not ilike '%TABLA%4 PERSONAS%'
       and public._norm(z.producto) not in ('CAFE','CAPUCCINO','EMPANADA','CROQUETAS')
       -- y que el nombre no exista ya en el catalogo
       and not exists (select 1 from public.menu_items m
                        where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
                          and public._norm(m.name) = public._norm(z.producto))
     ) z
group by z.categoria
order by z.categoria;

-- ═══ 15.2 · CREAR (escribe) ══════════════════════════════════════════════════
do $$
declare
  v_biz   uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_creados int := 0;
  v_ya      int := 0;
  v_sin_ref int := 0;
  rec       record;
  v_new     uuid;
  v_ref     uuid;
begin
  if to_regclass('public._map_producto') is null then
    raise exception 'Falta PENDA_OP_9_cargar_todo.sql. No se creo nada.';
  end if;

  for rec in
    select distinct z.codigo, z.producto, z.categoria
      from public._recetario_penda z
      join public._map_producto p on p.codigo = z.codigo
     where p.menu_item_id is null
       -- las PLANTILLA no llevan receta, no hace falta el producto
       and not exists (select 1 from public._recetario_penda z2
                        where z2.codigo = z.codigo and z2.nota like 'PLANTILLA%')
       -- y que tenga al menos un ingrediente que descuente
       and exists (
         select 1 from public._recetario_penda z3
         join public._map_ingrediente mi on mi.ingrediente = z3.ingrediente
          where z3.codigo = z.codigo and z3.unidad <> 'c/n' and z3.cantidad is not null
            and mi.inventory_item_id is not null
            and coalesce(mi.como,'') <> 'descartar')
       -- decision del dueño: la TABLA de 4 personas no se crea
       and z.producto not ilike '%TABLA%4 PERSONAS%'
       -- NOMBRES GENERICOS: el POS vende «CAFE DOMINICANO» y «CAPUCCINO
       -- ITALIANO», no «CAFE» ni «CAPUCCINO» a secas; y las empanadas y
       -- croquetas se COMPRAN HECHAS (existen con vinculo directo). Crear un
       -- producto con el nombre genérico solo ensucia el catalogo.
       and public._norm(z.producto) not in ('CAFE','CAPUCCINO','EMPANADA','CROQUETAS')
     order by z.categoria, z.producto
  loop
    -- ¿ya existe un producto con ese nombre? (idempotencia)
    if exists (select 1 from public.menu_items m
                where m.business_id = v_biz
                  and public._norm(m.name) = public._norm(rec.producto)) then
      v_ya := v_ya + 1;
      continue;
    end if;

    -- referencia: misma categoria del recetario, si no PLATOS FUERTES
    select ref_menu_item_id into v_ref from public._ref_categoria
     where categoria = rec.categoria;
    if v_ref is null then
      select ref_menu_item_id into v_ref from public._ref_categoria
       where categoria = 'PLATOS FUERTES';
    end if;
    if v_ref is null then
      v_sin_ref := v_sin_ref + 1;
      raise notice '  SIN REFERENCIA, no se crea: % (%)', rec.producto, rec.categoria;
      continue;
    end if;

    -- el producto, apagado y en 0, con la config del hermano
    insert into public.menu_items
      (business_id, name, price, category_id, print_area_code, is_active,
       is_inventory_tracked, tax_mode, description)
    select v_biz, rec.producto, 0, ref.category_id, ref.print_area_code, false,
           false, ref.tax_mode,
           'Creado para la receta ' || rec.codigo ||
           ' · INACTIVO y en precio 0: poner precio y activar antes de vender'
      from public.menu_items ref
     where ref.id = v_ref
    returning id into v_new;

    -- las areas de impresion de la tabla nueva (tienen prioridad sobre el code)
    insert into public.menu_item_print_areas (menu_item_id, print_area_id)
    select v_new, x.print_area_id
      from public.menu_item_print_areas x
     where x.menu_item_id = v_ref
    on conflict do nothing;

    -- EL IMPUESTO. Sin esto el producto factura ITBIS 0.
    insert into public.menu_item_taxes (item_id, tax_id)
    select v_new, mt.tax_id
      from public.menu_item_taxes mt
     where mt.item_id = v_ref
    on conflict do nothing;

    -- y al mapeo, para que el 9B lo levante
    update public._map_producto
       set menu_item_id = v_new, como = 'creado inactivo'
     where codigo = rec.codigo;

    v_creados := v_creados + 1;
  end loop;

  raise notice '15.2 — productos creados INACTIVOS: % · ya existian: % · sin referencia: %',
    v_creados, v_ya, v_sin_ref;
  raise notice 'Ninguno se puede vender: estan apagados y en precio 0. '
               'Ahora correr PENDA_OP_9B_crear_recetas.sql';
end
$$;


-- ═══ 15.3 · VERIFICAR ════════════════════════════════════════════════════════
--   ESPERADO: todos inactivos, precio 0, con categoría, con área y CON impuesto.
select m.name                                              as producto,
       m.price,
       coalesce(m.is_active,true)                            as activo_OJO,
       c.name                                                as categoria,
       coalesce(m.print_area_code,'—')                        as area_code,
       (select count(*) from public.menu_item_print_areas x
         where x.menu_item_id = m.id)                         as areas,
       coalesce((select string_agg(t.name,' · ') from public.menu_item_taxes mt
                   join public.taxes t on t.id = mt.tax_id
                  where mt.item_id = m.id), '⚠ SIN IMPUESTO')  as impuestos
from public.menu_items m
left join public.categories c on c.id = m.category_id
where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and m.description like 'Creado para la receta %'
order by c.name, m.name;


-- ═══ 15.4 · DESHACER ═════════════════════════════════════════════════════════
/*
-- solo los que creó este script, y solo si nunca se vendieron
delete from public.recipe_ingredients ri using public.recipes r, public.menu_items m
 where ri.recipe_id = r.id and r.menu_item_id = m.id
   and m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and m.description like 'Creado para la receta %';
delete from public.recipes r using public.menu_items m
 where r.menu_item_id = m.id
   and m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and m.description like 'Creado para la receta %';
update public._map_producto p set menu_item_id = null, como = 'auto'
  from public.menu_items m
 where p.menu_item_id = m.id and m.description like 'Creado para la receta %';
delete from public.menu_item_taxes mt using public.menu_items m
 where mt.item_id = m.id and m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and m.description like 'Creado para la receta %';
delete from public.menu_item_print_areas x using public.menu_items m
 where x.menu_item_id = m.id and m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and m.description like 'Creado para la receta %';
delete from public.menu_items m
 where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and m.description like 'Creado para la receta %'
   and not exists (select 1 from public.order_items oi where oi.product_id = m.id);
drop view if exists public._ref_categoria;
*/
