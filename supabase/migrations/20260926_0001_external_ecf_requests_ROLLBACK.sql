-- ROLLBACK de 20260926_0001_external_ecf_requests.sql
--
-- OJO: se BORRAN las solicitudes de facturación electrónica que llegaron de
-- otras apps y el seguimiento que se les haya hecho (estado, notas, quién la
-- tomó). Eso no se recupera desde la app de origen: allá solo queda su propia
-- solicitud, no lo que se anotó acá.
--
-- Antes de revertir, exporta la tabla si hay solicitudes sin atender:
--   copy (select * from public.external_ecf_requests) to stdout with csv header;

begin;

drop policy if exists "external_ecf_requests_operator_write" on public.external_ecf_requests;
drop policy if exists "external_ecf_requests_operator_read" on public.external_ecf_requests;
drop index if exists public.external_ecf_requests_status_idx;
drop table if exists public.external_ecf_requests;

commit;

notify pgrst, 'reload schema';
