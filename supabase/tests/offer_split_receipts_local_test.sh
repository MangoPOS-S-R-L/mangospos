#!/usr/bin/env bash
# PostgreSQL desechable. Reutiliza el esquema de ediciones versionadas, pero
# sustituye sus dobles de precios por las funciones reales del repositorio.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
export PG_PORT=${PG_PORT:-55479}
python3 - "$REPO" "$WORK" <<'PY'
from pathlib import Path
import sys,shlex
repo,work=map(Path,sys.argv[1:])
s=(repo/'supabase/tests/versioned_order_edits_local_test.sh').read_text()
s=s[:s.index("Q <<'SQL'\ncreate function public.edit")]
s=s.replace('REPO=$(cd "$(dirname "$0")/../.." && pwd)','REPO='+shlex.quote(str(repo)))
def cut(rel,start):
 t=(repo/rel).read_text();a=t.lower().index(start.lower());return t[a:t.index('$$;',a)+3]+'\n'
parts=[cut('supabase/migrations/20260630_0001_fix_exclusive_discount_double_count.sql','CREATE OR REPLACE FUNCTION public.fn_compute_item_totals()'),
'drop trigger trg_compute_item_totals on public.order_items;\ncreate trigger trg_compute_item_totals before insert or update on public.order_items for each row execute function public.fn_compute_item_totals();\n',
cut('supabase/migrations/20260327_0004_inclusive_service_fee_exact_totals.sql','create or replace function public.calculate_order_totals(').replace('_order_id','p'),
cut('supabase/migrations/20260327_0004_inclusive_service_fee_exact_totals.sql','create or replace function public.calculate_check_totals(').replace('_check_id','p'),
'''create or replace function public.fn_recalc_order_totals(p uuid) returns void language plpgsql as $$
declare c record; begin perform public.calculate_order_totals(p); for c in select id from order_checks where order_id=p loop perform public.calculate_check_totals(c.id); end loop; end $$;\n''']
# Incluir el trigger real de totales: mover una fila recalcula ambos checks.
parts.append(cut('supabase/migrations/20260303_0008_sales_split_open_table_full_fix.sql',
 'create or replace function public.trigger_update_order_totals()'))
parts.append('create trigger order_items_totals_trigger after insert or update or delete on public.order_items for each row execute function public.trigger_update_order_totals();\n')
for rel,start in [('20260605_0005_fn_add_offer_deal.sql','fn_add_offer_deal('),('20260601_0001_fix_explode_items_tax.sql','fn_explode_items_to_units('),('20260929_0001_add_item_idempotent.sql','fn_add_offer_deal_idempotent(')]:
 parts.append(cut('supabase/migrations/'+rel,'create or replace function public.'+start))
(work/'split_guards.sql').write_text(cut('supabase/migrations/20260512_0002_auto_close_empty_subchecks.sql','create or replace function public.fn_auto_close_empty_subcheck()')+
'create trigger trg_auto_close_empty_subcheck after insert or update or delete on public.order_items for each row execute function public.fn_auto_close_empty_subcheck();\n'+
cut('supabase/migrations/20260513_0004_guard_items_against_closed_checks.sql','create or replace function public.fn_guard_item_check_open()')+
'create trigger trg_guard_item_check_open before insert or update of check_id on public.order_items for each row execute function public.fn_guard_item_check_open();\n')
(work/'prices.sql').write_text(''.join(parts))
s+='\nQ -f "$REPO/supabase/tests/fixtures/offer_split_receipts_setup.sql"\n'
s+='Q -f '+shlex.quote(str(work/'prices.sql'))+'\n'
# Instalar dos veces: debe conservar cuerpos ajenos, datos y permisos.
s+='Q -f "$REPO/supabase/migrations/20261014_0001_preserve_offer_packages_in_split.sql"\n'*2
s+='Q -f "$REPO/supabase/migrations/20261014_0002_offer_quantity_discount.sql"\n'*2
s+='Q -f "$REPO/supabase/tests/fixtures/offer_split_receipts_assertions.sql"\n'
s+='Q -f "$REPO/supabase/tests/fixtures/offer_quantity_discount_assertions.sql"\n'
s+='Q -f "$REPO/supabase/migrations/20261015_0001_atomic_item_groups.sql"\n'*2
s+='Q -f "$REPO/supabase/tests/fixtures/atomic_item_groups_assertions.sql"\n'
s+='Q -f "$REPO/supabase/migrations/20261015_0002_legacy_offer_group_rules.sql"\n'*2
s+='Q -f "$REPO/supabase/tests/fixtures/legacy_offer_group_rules_assertions.sql"\n'
s+='Q -f '+shlex.quote(str(work/'split_guards.sql'))+'\n'
s+='Q -f "$REPO/supabase/migrations/20260605_0006_split_keep_offers_whole.sql"\n'
s+='Q -f "$REPO/supabase/migrations/20261015_0003_atomic_bill_splits.sql"\n'*2
s+='Q -f "$REPO/supabase/tests/fixtures/atomic_bill_splits_assertions.sql"\n'
s+='Q -f "$REPO/supabase/migrations/20261015_0004_split_ordinary_items_to_units.sql"\n'*2
s+='Q -f "$REPO/supabase/tests/fixtures/split_ordinary_units_assertions.sql"\n'
s+='Q -c "create table review_hash as select id,md5(to_jsonb(i)::text) h from order_items i"\n'
s+='Q -f "$REPO/supabase/migrations/20261015_0004_split_ordinary_items_to_units_ROLLBACK.sql"\n'
s+='Q -f "$REPO/supabase/migrations/20261015_0003_atomic_bill_splits_ROLLBACK.sql"\n'
s+='Q -f "$REPO/supabase/migrations/20261015_0002_legacy_offer_group_rules_ROLLBACK.sql"\n'
s+='Q -f "$REPO/supabase/migrations/20261015_0001_atomic_item_groups_ROLLBACK.sql"\n'
s+='Q -f "$REPO/supabase/migrations/20261014_0001_preserve_offer_packages_in_split_ROLLBACK.sql"\n'
s+='Q -f "$REPO/supabase/migrations/20261014_0001_preserve_offer_packages_in_split.sql"\n'
s+='Q -f "$REPO/supabase/migrations/20261014_0002_offer_quantity_discount_ROLLBACK.sql"\n'
s+='Q -f "$REPO/supabase/migrations/20261014_0002_offer_quantity_discount.sql"\n'
s+='Q -f "$REPO/supabase/migrations/20261015_0001_atomic_item_groups.sql"\n'
s+='Q -f "$REPO/supabase/migrations/20261015_0002_legacy_offer_group_rules.sql"\n'
s+='Q -f "$REPO/supabase/migrations/20261015_0003_atomic_bill_splits.sql"\n'
s+='Q -f "$REPO/supabase/migrations/20261015_0004_split_ordinary_items_to_units.sql"\n'
s+='Q -c "select test_assert(not exists(select 1 from review_hash h full join order_items i using(id) where h.h is distinct from md5(to_jsonb(i)::text)), \'rollback y reinstalación conservan los datos\')"\n'
(work/'run.sh').write_text(s)
PY
bash "$WORK/run.sh"
