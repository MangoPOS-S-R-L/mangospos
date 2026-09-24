-- =============================================================================
-- Pincer — el crédito fiscal salía en el comprobante equivocado
--
-- Ver docs/PRD_INTEGRACION_PINCER.md §8. Corrige 20260907_0006.
--
-- EL DEFECTO
--   La ingesta pedia el tipo de comprobante a mano:
--
--       p_requested_ncf_type => case when v_rnc is not null then 'B01' else null end
--
--   'B01' es credito fiscal de PAPEL. Tropella emite el credito fiscal en E31
--   ELECTRONICO (verificado 2026-09-24: E31 aceptados por la DGII casi a diario)
--   y solo el consumo va en papel — `fiscal_settings.default_ncf_type = 'B02'`,
--   con el negocio en modo `hybrid`. O sea que el primer pedido de Pincer en
--   que el cliente pidiera comprobante fiscal habria salido en una serie
--   distinta a la que el negocio viene usando.
--
--   Sin RNC no habia problema: pasa NULL y manda el default del negocio.
--
-- LA REGLA
--   Preferir E31 si el negocio tiene secuencia electronica activa, vigente y
--   con numeros disponibles; si no, B01. Asi:
--     - negocio con e-CF (Tropella)      → E31, igual que sus ventas de mostrador
--     - negocio solo en papel            → B01
--     - negocio sin credito fiscal       → NULL, y el cobro usa su default en
--       vez de reventar por una secuencia que no existe
--
--   Es la misma eleccion que hace el cajero en la app cuando marca "credito
--   fiscal": tomar la serie que el negocio tiene viva.
--
-- RIESGO: bajo. Aditivo (una funcion nueva) + una linea de la ingesta. No toca
--   `fn_process_payment_v3` ni ninguna funcion fiscal.
-- =============================================================================

begin;

create or replace function public.fn_external_credit_ncf_type(p_business_id uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select s.ncf_type::text
    from public.ncf_sequences s
   where s.business_id = p_business_id
     and s.is_active
     and s.ncf_type::text in ('E31', 'B01')
     and s.current_number < s.range_end
     and (s.expiration_date is null or s.expiration_date >= current_date)
   order by case s.ncf_type::text when 'E31' then 0 else 1 end
   limit 1;
$$;

comment on function public.fn_external_credit_ncf_type(uuid) is
  'Serie de credito fiscal que este negocio tiene viva, prefiriendo la '
  'electronica (E31) sobre la de papel (B01). NULL si no tiene ninguna: el '
  'cobro cae al default del negocio en vez de fallar. La usa la ingesta de '
  'canales externos cuando el pedido trae RNC.';

revoke all on function public.fn_external_credit_ncf_type(uuid) from public;
grant execute on function public.fn_external_credit_ncf_type(uuid) to service_role;

commit;
