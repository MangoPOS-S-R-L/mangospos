-- =============================================================================
-- LA PENDA EXPRESS — tres correcciones al conteo de Cocina (PC-2026-000003)
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- 1. «Salmón penca» sale: el insumo correcto es FILETE DE SALMON, confirmado.
--    Se creó hoy, nunca se usó, y ya tiene sus 2 libras cargadas en el insumo
--    bueno. Se desactiva con la convención de siempre, no se borra.
--
-- 2. Las dos pastas quedan en BOLSA y con su cantidad. Se crearon esta mañana
--    con unidad «unidad» — dentro del lote de 33 donde todo salió así — pero
--    la cocina las cuenta en bolsas. Es el mismo problema que dejó bloqueados
--    a los otros catorce, solo que este lo produjo la carga.
--
-- 3. Queda una decisión abierta, al final del archivo.
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ── 1. REVISAR antes de tocar nada ─────────────────────────────────────────
select
  ii.name, ii.unit, ii.is_active,
  coalesce((select sum(s.quantity) from public.inventory_stock s
             where s.item_id = ii.id), 0)                as existencia,
  (select count(*) from public.inventory_movements m
    where m.item_id = ii.id)                             as movimientos,
  (select count(*) from public.menu_items mi
    where mi.inventory_item_id = ii.id)                  as productos_enlazados,
  (select count(*) from public.recipe_ingredients ri
    where ri.inventory_item_id = ii.id)                  as recetas,
  (select count(*) from public.physical_count_lines l
    where l.item_id = ii.id and l.counted_quantity is not null)
                                                         as veces_contado
from public.inventory_items ii
where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and lower(ii.name) in ('salmón penca','salmon penca','pasta penne','pasta linguine')
order by ii.name;
-- Salmón penca debe salir en CERO en todo. Si no, parar y revisar.


-- ── 2. Salmón penca fuera ──────────────────────────────────────────────────
begin;

update public.inventory_items i
   set name = i.name || ' [FUSIONADO]',
       is_active = false
 where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and lower(i.name) in ('salmón penca','salmon penca')
   -- Cinturón: sólo si sigue sin usarse.
   and not exists (select 1 from public.inventory_stock s
                    where s.item_id = i.id and s.quantity <> 0)
   and not exists (select 1 from public.inventory_movements m
                    where m.item_id = i.id)
   and not exists (select 1 from public.menu_items mi
                    where mi.inventory_item_id = i.id)
   and not exists (select 1 from public.recipe_ingredients ri
                    where ri.inventory_item_id = i.id);

-- La línea que dejó en el conteo se vacía: el insumo ya no participa.
update public.physical_count_lines l
   set counted_quantity = null, updated_at = now()
  from public.inventory_items ii, public.physical_count_sessions s
 where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and ii.name like 'Salm%n penca%'
   and l.item_id = ii.id
   and s.id = l.session_id
   and s.business_id = ii.business_id
   and s.status = 'in_progress';

commit;


-- ── 3. Las pastas: unidad BOLSA y su cantidad ──────────────────────────────
begin;

update public.inventory_items
   set unit = 'bolsa'
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and lower(name) in ('pasta penne','pasta linguine');

with cant(nombre, contado) as (values
  ('pasta penne', 17), ('pasta linguine', 15)
)
update public.physical_count_lines l
   set counted_quantity = c.contado,
       counter_notes    = 'Cocina · conteo en papel 01-09-2026',
       updated_at       = now()
  from cant c, public.inventory_items ii, public.physical_count_sessions s
 where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and lower(ii.name) = c.nombre
   and s.business_id = ii.business_id
   and s.code = 'PC-2026-000003'
   and s.status = 'in_progress'
   and l.session_id = s.id
   and l.item_id = ii.id;

commit;
-- 2 filas en cada uno.


-- ── 4. VERIFICAR ───────────────────────────────────────────────────────────
-- VER_contados_cocina.sql debe dar 31 contados: se va Salmón penca y las dos
-- pastas pasan de 0 a 17 y 15.


-- ── LO QUE QUEDA ABIERTO ───────────────────────────────────────────────────
-- El papel traía DOS renglones de salmón:
--
--   «salmon penca»              2 libras   → ya cargado en FILETE DE SALMON
--   «FILETE DE SALMON 8 onza»   1 unidad   → sin resolver (de los 14)
--
-- Ahora que FILETE DE SALMON es el insumo único, hay que decidir si esas
-- 2 libras ya incluyen ese filete de 8 onzas, o si hay que sumarle su medio
-- libra y dejar la línea en 2.5.
--
-- Es la única pregunta de salmón que queda; el resto del pescado está resuelto.
