-- =============================================================================
-- HUELLA de consume_inventory_from_order — para saber si la función viva es
-- la del repositorio SIN tener que pegar 180 líneas.
--
-- Si todos los marcadores salen en `true` y el largo está cerca de 6,000
-- caracteres, la viva es la de 20260613_0001 y la 0003 se puede aplicar.
-- Si alguno sale en `false`, o aparecen marcadores EXTRA, hay divergencia y
-- ahí sí hace falta la definición completa.
-- =============================================================================

with d as (
  select pg_get_functiondef(
    'public.consume_inventory_from_order(uuid)'::regprocedure) as src
)
select
  length(src)                                              as largo,
  md5(src)                                                 as huella,
  (select count(*) from regexp_matches(src, 'union', 'gi')) as veces_union,

  -- Marcadores que DEBE tener la versión del repo (20260613_0001).
  src like '%v_main_warehouse_id%'          as tiene_bodega_unica,
  src like '%is_inventory_tracked%'         as tiene_gate_tracked,
  src like '%order_item_modifiers%'         as tiene_ruta_combos,
  src like '%mi.inventory_item_id%'         as tiene_terminado_directo,
  src like '%inventory_mode%'               as tiene_gate_modo,
  src like '%Devolución por cancelación%'   as tiene_nota_devolucion,
  src like '%reference_type%'               as tiene_referencia,

  -- Marcadores que NO debería tener: si alguno sale true, la base tiene
  -- cambios que el repositorio no conoce y hay que traerlos a la 0003.
  src like '%lot%'                          as OJO_menciona_lotes,
  src like '%allow_negative%'               as OJO_menciona_negativos,
  src like '%warehouse_type%'               as OJO_ya_menciona_secciones,
  src like '%production_area%'              as OJO_ya_menciona_areas,
  src like '%excluded%'                     as OJO_menciona_excluidos
from d;
