#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL del verificador de activos (20261001_0050).
# Postgres 15 DESECHABLE con el MISMO esquema mínimo de
# fixed_assets_local_test.sh (se toma de ahí, no se copia a mano), la 0052
# aplicada CON DATOS (como estaría en producción) y encima la 0050 del 1/10.
#
#   bash supabase/tests/fixed_asset_verification_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55481).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
BASE=$M/20260930_0052_fixed_assets.sql
MIG=$M/20261001_0050_fixed_asset_verification.sql
RB=$M/20261001_0050_fixed_asset_verification_ROLLBACK.sql
STUB=$REPO/supabase/tests/fixed_assets_local_test.sh
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55481}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_fa_verification
rm -rf "$D"; mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null || exit 1
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$D/log" start -w >/dev/null || { cat "$D/log"; exit 1; }
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
FAIL=0
ok()  { echo "  ok     $1"; }
bad() { echo "  FALLA  $1"; FAIL=1; }
run() {
  local label=$1; shift
  if OUT=$(Q "$@" 2>&1); then echo "$OUT" | grep -E "NOTICE:  (ok|--)" | sed 's/^.*NOTICE:  /  /'; ok "$label";
  else echo "$OUT" | grep -E "NOTICE:  ok|ERROR" | sed 's/^.*NOTICE:  /  /; s/^psql:[^:]*:[0-9]*: //'; bad "$label"; fi
}
run_fails() {
  local label=$1 expect=$2; shift 2
  if OUT=$(Q "$@" 2>&1); then bad "$label (no falló)";
  elif echo "$OUT" | grep -q "$expect"; then ok "$label";
  else echo "$OUT" | grep ERROR; bad "$label (falló distinto)"; fi
}

echo "== Esquema mínimo (el de fixed_assets_local_test.sh)"
# Entre «Q <<'SQL'» y la primera línea «SQL» de ese script.
awk "/^Q <<'SQL'/{f=1;next} f&&/^SQL\$/{exit} f" "$STUB" | Q >/dev/null || { bad "esquema"; exit 1; }
ok "esquema mínimo"

echo "== Producción hoy: la 0052 con datos"
run "aplica 0052" -f "$BASE"
run "datos de antes" <<'SQL'
do $$
declare v jsonb;
begin
  -- AF-00001 horno en Cocina, AF-00002 nevera en Principal, AF-00003 TV dada de baja en Cocina.
  v := public.fn_fixed_asset_create('11111111-1111-1111-1111-111111111111',
    '{"name":"Horno","warehouse_id":"a0000000-0000-0000-0000-000000000002","purchase_cost":"850000"}');
  v := public.fn_fixed_asset_create('11111111-1111-1111-1111-111111111111',
    '{"name":"Nevera","warehouse_id":"a0000000-0000-0000-0000-000000000001","purchase_cost":"95000"}');
  v := public.fn_fixed_asset_create('11111111-1111-1111-1111-111111111111',
    '{"name":"TV vieja","warehouse_id":"a0000000-0000-0000-0000-000000000002"}');
  v := public.fn_fixed_asset_set_status((v->>'id')::uuid, 'retired', 'Se dañó');
  perform test.chk('3 activos de antes', (select count(*) from public.fixed_assets) = 3);
end $$;
SQL

echo "== Migración real 20261001_0050"
run "aplica sobre la 0052 con datos" -f "$MIG"
run "es idempotente"                 -f "$MIG"

echo "== Cantidad y código de la etiqueta"
run "alta y edición" <<'SQL'
do $$
declare
  b uuid := '11111111-1111-1111-1111-111111111111';
  cocina text := 'a0000000-0000-0000-0000-000000000002';
  v jsonb; v2 jsonb; s uuid;
