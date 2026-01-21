-- ========================================================
-- SCRIPT DE DIAGNÓSTICO - Ejecutar primero
-- ========================================================
-- Este script te mostrará qué objetos ya existen relacionados
-- con employees, roles y permisos
-- ========================================================

-- Ver todas las tablas relacionadas
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
  AND table_name IN ('employees', 'roles', 'permissions', 'employee_roles', 'role_permissions', 'user_permission_overrides', 'employee_benefits', 'employee_deductions', 'audit_logs')
ORDER BY table_name;

-- Ver todas las vistas relacionadas
SELECT table_name 
FROM information_schema.views 
WHERE table_schema = 'public' 
  AND table_name LIKE '%employee%'
ORDER BY table_name;

-- Ver todas las funciones relacionadas
SELECT routine_name, routine_type
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND (routine_name LIKE '%employee%' OR routine_name LIKE '%permission%')
ORDER BY routine_name;

-- Ver constraints que puedan estar causando problemas
SELECT 
    tc.constraint_name, 
    tc.table_name, 
    kcu.column_name,
    tc.constraint_type
FROM information_schema.table_constraints AS tc 
JOIN information_schema.key_column_usage AS kcu
  ON tc.constraint_name = kcu.constraint_name
WHERE tc.table_schema = 'public'
  AND (tc.table_name LIKE '%employee%' OR tc.table_name LIKE '%role%' OR tc.table_name LIKE '%permission%')
ORDER BY tc.table_name, tc.constraint_name;
