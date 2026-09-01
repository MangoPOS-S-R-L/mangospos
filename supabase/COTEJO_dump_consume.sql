-- =============================================================================
-- Definición VIVA de consume_inventory_from_order, línea por línea.
--
-- La huella dio divergencia con el repositorio (sin `v_main_warehouse_id`,
-- 2 `union` en vez de 5, 6017 caracteres en vez de ~6649). Alguien la
-- cambió directo en la base y ese cambio no está en ninguna migración.
--
-- Hasta tener esto NO se puede aplicar 20260901_0003_consume_by_area:
-- `create or replace` la reemplaza entera y se perdería lo que hoy corre.
-- =============================================================================

select row_number() over () as n, linea
  from unnest(
    string_to_array(
      pg_get_functiondef(
        'public.consume_inventory_from_order(uuid)'::regprocedure),
      E'\n'
    )
  ) as linea;
