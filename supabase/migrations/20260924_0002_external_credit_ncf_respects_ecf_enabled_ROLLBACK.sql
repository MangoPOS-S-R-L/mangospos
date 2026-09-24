-- ROLLBACK de 20260924_0002_external_credit_ncf_respects_ecf_enabled.sql
--
-- Devuelve `fn_external_credit_ncf_type` a la version de 20260924_0001: elige
-- la serie mirando solo las secuencias, sin consultar `ecf_enabled`.
--
-- OJO: con esto vuelve el comportamiento que se corrigio — un negocio con la
-- modalidad e-CF APAGADA que todavia tenga su secuencia E31 activa seguira
-- emitiendo E31 en los pedidos externos con RNC. Si se revierte, hay que
-- desactivar la secuencia E31 a mano (`ncf_sequences.is_active = false`) en
-- los negocios que ya no emiten electronico.

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

notify pgrst, 'reload schema';
