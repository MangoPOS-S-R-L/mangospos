#!/bin/bash
# Ensayo de UNIF_0_diagnostico / UNIF_1_aplicar / UNIF_9_deshacer contra un
# Postgres 15 DESECHABLE (stub_unif.sql + fixture_unif.py). No toca bases reales.
#
#   bash ensayo/run_tests_unif.sh [carpeta_trabajo]
#
# La salida de psql va a archivos: NUNCA por `head` (SIGPIPE mata psql antes
# del commit y parece un bug).
set -u
B=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55473}
S="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$S/.." && pwd)"
W=${1:-$(mktemp -d)}
mkdir -p "$W/gen" "$W/log"

rm -rf "$W/pg"
$B/initdb -D "$W/pg" -U postgres --auth=trust >/dev/null || exit 1
$B/pg_ctl -D "$W/pg" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories='' -c timezone=UTC" \
  -l "$W/pg.log" -w start >/dev/null || { cat "$W/pg.log"; exit 1; }
trap '$B/pg_ctl -D "$W/pg" stop -m fast >/dev/null 2>&1' EXIT
export PGHOST=127.0.0.1 PGPORT=$PORT PGUSER=postgres PGCLIENTENCODING=UTF8
PSQL="$B/psql -X -q -v ON_ERROR_STOP=1"

( cd "$R" && python3 build_unificar_almacen.py --out "$W/gen" ) || exit 1
python3 "$S/fixture_unif.py" > "$W/fixture.sql" || exit 1

BIZ=85924083-2e8e-4e64-8192-808ee24674ed
P=a0000000-0000-0000-0000-000000000001
A=a0000000-0000-0000-0000-000000000002
C=a0000000-0000-0000-0000-000000000003
FAIL=0; PASS=0
fresh() { $B/dropdb --if-exists "$1" 2>/dev/null; $B/createdb "$1"
          $PSQL -d "$1" -f "$S/stub_unif.sql" >/dev/null && $PSQL -d "$1" -f "$W/fixture.sql" >/dev/null; }
sql()   { $PSQL -d "$1" -Atc "$2"; }
run()   { $PSQL -A -F ' | ' -d "$1" -f "$2" > "$W/log/$3.log" 2>&1; echo $?; }
eq()    { if [ "$2" == "$3" ]; then PASS=$((PASS+1)); echo "   ✓ $1"; else FAIL=$((FAIL+1)); echo "   ✗ $1: esperado [$3] obtuve [$2]"; fi; }
has()   { if grep -q -- "$3" "$W/log/$2.log"; then PASS=$((PASS+1)); echo "   ✓ $1"; else FAIL=$((FAIL+1)); echo "   ✗ $1: no aparece [$3] en $2.log"; sed 's/^/      /' "$W/log/$2.log" | tail -5; fi; }
qty()   { sql "$1" "select coalesce((select quantity from inventory_stock s join inventory_items i on i.id=s.item_id
                    where s.warehouse_id='$2' and i.business_id='$BIZ' and (i.sku='$3' or i.barcode='$3')),0)::numeric(12,2)"; }
