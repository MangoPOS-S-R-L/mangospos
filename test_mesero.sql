SELECT 
    schemaname, tablename, policyname, permissive, roles,
    cmd, pg_get_expr(qual, polrelid) as qual
FROM pg_policies 
WHERE tablename IN ('orders', 'table_sessions')
ORDER BY tablename, policyname;
