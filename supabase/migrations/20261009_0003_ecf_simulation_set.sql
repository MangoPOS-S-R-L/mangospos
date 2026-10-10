-- =============================================================================
-- 20261009_0003 — Set de pruebas DGII: simulación e-CF
-- =============================================================================
--
-- Paso 4 de la certificación ("Pruebas de simulación e-CF"): ya no hay Excel.
-- `ecf-onboarding` arma los e-CF a partir del set de datos que la DGII aceptó
-- (kind = ecf), con los datos reales del emisor, fecha de hoy y e-NCF nuevos,
-- y los manda como el set de datos. Cada e-CF necesita su representación
-- impresa (paso 5), que el panel genera de esos mismos datos.
--
-- La DGII da del 1 al 10,000,000 por tipo y NO deja reusar números entre
-- intentos. `simulation_sequences` guarda el último número usado por tipo
-- ({"31": 16, "32": 21, ...}) para que volver a generar nunca repita uno,
-- aunque se borren los casos.
--
-- Depende de 20261009_0002.
-- =============================================================================

begin;

alter table public.ecf_test_set_cases
  drop constraint if exists ecf_test_set_cases_kind_check,
  add constraint ecf_test_set_cases_kind_check check (kind in ('ecf', 'acecf', 'sim'));

comment on column public.ecf_test_set_cases.kind is
  'ecf = pruebas de datos e-CF (+ RFCE); acecf = aprobación comercial; sim = simulación e-CF.';

alter table public.ecf_onboarding
  add column if not exists simulation_set_generated_at timestamptz,
  add column if not exists simulation_sequences        jsonb not null default '{}'::jsonb;

alter table public.ecf_onboarding
  drop constraint if exists ecf_onboarding_simulation_sequences_is_object,
  add constraint ecf_onboarding_simulation_sequences_is_object
    check (jsonb_typeof(simulation_sequences) = 'object');

comment on column public.ecf_onboarding.simulation_sequences is
  'Último e-NCF usado por tipo en la simulación ({"31": 16, ...}). No baja nunca: la DGII no deja reusar números.';

commit;