huella(){ sql "$1" "select md5(string_agg(warehouse_id::text||item_id::text||quantity::numeric(14,4), ',' order by warehouse_id, item_id))
                    ||'/'||(select count(*) from inventory_movements)
                    ||'/'||(select string_agg(name||is_active||is_main||shows_in_pos, ',' order by name) from warehouses)
                    from inventory_stock"; }
apply() { run "$1" "$W/gen/UNIF_1_aplicar.sql" "$2"; }

echo "S1 · diagnóstico sobre la base (solo lee)"
fresh s1; H0=$(huella s1)
eq "diagnóstico corre" "$(run s1 "$W/gen/UNIF_0_diagnostico.sql" s1_diag)" 0
eq "no cambió nada" "$(huella s1)" "$H0"
has "ve la principal y su nombre nuevo" s1_diag "CAFETERIA  ◀ PRINCIPAL (aquí cae la venta) → «Almacén Principal»"
has "corte 11:55" s1_diag "ventas descontadas desde | 01/10/2026 11:55 (hora RD)"
has "PC-0004 a las 14:24" s1_diag "completed · congelado 01/10/2026 14:24"
has "PC-0002 se cancela" s1_diag "PC-2026-000002 (in_progress) → el aplicar lo CANCELA"
has "Almacen Cocina se apaga" s1_diag "Almacen Cocina  → se apaga"
has "cruce: 196 líneas, 195 encontradas, 1 no existe" s1_diag "196 líneas · encontradas 195 · no existen 1 · ambiguas 0"
has "PC-0004 cuadra con la columna almacén" s1_diag "0 diferencias"
has "PC-0004 coincide en almacén (97 sin BEEFEATER... con alm>0)" s1_diag "CAMPAÑA 01-OCT"
has "referencia: orden de compra a ALMACEN" s1_diag "purchase_orders.warehouse_id"
has "aviso: 1 orden abierta fuera de la principal" s1_diag "órdenes abiertas con consumo fuera de la principal | 1"
has "venta antes del corte" s1_diag "a) antes del corte | 1 movimientos, 2.00 u"
has "venta entre 11:55 y 14:24" s1_diag "b) después del corte, mismo día | 1 movimientos, 1.00 u"
has "anulación de recepción a la vista" s1_diag "adjustment / direct_receipt_cancel / correction"
has "negativo previsto CHIVA" s1_diag "CHIVA 18 BOTELLA (contado 1, tras corte -3)"
cp "$W/log/s1_diag.log" "$W/diagnostico_base.txt"

echo "S2 · aplicar"
eq "aplicar corre" "$(apply s1 s2)" 0
has "reporte: verificación" s2 "✓ otras bodegas en 0"
eq "BARRAS = 53 − 1 − 5 − 2 + 10 (la de las 11:00 no)" "$(qty s1 $P 016000264694)" "55.00"
eq "STOLI (por barras) = 6 + 6 − 6 − 1 (anulación no frena)" "$(qty s1 $P 4750021000157)" "5.00"
eq "CHIVA = 1 − 3" "$(qty s1 $P 5000299225028)" "-2.00"
eq "GOMITAS = 141 − 4 − 1" "$(qty s1 $P 034856008187)" "136.00"
eq "MICHELOB = 546 (transferencia neta 0)" "$(qty s1 $P 01833225)" "546.00"
eq "no contado U1 = 7 − 2" "$(qty s1 $P ZZ-U1)" "5.00"
eq "no contado U2 = −3" "$(qty s1 $P ZZ-U2)" "-3.00"
eq "un código sin cantidad de almacén (cafetería pura) = su cafetería" \
   "$(qty s1 $P 016000439894)" "8.00"
eq "ALMACEN y BARRA en 0" "$(sql s1 "select count(*) from inventory_stock where warehouse_id in ('$A','$C') and quantity<>0")" 0
eq "una sola bodega activa (+ tránsito), renombrada" "$(sql s1 "select string_agg(name, ',' order by name) from warehouses where is_active")" "Almacén Principal,__IN_TRANSIT__"
eq "nadie más en POS ni principal" "$(sql s1 "select count(*) from warehouses where name<>'Almacén Principal' and (shows_in_pos or is_main)")" 0
eq "PC-0002 cancelado con motivo" "$(sql s1 "select status||'/'||(cancellation_reason is not null) from physical_count_sessions where code='PC-2026-000002'")" "cancelled/true"
has "reporte: conteo cancelado" s2 "Conteo abandonado cancelado | PC-2026-000002"
has "reporte: renombre" s2 "Almacén Principal (antes «CAFETERIA»)"
eq "capas UEPS = existencia en cada contado de la principal" "$(sql s1 "select count(*) from (select s.item_id from inventory_stock s left join inventory_cost_layers l on l.warehouse_id=s.warehouse_id and l.item_id=s.item_id where s.warehouse_id='$P' group by s.item_id, s.quantity having coalesce(sum(l.quantity_remaining),0) <> greatest(s.quantity,0)) z")" 0
eq "bodegas apagadas sin capas (también la de saldo negativo)" "$(sql s1 "select coalesce(sum(quantity_remaining),0)::numeric(12,2) from inventory_cost_layers where warehouse_id in ('$A','$C')")" "0.00"
eq "en la principal solo se netearon capas de esta corrida" "$(sql s1 "select count(*) from inventory_cost_layers l left join inventory_movements m on m.id=l.source_movement_id where l.warehouse_id='$P' and l.notes like 'neteada%' and coalesce(m.reference_type,'') not like 'unificacion_almacen%'")" 0
eq "la capa vieja de la principal (compra de BARRAS) no se tocó" "$(sql s1 "select count(*) from inventory_cost_layers l join inventory_movements m on m.id=l.source_movement_id where l.warehouse_id='$P' and m.movement_type='purchase' and l.notes is not null")" 0
has "reporte: capas" s2 "Capas de costo (lifo) | neteadas"
eq "bandera de secciones sigue apagada" "$(sql s1 "select warehouse_sections_enabled from business_settings")" f
eq "consume llamado solo para la orden abierta" "$(sql s1 "select string_agg(order_id::text, ',') from _consume_calls")" "d0000000-0000-0000-0000-000000000001"
eq "orden de compra pendiente → principal" "$(sql s1 "select count(*) from purchase_orders where warehouse_id='$P'")" 1
has "reporte: compras" s2 "Órdenes de compra pendientes pasadas a la principal | 1"
eq "otro negocio intacto" "$(sql s1 "select count(*) from inventory_stock s join inventory_items i on i.id=s.item_id where i.name='OTRO NEGOCIO'")" 0
eq "total contados = Σ(total+post)" "$(sql s1 "select sum(quantity)::numeric(12,2) from inventory_stock s join inventory_items i on i.id=s.item_id where s.warehouse_id='$P' and i.sku not like 'ZZ-%'")" \
   "$(python3 - "$W/gen/UNIF_1_aplicar.sql" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
tot=sum(float(m.group(1)) for m in re.finditer(r"^    \('(?!5000329002230)[^']*', '(?:[^']|'')*', [\d.]+, [\d.]+, ([\d.]+)\)", s, re.M))
print(f"{tot-8+10-1-3-5:.2f}")
PY
)"
eq "kardex: ajustes por conteo con razón physical_count" "$(sql s1 "select count(*) from inventory_movements where reference_type='unificacion_almacen_20261013_conteo' and reason_code='physical_count'")" \
   "$(sql s1 "select count(*) from inventory_movements where reference_type='unificacion_almacen_20261013_conteo'")"