begin
  perform test.chk('lo de antes quedó con cantidad 1',
    not exists (select 1 from public.fixed_assets where quantity <> 1));

  v := public.fn_fixed_asset_create(b, jsonb_build_object('name','Silla de madera','code','MB-001',
         'quantity',40,'purchase_cost','2500','warehouse_id',cocina));
  s := (v->>'id')::uuid;
  perform test.chk('código propio y cantidad', v->>'code' = 'MB-001' and (v->>'quantity')::int = 40, v::text);
  perform test.chk('la historia del alta trae la cantidad',
    (select to_quantity from public.fixed_asset_movements where asset_id = s and event_type = 'created') = 40);

  perform test.chk('mismo código con otras mayúsculas: tomado',
    test.err($q$select public.fn_fixed_asset_create('11111111-1111-1111-1111-111111111111',
      '{"name":"Otra","code":"mb-001"}')$q$) like 'FIXED_ASSET_CODE_TAKEN%');
  perform test.chk('código de más de 40: inválido',
    test.err(format($q$select public.fn_fixed_asset_create('11111111-1111-1111-1111-111111111111',
      '{"name":"X","code":"%s"}')$q$, repeat('A', 41))) like 'FIXED_ASSET_INVALID_CODE%');
  perform test.chk('cantidad 0: inválida',
    test.err($q$select public.fn_fixed_asset_create('11111111-1111-1111-1111-111111111111',
      '{"name":"X","quantity":0}')$q$) like 'FIXED_ASSET_INVALID_QUANTITY%');
  perform test.chk('cantidad 2.5: inválida',
    test.err($q$select public.fn_fixed_asset_create('11111111-1111-1111-1111-111111111111',
      '{"name":"X","quantity":2.5}')$q$) like 'FIXED_ASSET_INVALID_QUANTITY%');
  perform test.chk('cantidad «abc»: inválida',
    test.err($q$select public.fn_fixed_asset_create('11111111-1111-1111-1111-111111111111',
      '{"name":"X","quantity":"abc"}')$q$) like 'FIXED_ASSET_INVALID_QUANTITY%');
  perform test.chk('cantidad «3.0» se acepta',
    (public.fn_fixed_asset_create(b, '{"name":"Mesa","quantity":"3.0","code":"MS-01"}')->>'quantity')::int = 3);

  -- Sin código: sigue la secuencia AF de antes (AF-00004), y un «af-00010»
  -- escrito a mano también ocupa su número.
  v := public.fn_fixed_asset_create(b, '{"name":"Licuadora"}');
  perform test.chk('sin código sigue AF-00004', v->>'code' = 'AF-00004', v->>'code');
  v := public.fn_fixed_asset_create(b, '{"name":"Freidora","code":"af-00010"}');
  v := public.fn_fixed_asset_create(b, '{"name":"Plancha"}');
  perform test.chk('después de af-00010 viene AF-00011', v->>'code' = 'AF-00011', v->>'code');

  -- Reintento con la misma llave: el mismo activo.
  v := public.fn_fixed_asset_create(b, '{"name":"Batidora","client_request_id":"aaaaaaaa-0000-0000-0000-000000000001"}');
  v2 := public.fn_fixed_asset_create(b, '{"name":"Batidora","client_request_id":"aaaaaaaa-0000-0000-0000-000000000001"}');
  perform test.chk('reintento del alta: el mismo', v->>'id' = v2->>'id');

  -- Bajar la cantidad: SU evento, con el motivo, y sin «editado».
  v := public.fn_fixed_asset_update(s, '{"quantity":38,"change_note":"se rompieron 2"}');
  perform test.chk('cantidad 38', (v->>'quantity')::int = 38);
  perform test.chk('evento quantity_changed 40 → 38 con el motivo',
    exists (select 1 from public.fixed_asset_movements where asset_id = s and event_type = 'quantity_changed'
             and from_quantity = 40 and to_quantity = 38 and notes = 'se rompieron 2'));
  perform test.chk('solo cantidad: sin evento «editado»',
    not exists (select 1 from public.fixed_asset_movements where asset_id = s and event_type = 'updated'));
  -- Mismo código con otras mayúsculas sobre sí mismo: permitido y queda en «editado».
  v := public.fn_fixed_asset_update(s, '{"code":"mb-001"}');
  perform test.chk('cambiar mayúsculas del propio código', v->>'code' = 'mb-001'
    and exists (select 1 from public.fixed_asset_movements where asset_id = s and event_type = 'updated'
                 and changes ? 'code'));
  v := public.fn_fixed_asset_update(s, '{"code":"MB-001"}');
  perform test.chk('código de OTRO activo: tomado',
    test.err(format($q$select public.fn_fixed_asset_update(%L, '{"code":"ms-01"}')$q$, s))
      like 'FIXED_ASSET_CODE_TAKEN%');
  perform test.chk('código vacío: se queda el que tiene',
    public.fn_fixed_asset_update(s, '{"code":""}')->>'code' = 'MB-001');
  perform test.chk('cantidad 0 en edición: inválida',
    test.err(format($q$select public.fn_fixed_asset_update(%L, '{"quantity":0}')$q$, s))
      like 'FIXED_ASSET_INVALID_QUANTITY%');
  -- Guardar sin cambios no deja historia.
  perform public.fn_fixed_asset_update(s, '{"quantity":38,"name":"Silla de madera"}');
  perform test.chk('guardar sin cambios no deja historia',
    (select count(*) from public.fixed_asset_movements where asset_id = s and event_type = 'quantity_changed') = 1);
