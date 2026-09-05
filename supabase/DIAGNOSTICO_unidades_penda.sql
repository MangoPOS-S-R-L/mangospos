-- =============================================================================
-- LA PENDA EXPRESS — el estado real de las unidades, en vivo
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Es el diagnóstico previo al trabajo de porcionado: qué unidades hay, cuántos
-- insumos declaran su empaque, y cuáles esconden un bulto detrás de la palabra
-- «unidad».
-- =============================================================================

-- ── 1. CENSO — cuántos insumos por unidad y cuánto valen ───────────────────
select
  coalesce(nullif(btrim(i.unit), ''), '(vacía)')  as unidad,
  count(*)                                        as insumos,
  round(100.0 * count(*) / sum(count(*)) over (), 1) as porcentaje,
  round(sum(coalesce((select sum(s.quantity) from public.inventory_stock s
                       where s.item_id = i.id), 0)
            * coalesce(i.cost, 0)), 2)            as valor
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
group by 1
order by count(*) desc;


-- ── 2. CUÁNTOS DECLARAN SU EMPAQUE ─────────────────────────────────────────
select
  count(*)                                                as activos,
  count(*) filter (where i.purchase_unit is not null)     as con_unidad_compra,
  count(*) filter (where i.purchase_unit is not null
                     and coalesce(i.pack_size, 1) > 1)    as bien_declarados,
  count(*) filter (where i.purchase_unit is not null
                     and coalesce(i.pack_size, 1) <= 1)   as a_medias
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true);


-- ── 3. EMPAQUE A MEDIAS — dicen la unidad de compra pero no el contenido ───
--     Sin `pack_size` el campo no sirve para nada: la app no puede convertir.
select i.id, i.name, i.unit, i.purchase_unit, i.pack_size,
       round(coalesce(i.cost,0),2) as costo,
       coalesce((select sum(s.quantity) from public.inventory_stock s
                  where s.item_id = i.id), 0) as existencia
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and i.purchase_unit is not null
  and coalesce(i.pack_size, 1) <= 1
order by i.name;


-- ── 4. EL BULTO ESCONDIDO — el nombre lleva el empaque adentro ─────────────
--     CORREGIDO: la versión anterior buscaba «lata» suelta y esa palabra vive
--     dentro de p-LATA-no, p-LATA-nitos, servi-LLATA-s y choco-LATA, así que
--     traía 95 filas de ruido. Ahora la palabra tiene que estar SOLA (\m…\M),
--     y las latas de bebida quedan fuera a propósito: una lata de cerveza SÍ
--     es una unidad, y ahí «unidad» está bien.
--
--     Lo que queda son los de verdad: el nombre dice saco, caja, funda, galón
--     o paquete porque el campo que debía decirlo está vacío.
select
  i.id, i.name                                    as articulo,
  i.unit                                          as unidad_actual,
  round(coalesce(i.cost, 0), 2)                   as costo_unitario,
  coalesce((select sum(s.quantity) from public.inventory_stock s
             where s.item_id = i.id), 0)          as existencia,
  round(coalesce((select sum(s.quantity) from public.inventory_stock s
                   where s.item_id = i.id), 0)
        * coalesce(i.cost, 0), 2)                 as valor,
  (select count(*) from public.recipe_ingredients ri
    where ri.inventory_item_id = i.id)            as en_recetas
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and i.purchase_unit is null
  and i.name ~* '\m(saco|sacos|caja|cajas|funda|fundas|gal[oó]n|galones|paquete|paquetes|bolsa|bolsas|cart[oó]n|pote|potecito|barril|bulto|docena)\M'
order by coalesce((select sum(s.quantity) from public.inventory_stock s
                    where s.item_id = i.id), 0) * coalesce(i.cost, 0) desc;


-- ── 4b. LIBRAS DISFRAZADAS DE LITROS ──────────────────────────────────────
--     El selector de unidades del formulario NO tiene libra
--     (`baseUnitOptions` = unidad · ml · L · oz · g · kg). Quien necesita
--     libras ve la «L» y la escoge. Por eso hay pastrami, salami, pepperoni
--     y queso en «litros».
--
--     Son 52 insumos por RD$1.75 millones — el segundo bucket de valor del
--     catálogo entero. Esta consulta los saca todos para separar a mano los
--     que sí son líquidos de los que son peso.
select
  i.id, i.name                                    as articulo,
  round(coalesce(i.cost, 0), 2)                   as costo_por_L,
  coalesce((select sum(s.quantity) from public.inventory_stock s
             where s.item_id = i.id), 0)          as existencia,
  round(coalesce((select sum(s.quantity) from public.inventory_stock s
                   where s.item_id = i.id), 0)
        * coalesce(i.cost, 0), 2)                 as valor,
  case when i.name ~* '\m(aceite|vinagre|jugo|leche|agua|salsa|sirope|jarabe|crema|refresco|vino|ron|whisky|cerveza|licor|almibar|caldo)\M'
       then 'parece líquido'
       else 'REVISAR — ¿es libra?' end            as pista
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and lower(btrim(i.unit)) in ('l', 'lt', 'litro', 'litros')
order by 5 desc;


-- ── 5. LO QUE SE AGREGÓ AL CONTEO DE COCINA ────────────────────────────────
--     CORREGIDO: antes salía cada insumo cinco veces. El filtro de sesión
--     estaba en el join de `sessions`, así que las líneas de las OTRAS cuatro
--     sesiones pasaban igual. Ahora la sesión se resuelve en un subselect y
--     cada insumo sale UNA vez.
select
  i.id, i.name, i.unit, i.purchase_unit, i.pack_size,
  round(coalesce(i.cost, 0), 2) as costo,
  (select l.counted_quantity
     from public.physical_count_lines l
     join public.physical_count_sessions s on s.id = l.session_id
    where l.item_id = i.id
      and s.code = 'PC-2026-000003')             as contado_en_cocina,
  (select count(*)
     from public.physical_count_lines l
     join public.physical_count_sessions s on s.id = l.session_id
    where l.item_id = i.id
      and s.business_id = i.business_id
      and l.counted_quantity is not null)        as areas_que_lo_contaron,
  (i.created_at at time zone 'America/Santo_Domingo') as creado
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and i.created_at >= '2026-09-01'
order by i.created_at desc, i.name;
