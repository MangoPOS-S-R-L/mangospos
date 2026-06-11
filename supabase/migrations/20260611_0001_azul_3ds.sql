-- =============================================================================
-- PRD-Azul-3DSecure §8 — Estado del flujo 3D Secure 2.0 en azul_payment_sessions.
--
-- ALCANCE (Fase 3DS.1):
--   1. auth_hash_sent pasa a NULLABLE: el camino API-directa / 3DS no usa
--      AuthHash (era exclusivo de la Payment Page v1). Las sesiones 3DS se
--      crean sin él.
--   2. Columnas threeds_* + browser_info/cardholder_info (jsonb) + timestamps
--      de los callbacks del ACS.
--   3. Nuevo estado 'authenticating' en azul_payment_sessions.status (mientras
--      corre el handshake 3DS, entre 'pending' y 'approved'/'declined').
--   4. Nuevos event_type en azul_webhook_events para los POST del ACS.
--
-- STRANGLER FIG: solo toca tablas azul_ propias. ADD COLUMN IF NOT EXISTS.
-- ROLLBACK: 20260611_0001_azul_3ds_ROLLBACK.sql
-- =============================================================================

begin;

-- 1. auth_hash_sent ya no es obligatorio (v2 API-directa / 3DS).
alter table public.azul_payment_sessions
  alter column auth_hash_sent drop not null;

-- 2. Columnas de estado 3DS.
alter table public.azul_payment_sessions
  add column if not exists threeds_flow text
    check (threeds_flow in ('none', 'frictionless', 'challenge')),
  add column if not exists threeds_server_trans_id text,
  add column if not exists threeds_method_status text
    check (threeds_method_status in ('RECEIVED', 'EXPECTED_BUT_NOT_RECEIVED', 'NOT_EXPECTED')),
  add column if not exists threeds_auth_status text,
  add column if not exists threeds_eci text,
  add column if not exists browser_info jsonb,
  add column if not exists cardholder_info jsonb,
  add column if not exists method_notification_received_at timestamptz,
  add column if not exists cres_received_at timestamptz,
  add column if not exists challenge_started_at timestamptz;

comment on column public.azul_payment_sessions.threeds_flow is
  'Camino 3DS resuelto: none (aún no), frictionless (sin desafío), '
  'challenge (el emisor pidió desafío). Ver PRD-Azul-3DSecure §6.';
comment on column public.azul_payment_sessions.browser_info is
  'BrowserInfo capturado del navegador (sin PAN). Para análisis de riesgo/forense.';
comment on column public.azul_payment_sessions.cardholder_info is
  'CardHolderInfo enviado (Name/Email/dirección, SIN datos de tarjeta).';

-- 3. Estado 'authenticating'. El check inline original se llama
--    azul_payment_sessions_status_check (convención PG: tabla_columna_check).
alter table public.azul_payment_sessions
  drop constraint if exists azul_payment_sessions_status_check;
alter table public.azul_payment_sessions
  add constraint azul_payment_sessions_status_check
  check (status in (
    'pending', 'redirected', 'authenticating', 'approved', 'declined',
    'cancelled', 'tampered', 'timeout', 'error'
  ));

-- 4. event_type del ACS (callbacks 3DS).
alter table public.azul_webhook_events
  drop constraint if exists azul_webhook_events_event_type_check;
alter table public.azul_webhook_events
  add constraint azul_webhook_events_event_type_check
  check (event_type in (
    'payment_page_callback', 'ipn_notification', 'webservice_response',
    'threeds_method_notification', 'threeds_term_callback'
  ));

commit;
