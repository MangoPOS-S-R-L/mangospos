-- Validar alcance de NCF por negocio (versión segura)
-- No usa placeholders UUID obligatorios.
-- Primero descubre qué business_id existe y luego, si quieres, usa el bloque opcional del final.

-- ============================================================
-- 1. Qué business_id tienen documentos fiscales emitidos
-- ============================================================
select
  business_id,
  count(*) as docs,
  min(created_at) as first_doc,
  max(created_at) as last_doc
from public.fiscal_documents
group by business_id
order by docs desc;

-- ============================================================
-- 2. Qué business_id tienen secuencias NCF
-- ============================================================
select
  business_id,
  ncf_type,
  prefix,
  current_number,
  range_end,
  is_active,
  expiration_date
from public.ncf_sequences
order by business_id, ncf_type, prefix;

-- ============================================================
-- 3. Cruce entre secuencias y documentos por negocio
-- ============================================================
select
  s.business_id,
  s.ncf_type,
  s.prefix,
  s.current_number,
  count(fd.id) as docs_count,
  min(fd.ncf_number) as first_ncf,
  max(fd.ncf_number) as last_ncf
from public.ncf_sequences s
left join public.fiscal_documents fd
  on fd.ncf_sequence_id = s.id
group by s.business_id, s.ncf_type, s.prefix, s.current_number
order by s.business_id, s.ncf_type, s.prefix;

-- ============================================================
-- 4. Último B02 usado por negocio
-- ============================================================
select
  business_id,
  max(cast(substring(ncf_number from 4) as bigint)) as max_ncf_usado,
  max(ncf_number) as max_ncf_texto,
  count(*) as docs_count
from public.fiscal_documents
where ncf_number like 'B02%'
group by business_id
order by max_ncf_usado desc;

-- ============================================================
-- 5. Secuencias activas B02 por negocio
-- ============================================================
select
  id,
  business_id,
  ncf_type,
  prefix,
  current_number,
  range_end,
  is_active,
  expiration_date,
  created_at
from public.ncf_sequences
where prefix = 'B02'
order by business_id, is_active desc, created_at desc nulls last;

-- ============================================================
-- 6. Comparación directa: secuencia actual vs último B02 por negocio
-- ============================================================
select
  s.id as sequence_id,
  s.business_id,
  s.ncf_type,
  s.prefix,
  s.current_number,
  d.max_numeric_suffix,
  (d.max_numeric_suffix - s.current_number) as gap
from public.ncf_sequences s
left join (
  select
    business_id,
    max(cast(substring(ncf_number from 4) as bigint)) as max_numeric_suffix
  from public.fiscal_documents
  where ncf_number like 'B02%'
  group by business_id
) d on d.business_id = s.business_id
where s.prefix = 'B02'
order by s.business_id, s.created_at desc nulls last;

-- ============================================================
-- 7. Ver si hay B02 emitidos por varios negocios
-- ============================================================
select
  business_id,
  count(*) as docs_count,
  min(ncf_number) as first_ncf,
  max(ncf_number) as last_ncf
from public.fiscal_documents
where ncf_number like 'B02%'
group by business_id
order by docs_count desc;

-- ============================================================
-- 8. OPCIONAL: cuando ya tengas el business_id real, descomenta y úsalo
-- ============================================================
-- select
--   id,
--   business_id,
--   order_id,
--   payment_id,
--   ncf_number,
--   ncf_type,
--   ncf_sequence_id,
--   status,
--   created_at
-- from public.fiscal_documents
-- where business_id = '<UUID_REAL_AQUI>'
--   and ncf_number like 'B02%'
-- order by cast(substring(ncf_number from 4) as bigint) desc;

-- select
--   id,
--   business_id,
--   ncf_type,
--   prefix,
--   current_number,
--   range_end,
--   is_active,
--   expiration_date,
--   created_at
-- from public.ncf_sequences
-- where business_id = '<UUID_REAL_AQUI>'
--   and prefix = 'B02'
-- order by is_active desc, created_at desc nulls last;
