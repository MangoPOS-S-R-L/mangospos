-- =============================================================================
-- 20260917_0006 — ecf_onboarding: solicitud del cliente desde la POS
-- =============================================================================
--
-- El dueño de un negocio pide la facturación electrónica desde la POS
-- (Ajustes → Comprobantes fiscales → "Solicitar"). Manda sus datos de la DGII,
-- un contacto y su certificado; la empresa se registra en Alanube en esa misma
-- petición y el certificado no se guarda (igual que en el panel).
--
-- Estas columnas registran la solicitud para que MangoPOS la vea en el panel
-- y dé seguimiento. El avance (empresa, certificación, secuencias, activación)
-- se sigue derivando de lo que ya existe; no hay un estado paralelo.
--
-- Depende de 20260917_0002 y 0003.
-- =============================================================================

begin;

alter table public.ecf_onboarding
  add column if not exists requested_at       timestamptz,
  add column if not exists requested_by       uuid references auth.users(id),
  add column if not exists contact_name       text,
  add column if not exists contact_phone      text,
  add column if not exists already_authorized boolean;

comment on column public.ecf_onboarding.requested_at is
  'Cuando el dueño pidió la facturación electrónica desde la POS. Null = la '
  'inició un operador desde el panel.';
comment on column public.ecf_onboarding.contact_name is
  'Persona con quien MangoPOS coordina la certificación (OFV, roles).';
comment on column public.ecf_onboarding.already_authorized is
  'Lo que declaró el cliente al pedirlo: si ya es emisor electrónico '
  'autorizado por la DGII. Informativo; lo confirma el operador.';

create index if not exists ecf_onboarding_requested_at_idx
  on public.ecf_onboarding (requested_at)
  where requested_at is not null;

commit;
