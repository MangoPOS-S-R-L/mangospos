#!/usr/bin/env bash
# Ejecuta las funciones SQL reales en un PostgreSQL desechable. Sin acceso a
# Supabase ni a otra base: cluster propio, solo socket Unix y limpieza al salir.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PG_BIN=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
WORK=$(mktemp -d /tmp/mangos-receipt-totals.XXXXXX)
cleanup() {
  "$PG_BIN/pg_ctl" -D "$WORK/data" -m immediate -w stop >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
"$PG_BIN/initdb" -D "$WORK/data" -U postgres --auth=trust --no-locale >/dev/null
"$PG_BIN/pg_ctl" -D "$WORK/data" -l "$WORK/postgres.log" \
  -o "-c listen_addresses='' -c unix_socket_directories='$WORK'" -w start >/dev/null
Q() { "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -h "$WORK" -U postgres -d postgres "$@"; }
Q -f "$REPO/supabase/tests/fixtures/receipt_totals_from_sale_setup.sql"
# Rechazar un servidor legacy antes de agregar columnas o cambiar funciones.
Q -c 'create function fn_compute_item_totals() returns trigger language plpgsql as $$ begin return new; end $$'
if Q -f "$REPO/supabase/migrations/20261016_0001_receipt_totals_from_sale.sql" >"$WORK/legacy_guard.log" 2>&1; then
  printf 'FAIL: se aceptó motor legacy\n' >&2
  exit 1
fi
Q -c "select test_assert(not exists(select 1 from information_schema.columns where table_schema='public' and table_name='fiscal_documents' and column_name='sale_totals_locked'), 'contrato legacy rechazado antes de DDL')"
python3 - "$REPO" "$WORK" <<'PY'
from pathlib import Path
import sys
repo,work=map(Path,sys.argv[1:])
src=(repo/'supabase/migrations/20260630_0001_fix_exclusive_discount_double_count.sql').read_text()
start=src.index('CREATE OR REPLACE FUNCTION public.fn_compute_item_totals()')
(work/'prices.sql').write_text(src[start:src.index('$$;',start)+3])
PY
Q -f "$WORK/prices.sql"
Q -c 'create trigger compute_item before insert or update on order_items for each row execute function fn_compute_item_totals()'
Q -f "$REPO/supabase/migrations/20260902_0007_fd_split_by_tax_name.sql"
Q -f "$REPO/supabase/migrations/20260530_0002_trigger_recompute_fd_on_payment_link.sql"
Q -f "$REPO/supabase/tests/fixtures/receipt_totals_from_sale_reproduce.sql"
# Instalar dos veces preserva datos y el estado de los snapshots.
Q -f "$REPO/supabase/migrations/20261016_0001_receipt_totals_from_sale.sql"
Q -f "$REPO/supabase/migrations/20261016_0001_receipt_totals_from_sale.sql"
Q -f "$REPO/supabase/tests/fixtures/receipt_totals_from_sale_assertions.sql"
Q -c 'create table before_rollback as select id, md5(to_jsonb(f)::text) h from fiscal_documents f'
Q -f "$REPO/supabase/migrations/20261016_0001_receipt_totals_from_sale_ROLLBACK.sql"
Q -c "select test_assert(position('v_scope_total' in pg_get_functiondef('fn_recompute_fd_for_scope(uuid,uuid,uuid)'::regprocedure))>0, 'rollback restaura v6')"
Q -f "$REPO/supabase/migrations/20261016_0001_receipt_totals_from_sale.sql"
Q -c "select test_assert(not exists(select 1 from before_rollback b full join fiscal_documents f using(id) where b.h is distinct from md5(to_jsonb(f)::text)), 'rollback y reinstalación no alteran documentos')"
printf 'receipt_totals_from_sale: OK\n'
