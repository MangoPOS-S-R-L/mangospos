-- =============================================================================
-- 20260917_0003 — ecf_onboarding: avance de la certificación ante la DGII
-- =============================================================================
--
-- Fase 2 del alta e-CF desde el panel. Para un cliente que todavía no está
-- autorizado como emisor electrónico, el operador:
--   1. llena la postulación en la OFV con los datos del proveedor (Alanube),
--   2. firma el XML de postulación que da la DGII,
--   3. corre el set de pruebas (set_test_id ya existe desde 0002),
--   4. firma la declaración jurada,
--   5. el representante asigna roles (el XML de roles se firma si lo piden),
--   6. la DGII lo autoriza.
--
-- Estas columnas solo registran CUÁNDO se hizo cada paso en el panel. La
-- verdad la tiene la OFV: firmar un XML no significa que se haya subido.
--
-- `dgii_authorized_at` lo marca el operador a mano cuando la DGII aprueba (o
-- cuando el cliente ya llegaba autorizado). No habilita la emisión: eso sigue
-- siendo `business_alanube_settings` vía provision-ecf.
--
-- Depende de 20260917_0002_ecf_onboarding.sql.
-- =============================================================================

begin;

alter table public.ecf_onboarding
  add column if not exists postulation_signed_at timestamptz,
  add column if not exists set_test_created_at   timestamptz,
  add column if not exists declaration_signed_at timestamptz,
  add column if not exists roles_signed_at       timestamptz,
  add column if not exists dgii_authorized_at    timestamptz;

comment on column public.ecf_onboarding.postulation_signed_at is
  'Última firma del XML de postulación desde el panel.';
comment on column public.ecf_onboarding.set_test_created_at is
  'Cuándo se generó el set de pruebas vigente (set_test_id).';
comment on column public.ecf_onboarding.declaration_signed_at is
  'Última firma de la declaración jurada desde el panel.';
comment on column public.ecf_onboarding.roles_signed_at is
  'Última firma del XML de asignación de roles (opcional).';
comment on column public.ecf_onboarding.dgii_authorized_at is
  'Marcado por el operador: la DGII autorizó al contribuyente como emisor '
  'electrónico. Informativo; no habilita la emisión.';

commit;
