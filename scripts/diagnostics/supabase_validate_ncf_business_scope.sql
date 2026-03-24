-- Validar que los NCF usados pertenecen al negocio actual
--
-- Uso:
-- 1) Si conoces el business_id actual, reemplaza <BUSINESS_ID_ACTUAL>
-- 2) Si no lo conoces, primero corre el bloque 1 y 2
-- 3) Para revisar una serie específica (ej. B02), usa los bloques 4-8

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
-- 4. Último NCF usado por negocio para prefijo B02
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
-- 5. Ver todos los B02 del negocio actual
-- Reemplaza <BUSINESS_ID_ACTUAL>
-- ============================================================
select
  id,
  business_id,
  order_id,
  payment_id,
  ncf_number,
  ncf_type,
  ncf_sequence_id,
  status,
  created_at
from public.fiscal_documents
where business_id = '<BUSINESS_ID_ACTUAL>'
  and ncf_number like 'B02%'
order by cast(substring(ncf_number from 4) as bigint) desc;

-- ============================================================
-- 6. Ver si hay B02 emitidos por OTROS negocios
-- Reemplaza <BUSINESS_ID_ACTUAL>
-- ============================================================
select
  business_id,
  ncf_number,
  order_id,
  status,
  created_at
from public.fiscal_documents
where business_id <> '<BUSINESS_ID_ACTUAL>'
  and ncf_number like 'B02%'
order by business_id, ncf_number;

-- ============================================================
-- 7. Revisar que la secuencia B02 activa pertenezca al negocio actual
-- Reemplaza <BUSINESS_ID_ACTUAL>
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
where business_id = '<BUSINESS_ID_ACTUAL>'
  and prefix = 'B02'
order by is_active desc, created_at desc nulls last;

-- ============================================================
-- 8. Comparación directa: secuencia actual vs último B02 del negocio actual
-- Reemplaza <BUSINESS_ID_ACTUAL>
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
where s.business_id = '<BUSINESS_ID_ACTUAL>'
  and s.prefix = 'B02'
order by s.created_at desc nulls last;

-- ============================================================
-- 9. Si no sabes el business_id actual pero sí una orden reciente
-- reemplaza <ORDER_ID_REAL>
-- ============================================================
-- select
--   o.id as order_id,
--   fd.business_id,
--   fd.ncf_number,
--   fd.created_at
-- from public.orders o
-- left join public.fiscal_documents fd on fd.order_id = o.id
-- where o.id = '<ORDER_ID_REAL>';