end $$;
SQL

echo "== Verificación de Cocina"
run "abrir, marcar, alta en el acto" <<'SQL'
do $$
declare
  b uuid := '11111111-1111-1111-1111-111111111111';
  cocina uuid := 'a0000000-0000-0000-0000-000000000002';
  v jsonb; v2 jsonb; ver uuid; horno uuid; sillas uuid; nevera uuid; tv uuid; l jsonb;
begin
  select id into horno  from public.fixed_assets where name = 'Horno';
  select id into sillas from public.fixed_assets where code = 'MB-001';
  select id into nevera from public.fixed_assets where name = 'Nevera';
  select id into tv     from public.fixed_assets where name = 'TV vieja';

  -- Quién puede.
  perform test.as_user('88888888-8888-8888-8888-888888888888');
  perform test.chk('mesero sin permiso: negado',
    test.err($q$select public.fn_fixed_asset_verification_start('11111111-1111-1111-1111-111111111111',
      'a0000000-0000-0000-0000-000000000002')$q$) like 'FIXED_ASSET_DENIED%');
  perform test.as_user('66666666-6666-6666-6666-666666666666');
  perform test.chk('dueño de otro negocio: negado',
    test.err($q$select public.fn_fixed_asset_verification_start('11111111-1111-1111-1111-111111111111', null)$q$)
      like 'NOT_AUTHORIZED%');
  perform test.as_user('99999999-9999-9999-9999-999999999999');
  perform test.chk('bodega de otro negocio: rechazada',
    test.err($q$select public.fn_fixed_asset_verification_start('11111111-1111-1111-1111-111111111111',
      'b0000000-0000-0000-0000-000000000001')$q$) like 'WAREHOUSE_NOT_IN_BUSINESS%');

  v := public.fn_fixed_asset_verification_start(b, cocina, 'Cierre de mes');
  ver := (v->>'id')::uuid;
  perform test.chk('verificación #1 de Cocina', (v->>'number')::int = 1 and v->>'warehouse_name' = 'Cocina'
    and v->>'status' = 'open' and not (v->>'resumed')::boolean, v::text);
  -- Lo esperado: horno + sillas (×38). La TV dada de baja y lo de otras bodegas, no.
  perform test.chk('lista esperada: horno y sillas, sin la TV dada de baja',
    jsonb_array_length(v->'lines') = 2
    and exists (select 1 from jsonb_array_elements(v->'lines') x
                 where x->>'asset_id' = sillas::text and (x->>'expected_qty')::int = 38
                   and (x->>'unit_value')::numeric = 2500)
    and not exists (select 1 from jsonb_array_elements(v->'lines') x where x->>'asset_id' = tv::text),
    (v->'lines')::text);
  v2 := public.fn_fixed_asset_verification_start(b, cocina);
  perform test.chk('abrir otra vez Cocina: la misma, «resumed»',
    v2->>'id' = ver::text and (v2->>'resumed')::boolean);

  -- El horno, uno: encontrado.
  l := public.fn_fixed_asset_verification_check(ver, horno, 1);
  perform test.chk('horno encontrado', (l->>'found_qty')::int = 1 and (l->>'expected')::boolean
    and l->>'checked_by_name' = 'Dueño Penda', l::text);
  -- Visto igual que como está registrado = sin cambio.
  l := public.fn_fixed_asset_verification_check(ver, horno, 1, 'active');
  perform test.chk('estado igual al registrado = sin cambio', l->>'observed_status' is null, l::text);

  -- Las sillas: 36 de 38, dos dañadas a la vista. Repetir no suma.
  l := public.fn_fixed_asset_verification_check(ver, sillas, 36, 'damaged', 'dos con la pata floja');
  l := public.fn_fixed_asset_verification_check(ver, sillas, 36);
  perform test.chk('sillas 36, repetir no suma, el estado anotado se conserva',
    (l->>'found_qty')::int = 36 and l->>'observed_status' = 'damaged'
    and l->>'notes' = 'dos con la pata floja', l::text);

  -- La nevera está registrada en Principal pero apareció en Cocina.
  l := public.fn_fixed_asset_verification_check(ver, nevera, 1);
  perform test.chk('nevera: fuera de lugar (no esperada, registrada en Principal)',
    not (l->>'expected')::boolean and l->>'registered_warehouse_name' = 'Principal', l::text);
  -- Deshacer una no esperada la quita; una esperada vuelve a «sin revisar».
  v2 := public.fn_fixed_asset_verification_uncheck(ver, nevera);
  perform test.chk('deshacer la nevera la quita', (v2->>'removed')::boolean
    and not exists (select 1 from public.fixed_asset_verification_lines where verification_id = ver and asset_id = nevera));
  l := public.fn_fixed_asset_verification_check(ver, nevera, 1);
  v2 := public.fn_fixed_asset_verification_uncheck(ver, horno);
  perform test.chk('deshacer el horno: sin revisar', not (v2->>'removed')::boolean
    and v2->'line'->>'found_qty' is null);
  l := public.fn_fixed_asset_verification_check(ver, horno, 2);   -- había DOS hornos

  perform test.chk('la TV dada de baja no se verifica',
    test.err(format($q$select public.fn_fixed_asset_verification_check(%L, %L, 1)$q$, ver, tv))
      like 'FIXED_ASSET_RETIRED%');
  perform test.chk('cantidad negativa: inválida',
    test.err(format($q$select public.fn_fixed_asset_verification_check(%L, %L, -1)$q$, ver, horno))
      like 'FIXED_ASSET_INVALID_QUANTITY%');
  perform test.chk('estado «retired» no es un estado visto',
    test.err(format($q$select public.fn_fixed_asset_verification_check(%L, %L, 1, 'retired')$q$, ver, horno))
      like 'FIXED_ASSET_INVALID_STATUS%');

  -- Lo que no estaba dado de alta: se registra en el acto, EN Cocina.
  v := public.fn_fixed_asset_verification_add_asset(ver, jsonb_build_object(
         'name','Olla industrial','code','OL-01','quantity',3,'purchase_cost','4000',
         'warehouse_id','a0000000-0000-0000-0000-000000000001',
         'client_request_id','bbbbbbbb-0000-0000-0000-000000000001'));
  perform test.chk('alta en el acto, ubicada en Cocina aunque pidieran Principal',
    v->'asset'->>'warehouse_id' = cocina::text and (v->'line'->>'is_new')::boolean
    and (v->'line'->>'found_qty')::int = 3, v::text);
  v2 := public.fn_fixed_asset_verification_add_asset(ver, jsonb_build_object(
         'name','Olla industrial','code','OL-01','quantity',3,
         'client_request_id','bbbbbbbb-0000-0000-0000-000000000001'));
  perform test.chk('reintento del alta: el mismo activo y una sola línea',
    v2->'asset'->>'id' = v->'asset'->>'id'
    and (select count(*) from public.fixed_asset_verification_lines
          where verification_id = ver and is_new) = 1);
  perform test.chk('deshacer un alta del acto: no',
    test.err(format($q$select public.fn_fixed_asset_verification_uncheck(%L, %L)$q$, ver,
      v->'asset'->>'id')) like 'FIXED_ASSET_VERIFICATION_IS_NEW%');
