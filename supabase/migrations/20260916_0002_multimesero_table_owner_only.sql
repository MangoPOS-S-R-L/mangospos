-- =============================================================================
-- 20260916_0002 — business_settings.multimesero_table_owner_only
-- =============================================================================
--
-- Sub-opción del modo multimesero ("Cada mesero es dueño de su mesa"). Con
-- el modo normal, cualquier mesero entra a cualquier mesa identificándose con
-- su PIN. Con esta opción, una mesa abierta solo la abre el mesero que la
-- abrió por primera vez (`table_sessions.opened_by_employee_id`); los demás
-- necesitan el PIN de un supervisor. Dueño/admin/supervisor/cajero entran a
-- todas.
--
-- Solo tiene efecto con `multimesero_enabled = true`. La regla vive en la app
-- (core/multimesero/table_ownership.dart), igual que el gate de PIN.
--
-- Default `false`: nadie cambia de comportamiento sin opt-in.
--
-- Safe deploy: Flutter cae a `false` si la columna aún no existe, y el
-- guardado de banderas la descarta sin romper las demás.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists multimesero_table_owner_only boolean
    not null default false;

comment on column public.business_settings.multimesero_table_owner_only is
  'Multimesero: si true, una mesa abierta solo la puede abrir el mesero que '
  'la abrió (opened_by_employee_id). Otros meseros requieren PIN de '
  'supervisor. Default false.';

commit;
