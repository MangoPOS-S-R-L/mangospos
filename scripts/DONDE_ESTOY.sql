-- =============================================================================
-- ¿A qué base estoy conectado?  (solo lee)
-- =============================================================================

-- 1) Identidad de la conexión
select current_database()            as base,
       current_user                  as usuario,
       current_setting('search_path') as search_path,
       inet_server_addr()::text      as host_servidor,
       version()                     as version;

-- 2) ¿Existen las tablas de MangoPOS en ALGÚN esquema?
select table_schema, table_name
from information_schema.tables
where table_name in ('businesses','menu_items','categories','taxes','print_areas','menus')
order by table_schema, table_name;

-- 3) Qué esquemas hay y cuántas tablas tiene cada uno
select schemaname as esquema, count(*) as tablas
from pg_tables
where schemaname not in ('pg_catalog','information_schema')
group by schemaname
order by tablas desc;

-- 4) Si el paso 2 devolvió 0 filas: ¿hay OTRAS bases en este servidor?
select datname as base_de_datos
from pg_database
where not datistemplate
order by datname;
