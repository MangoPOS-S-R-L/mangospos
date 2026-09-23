-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 14: rescatar lo rescatable
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Sale del reporte del PASO 13. Tres cosas, en este orden:
--   14.1  destrabar dos unidades que frenaban 4 fichas
--   14.2  REACTIVAR 5 productos que existen pero están desactivados
--   14.3  mapear a mano las que verifiqué que son el mismo plato
-- Después: correr `PENDA_OP_9B_crear_recetas.sql`.
--
-- OJO: 14.1 necesita que ANTES se vuelva a correr `PENDA_PASO6_recetario.sql`,
-- porque ahí viven las funciones de conversión y les agregué el «shot».
--
-- LO QUE NO ENTRA, Y POR QUÉ — el grupo 1 del PASO 13 está lleno de falsos
-- positivos. `WRAP DE POLLO` sale sugerido para CINCO fichas distintas:
--   DEDITOS DE POLLO · QUIPE DE POLLO · WRAP DE PAVO · WRAP POLLO BBQ ·
--   WRAP POLLO CESAR    → un producto solo admite una receta, y ninguna de las
--                          cinco es «wrap de pollo» a secas
-- Otras que descarté:
--   DESAYUNO AMERICANO   → CAFE AMERICANO        no tienen nada que ver
--   JUGO DE TAMARINDO    → PALETA DE TAMARINDO   es una paleta helada
--   MOFONGO DE POLLO     → DE TODITO MOFONGO     otro plato
--   CAPUCCINO            → CARAMEL CAPUCCINO     otra bebida
--   LIMONADA FROZEN      → LIMONADA              son dos productos distintos
--   JUGO DE CEREZA       → CEREZA                «CEREZA» sola no es el jugo
--   EMPANADAS DE CATIBIA → CATIBIA QUESO SERVICIO 3   dudoso
--
-- DOS QUE DEJO PARA QUE DECIDAS TÚ, porque no se pueden adivinar:
--   TABLA PARA 2 PERSONAS (135 líneas vendidas) la piden CUATRO fichas:
--     TABLA DE FIAMBRES 2 y 4 · TABLA PENDA 2 y 4. Y solo hay UN producto para
--     dos tamaños. Hay que decidir qué ficha le toca, o crear el de 4 personas.
--   CARNE SALADA: el producto de 660 líneas tiene vínculo directo, y el único
--     usable es «CARNE SALADA SIN GUARNICIÓN», de 7 líneas. Ponerle la receta
--     del plato principal a la variante chica es engañoso.
--
-- IDEMPOTENTE: sí. REVERSIBLE: sí (14.4).
-- =============================================================================

-- ═══ 14.1 · DESTRABAR DOS UNIDADES ═══════════════════════════════════════════
--   (a) «shot»: ya quedó resuelto en las funciones del PASO 6 (1 shot = 36 ml,
--       tomado del propio recetario). Solo hay que haber recorrido el PASO 6.
--   (b) «Pulpa de chinola»: la ficha del TÉ la pide en ml y el insumo está en g.
--       Para una pulpa 1 g ≈ 1 ml, así que se llena la equivalencia propia.
do $$
declare v_biz uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'; v_n int;
begin
  if public._penda_unidad('shot') is null then
    raise exception 'El conversor no conoce «shot». Volver a correr '
                    'PENDA_PASO6_recetario.sql (ahi viven las funciones). '
                    'No se toco nada.';
  end if;

  update public.inventory_items
     set conversion_unit = 'ml', conversion_factor = 1
   where business_id = v_biz
     and name = 'COCINA · Pulpa de chinola'
     and unit = 'g'
     and conversion_factor is null;
  get diagnostics v_n = row_count;
  raise notice '14.1 — equivalencia puesta a Pulpa de chinola: % (1 g = 1 ml)', v_n;
end
$$;


-- ═══ 14.2 · REACTIVAR LOS 5 QUE ESTÁN DESACTIVADOS ═══════════════════════════
--   Existen en el catálogo, nunca se vendieron y están apagados. Reactivarlos
--   los devuelve al menú: si no los quieres visibles todavía, saltate esta
--   sección y esas 5 fichas no se cargan.
do $$
declare v_biz uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'; v_n int;
begin
  update public.menu_items
     set is_active = true
   where business_id = v_biz
     and coalesce(is_active,true) = false
     and public._norm(name) in (
       public._norm('CROISSANT DE QUESO PEQUEÑO'),
       public._norm('CROISSANT DE JAMON Y QUESO'),
       public._norm('CROISSANTS NUTELLA'),
       public._norm('SANDWICH CUBANO'),
       public._norm('MOKACCINO SD'));
  get diagnostics v_n = row_count;
  raise notice '14.2 — productos reactivados: % (de 5)', v_n;
end
$$;


