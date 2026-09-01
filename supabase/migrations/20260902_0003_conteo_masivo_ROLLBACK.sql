-- ROLLBACK de 20260902_0003_conteo_masivo.sql
--
-- Devuelve el statement_timeout de las funciones del conteo al del rol.
-- OJO: con eso vuelve el riesgo de que un conteo grande no se pueda cerrar.
--
-- El resolvedor NO se revierte a la versión con la doble llamada: era un
-- error, no una decisión. Si hace falta volver atrás de verdad, revertir
-- 20260901_0006 completa.

begin;

drop function if exists public.fn_physical_count_zero_pending(uuid);

alter function public.fn_physical_count_freeze(uuid) reset statement_timeout;
alter function public.fn_physical_count_complete(uuid) reset statement_timeout;

commit;