eq "negativos se mudan como ajuste de corrección" "$(sql s1 "select count(*) from inventory_movements where reference_type='unificacion_almacen_20261013' and movement_type='adjustment' and reason_code='correction'")" 10
cp "$W/log/s2.log" "$W/reporte_aplicar.txt"
H1=$(huella s1)

echo "S3 · volver a aplicar → se niega"
eq "aborta" "$(apply s1 s3)" 3
has "mensaje" s3 "YA SE CORRIÓ"
eq "no cambió nada" "$(huella s1)" "$H1"

echo "S4 · diagnóstico después de aplicar"
eq "corre" "$(run s1 "$W/gen/UNIF_0_diagnostico.sql" s4)" 0
has "vista previa: ajuste neto 0" s4 "ajuste neto 0.00 u (+0.00 / 0.00)"

echo "S5 · deshacer"
fresh s5; apply s5 s5a >/dev/null
fresh base; HB=$(sql base "select md5(string_agg(warehouse_id::text||item_id::text||quantity::numeric(14,4), ',' order by warehouse_id, item_id)) from inventory_stock where warehouse_id='$A'")
eq "deshacer corre" "$(run s5 "$W/gen/UNIF_9_deshacer.sql" s5b)" 0
eq "ALMACEN vuelve exacto" "$(sql s5 "select md5(string_agg(warehouse_id::text||item_id::text||quantity::numeric(14,4), ',' order by warehouse_id, item_id)) from inventory_stock where warehouse_id='$A'")" "$HB"
eq "bodegas como antes" "$(sql s5 "select string_agg(name||is_active||is_main||shows_in_pos, ',' order by name) from warehouses")" \
   "$(sql base "select string_agg(name||is_active||is_main||shows_in_pos, ',' order by name) from warehouses")"
eq "orden de compra vuelve a ALMACEN" "$(sql s5 "select count(*) from purchase_orders where warehouse_id='$A'")" 1
eq "PC-0002 sigue cancelado" "$(sql s5 "select status from physical_count_sessions where code='PC-2026-000002'")" cancelled
eq "totales por ítem = antes" "$(sql s5 "select md5(string_agg(item_id::text||q::numeric(14,4), ',' order by item_id)) from (select item_id, sum(quantity) q from inventory_stock s join warehouses w on w.id=s.warehouse_id where w.name<>'__IN_TRANSIT__' group by 1 having sum(quantity)<>0) z")" \
   "$(sql base "select md5(string_agg(item_id::text||q::numeric(14,4), ',' order by item_id)) from (select item_id, sum(quantity) q from inventory_stock s join warehouses w on w.id=s.warehouse_id where w.name<>'__IN_TRANSIT__' group by 1 having sum(quantity)<>0) z")"
eq "BARRA: igual salvo la orden abierta (+4 gomitas que ahora salen de la principal)" \
   "$(qty s5 $C 034856008187)" "$(sql base "select (quantity+4)::numeric(12,2) from inventory_stock s join inventory_items i on i.id=s.item_id where s.warehouse_id='$C' and i.sku='034856008187'")"
eq "deshacer dos veces → se niega" "$(run s5 "$W/gen/UNIF_9_deshacer.sql" s5c)" 3
has "mensaje" s5c "No hay nada que deshacer"

echo "S6 · aplicar después de deshacer → mismo resultado que S2"
eq "corre" "$(apply s5 s6)" 0
eq "BARRAS" "$(qty s5 $P 016000264694)" "55.00"
eq "GOMITAS" "$(qty s5 $P 034856008187)" "136.00"
eq "U1" "$(qty s5 $P ZZ-U1)" "5.00"
eq "mismas existencias que S2" "$(sql s5 "select md5(string_agg(warehouse_id::text||item_id::text||quantity::numeric(14,4), ',' order by warehouse_id, item_id)) from inventory_stock where quantity<>0")" \
   "$(sql s1 "select md5(string_agg(warehouse_id::text||item_id::text||quantity::numeric(14,4), ',' order by warehouse_id, item_id)) from inventory_stock where quantity<>0")"

