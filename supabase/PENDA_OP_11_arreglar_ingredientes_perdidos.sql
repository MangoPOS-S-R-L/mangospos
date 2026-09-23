-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 11: ingredientes perdidos
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ARREGLA UN BUG DEL CARGADOR. No es opcional: hay recetas en producción a las
-- que les falta un ingrediente, y nadie lo sabía.
--
-- EL BUG, tal como lo delató el reporte del PASO 10:
--   `PE-DES-133 SÁNDWICH COMPLETO` salió en K2 («frenada por Jamón») Y en K5
--   («cargada, 7 ingredientes») a la vez. No es contradicción del reporte: la
--   receta se cargó SIN el jamón.
--
--   La causa: `_map_ingrediente` se llena con
--       select min(z.ingrediente) ... group by public._norm(z.ingrediente)
--   o sea, por cada grupo normalizado guarda UNA sola forma del texto. El papel
--   escribe «Jamon» y «Jamón», el mapa guarda una, y el cargador hace
--       join public._map_ingrediente m on m.ingrediente = z.ingrediente
--   por el TEXTO CRUDO. La forma que no quedó guardada no encuentra fila y,
--   siendo INNER JOIN, **se cae sin ruido**: no bloquea la ficha ni entra a la
--   receta. El plato queda cargado y le falta un insumo.
--
--   La comprobación `frenan` del PASO 10 usa LEFT JOIN, y por eso SÍ lo vio.
--   Las dos miradas discrepaban y esa discrepancia es lo que destapó el bug.
--
-- EL ARREGLO: la clave del mapa pasa a ser el nombre NORMALIZADO, y el join
-- también. Así «Jamon» y «Jamón» encuentran la misma fila.
--
-- IDEMPOTENTE: sí. REVERSIBLE: sí (borra y recarga solo las afectadas).
-- =============================================================================

-- ═══ 11.1 · QUÉ RECETAS ESTÁN INCOMPLETAS (leer primero) ═════════════════════
--   Compara, ficha por ficha, los ingredientes que DEBERÍA tener contra los que
--   tiene. Si «faltan» es mayor que 0, a esa receta le falta un insumo.
select r.instructions ~ 'ficha (PE-[A-Z0-9-]+)'                          as tiene_ficha,
       substring(r.instructions from 'ficha (PE-[A-Z0-9-]+)')             as codigo,
       m.name                                                            as producto,
       (select count(*) from public._recetario_penda z
         where z.codigo = substring(r.instructions from 'ficha (PE-[A-Z0-9-]+)')
           and z.unidad <> 'c/n' and z.cantidad is not null
           and not exists (select 1 from public._map_ingrediente mi
                            where public._norm(mi.ingrediente) = public._norm(z.ingrediente)
                              and coalesce(mi.como,'') = 'descartar'))    as deberia_tener,
       count(ri.*)                                                       as tiene,
       (select count(*) from public._recetario_penda z
         where z.codigo = substring(r.instructions from 'ficha (PE-[A-Z0-9-]+)')
           and z.unidad <> 'c/n' and z.cantidad is not null
           and not exists (select 1 from public._map_ingrediente mi
                            where public._norm(mi.ingrediente) = public._norm(z.ingrediente)
                              and coalesce(mi.como,'') = 'descartar'))
       - count(ri.*)                                                     as faltan,
       (select string_agg(z.ingrediente, ' · ')
          from public._recetario_penda z
         where z.codigo = substring(r.instructions from 'ficha (PE-[A-Z0-9-]+)')
           and z.unidad <> 'c/n' and z.cantidad is not null
           and not exists (select 1 from public._map_ingrediente mi
                            where mi.ingrediente = z.ingrediente))        as sin_fila_en_el_mapa
from public.recipes r
join public.menu_items m          on m.id = r.menu_item_id
left join public.recipe_ingredients ri on ri.recipe_id = r.id
where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and r.instructions like '%cargada automaticamente%'
group by r.id, r.instructions, m.name
having (select count(*) from public._recetario_penda z
         where z.codigo = substring(r.instructions from 'ficha (PE-[A-Z0-9-]+)')
           and z.unidad <> 'c/n' and z.cantidad is not null
           and not exists (select 1 from public._map_ingrediente mi
                            where public._norm(mi.ingrediente) = public._norm(z.ingrediente)
                              and coalesce(mi.como,'') = 'descartar'))
       <> count(ri.*)
order by 6 desc, m.name;


-- ═══ 11.2 · ARREGLAR EL MAPA: una fila por CADA forma del texto ══════════════
--   En vez de cambiar la clave (que obligaría a tocar los tres joins del 9B),
--   se agregan las formas que faltan apuntando al MISMO insumo. El join por
--   texto crudo entonces encuentra fila siempre, y nada más cambia.
do $$
declare v_n int;
begin
  if to_regclass('public._map_ingrediente') is null then
    raise exception 'Falta PENDA_OP_9_cargar_todo.sql. No se toco nada.';
  end if;

  insert into public._map_ingrediente
    (ingrediente, inventory_item_id, como, unidad_receta, fichas)
  select distinct z.ingrediente,
         m.inventory_item_id,
         m.como,
         m.unidad_receta,
         m.fichas
    from public._recetario_penda z
    join public._map_ingrediente m
      on public._norm(m.ingrediente) = public._norm(z.ingrediente)
   where not exists (select 1 from public._map_ingrediente m2
                      where m2.ingrediente = z.ingrediente)
  on conflict (ingrediente) do nothing;

  get diagnostics v_n = row_count;
  raise notice '11.2 — formas de texto agregadas al mapa: %', v_n;
end
$$;


-- ═══ 11.3 · BORRAR LAS RECETAS INCOMPLETAS ═══════════════════════════════════
--   Solo las que este cargue creó Y a las que les falta algo. Las completas no
--   se tocan. Después se vuelve a correr `PENDA_OP_9B_crear_recetas.sql`, que
--   es idempotente y las rehace enteras.
do $$
declare
  v_biz uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_n   int := 0;
  -- OJO: la variable del loop NO puede llamarse `r`. La consulta de abajo
  -- alias `public.recipes` como `r`, y plpgsql resuelve `r.id` a la VARIABLE
  -- (todavia sin asignar) en vez de a la tabla: «record r is not assigned yet».
  rec   record;
begin
  for rec in
    select r.id, r.menu_item_id, m.name,
           substring(r.instructions from 'ficha (PE-[A-Z0-9-]+)') as codigo,
           (select count(*) from public.recipe_ingredients ri where ri.recipe_id = r.id) as tiene
      from public.recipes r
      join public.menu_items m on m.id = r.menu_item_id
     where m.business_id = v_biz
       and r.instructions like '%cargada automaticamente%'
  loop
    if rec.tiene <> (select count(*) from public._recetario_penda z
                      join public._map_ingrediente mi
                        on mi.ingrediente = z.ingrediente
                     where z.codigo = rec.codigo
                       and z.unidad <> 'c/n' and z.cantidad is not null
                       and mi.inventory_item_id is not null
                       and coalesce(mi.como,'') <> 'descartar') then
      delete from public.recipe_ingredients where recipe_id = rec.id;
      delete from public.recipes where id = rec.id;
      v_n := v_n + 1;
      raise notice '  borrada para rehacer: % (%)', rec.name, rec.codigo;
    end if;
  end loop;
  raise notice '11.3 — recetas incompletas borradas: %. Ahora correr de nuevo '
               'PENDA_OP_9B_crear_recetas.sql', v_n;
end
$$;
