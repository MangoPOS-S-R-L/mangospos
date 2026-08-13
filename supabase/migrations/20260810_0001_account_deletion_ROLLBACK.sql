-- =============================================================================
-- ROLLBACK 20260810_0001 — Eliminación de cuenta iniciada por el usuario
--
-- OJO: quitar las funciones NO revierte las bajas ya procesadas. Si hay
-- solicitudes en `pending` dentro de la ventana de gracia, restaurarlas ANTES
-- de correr esto, usando los snapshots:
--
--   select memberships_snapshot, employees_snapshot, profile_snapshot
--     from public.account_deletion_requests
--    where status = 'pending';
--
-- La tabla NO se borra por defecto: es la única evidencia de qué se dio de baja.
-- Descomentar el drop solo si estás seguro de no necesitar esa bitácora.
-- =============================================================================

begin;

drop function if exists public.fn_purge_expired_account_deletions();
drop function if exists public.fn_request_account_deletion(text);

-- drop table if exists public.account_deletion_requests;

commit;
