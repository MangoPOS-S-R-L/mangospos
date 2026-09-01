-- =============================================================================
-- Lo que falta para cerrar F1: la vista de stock del menú y el auto-86.
--
-- Las dos SUMAN todas las bodegas. Hoy da igual (hay una sola), pero el día
-- que la bandera se prenda, un plato de Cocina se va a ver disponible
-- teniendo la mercancía sólo en la principal — y al revés, se va a apagar
-- solo teniendo existencia en su propia área.
--
-- Una consulta, línea por línea, para escribir la 20260901_0004 sobre lo que
-- de verdad hay en producción y no sobre lo que dice el repositorio.
-- =============================================================================

select 'v_menu_items_stock' as objeto,
       row_number() over () as n,
       linea
  from unnest(string_to_array(
         pg_get_viewdef('public.v_menu_items_stock'::regclass, true), E'\n'
       )) as linea

union all

select 'fn_recompute_menu_items_availability',
       row_number() over (),
       linea
  from unnest(string_to_array(
         (select pg_get_functiondef(p.oid)
            from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public'
             and p.proname = 'fn_recompute_menu_items_availability'
           limit 1),
         E'\n'
       )) as linea;
