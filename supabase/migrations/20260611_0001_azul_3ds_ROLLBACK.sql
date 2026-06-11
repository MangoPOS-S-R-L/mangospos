-- ROLLBACK de 20260611_0001_azul_3ds.sql
--
-- NOTA: NO se re-impone NOT NULL en auth_hash_sent. Si ya existen sesiones 3DS
-- (creadas sin AuthHash), tendrían auth_hash_sent NULL y el ALTER fallaría.
-- Dejar nullable es seguro y no rompe el camino Payment Page v1 (que sí lo
-- llena). Si se requiere revertir del todo, primero limpiar/backfillear esas
-- filas y luego `alter column auth_hash_sent set not null` manualmente.

begin;

alter table public.azul_payment_sessions
  drop column if exists threeds_flow,
  drop column if exists threeds_server_trans_id,
  drop column if exists threeds_method_status,
  drop column if exists threeds_auth_status,
  drop column if exists threeds_eci,
  drop column if exists browser_info,
  drop column if exists cardholder_info,
  drop column if exists method_notification_received_at,
  drop column if exists cres_received_at,
  drop column if exists challenge_started_at;

-- Restaurar el check de status sin 'authenticating'.
alter table public.azul_payment_sessions
  drop constraint if exists azul_payment_sessions_status_check;
alter table public.azul_payment_sessions
  add constraint azul_payment_sessions_status_check
  check (status in (
    'pending', 'redirected', 'approved', 'declined',
    'cancelled', 'tampered', 'timeout', 'error'
  ));

-- Restaurar el check de event_type original.
alter table public.azul_webhook_events
  drop constraint if exists azul_webhook_events_event_type_check;
alter table public.azul_webhook_events
  add constraint azul_webhook_events_event_type_check
  check (event_type in (
    'payment_page_callback', 'ipn_notification', 'webservice_response'
  ));

commit;