end $$;
SQL

echo "== Cerrar"
run "decisiones malas: no toca nada" <<'SQL'
do $$
declare ver uuid; horno uuid; sillas uuid; msg text;
begin
  select id into ver from public.fixed_asset_verifications where number = 1;
  select id into horno from public.fixed_assets where name = 'Horno';
  select id into sillas from public.fixed_assets where code = 'MB-001';
  perform test.chk('perdido sobre algo que apareció completo: no',
    test.err(format($q$select public.fn_fixed_asset_verification_close(%L, %L)$q$, ver,
      jsonb_build_array(jsonb_build_object('asset_id', horno, 'action', 'mark_lost'))))
      like 'FIXED_ASSET_VERIFICATION_BAD_DECISION%');
  perform test.chk('activo que no está en la verificación: no',
    test.err(format($q$select public.fn_fixed_asset_verification_close(%L, %L)$q$, ver,
      jsonb_build_array(jsonb_build_object('asset_id', gen_random_uuid(), 'action', 'set_quantity'))))
      like 'FIXED_ASSET_VERIFICATION_BAD_DECISION%');
  perform test.chk('perdido y «cantidad encontrada» a la vez: no',
    test.err(format($q$select public.fn_fixed_asset_verification_close(%L, %L)$q$, ver,
      jsonb_build_array(jsonb_build_object('asset_id', sillas, 'action', 'mark_lost'),
                        jsonb_build_object('asset_id', sillas, 'action', 'set_quantity'))))
      like 'FIXED_ASSET_VERIFICATION_BAD_DECISION%');
  perform test.chk('acción desconocida: no',
    test.err(format($q$select public.fn_fixed_asset_verification_close(%L, %L)$q$, ver,
      jsonb_build_array(jsonb_build_object('asset_id', sillas, 'action', 'borrar'))))
      like 'FIXED_ASSET_VERIFICATION_BAD_DECISION%');
  perform test.chk('sigue abierta y sin cambios',
    (select status from public.fixed_asset_verifications where id = ver) = 'open'
    and (select quantity from public.fixed_assets where id = sillas) = 38);
