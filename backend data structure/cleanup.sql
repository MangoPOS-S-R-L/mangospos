-- ========================================================
-- SCRIPT DE LIMPIEZA COMPLETA
-- ========================================================
-- ADVERTENCIA: Este script eliminará TODAS las tablas, vistas
-- y funciones relacionadas con employees, roles y permisos
-- ========================================================
-- Ejecutar SOLO después de revisar el diagnóstico
-- ========================================================

-- PASO 1: Eliminar todas las funciones relacionadas
DROP FUNCTION IF EXISTS public.get_employee_permissions(uuid) CASCADE;
DROP FUNCTION IF EXISTS public.fn_user_effective_permissions(uuid, uuid) CASCADE;

-- PASO 2: Eliminar todas las vistas relacionadas
DROP VIEW IF EXISTS public.v_employees_summary CASCADE;

-- PASO 3: Eliminar tablas en orden inverso (respetando foreign keys)
DROP TABLE IF EXISTS public.audit_logs CASCADE;
DROP TABLE IF EXISTS public.employee_deductions CASCADE;
DROP TABLE IF EXISTS public.employee_benefits CASCADE;
DROP TABLE IF EXISTS public.user_permission_overrides CASCADE;
DROP TABLE IF EXISTS public.employee_roles CASCADE;
DROP TABLE IF EXISTS public.role_permissions CASCADE;
DROP TABLE IF EXISTS public.permissions CASCADE;
DROP TABLE IF EXISTS public.roles CASCADE;
DROP TABLE IF EXISTS public.employees CASCADE;

-- PASO 4: Eliminar tablas alternativas si existen (user_roles, etc)
DROP TABLE IF EXISTS public.user_roles CASCADE;

-- Verificar que todo se eliminó
SELECT 'Tables remaining:' as status;
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
  AND table_name IN ('employees', 'roles', 'permissions', 'employee_roles', 'role_permissions', 'user_permission_overrides', 'employee_benefits', 'employee_deductions', 'audit_logs', 'user_roles')
ORDER BY table_name;

SELECT 'Views remaining:' as status;
SELECT table_name 
FROM information_schema.views 
WHERE table_schema = 'public' 
  AND table_name LIKE '%employee%'
ORDER BY table_name;

-- ========================================================
-- ✅ LIMPIEZA COMPLETA
-- Ahora puedes ejecutar setup_roles_fixed.sql
-- ========================================================