guard() { # nombre, sql de preparación, texto esperado
  fresh g; sql g "$2" >/dev/null; local h; h=$(huella g)
  local rc; rc=$(apply g "g_$1")
  eq "$1 · aborta" "$rc" 3
  has "$1 · mensaje" "g_$1" "$3"
  eq "$1 · no cambió nada" "$(huella g)" "$h"
}
echo "S7 · guardias"
guard conteo_abierto "insert into physical_count_sessions (business_id, warehouse_id, code, status) values ('$BIZ','$C','PC-2026-000009','in_progress')" "Hay conteos abiertos"
guard abandonado_otro_dia "update physical_count_sessions set frozen_at='2026-10-05 10:00-04' where code='PC-2026-000002'" "Hay conteos abiertos: PC-2026-000002"
guard nombre_ocupado "update warehouses set name='Almacén Principal' where id='$A'" "Ya hay otra bodega llamada"
guard conteo_posterior "insert into physical_count_sessions (business_id, warehouse_id, code, status, frozen_at, completed_at) values ('$BIZ','$C','PC-2026-000005','completed','2026-10-05 10:00-04','2026-10-05 11:00-04')" "DESPUÉS del 01-oct"
guard transferencia "insert into stock_transfers (business_id, from_warehouse_id, to_warehouse_id, transfer_number, status) values ('$BIZ','$A','$P','TR-2','sent')" "transferencias sin cerrar"
guard dos_principales "update warehouses set is_main=true where id='$A'" "Se esperaba UNA bodega principal"
guard sin_principal "update warehouses set is_main=false where id='$P'" "Se esperaba UNA bodega principal"
guard sin_conteo_almacen "update physical_count_sessions set code='PC-OTRO' where code='PC-2026-000004'" "No está el conteo PC-2026-000004"
guard ambiguo "insert into inventory_items (business_id, sku, name) values ('$BIZ','016000264694','DUPLICADO')" "ambiguos"
guard mismo_insumo "update inventory_items set sku='X-CHIVA' where sku='5000299225028'; update inventory_items set barcode='5000299225028' where sku='016000264694'" "MISMO insumo"
guard ajuste_manual "insert into inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity, reference_type, reason_code, created_at) select '$BIZ','$C',id,'adjustment',20,'stock_adjustment','correction','2026-10-02 09:00-04' from inventory_items where sku='016000264694' and business_id='$BIZ'" "AJUSTES MANUALES"
guard ajuste_manual_sin_ref "insert into inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity, reason_code, created_at) select '$BIZ','$C',id,'adjustment',20,'correction','2026-10-02 09:00-04' from inventory_items where sku='016000264694' and business_id='$BIZ'" "AJUSTES MANUALES"
guard negocio_equivocado "delete from physical_count_lines; delete from inventory_stock; delete from inventory_movements; delete from inventory_items where sku ~ '^[0-9]{6}'" "es el negocio correcto"

echo "S8 · ajuste manual con AJUSTES_MANUALES = sumar / ignorar"
for modo in sumar ignorar; do
  sed "s/AJUSTES_MANUALES constant text := 'abortar'/AJUSTES_MANUALES constant text := '$modo'/" "$W/gen/UNIF_1_aplicar.sql" > "$W/gen/aplicar_$modo.sql"
  fresh m; sql m "insert into inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity, reason_code, created_at) select '$BIZ','$C',id,'adjustment',20,'correction','2026-10-02 09:00-04' from inventory_items where sku='016000264694' and business_id='$BIZ'" >/dev/null
  eq "$modo · corre" "$(run m "$W/gen/aplicar_$modo.sql" "m_$modo")" 0
  if [ $modo == sumar ]; then eq "sumar · BARRAS = 55 + 20" "$(qty m $P 016000264694)" "75.00"
  else eq "ignorar · BARRAS = 55" "$(qty m $P 016000264694)" "55.00"; fi
done

echo "S9 · costeo last_price: no hay capas que netear"
fresh lp; sql lp "update business_settings set inventory_costing_method='last_price'; delete from inventory_cost_layers" >/dev/null
eq "corre" "$(apply lp s9)" 0
has "reporte: motor apagado" s9 "motor apagado"
eq "sin capas" "$(sql lp "select count(*) from inventory_cost_layers")" 0
eq "BARRAS igual" "$(qty lp $P 016000264694)" "55.00"

echo
echo "RESULTADO: $PASS ✓ · $FAIL ✗   (trabajo en $W)"
[ $FAIL -eq 0 ]