end $$;
SQL

run "cerrar con decisiones" <<'SQL'
do $$
declare
  b uuid := '11111111-1111-1111-1111-111111111111';
  cocina uuid := 'a0000000-0000-0000-0000-000000000002';
  ver uuid; horno uuid; sillas uuid; nevera uuid; licuadora uuid; olla uuid; v jsonb; s jsonb;
begin
  select id into ver from public.fixed_asset_verifications where number = 1;
  select id into horno from public.fixed_assets where name = 'Horno';
  select id into sillas from public.fixed_assets where code = 'MB-001';
  select id into nevera from public.fixed_assets where name = 'Nevera';
  select id into olla from public.fixed_assets where code = 'OL-01';
  -- Una licuadora registrada en Cocina DESPUÉS de abrir: no está en la lista.
  -- Se mueve a Cocina y se mete como esperada a mano para tener un faltante
  -- sin decisión (queda pendiente).
  select id into licuadora from public.fixed_assets where code = 'AF-00004';
  perform public.fn_fixed_asset_move(licuadora, cocina, null, null);
  insert into public.fixed_asset_verification_lines (verification_id, business_id, asset_id,
    asset_code, asset_name, unit_value, expected, expected_qty, expected_status)
  values (ver, b, licuadora, 'AF-00004', 'Licuadora', 3000, true, 1, 'active');

  v := public.fn_fixed_asset_verification_close(ver, jsonb_build_array(
         jsonb_build_object('asset_id', sillas, 'action', 'mark_lost'),        -- faltaron 2
         jsonb_build_object('asset_id', sillas, 'action', 'apply_condition'),  -- vistas dañadas
         jsonb_build_object('asset_id', horno,  'action', 'set_quantity'),     -- había 2
         jsonb_build_object('asset_id', nevera, 'action', 'move_here')),       -- estaba en Cocina
       'Todo revisado con Jesús');
  s := v->'summary';

  perform test.chk('cerrada', v->>'status' = 'closed' and v->>'closed_by_name' = 'Dueño Penda'
    and v->>'notes' = 'Cierre de mes · Todo revisado con Jesús', v::text);
  perform test.chk('sillas: cantidad 36 con el motivo de la verificación',
    (select quantity from public.fixed_assets where id = sillas) = 36
    and exists (select 1 from public.fixed_asset_movements where asset_id = sillas
                 and event_type = 'quantity_changed' and from_quantity = 38 and to_quantity = 36
                 and notes = 'Faltaron 2 en la verificación #1'));
  perform test.chk('sillas: estado dañado',
    (select status from public.fixed_assets where id = sillas) = 'damaged');
  perform test.chk('horno: cantidad 2', (select quantity from public.fixed_assets where id = horno) = 2);
  perform test.chk('nevera: trasladada a Cocina',
    (select warehouse_id from public.fixed_assets where id = nevera) = cocina);
  perform test.chk('licuadora sin decisión: pendiente y sin tocar',
    (select resolution from public.fixed_asset_verification_lines where verification_id = ver and asset_id = licuadora) = 'pending'
    and (select status from public.fixed_assets where id = licuadora) = 'active');
  perform test.chk('resoluciones', (select jsonb_object_agg(asset_code, resolution)
      from public.fixed_asset_verification_lines where verification_id = ver)
    = '{"MB-001":"lost","AF-00001":"quantity_set","AF-00002":"moved","OL-01":"new","AF-00004":"pending"}'::jsonb,
    (select jsonb_object_agg(asset_code, resolution)::text from public.fixed_asset_verification_lines where verification_id = ver));
  perform test.chk('verificados: horno, sillas, nevera y olla; la licuadora no',
    (select count(*) from public.fixed_assets where last_verification_id = ver) = 4
    and (select last_verified_at from public.fixed_assets where id = licuadora) is null);
  perform test.chk('evento «verificado» con lo encontrado de lo esperado',
    exists (select 1 from public.fixed_asset_movements where asset_id = sillas and event_type = 'verified'
             and verification_id = ver and from_quantity = 38 and to_quantity = 36
             and notes = 'Verificación #1 (Cocina): 36 de 38'));
  perform test.chk('resumen: 3 esperados, 1 fuera de lugar, 1 nuevo, 2 faltantes (2 sillas + licuadora)',
    (s->>'expected_count')::int = 3 and (s->>'misplaced_count')::int = 1 and (s->>'new_count')::int = 1
    and (s->>'missing_count')::int = 2 and (s->>'missing_units')::int = 3
    and (s->>'missing_value')::numeric = 8000 and (s->>'extra_count')::int = 1
    and (s->>'lost_count')::int = 1 and (s->>'pending_count')::int = 1, s::text);
  perform test.chk('cerrada no se toca más',
    test.err(format($q$select public.fn_fixed_asset_verification_check(%L, %L, 1)$q$, ver, horno))
      like 'FIXED_ASSET_VERIFICATION_NOT_OPEN%');
