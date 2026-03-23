-- Aplicar realineación de NCF para negocio 38a0dfd6-f342-4e8c-b9d6-daf9e07d60da
-- Caso: B0200000014 ya existe, pero current_number seguía en 13.
-- Resultado esperado: current_number = 14
-- Próximo NCF esperado: B0200000015

BEGIN;

update public.ncf_sequences s
set current_number = d.max_numeric_used
from (
  select max(cast(substring(ncf_number from 4) as bigint)) as max_numeric_used
  from public.fiscal_documents
  where business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
    and ncf_number like 'B02%'
) d
where s.business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
  and s.prefix = 'B02'
  and s.current_number < d.max_numeric_used;

select
  id,
  business_id,
  prefix,
  ncf_type,
  current_number,
  range_end,
  is_active,
  expiration_date,
  created_at
from public.ncf_sequences
where business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
  and prefix = 'B02';

COMMIT;
