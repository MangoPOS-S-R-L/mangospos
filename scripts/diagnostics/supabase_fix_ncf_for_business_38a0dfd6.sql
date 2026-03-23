-- Validación y ajuste de NCF para negocio fijo
-- business_id objetivo:
--   38a0dfd6-f342-4e8c-b9d6-daf9e07d60da
--
-- Objetivo:
-- 1) verificar secuencia B02 de este negocio
-- 2) confirmar último NCF emitido
-- 3) corregir current_number si quedó atrasado
--
-- IMPORTANTE:
-- - Ejecuta primero los SELECTs
-- - El bloque de UPDATE viene con ROLLBACK
-- - Cambia a COMMIT solo si todo cuadra

-- ============================================================
-- 1. Documentos B02 del negocio actual
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
where business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
  and ncf_number like 'B02%'
order by cast(substring(ncf_number from 4) as bigint) desc;

-- ============================================================
-- 2. Resumen B02 del negocio actual
-- Esperado según lo que mandaste: max = 12
-- ============================================================
select
  business_id,
  min(cast(substring(ncf_number from 4) as bigint)) as min_ncf_usado,
  max(cast(substring(ncf_number from 4) as bigint)) as max_ncf_usado,
  min(ncf_number) as first_ncf,
  max(ncf_number) as last_ncf,
  count(*) as docs_count
from public.fiscal_documents
where business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
  and ncf_number like 'B02%'
group by business_id;

-- ============================================================
-- 3. Secuencias B02 del negocio actual
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
where business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
  and prefix = 'B02'
order by is_active desc, created_at desc nulls last;

-- ============================================================
-- 4. Comparación: secuencia actual vs último B02 emitido
-- Si gap > 0, la secuencia está atrasada
-- ============================================================
select
  s.id as sequence_id,
  s.business_id,
  s.ncf_type,
  s.prefix,
  s.current_number,
  d.max_numeric_suffix,
  (d.max_numeric_suffix - s.current_number) as gap,
  (d.max_numeric_suffix + 1) as expected_next_number
from public.ncf_sequences s
left join (
  select
    business_id,
    max(cast(substring(ncf_number from 4) as bigint)) as max_numeric_suffix
  from public.fiscal_documents
  where business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
    and ncf_number like 'B02%'
  group by business_id
) d on d.business_id = s.business_id
where s.business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
  and s.prefix = 'B02'
order by s.created_at desc nulls last;

-- ============================================================
-- 5. Generador actual que está usando el negocio
-- ============================================================
select
  n.nspname as schema_name,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as args,
  pg_get_functiondef(p.oid) as definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'generate_ncf',
    'issue_fiscal_document',
    'create_fiscal_document',
    'trigger_issue_fiscal_on_payment'
  )
order by p.proname;

-- ============================================================
-- 6. FIX SEGURO de current_number si está atrasado
-- Esto pondrá current_number = último usado (ej. 12),
-- para que el próximo generado sea 13.
-- ============================================================
BEGIN;

update public.ncf_sequences s
set current_number = d.max_numeric_suffix
from (
  select
    business_id,
    max(cast(substring(ncf_number from 4) as bigint)) as max_numeric_suffix
  from public.fiscal_documents
  where business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
    and ncf_number like 'B02%'
  group by business_id
) d
where s.business_id = d.business_id
  and s.business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
  and s.prefix = 'B02'
  and s.current_number < d.max_numeric_suffix;

-- revisar cómo quedaría
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
where business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
  and prefix = 'B02'
order by is_active desc, created_at desc nulls last;

ROLLBACK;
-- Si ves que quedó bien, cambia ROLLBACK por COMMIT.

-- ============================================================
-- 7. Validación rápida posterior
-- Esperado: current_number >= 12
-- ============================================================
select
  id,
  business_id,
  prefix,
  current_number,
  range_end,
  is_active
from public.ncf_sequences
where business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
  and prefix = 'B02';
