-- Diagnóstico fiscal seguro v2
-- No asume que existan tablas como public.business_fiscal_settings.
-- Usa bloques DO para evitar errores si una tabla no existe.

-- ============================================================
-- 1. Tablas fiscales / NCF / comprobantes / receipts
-- ============================================================
select
  table_schema,
  table_name
from information_schema.tables
where table_schema = 'public'
  and (
    table_name ilike '%fiscal%'
    or table_name ilike '%ncf%'
    or table_name ilike '%receipt%'
    or table_name ilike '%voucher%'
    or table_name ilike '%comprobante%'
  )
order by table_name;

-- ============================================================
-- 2. Columnas candidatas para NCF / secuencia / rango
-- ============================================================
select
  table_name,
  column_name,
  data_type,
  is_nullable
from information_schema.columns
where table_schema = 'public'
  and (
    column_name ilike '%ncf%'
    or column_name ilike '%sequence%'
    or column_name ilike '%range%'
    or column_name ilike '%current%'
    or column_name ilike '%next%'
    or column_name ilike '%receipt%'
    or column_name ilike '%voucher%'
  )
order by table_name, column_name;

-- ============================================================
-- 3. Estructura de fiscal_documents (si existe)
-- ============================================================
select
  column_name,
  data_type,
  is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'fiscal_documents'
order by ordinal_position;

-- ============================================================
-- 4. Sample de fiscal_documents (si existe)
-- ============================================================
do $$
begin
  if exists (
    select 1
    from information_schema.tables
    where table_schema = 'public'
      and table_name = 'fiscal_documents'
  ) then
    raise notice 'Sample from public.fiscal_documents';
    execute 'select * from public.fiscal_documents limit 10';
  else
    raise notice 'Tabla public.fiscal_documents no existe';
  end if;
end $$;

-- ============================================================
-- 5. Buscar tablas de configuración fiscal posibles
-- ============================================================
select
  table_schema,
  table_name
from information_schema.tables
where table_schema = 'public'
  and (
    table_name ilike '%business%fiscal%'
    or table_name ilike '%fiscal%settings%'
    or table_name ilike '%fiscal%config%'
    or table_name ilike '%dgii%'
  )
order by table_name;

-- ============================================================
-- 6. Columnas de tablas de configuración fiscal posibles
-- ============================================================
select
  table_name,
  column_name,
  data_type,
  is_nullable
from information_schema.columns
where table_schema = 'public'
  and (
    table_name ilike '%business%fiscal%'
    or table_name ilike '%fiscal%settings%'
    or table_name ilike '%fiscal%config%'
    or table_name ilike '%dgii%'
  )
order by table_name, ordinal_position;

-- ============================================================
-- 7. Funciones relacionadas a fiscal / NCF / receipts
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
    or p.proname ilike '%comprobante%'
    or p.proname ilike '%dgii%'
  )
order by p.proname;

-- ============================================================
-- 8. Índices / constraints sobre fiscal_documents (si existe)
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
-- 9. Triggers sobre fiscal_documents (si existe)
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
-- 10. Buscar si existe alguna columna ncf_number en cualquier tabla pública
-- ============================================================
select
  table_name,
  column_name,
  data_type
from information_schema.columns
where table_schema = 'public'
  and column_name ilike '%ncf%'
order by table_name, column_name;
