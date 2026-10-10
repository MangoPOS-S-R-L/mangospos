-- =============================================================================
-- 20261008_0001 — ecf_onboarding: requisitos completos de la solicitud
-- =============================================================================
--
-- El formulario de la POS ahora pide todo lo que hace falta para el alta e-CF:
--   - teléfono de la empresa y nombre del representante legal,
--   - direcciones de las sucursales (si tiene),
--   - tipos de comprobantes electrónicos que usa,
--   - usuario y clave de la Oficina Virtual (OFV) de la DGII.
--
-- La clave de la OFV SÍ se guarda (el operador la necesita para la postulación
-- y las pruebas), pero solo CIFRADA: la Edge Function `ecf-onboarding` la cifra
-- con AES-256-GCM y la llave `ECF_CREDENTIALS_KEY`, que vive en el entorno de
-- las funciones, no en la BD. El check impide guardar texto plano por error.
--
-- La tabla sigue con RLS encendido y sin policies: solo service_role.
--
-- Depende de 20260917_0002, 0003 y 0006.
-- =============================================================================

begin;

alter table public.ecf_onboarding
  add column if not exists phone                   text,
  add column if not exists legal_rep_name          text,
  add column if not exists branches                jsonb,
  add column if not exists ecf_types               text[],
  add column if not exists ofv_user                text,
  add column if not exists ofv_password_enc        text,
  add column if not exists ofv_password_updated_at timestamptz;

alter table public.ecf_onboarding
  drop constraint if exists ecf_onboarding_branches_is_array,
  add constraint ecf_onboarding_branches_is_array
    check (branches is null or jsonb_typeof(branches) = 'array'),
  drop constraint if exists ecf_onboarding_ofv_password_sealed,
  add constraint ecf_onboarding_ofv_password_sealed
    check (ofv_password_enc is null or ofv_password_enc like 'v1:%');

comment on column public.ecf_onboarding.phone is
  'Teléfono de la empresa (el de contacto con MangoPOS es contact_phone).';
comment on column public.ecf_onboarding.legal_rep_name is
  'Nombre completo del representante legal ante la DGII.';
comment on column public.ecf_onboarding.branches is
  'Sucursales que declaró el cliente: [{ "name": text|null, "address": text }].';
comment on column public.ecf_onboarding.ecf_types is
  'Tipos de e-CF que usa el negocio (E31, E32, E34...).';
comment on column public.ecf_onboarding.ofv_user is
  'Usuario de la Oficina Virtual de la DGII (casi siempre el RNC o la cédula).';
comment on column public.ecf_onboarding.ofv_password_enc is
  'Clave de la OFV cifrada por ecf-onboarding (AES-256-GCM, llave '
  'ECF_CREDENTIALS_KEY, business_id como dato autenticado). Formato v1:base64. '
  'Solo se descifra con la acción reveal_ofv_password, que queda auditada.';

commit;
