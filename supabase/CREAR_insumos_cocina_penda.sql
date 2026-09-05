-- =============================================================================
-- LA PENDA EXPRESS — los 8 insumos nuevos que reportó la cocina
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- NO ES UNA MIGRACIÓN, y no debe ir a supabase/migrations/. Es data de UN
-- negocio: una migración corre en todos los entornos y ahí este business_id
-- no existe, así que fallaría por la llave foránea.
--
-- ── LA UNIDAD ES LA DECISIÓN IMPORTANTE ───────────────────────────────────
-- Cada uno se crea en la unidad en que la COCINA lo cuenta, no en la que
-- viene del proveedor. El chicharrón en BOLSAS, el aceite en LATAS.
--
-- Esto es a propósito y es la lección del conteo de hoy: catorce renglones
-- quedaron bloqueados porque la cocina contaba en bolsas y el sistema llevaba
-- libras. Creándolos así, el próximo conteo entra directo y no hay nada que
-- convertir. El campo de unidad de la app es texto libre, así que «bolsa» y
-- «lata» se guardan y se editan igual que «unidad».
--
-- ── NACEN CON COSTO 0 ─────────────────────────────────────────────────────
-- El papel no trae precio. Mientras el costo sea 0, lo que se cuente de ellos
-- suma unidades pero NO suma valor — y el informe del auditor los va a listar
-- en la columna «contados_sin_costo». Hay que costearlos antes de firmar la
-- valuación, o al recibir la próxima compra.
--
-- ── UNO VA CON RESERVA ────────────────────────────────────────────────────
-- «Salmón penca» se crea porque se pidió, pero el sistema ya tiene
-- FILETE DE SALMON (3.7 L) y PORCION DE SALMON 8OZ (2 unidades). Si la penca
-- resulta ser el mismo artículo con otro nombre, esto es un duplicado — que
-- es justo lo que estuvimos limpiando hoy. Está en la pregunta al auditor.
--
-- IDEMPOTENTE: el `where not exists` por nombre evita duplicar si se corre
-- dos veces.
-- =============================================================================

begin;

insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', v.name, nullif(v.sku,''),
       v.unit, 0, 0, true
from (values
  -- nombre                            código          unidad de conteo
  ('Salami Genoa',                     '',             'L'),
  ('Pepperoni Pedrollo',               '2754491014623','L'),
  ('Picante Red Hot',                  '41500055602',  'unidad'),
  ('Aceite especial lata 30 libras',   '7468612640312','lata'),
  ('Salmón penca',                     '',             'L'),
  ('Chicharrón 10 oz',                 '',             'bolsa'),
  ('Pollo mechado 4 oz',               '',             'bolsa'),
  ('Cativía de queso',                 '',             'unidad')
) as v(name, sku, unit)
where not exists (
  select 1 from public.inventory_items i
   where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and lower(i.name) = lower(v.name)
);

commit;

-- Tienen que salir 8 filas.


-- ── DESPUÉS DE CREARLOS ────────────────────────────────────────────────────
-- 1. Meterlos en las sesiones abiertas: consulta 2 de RECARGAR_conteo_penda.sql
--    Sin eso no aparecen en ningún conteo y las cantidades del papel no se
--    pueden teclear.
--
-- 2. Cargar lo que contó la cocina, ya con la unidad correcta:
--
-- with nuevos(nombre, contado) as (values
--   ('Salami Genoa', 9), ('Pepperoni Pedrollo', 3.3), ('Picante Red Hot', 1),
--   ('Aceite especial lata 30 libras', 1), ('Salmón penca', 2),
--   ('Chicharrón 10 oz', 66), ('Pollo mechado 4 oz', 126),
--   ('Cativía de queso', 150)
-- )
-- update public.physical_count_lines l
--    set counted_quantity = n.contado,
--        counter_notes    = 'Cocina · conteo en papel 01-09-2026',
--        updated_at       = now()
--   from nuevos n,
--        public.inventory_items ii,
--        public.physical_count_sessions s
--  where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--    and lower(ii.name) = lower(n.nombre)
--    and s.business_id = ii.business_id
--    and s.code = 'PC-2026-000003'
--    and s.status = 'in_progress'
--    and l.session_id = s.id
--    and l.item_id = ii.id
--    and l.counted_quantity is null;
--
-- 3. Verificar: VERIFICAR_cocina_000003.sql — «contadas» debe pasar de 21 a 29.