end $$;
SQL

run "lo que no apareció se marca perdido; cancelar" <<'SQL'
do $$
declare
  b uuid := '11111111-1111-1111-1111-111111111111';
  v jsonb; ver uuid; licuadora uuid; plancha uuid;
begin
  select id into licuadora from public.fixed_assets where code = 'AF-00004';
  -- Verificación de TODAS: #2; la licuadora no aparece y se marca perdida.
  v := public.fn_fixed_asset_verification_start(b, null);
  ver := (v->>'id')::uuid;
  perform test.chk('#2 de todas las ubicaciones', (v->>'number')::int = 2
    and v->>'warehouse_name' = 'Todas las ubicaciones' and v->>'warehouse_id' is null);
  perform test.chk('todas: incluye lo que no tiene bodega',
    exists (select 1 from jsonb_array_elements(v->'lines') x where x->>'asset_code' = 'MS-01'));
  perform test.chk('en «todas» no se traslada',
    test.err(format($q$select public.fn_fixed_asset_verification_close(%L, %L)$q$, ver,
      jsonb_build_array(jsonb_build_object('asset_id', licuadora, 'action', 'move_here'))))
      like 'FIXED_ASSET_VERIFICATION_BAD_DECISION%');
  v := public.fn_fixed_asset_verification_close(ver, jsonb_build_array(
         jsonb_build_object('asset_id', licuadora, 'action', 'mark_lost')));
  perform test.chk('licuadora: perdida, con el motivo',
    (select status from public.fixed_assets where id = licuadora) = 'lost'
    and exists (select 1 from public.fixed_asset_movements where asset_id = licuadora
                 and event_type = 'status_changed' and to_status = 'lost'
                 and notes = 'No apareció en la verificación #2'));

  -- #3: cancelar pide motivo; lo dado de alta adentro se queda.
  v := public.fn_fixed_asset_verification_start(b, 'a0000000-0000-0000-0000-000000000001');
  ver := (v->>'id')::uuid;
  v := public.fn_fixed_asset_verification_add_asset(ver, '{"name":"Ventilador"}');
  perform test.chk('cancelar sin motivo: no',
    test.err(format($q$select public.fn_fixed_asset_verification_cancel(%L, '  ')$q$, ver))
      like 'FIXED_ASSET_VERIFICATION_REASON_REQUIRED%');
  v := public.fn_fixed_asset_verification_cancel(ver, 'Se abrió por error');
  perform test.chk('cancelada; el ventilador sigue registrado', v->>'status' = 'cancelled'
    and exists (select 1 from public.fixed_assets where name = 'Ventilador'));
  v := public.fn_fixed_asset_verification_start(b, 'a0000000-0000-0000-0000-000000000001');
  perform test.chk('después de cancelar se puede abrir otra (#4)', (v->>'number')::int = 4
    and not (v->>'resumed')::boolean);