-- ═══ 14.3 · EL MAPEO ═════════════════════════════════════════════════════════
drop table if exists public._mapeo_14;
create table public._mapeo_14 (
  codigo       text primary key,
  ficha        text,
  producto_pos text,
  por_que      text,
  menu_item_id uuid,
  estado       text
);

insert into public._mapeo_14 (codigo, ficha, producto_pos, por_que) values
  -- los 5 que estaban desactivados
  ('PE-DES-007','CROISSANT DE QUESO',         'CROISSANT DE QUESO PEQUEÑO',        'estaba desactivado'),
  ('PE-DES-008','CROISSANT DE JAMON Y QUESO', 'CROISSANT DE JAMON Y QUESO',        'estaba desactivado · 1.00'),
  ('PE-DES-009','CROISSANT DE NUTELLA',       'CROISSANTS NUTELLA',                'estaba desactivado'),
  ('PE-EWB-041','SANDWICH CUBANO',            'SANDWICH CUBANO',                   'estaba desactivado · 1.00'),
  ('PE-CAF-112','MOCACCINO',                  'MOKACCINO SD',                      'estaba desactivado · MOKA/MOCA'),
  -- existen activos y casan bien
  ('PE-CAF-107','CARAMEL MACCHIATO',          'CARAMEL MACCHIATO',                 '1.00 · destrabada por el shot'),
  ('PE-CAF-113','MARSHMELLO',                 'MARSHMELLO',                        '1.00 · destrabada por el shot'),
  ('PE-CAF-121','CHOCOLATE CALIENTE LA PENDA','CHOCOLATE CALIENTE LA PENDA',       '1.00 · 294 líneas · shot'),
  ('PE-CAF-132','TE DE CHINOLA',              'TE DE CHINOLA',                     '1.00 · destrabada por la pulpa'),
  ('PE-EWB-052','MADURO BACON BURGER',        'MADURO BACON BURGUER',              'el POS lo escribe BURGUER'),
  ('PE-PIZ-027','PIZZA MARGARITA',            'PIZZA MARGARITA MEDIANA',           'misma pizza, dice el tamaño'),
  ('PE-PIZ-028','PIZZA PEPPERONI',            'PIZZA ITALIANA PEPPERONI PERSONAL', 'misma pizza, dice el tamaño'),
  ('PE-GUA-102','AGUACATE',                   'SERVICIO DE AGUACATE',              'la ficha es GUARNICIONES · 71 líneas');

update public._mapeo_14 mm
   set menu_item_id = m.id,
       estado = case
         when m.inventory_item_id is not null            then 'RECHAZADA · vínculo directo'
         when not coalesce(m.is_active,true)             then 'RECHAZADA · sigue desactivado'
         when exists (select 1 from public.recipes r where r.menu_item_id = m.id)
                                                        then 'ya tiene receta'
         else 'lista' end
  from public.menu_items m
 where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and public._norm(m.name) = public._norm(mm.producto_pos);

update public._mapeo_14 set estado = 'RECHAZADA · no está en el catálogo'
 where menu_item_id is null;

select estado, count(*) as fichas,
       string_agg(codigo || ' ' || ficha || '  →  ' || producto_pos ||
                  '   [' || por_que || ']', E'\n' order by codigo) as detalle
from public._mapeo_14 group by estado order by estado;

do $$
declare v_n int := 0;
begin
  if exists (select 1 from public._mapeo_14 where estado = 'lista'
              group by menu_item_id having count(*) > 1) then
    raise exception 'Dos fichas apuntan al mismo producto. No se toco nada.';
  end if;

  update public._map_producto p
     set menu_item_id = mm.menu_item_id, como = 'mano'
    from public._mapeo_14 mm
   where p.codigo = mm.codigo and mm.estado = 'lista'
     and p.menu_item_id is distinct from mm.menu_item_id;
  get diagnostics v_n = row_count;
  raise notice '14.3 — fichas mapeadas: %. Ahora correr PENDA_OP_9B_crear_recetas.sql', v_n;
end
$$;


-- ═══ 14.4 · DESHACER ═════════════════════════════════════════════════════════
/*
delete from public.recipe_ingredients ri using public.recipes r, public._mapeo_14 mm
 where ri.recipe_id = r.id and r.menu_item_id = mm.menu_item_id
   and r.instructions like '%cargada automaticamente%';
delete from public.recipes r using public._mapeo_14 mm
 where r.menu_item_id = mm.menu_item_id and r.instructions like '%cargada automaticamente%';
update public._map_producto p set menu_item_id = null, como = 'auto'
  from public._mapeo_14 mm where p.codigo = mm.codigo;
-- y volver a desactivar los 5
update public.menu_items set is_active = false
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and public._norm(name) in (public._norm('CROISSANT DE QUESO PEQUEÑO'),
       public._norm('CROISSANT DE JAMON Y QUESO'), public._norm('CROISSANTS NUTELLA'),
       public._norm('SANDWICH CUBANO'), public._norm('MOKACCINO SD'));
*/
