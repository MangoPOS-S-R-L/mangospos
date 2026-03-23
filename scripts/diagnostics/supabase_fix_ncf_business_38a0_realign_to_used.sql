-- Realinear secuencia NCF para negocio 38a0dfd6-f342-4e8c-b9d6-daf9e07d60da
-- Caso observado: duplicate key con B0200000014 ya existente.
--
-- generate_ncf() hace:
--   _new_number := current_number + 1
-- Por tanto, si 0014 ya existe, current_number debe quedar al menos en 14.
--
-- Este script recalcula current_number con base en el MAYOR NCF ya usado
-- para ese negocio/prefijo B02.

-- ============================================================
-- 1. Ver últimos B02 del negocio
-- ============================================================
select
  id,
  business_id,
  ncf_number,
  ncf_type,
  ncf_sequence_id,
  status,
  created_at
from public.fiscal_documents
where business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
  and ncf_number like 'B02%'
order by cast(substring(ncf_number from 4) as bigint) desc;

-- ============================================================
-- 2. Ver max real usado
-- ============================================================
select
  max(cast(substring(ncf_number from 4) as bigint)) as max_numeric_used,
  max(ncf_number) as max_ncf_text
from public.fiscal_documents
where business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
  and ncf_number like 'B02%';

-- ============================================================
-- 3. Ver secuencia actual B02
-- ============================================================
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
  and prefix = 'B02'
order by is_active desc, created_at desc nulls last;

-- ============================================================
-- 4. Preview de ajuste
-- expected_next_number = max_used + 1
-- current_number debe quedar = max_used
-- ============================================================
select
  s.id as sequence_id,
  s.current_number as current_number_before,
  d.max_numeric_used,
  (d.max_numeric_used + 1) as expected_next_number,
  case
    when s.current_number < d.max_numeric_used then 'NEEDS_UPDATE'
    when s.current_number = d.max_numeric_used then 'OK'
    when s.current_number > d.max_numeric_used then 'AHEAD'
  end as status
from public.ncf_sequences s
cross join (
  select max(cast(substring(ncf_number from 4) as bigint)) as max_numeric_used
  from public.fiscal_documents
  where business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
    and ncf_number like 'B02%'
) d
where s.business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
  and s.prefix = 'B02';

-- ============================================================
-- 5. Ajuste seguro con rollback
-- ============================================================
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

ROLLBACK;
-- Si el valor queda correcto, cambia ROLLBACK por COMMIT.

-- ============================================================
-- 6. Después del COMMIT, el próximo NCF esperado será:
--   B02 + LPAD(current_number + 1, 8, '0')
-- ============================================================
