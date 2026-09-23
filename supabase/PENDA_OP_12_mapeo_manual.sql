-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 12: mapeo manual de K3
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Mapea a mano las fichas que SÍ existen en el POS con otro nombre. Es la lista
-- que revisé una por una del reporte K3; las dudosas quedaron fuera a propósito
-- y están listadas abajo para que decidas.
--
-- DESPUÉS DE ESTO: correr `PENDA_OP_9B_crear_recetas.sql`. Es idempotente, así
-- que levanta solo las nuevas y no toca las 35 que ya están.
--
-- LO QUE NO ENTRA, Y POR QUÉ
--
--   (a) SUGERENCIAS VENENOSAS del trigrama — mapearlas haría que un plato
--       descuente los insumos de otro:
--         MERO A LA PLANCHA    → PECHUGA A LA PLANCHA   el mero gastaría pollo
--         MERO A LA CREMA      → PECHUGA A LA CREMA     igual
--         PIZZA PEPPERONI      → PERONI                 es una CERVEZA
--         PIZZA MARGARITA      → MARGARITA FRESA        es un cóctel
--         PIZZA JAMON Y QUESO  → BAGEL JAMON Y QUESO    otro plato
--         SANDWICH CUBANO      → CLUB SANDWICH          otro plato
--         CEVICHE DE CHICHARRON→ MOFONGO DE CHICHARRON  otro plato
--         TOSTADA PENDA        → CASABE TOSTADO PENDA   otra cosa
--         YUQUITAS             → ZAMBOS YUQUITAS        Zambos es un snack
--         CAPUCCINO            → CARAMEL CAPUCCINO      otra bebida
--         EMPANADA             → EMPANADA DE POLLO      genérica, y es producto
--                                                       terminado que se compra
--
--   (b) CHOQUES: dos fichas distintas apuntan al MISMO producto del POS, y un
--       producto solo puede tener UNA receta. El 9B resolvería el empate por
--       orden de código, o sea al azar. Mejor dejarlos fuera y que los decidas:
--         TABLA PARA 2 PERSONAS ← PE-ENT-023 (TABLA DE FIAMBRES) y
--                                  PE-PF-054 (TABLA PENDA)
--         TABLA PARA 4 PERSONAS ← PE-ENT-024 y PE-PF-055
--         ARROZ FRITO PENDA     ← PE-APM-083 (YA cargada) y PE-APM-084 (la de
--                                  mariscos, que es otro plato)
--         CHEESE BURGER         ← PE-EWB-049 (entra) y PE-INF-031 (MINI, fuera)
--         BACON CHEESE BURGER   ← PE-EWB-048 (entra) y PE-EWB-052 (MADURO, fuera)
--         CLUB SANDWICH         ← PE-EWB-040 (YA cargada) y PE-EWB-041 (CUBANO)
--         PENDA EXPRESS FRAPPE  ← PE-CAF-119 (YA cargada) y PE-CAF-115
--
--   (c) LAS 14 DEL CANDADO: el producto existe con el MISMO nombre (por eso
--       salen con parecido 1.00 en K3) pero tiene `inventory_item_id`, así que
--       se descuenta a sí mismo. Son los 3 quipes, CARNE SALADA, CHIVO GUISADO,
--       PECHURINA, los 2 mofongos, LIMONADA FROZEN, FRESA FROZEN, JUGO DE
--       CEREZA, JUGO DE TAMARINDO, AGUACATE y CEPA DE APIO. Ponerles receta las
--       rompe. Si quieres convertirlas a receta de verdad hay que quitarles el
--       vínculo primero, y es otra decisión.
--
-- IDEMPOTENTE: sí. REVERSIBLE: sí (12.3).
-- =============================================================================

-- ═══ 12.1 · LA LISTA, Y LA VERIFICACIÓN ══════════════════════════════════════
--   Se mapea por NOMBRE, no por uuid, para que se pueda leer y auditar. La
--   comparación va por `_norm` para no pelear con tildes ni dobles espacios.
drop table if exists public._mapeo_manual;
create table public._mapeo_manual (
  codigo        text primary key,
  ficha         text,
  producto_pos  text,
  menu_item_id  uuid,
  estado        text
);

