-- Reversa de 20261010_0025: quita la tabla de versiones publicadas. La app
-- deja de avisar (la consulta falla y el aviso queda apagado, sin errores).
begin;

drop table if exists public.app_releases;

commit;
