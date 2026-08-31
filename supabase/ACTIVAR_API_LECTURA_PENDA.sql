-- ACTIVAR_API_LECTURA_PENDA.sql
-- Activa la API de lectura para Penda Express.
-- Requiere haber aplicado antes: migrations/20260829_0002_analytics_readonly_api.sql
--
-- ORDEN DE PASOS (los 1 y 5 NO son SQL):
--   1. Studio > Authentication > Add user
--        Email:    lectura.penda@mangopos.do     <-- OBLIGATORIO: correo controlado por MangoPOS
--        Password: uno largo y aleatorio, que NO se le entrega a nadie
--        Auto Confirm User: si
--      Por que el correo debe ser de MangoPOS: si el cliente controlara ese buzon podria hacer
--      "olvide mi contrasena", iniciar sesion y recibir un JWT con role=authenticated, que SI
--      tiene permisos de escritura. El cliente nunca debe poder iniciar sesion como este usuario.
--   2. Ejecutar los bloques 2 a 4 de este archivo.
--   3. Generar la key:  SUPABASE_JWT_SECRET=... ./scripts/mint_analytics_api_key.sh <user_id> 365
--   4. Verificar con el bloque 5.
--   5. Exponer el esquema analytics en PostgREST. Ver BLOQUE 6: se hace desde la BD,
--      no hace falta tocar Coolify ni reiniciar nada.

-- ===========================================================================
-- BLOQUE 1 - comprobaciones previas (no cambia nada)
-- ===========================================================================
select
  b.id                                        as business_id,
  b.business_name,
  b.branch_name,
  b.status,
  (select count(*) from public.fiscal_documents fd where fd.business_id = b.id) as documentos_fiscales
from public.businesses b
where b.id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
-- Debe devolver 1 fila y debe decir Penda Express. Si no, DETENERSE aqui.

select id, email, created_at
from auth.users
where email = 'lectura.penda@mangopos.do';
-- Debe devolver 1 fila (la creada en el paso 1). Copiar el id.


-- ===========================================================================
-- BLOQUE 2 - dar acceso de lectura al negocio (satisface la RLS de public.*)
-- ===========================================================================
-- Se usa SOLO user_businesses, a proposito: NO se crea fila en memberships para no alterar
-- la resolucion de plan del negocio.
insert into public.user_businesses (user_id, business_id, role, permissions)
select u.id,
       '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid,
       'manager',
       array[]::text[]      -- sin permisos de app: este usuario nunca entra al POS
from auth.users u
where u.email = 'lectura.penda@mangopos.do'
on conflict (user_id, business_id) do nothing;


-- ===========================================================================
-- BLOQUE 3 - pin duro de alcance (el candado que hace que sea UN solo negocio)
-- ===========================================================================
insert into analytics.api_clients (user_id, business_id, label, notes)
select u.id,
       '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid,
       'Penda Express',
       'Acceso de solo lectura para su herramienta de analisis. Alta 2026-08-29.'
from auth.users u
where u.email = 'lectura.penda@mangopos.do'
on conflict (user_id) do update
  set business_id = excluded.business_id,
      is_active   = true;


-- ===========================================================================
-- BLOQUE 4 - bloquear el inicio de sesion interactivo de este usuario
-- ===========================================================================
-- La API key es un JWT firmado: PostgREST solo valida firma y exp, asi que la key sigue
-- funcionando. GoTrue en cambio rechaza el login de un usuario baneado, de modo que nadie
-- puede convertir esta cuenta en una sesion con permisos de escritura.
update auth.users
set banned_until = 'infinity'
where email = 'lectura.penda@mangopos.do';


-- ===========================================================================
-- BLOQUE 5 - verificacion (ejecutar despues de todo lo anterior)
-- ===========================================================================
-- 5.a el pin quedo en un unico negocio, el correcto
select c.label, c.business_id, b.business_name, c.is_active
from analytics.api_clients c
join public.businesses b on b.id = c.business_id;

-- 5.b simular exactamente lo que vera la API key. No hay que pegar nada:
--     el sub se toma del propio usuario por correo.
begin;
  select set_config('request.jwt.claim.sub',
                    (select u.id::text from auth.users u
                      where u.email = 'lectura.penda@mangopos.do'), true);
  set local role analytics_ro;

  select count(*) as documentos_visibles from analytics.documentos;

  -- DEBE devolver 0. Si devuelve mas de 0, hay una fuga: detener y revisar.
  select count(*) as filas_de_otros_negocios
  from analytics.documentos_detalle
  where business_id <> '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';

  -- DEBE fallar con "permission denied": la key no puede escribir.
  -- (descomentar para probarlo; aborta la transaccion, por eso va al final)
  -- update analytics.customers set name = 'prueba';
rollback;

-- 5.c inventario de lo publicado (esto es el diccionario que se le entrega al cliente)
select table_name, (select count(*) from information_schema.columns c
                    where c.table_schema = 'analytics' and c.table_name = t.table_name) as columnas
from information_schema.tables t
where t.table_schema = 'analytics' and t.table_type = 'VIEW'
order by table_name;


-- ===========================================================================
-- BLOQUE 6 - exponer el esquema analytics en PostgREST (sin reiniciar nada)
-- ===========================================================================
-- PostgREST lee su configuracion tambien desde la base (db-config, activo por defecto), y
-- ESO TIENE PRIORIDAD sobre la variable de entorno PGRST_DB_SCHEMAS del stack.
-- Verificado contra PostgREST 16.2: con db-schemas="public" en el archivo, este ALTER ROLE
-- + NOTIFY expuso analytics al instante y public siguio funcionando.
--
-- Por eso NO hay que editar nada en Coolify. La variable de entorno seguira diciendo
-- `public,storage,graphql_public` y no pasa nada: la de la BD manda.
--
-- OJO PARA EL FUTURO: a partir de aqui, cambiar PGRST_DB_SCHEMAS en Coolify ya no surte
-- efecto. Si algun dia hay que volver a mandar desde el entorno:
--     alter role authenticator reset pgrst.db_schemas;
--     notify pgrst, 'reload config';

-- Se conserva la lista actual de prod y se le AGREGA analytics.
-- Sin `storage`, PostgREST deja de servir el esquema de archivos.
alter role authenticator set pgrst.db_schemas = 'public,storage,graphql_public,analytics';

notify pgrst, 'reload config';
notify pgrst, 'reload schema';

-- Comprobar que quedo:
select rolname, rolconfig
from pg_roles
where rolname = 'authenticator';
