-- Rollback de 20260907_0007. Ambas funciones son NUEVAS y aditivas: nada más
-- en la BD depende de ellas, así que basta con soltarlas. La app vuelve sola al
-- camino por ventana de tiempo (su fallback ya lo contempla) y el ticket de
-- cierre sigue imprimiendo — con el desglose por área mezclando las cajas otra
-- vez, que es el bug que 20260907_0007 vino a arreglar.

begin;

drop function if exists public.get_sales_by_production_area_for_session(uuid);
drop function if exists public.get_products_by_production_area_for_session(uuid);

commit;
