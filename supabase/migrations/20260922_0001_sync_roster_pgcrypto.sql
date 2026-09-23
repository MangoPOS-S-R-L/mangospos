-- Corrige 42883: function crypt(text, text) does not exist en fn_sync_roster.
-- Solo califica crypt con el schema real de pgcrypto. Conserva el cuerpo
-- instalado, firma, SECURITY DEFINER y ACL; no rota tokens ni modifica usuarios.
-- Aplicable desde el SQL Editor. Idempotente; aborta si faltan prerrequisitos.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

do $migration$
declare
  target regprocedure := to_regprocedure('public.fn_sync_roster(text)');
  crypto_schema name;
  original_definition text;
  corrected_definition text;
begin
  if target is null then
    raise exception 'Falta public.fn_sync_roster(text). Aplicar primero la migración de acceso offline.';
  end if;
  select n.nspname into crypto_schema
    from pg_catalog.pg_extension e
    join pg_catalog.pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pgcrypto';
  if crypto_schema is null or
     to_regprocedure(format('%I.crypt(text,text)', crypto_schema)) is null then
    raise exception 'No se encontró crypt(text,text) en la extensión pgcrypto. Revisar la instalación antes de continuar.';
  end if;

  original_definition := pg_catalog.pg_get_functiondef(target);
  -- Solo llamadas sin schema: no reemplaza extensions.crypt ni identificadores
  -- como decrypt. Reaplicar conserva una función que ya esté corregida.
  corrected_definition := regexp_replace(
    original_definition,
    '(^|[^[:alnum:]_.])crypt([[:space:]]*\()',
    E'\\1' || format('%I.crypt', crypto_schema) || E'\\2',
    'g'
  );
  if corrected_definition = original_definition and
     position(format('%I.crypt', crypto_schema) in original_definition) = 0 then
    raise exception 'La definición de fn_sync_roster no coincide con el caso esperado. Revisarla sin sobrescribirla.';
  end if;
  if corrected_definition <> original_definition then
    execute corrected_definition;
  end if;
  execute format(
    'alter function public.fn_sync_roster(text) set search_path = pg_catalog, public, %I',
    crypto_schema
  );
end;
$migration$;

-- Comprueba resolución y configuración sin consultar PINs ni tokens reales.
select p.oid::regprocedure as funcion,
       p.prosecdef as security_definer,
       p.proconfig as configuracion
  from pg_catalog.pg_proc p
 where p.oid = 'public.fn_sync_roster(text)'::regprocedure;
commit;