insert into public._mapeo_manual (codigo, ficha, producto_pos) values
  ('PE-APM-085','PASTA 3 QUESOS',               'PASTA 3 QUESOS LARGA'),
  ('PE-APM-086','PASTA ALFREDO',                'PASTA ALFREDO PENDA'),
  ('PE-APM-087','PASTA PESTO',                  'PASTA PESTO CORTA'),
  ('PE-BAR-132','NEGRONI',                      'NEGRONI TRAGO'),
  ('PE-BEB-133','LICUADO DE FRESA CON LECHOSA', 'LICUADO FRESA LECHOSA'),
  ('PE-CAF-117','MILKY WAY FRAPPE',             'MILK WAY FRAPPE'),
  ('PE-CAF-131','COLD COFFEE',                  'COLD COFFE'),
  ('PE-DES-003','OMELETTE CON BACON',           'OMELETTE CON BEICON'),
  ('PE-DES-006','CROISSANT PLAIN',              'CROISSANTS PLAIN PQ'),
  ('PE-DES-010','PANCAKES',                     'PANCAKE'),
  ('PE-DES-132','BAGEL DE JAMON Y QUESO',       'BAGEL JAMON Y QUESO'),
  ('PE-ENT-022','LONGANIZA CRIOLLA',            'LONGANIZA'),
  ('PE-EWB-037','SANDWICH DE JAMON Y QUESO',    'SANDWICH JAMON QUESO'),
  ('PE-EWB-048','BACON CHEESEBURGER',           'BACON CHEESE BURGER'),
  ('PE-EWB-049','CHEESEBURGER',                 'CHEESE BURGER'),
  ('PE-GUA-093','ARROZ BLANCO',                 'GUARNICION ARROZ BLANCO'),
  ('PE-GUA-099','VEGETALES AL GRILL',           'VEGETALES AL GRILL (GUARNICION)'),
  ('PE-JYF-123','LIMONADA DE COCO',             'LIMONADA COCO'),
  ('PE-PF-057', 'CHICHARRON',                   'CHICHARRON LA PENDA');

-- resolver el uuid y dictaminar cada fila
update public._mapeo_manual mm
   set menu_item_id = m.id,
       estado = case
         when m.inventory_item_id is not null then 'RECHAZADA · tiene vínculo directo'
         when exists (select 1 from public.recipes r where r.menu_item_id = m.id)
                                              then 'ya tiene receta'
         else 'lista' end
  from public.menu_items m
 where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and coalesce(m.is_active,true)
   and public._norm(m.name) = public._norm(mm.producto_pos);

update public._mapeo_manual
   set estado = 'RECHAZADA · no existe ese producto en el POS'
 where menu_item_id is null;

-- y que la ficha exista en el recetario
update public._mapeo_manual mm
   set estado = 'RECHAZADA · la ficha no está en el recetario'
 where not exists (select 1 from public._recetario_penda z where z.codigo = mm.codigo);

select estado, count(*) as fichas,
       string_agg(codigo || ' ' || ficha || '  →  ' || producto_pos, E'\n' order by codigo) as detalle
from public._mapeo_manual
group by estado
order by estado;


-- ═══ 12.2 · APLICAR AL MAPEO (escribe) ═══════════════════════════════════════
--   Solo las que dicen «lista». Después: correr PENDA_OP_9B_crear_recetas.sql
do $$
declare v_n int := 0; v_mal int;
begin
  select count(*) into v_mal from public._mapeo_manual where estado like 'RECHAZADA%';
  if v_mal > 0 then
    raise notice 'OJO: % filas RECHAZADAS, se saltan. Mirar el detalle de 12.1.', v_mal;
  end if;

  -- un producto no puede recibir dos fichas: si el nombre se repite, se aborta
  if exists (select 1 from public._mapeo_manual where estado = 'lista'
              group by menu_item_id having count(*) > 1) then
    raise exception 'Dos fichas apuntan al mismo producto. Arreglar la lista de '
                    '12.1 antes de seguir. No se toco nada.';
  end if;

  update public._map_producto p
     set menu_item_id = mm.menu_item_id,
         como = 'mano'
    from public._mapeo_manual mm
   where p.codigo = mm.codigo
     and mm.estado = 'lista'
     and p.menu_item_id is distinct from mm.menu_item_id;

  get diagnostics v_n = row_count;
  raise notice '12.2 — fichas mapeadas a mano: %. Ahora correr '
               'PENDA_OP_9B_crear_recetas.sql', v_n;
end
$$;


-- ═══ 12.3 · DESHACER ═════════════════════════════════════════════════════════
/*
-- borra las recetas que salieron de este mapeo y devuelve el mapeo a null
delete from public.recipe_ingredients ri
 using public.recipes r, public._mapeo_manual mm
 where ri.recipe_id = r.id and r.menu_item_id = mm.menu_item_id
   and r.instructions like '%cargada automaticamente%';
delete from public.recipes r
 using public._mapeo_manual mm
 where r.menu_item_id = mm.menu_item_id
   and r.instructions like '%cargada automaticamente%';
update public._map_producto p set menu_item_id = null, como = 'auto'
  from public._mapeo_manual mm where p.codigo = mm.codigo;
*/
