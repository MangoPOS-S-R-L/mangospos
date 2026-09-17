-- =============================================================================
-- ROLLBACK — 20260917_0002 — ecf_onboarding
-- =============================================================================
--
-- Borra solo lo capturado en el panel. No toca business_alanube_settings,
-- fiscal_settings ni ncf_sequences, ni la empresa creada en Alanube.
-- =============================================================================

begin;

drop table if exists public.ecf_onboarding;

commit;