end $$;
SQL

echo "== RLS y grants como 'authenticated'"
Q -c "grant insert, update, delete on public.fixed_asset_verifications, public.fixed_asset_verification_lines to authenticated;" \
  >/dev/null || bad "grants de supabase"
run "aislamiento y escritura solo por RPC" <<'SQL'
begin;
set local test.uid = '99999999-9999-9999-9999-999999999999';
set local role authenticated;
do $$
declare v_msg text;
begin
  perform test.chk('B1 ve sus verificaciones y líneas',
    (select count(*) from public.fixed_asset_verifications) = 4
    and (select count(*) from public.fixed_asset_verification_lines) > 0);
  v_msg := test.err($q$insert into public.fixed_asset_verifications (business_id, number, warehouse_name)
    values ('11111111-1111-1111-1111-111111111111', 99, 'x')$q$);
  perform test.chk('insert directo rechazado por RLS', v_msg like '%row-level security%', coalesce(v_msg, 'pasó'));
  v_msg := test.err($q$update public.fixed_asset_verification_lines set found_qty = 999$q$);
  perform test.chk('update directo no toca nada', v_msg is null
    and not exists (select 1 from public.fixed_asset_verification_lines where found_qty = 999));
  v_msg := test.err($q$select public.fn_fixed_asset_verification_lock(gen_random_uuid())$q$);
  perform test.chk('el candado interno no es API', v_msg like 'permission denied%', coalesce(v_msg, 'pasó'));
  v_msg := test.err($q$select public.fn_fixed_asset_parse_quantity('3')$q$);
  perform test.chk('el parser interno no es API', v_msg like 'permission denied%', coalesce(v_msg, 'pasó'));
  perform test.chk('el RPC funciona con el rol authenticated',
    (public.fn_fixed_asset_create('11111111-1111-1111-1111-111111111111', '{"name":"Caja fuerte","quantity":1}')->>'code') like 'AF-%');
