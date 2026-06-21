-- =============================================================================
-- Garantiza las columnas fiscales por sub-cuenta en order_checks.
--
-- Contexto: el comprobante por sub-cuenta (cuenta dividida con 2 Crédito Fiscal
-- + 1 Consumidor Final, p. ej.) requiere persistir POR CHECK el tipo de NCF y
-- el RNC del cliente. La migración 20260511_0003 ya las agrega, pero en la BD
-- viva (que diverge del repo) podrían no estar. Esta migración es idempotente
-- (`add column if not exists`) y segura de aplicar exista o no la 0003.
--
-- El bundle (`fn_get_order_bundle`) ya devuelve estas columnas porque serializa
-- la fila completa con `to_jsonb(oc)`. Al cobrar, el cliente pasa el tipo y el
-- RNC resueltos por sub-cuenta de forma EXPLÍCITA a fn_process_payment_v3
-- (param > check > default), así que la emisión no depende del coalesce.
-- =============================================================================

begin;

-- customer_id: cliente asignado a la sub-cuenta (hereda al payment).
alter table public.order_checks
  add column if not exists customer_id uuid
    references public.customers(id) on delete set null;

-- customer_rnc: RNC del cliente para esta sub-cuenta (Crédito Fiscal por check).
alter table public.order_checks
  add column if not exists customer_rnc text;

-- requested_ncf_type: tipo de comprobante para esta sub-cuenta (B01/B02/...).
-- Usa el enum public.ncf_type cuando existe; si no, queda como texto libre.
do $$
begin
  if exists (select 1 from pg_type where typname = 'ncf_type') then
    execute 'alter table public.order_checks
      add column if not exists requested_ncf_type public.ncf_type';
  else
    execute 'alter table public.order_checks
      add column if not exists requested_ncf_type text';
  end if;
end $$;

comment on column public.order_checks.customer_rnc is
  'RNC del cliente para esta sub-cuenta. Hereda al payment al cobrar el check. '
  'Lo persiste la UI (assignCustomerToCheck / fn_set_check_customer_and_ncf).';

comment on column public.order_checks.requested_ncf_type is
  'Tipo de comprobante para esta sub-cuenta (B01/B02/E31...). NULL = default '
  'del business. Lo persiste la UI y se hereda/pasa al cobrar el check.';

commit;
