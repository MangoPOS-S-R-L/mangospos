-- ROLLBACK de 20260902_0004_conteo_sincronizar_lineas.sql
--
-- Quita la función. Las líneas que ya haya agregado NO se tocan: son parte
-- del conteo y borrarlas perdería lo contado en ellas.

begin;

drop function if exists public.fn_physical_count_sync_lines(uuid);

commit;
