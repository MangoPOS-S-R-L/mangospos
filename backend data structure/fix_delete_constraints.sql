-- Script para corregir problemas de eliminación de empleados
-- Busca todas las llaves foráneas que apuntan a 'employees' y las cambia a ON DELETE SET NULL
-- Esto permite eliminar empleados sin borrar las ventas, órdenes, o historial asociado.

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT 
            tc.table_schema, 
            tc.table_name, 
            kcu.column_name, 
            tc.constraint_name
        FROM information_schema.table_constraints AS tc
        JOIN information_schema.key_column_usage AS kcu
          ON tc.constraint_name = kcu.constraint_name
          AND tc.table_schema = kcu.table_schema
        JOIN information_schema.constraint_column_usage AS ccu
          ON ccu.constraint_name = tc.constraint_name
          AND ccu.table_schema = tc.table_schema
        WHERE tc.constraint_type = 'FOREIGN KEY' 
          AND ccu.table_name = 'employees'
          -- Excluir tablas propias del sistema de roles que ya tienen CASCADE
          AND tc.table_name NOT IN (
              'employee_roles', 
              'role_permissions', 
              'user_permission_overrides', 
              'employee_benefits', 
              'employee_deductions'
          )
    LOOP
        RAISE NOTICE 'Cambiando constraint % en tabla % a ON DELETE SET NULL', r.constraint_name, r.table_name;

        -- 1. Eliminar constraint existente
        EXECUTE 'ALTER TABLE ' || quote_ident(r.table_schema) || '.' || quote_ident(r.table_name) || 
                ' DROP CONSTRAINT ' || quote_ident(r.constraint_name);
                
        -- 2. Volver a crear con ON DELETE SET NULL
        EXECUTE 'ALTER TABLE ' || quote_ident(r.table_schema) || '.' || quote_ident(r.table_name) || 
                ' ADD CONSTRAINT ' || quote_ident(r.constraint_name) || 
                ' FOREIGN KEY (' || quote_ident(r.column_name) || ') ' || 
                ' REFERENCES public.employees(id) ON DELETE SET NULL';
    END LOOP;
END$$;
