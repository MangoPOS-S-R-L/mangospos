-- Diagnóstico de error fiscal por NCF duplicado
-- Error visto: fiscal_documents_ncf_number_key
-- Ejemplo: Key (ncf_number)=(B0200000013) already exists
--
-- Uso:
-- 1) Reemplaza B0200000013 donde aplique
-- 2) Si conoces el order_id, reemplázalo también en los bloques marcados
-- 3) Ejecuta por bloques en Supabase SQL Editor

-- ============================================================
-- 1. Ver si el NCF ya existe y a qué orden/pago quedó ligado
-- ============================================================
select
  id,
  business_id,
  order_id,
  ncf_number,
  fiscal_type,
  status,
  created_at,
  updated_at
from public.fiscal_documents
where ncf_number = 'B0200000013';

-- ============================================================
-- 2. Últimos NCF emitidos de esa serie
-- ============================================================
select
  id,
  order_id,
  ncf_number,
  fiscal_type,
  status,
  created_at
from public.fiscal_documents
where ncf_number like 'B02%'
order by created_at desc, ncf_number desc
limit 50;

-- ============================================================
-- 3. Buscar duplicados por ncf_number en fiscal_documents
-- ============================================================
select
  ncf_number,
  count(*) as copies,
  min(created_at) as first_seen,
  max(created_at) as last_seen
from public.fiscal_documents
group by ncf_number
having count(*) > 1
order by copies desc, ncf_number;

-- ============================================================
-- 4. Configuración fiscal activa del negocio
-- ============================================================
select *
from public.business_fiscal_settings
order by created_at desc;

-- ============================================================
-- 5. Tablas fiscales relacionadas (para descubrir secuencias/rangos reales)
-- ============================================================
select
  table_schema,
  table_name
from information_schema.tables
where table_schema = 'public'
  and (
    table_name ilike '%fiscal%'
    or table_name ilike '%ncf%'
    or table_name ilike '%voucher%'
    or table_name ilike '%receipt%'
  )
order by table_name;

-- ============================================================
-- 6. Columnas de tablas fiscales relevantes
-- ============================================================
select
  table_name,
  column_name,
  data_type,
  is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name in (
    'fiscal_documents',
    'business_fiscal_settings',
    'fiscal_receipts'
  )
order by table_name, ordinal_position;

-- ============================================================
-- 7. Funciones relacionadas a fiscal/NCF/receipt
-- ============================================================
select
  n.nspname as schema_name,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as args,
  pg_get_functiondef(p.oid) as definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and (
    p.proname ilike '%fiscal%'
    or p.proname ilike '%ncf%'
    or p.proname ilike '%receipt%'
    or p.proname ilike '%voucher%'
  )
order by p.proname;

-- ============================================================
-- 8. Índices y constraints sobre fiscal_documents
-- ============================================================
select
  schemaname,
  tablename,
  indexname,
  indexdef
from pg_indexes
where schemaname = 'public'
  and tablename = 'fiscal_documents'
order by indexname;

select
  tc.constraint_name,
  tc.constraint_type,
  kcu.column_name
from information_schema.table_constraints tc
left join information_schema.key_column_usage kcu
  on tc.constraint_name = kcu.constraint_name
  and tc.table_schema = kcu.table_schema
where tc.table_schema = 'public'
  and tc.table_name = 'fiscal_documents'
order by tc.constraint_name, kcu.ordinal_position;

-- ============================================================
-- 9. Triggers sobre fiscal_documents
-- ============================================================
select
  event_object_table as table_name,
  trigger_name,
  action_timing,
  event_manipulation,
  action_statement
from information_schema.triggers
where trigger_schema = 'public'
  and event_object_table = 'fiscal_documents'
order by trigger_name;

-- ============================================================
-- 10. Si conoces el order_id, revisa si ya tiene fiscal document
-- Reemplaza AQUI_EL_ORDER_ID
-- ============================================================
select
  o.id as order_id,
  o.status,
  o.total,
  o.created_at,
  fd.id as fiscal_document_id,
  fd.ncf_number,
  fd.fiscal_type,
  fd.status as fiscal_status,
  fd.created_at as fiscal_created_at
from public.orders o
left join public.fiscal_documents fd on fd.order_id = o.id
where o.id = 'AQUI_EL_ORDER_ID';

-- ============================================================
-- 11. Si conoces el order_id, revisa pagos de esa orden
-- Reemplaza AQUI_EL_ORDER_ID
-- ============================================================
select
  p.id,
  p.order_id,
  p.check_id,
  p.amount,
  p.status,
  p.reference,
  p.created_at
from public.payments p
where p.order_id = 'AQUI_EL_ORDER_ID'
order by p.created_at desc;

-- ============================================================
-- 12. Detectar si hay varias órdenes intentando usar el mismo NCF
-- ============================================================
select
  fd.ncf_number,
  array_agg(fd.order_id order by fd.created_at) as order_ids,
  count(distinct fd.order_id) as distinct_orders,
  count(*) as rows_count
from public.fiscal_documents fd
where fd.ncf_number = 'B0200000013'
group by fd.ncf_number;

-- ============================================================
-- 13. Buscar el último número emitido por prefijo
-- Ajusta el prefijo según necesites (ej. B01, B02, B14)
-- ============================================================
select
  ncf_number,
  created_at,
  order_id,
  status
from public.fiscal_documents
where ncf_number like 'B02%'
order by ncf_number desc
limit 20;

-- ============================================================
-- 14. Vista rápida: posibles tablas de secuencia/rango de NCF
-- ============================================================
select
  table_name,
  column_name
from information_schema.columns
where table_schema = 'public'
  and (
    column_name ilike '%ncf%'
    or column_name ilike '%sequence%'
    or column_name ilike '%range%'
    or column_name ilike '%current_number%'
    or column_name ilike '%next_number%'
  )
order by table_name, column_name;

-- ============================================================
-- 15. Query útil para comparar config vs documentos emitidos por negocio
-- ============================================================
select
  bfs.business_id,
  bfs.created_at as settings_created_at,
  fd.ncf_number,
  fd.fiscal_type,
  fd.order_id,
  fd.status,
  fd.created_at as document_created_at
from public.business_fiscal_settings bfs
left join public.fiscal_documents fd
  on fd.business_id = bfs.business_id
order by bfs.business_id, fd.created_at desc nulls last
limit 200;
