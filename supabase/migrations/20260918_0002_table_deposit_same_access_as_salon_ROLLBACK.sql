-- =============================================================================
-- ROLLBACK 20260918_0002 — El saldo de mesa se ve con el MISMO acceso que el
-- salón
-- =============================================================================
--
-- Vuelve al filtro de la 0007 (`user_has_business_access`). OJO: eso deja otra
-- vez a las cajeras vinculadas solo por `memberships` sin ver el saldo NI
-- poder cobrar contra él.
-- =============================================================================

begin;

drop policy if exists tda_select on public.table_deposit_accounts;
create policy tda_select on public.table_deposit_accounts
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists tdm_select on public.table_deposit_movements;
create policy tdm_select on public.table_deposit_movements
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

-- Las cuatro funciones de lectura siguen llamando a fn_table_deposit_can_view.
-- En vez de reescribirlas, se neutraliza el helper con el criterio viejo.
create or replace function public.fn_table_deposit_can_view(
  p_business_id uuid
) returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select public.user_has_business_access(auth.uid(), p_business_id);
$$;

comment on function public.fn_table_deposit_can_view(uuid) is
  'ROLLBACK 20260918_0002: criterio de la 0007 (user_has_business_access, '
  'sin memberships).';

commit;
