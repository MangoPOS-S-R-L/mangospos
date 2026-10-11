#!/usr/bin/env bash
# Postgres local desechable; no toca ninguna base remota.
# Prueba 20261010_0025 (versiones publicadas): lectura para anon y
# authenticated, sin escritura desde la app; dos veces y reversa.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55470}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_app_releases
rm -rf "$D"; mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

Q -c "create role anon; create role authenticated;"
Q -f "$M/20261010_0025_app_releases.sql"
Q -f "$M/20261010_0025_app_releases.sql"

Q <<'SQL'
insert into public.app_releases (platform, version, build, download_url)
values ('macos', '2.0.20', 20020, 'https://mangopos.com/MangoPOS-2.0.20-macOS.dmg'),
       ('macos', '2.0.21', 20021, 'https://mangopos.com/MangoPOS-2.0.21-macOS.dmg'),
       ('windows', '2.0.21', 20021, null);
-- Republicar la misma build actualiza la fila (lo que imprimen los scripts).
insert into public.app_releases (platform, version, build, download_url, notes)
values ('macos', '2.0.21', 20021, 'https://mangopos.com/MangoPOS-2.0.21-macOS.dmg', 'Cuentas en revisión')
on conflict (platform, build) do update set version = excluded.version,
  download_url = excluded.download_url, notes = excluded.notes, published_at = now();
do $$
begin
  if (select count(*) from public.app_releases) <> 3 then raise exception 'FAIL: republicar duplicó'; end if;
  if (select notes from public.app_releases where platform = 'macos' and build = 20021) <> 'Cuentas en revisión' then
    raise exception 'FAIL: republicar no actualizó'; end if;
  raise notice 'ok: republicar la misma build actualiza la fila';
end $$;
SQL

for r in anon authenticated; do
  n=$(Q -At -c "set role $r; select build from public.app_releases where platform = 'macos' order by build desc limit 1;")
  [ "$n" = "20021" ] || { echo "FAIL: $r no lee la última versión ($n)"; exit 1; }
  echo "ok: $r lee la última versión de su plataforma"
  if Q -c "set role $r; insert into public.app_releases (platform, version, build) values ('ios', '9.9.9', 99999);" >/dev/null 2>&1; then
    echo "FAIL: $r pudo publicar una versión"; exit 1
  fi
  echo "ok: $r no puede publicar versiones"
done

if Q -c "insert into public.app_releases (platform, version, build) values ('symbian', '1', 1);" >/dev/null 2>&1; then
  echo 'FAIL: aceptó una plataforma desconocida'; exit 1
fi
echo 'ok: solo plataformas conocidas'

Q -f "$M/20261010_0025_app_releases_ROLLBACK.sql"
[ "$(Q -At -c "select to_regclass('public.app_releases') is null")" = "t" ] || { echo 'FAIL: reversa'; exit 1; }
echo 'ok: reversa quita la tabla'
echo 'TODO OK'
