-- =============================================================================
-- Los 7 insumos fantasma: los que se crearon al escanear en el anaquel y
-- quedaron con el CÓDIGO como nombre.
--
-- Cada uno es un duplicado del producto real. Mientras existan, el conteo
-- físico los va a listar aparte y la misma botella se cuenta dos veces.
--
-- ESTE ARCHIVO TIENE DOS PARTES. La primera NO ESCRIBE NADA: dice de qué
-- cuelga cada fantasma. Recién con eso a la vista se corre la segunda.
--
-- POR QUÉ NO SE PUEDE BORRAR Y YA:
--   Si un producto del menú apunta al fantasma (`inventory_item_id`), o si
--   una receta lo usa como ingrediente, borrarlo rompe la venta de ese
--   producto. Y si tiene existencia, borrarlo la hace desaparecer sin
--   movimiento que lo explique.
-- =============================================================================

-- ── PARTE 1: DIAGNÓSTICO (no escribe) ──────────────────────────────────────

with huerfanos(codigo) as (values
  ('8020141203001'),  -- Agua Santa Anna
  ('842595138375'),   -- Bloom Pop Fresa
  ('842595121766'),   -- C4 Cosmic Rainbow
  ('842595139778'),   -- C4 Pink Lemonade
  ('4054500119331'),  -- Eichbaum radler grapefruit
  ('3800205871705'),  -- My Motto Cocoa y Cocoa
  ('4054500131746')   -- Zahringer premium
)
select
  f.name                        as fantasma,
  r.name                        as producto_real,
  coalesce((select sum(s.quantity) from public.inventory_stock s
             where s.item_id = f.id), 0)          as existencia_fantasma,
  coalesce((select sum(s.quantity) from public.inventory_stock s
             where s.item_id = r.id), 0)          as existencia_real,
  (select count(*) from public.inventory_movements m
    where m.item_id = f.id)                       as movimientos_fantasma,
  -- Lo que impide borrarlo sin más:
  (select string_agg(mi.name, ' | ') from public.menu_items mi
    where mi.inventory_item_id = f.id)            as ojo_producto_enlazado,
  (select count(*) from public.recipe_ingredients ri
    where ri.inventory_item_id = f.id)            as ojo_recetas_que_lo_usan
from huerfanos h
join public.inventory_items f
  on f.name = h.codigo
 and f.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
left join public.inventory_items r
  on coalesce(nullif(r.barcode,''), nullif(r.sku,'')) = h.codigo
 and r.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
 and r.id <> f.id
order by f.name;


-- ── PARTE 2: DESACTIVAR (diagnóstico corrido 2026-09-02) ───────────────────
--
-- El diagnóstico de arriba salió limpio en los SIETE:
--   · existencia 0
--   · cero movimientos
--   · ningún producto del menú enlazado
--   · ninguna receta que los use
--
-- O sea, son duplicados que nunca se usaron: alguien escaneó, el sistema
-- creó el insumo con el código de nombre, y ahí quedó. No hay existencia que
-- mover ni nada que reapuntar — por eso esto sólo desactiva.
--
-- REVERSIBLE: al final del archivo está el UPDATE que los devuelve.

begin;

update public.inventory_items i
   set name = i.name || ' [FUSIONADO]',
       is_active = false
 where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and i.name in ('8020141203001','842595138375','842595121766',
                  '842595139778','4054500119331','3800205871705',
                  '4054500131746')
   -- Cinturón: sólo si sigue vacío. Si entre el diagnóstico y esto alguien
   -- le movió existencia, no se toca.
   and not exists (select 1 from public.inventory_stock s
                    where s.item_id = i.id and s.quantity <> 0)
   and not exists (select 1 from public.inventory_movements m
                    where m.item_id = i.id)
   and not exists (select 1 from public.menu_items mi
                    where mi.inventory_item_id = i.id)
   and not exists (select 1 from public.recipe_ingredients ri
                    where ri.inventory_item_id = i.id);

commit;

-- Tienen que salir 7 filas afectadas. Si salen menos, alguno dejó de estar
-- vacío: correr otra vez la PARTE 1 para ver cuál y por qué.


-- ── PARA REVERTIR ──────────────────────────────────────────────────────────
-- update public.inventory_items
--    set name = replace(name, ' [FUSIONADO]', ''), is_active = true
--  where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--    and name like '%[FUSIONADO]'
--    and replace(name, ' [FUSIONADO]', '') in
--        ('8020141203001','842595138375','842595121766','842595139778',
--         '4054500119331','3800205871705','4054500131746');