end $$;
commit;
begin;
set local test.uid = '66666666-6666-6666-6666-666666666666';
set local role authenticated;
do $$ begin
  perform test.chk('B2 no ve nada de B1',
    (select count(*) from public.fixed_asset_verifications) = 0
    and (select count(*) from public.fixed_asset_verification_lines) = 0);
end $$;
commit;
begin;
set local role anon;
do $$
declare v_msg text;
begin
  v_msg := test.err($q$select public.fn_fixed_asset_verification_start('11111111-1111-1111-1111-111111111111', null)$q$);
  perform test.chk('anon no ejecuta', v_msg like 'permission denied%', coalesce(v_msg, 'pasó'));
end $$;
commit;
SQL

echo "== Rollback"
run_fails "se niega con datos de esta migración" "ROLLBACK_BLOCKED" -f "$RB"
Q -c "delete from public.fixed_asset_verifications;
      delete from public.fixed_asset_movements where event_type in ('quantity_changed','verified');
      update public.fixed_assets set quantity = 1;" || bad "limpiar datos"
run "aplica sin datos" -f "$RB"
run "vuelve a la 0052" <<'SQL'
do $$
declare v jsonb;
begin
  perform test.chk('sin tablas de verificación', to_regclass('public.fixed_asset_verifications') is null
    and to_regclass('public.fixed_asset_verification_lines') is null);
  perform test.chk('sin columna quantity', not exists (select 1 from information_schema.columns
    where table_name = 'fixed_assets' and column_name = 'quantity'));
  perform test.chk('historia con la firma de la 0052',
    to_regprocedure('public.fn_fixed_asset_log(uuid,uuid,text,uuid,uuid,text,text,uuid,uuid,text,text,text,jsonb)') is not null
    and (select count(*) from pg_proc where proname = 'fn_fixed_asset_log') = 1);
  perform test.chk('helpers fuera', to_regprocedure('public.fn_fixed_asset_parse_quantity(text)') is null);
  -- El alta de la 0052 funciona otra vez (sin cantidad, con AF).
  v := public.fn_fixed_asset_create('11111111-1111-1111-1111-111111111111', '{"name":"Después del rollback"}');
  perform test.chk('alta de la 0052 funciona', v->>'code' like 'AF-%' and not (v ? 'quantity'), v::text);
  perform test.chk('los códigos propios siguen', exists (select 1 from public.fixed_assets where code = 'MB-001'));
end $$;
SQL
run "se puede volver a aplicar" -f "$MIG"

echo
if [ "$FAIL" = 0 ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit $FAIL
