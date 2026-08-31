#!/usr/bin/env bash
# Prueba de la API de lectura de LA PENDA EXPRESS.
# Solo hace GET: no modifica nada. Corre desde cualquier maquina con internet.
#
#   ./scripts/probar_api_penda.sh [desde] [hasta]
#   ./scripts/probar_api_penda.sh 2026-07-01 2026-07-31
#
# La key se puede pasar por entorno:  PENDA_API_KEY=... ./scripts/probar_api_penda.sh
# Sirve tambien como prueba de humo para entregarle al cliente.

KEY="${PENDA_API_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJvbGUiOiJhbmFseXRpY3Nfcm8iLCJzdWIiOiI1NzliZjE5MS00ZjYxLTQ4MjEtODE5Zi1kYTZhYjFkYTlmMzIiLCJhdWQiOiJhdXRoZW50aWNhdGVkIiwiaWF0IjoxNzg4MTMwNTYwLCJleHAiOjE4MTk2NjY1NjB9.3ohm8ImlX61bARXvKHXP4QDc5IaC9LpqyAcMNhjrPp8}"
ANON='eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJzdXBhYmFzZSIsImlhdCI6MTc3MjgzOTUwMCwiZXhwIjo0OTI4NTEzMTAwLCJyb2xlIjoiYW5vbiJ9.LHw1pkCZ3DySAmly08hFoykgbG0CCC7k7Igh2izbCAg'
BASE='https://supabase.mangopos.do/rest/v1'
NEGOCIO='35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
H=(-H "apikey: $ANON" -H "Authorization: Bearer $KEY" -H "Accept-Profile: analytics")
DESDE="${1:-2026-08-01}"; HASTA="${2:-2026-08-31}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "MangoPOS - API de lectura - LA PENDA EXPRESS"
echo "Periodo: $DESDE a $HASTA"
echo

echo "1) Conexion"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$BASE/documentos?limit=1" "${H[@]}")
if [ "$code" = "200" ]; then echo "   OK (HTTP 200)"; else echo "   FALLO (HTTP $code)"; exit 1; fi

echo
echo "2) Primeras facturas del periodo"
curl -s --max-time 60 "$BASE/documentos?FECHA=gte.$DESDE&FECHA=lte.$HASTA&limit=5&order=NUMERO.asc" \
     "${H[@]}" > "$TMP/muestra.json"
python3 - "$TMP/muestra.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1]))
cab = '   %-20s%11s%12s  %-24s%11s%10s%9s%11s'
print(cab % ('TIPO', 'NUMERO', 'FECHA', 'CLIENTE', 'BRUTO', 'ITBIS', 'LEY', 'TOTAL'))
for r in d:
    print('   %-20s%11s%12s  %-24s%11s%10s%9s%11s' % (
        r['TIPO_DOC'], r['NUMERO'], r['FECHA'], r['NOMBRE'][:23],
        format(float(r['BRUTO']), ',.2f'), format(float(r['ITBIS']), ',.2f'),
        format(float(r['LEY']), ',.2f'), format(float(r['TOTAL']), ',.2f')))
PY

echo
echo "3) Resumen del periodo y comprobacion de cuadre"
curl -s --max-time 120 "$BASE/documentos?FECHA=gte.$DESDE&FECHA=lte.$HASTA&limit=50000" \
     "${H[@]}" > "$TMP/todo.json"
python3 - "$TMP/todo.json" <<'PY'
import sys, json, collections
d = json.load(open(sys.argv[1]))
num = lambda x: float(x or 0)
por = collections.defaultdict(lambda: [0, 0.0])
for r in d:
    por[r['TIPO_DOC']][0] += 1
    por[r['TIPO_DOC']][1] += num(r['TOTAL'])
for t in sorted(por):
    n, m = por[t]
    print('   %-22s%7d docs   RD$ %16s' % (t, n, format(m, ',.2f')))
b = sum(num(r['BRUTO']) for r in d); i = sum(num(r['ITBIS']) for r in d)
l = sum(num(r['LEY']) for r in d);   t = sum(num(r['TOTAL']) for r in d)
pct = lambda v: (100 * v / b) if b else 0
print()
print('   %-22s          RD$ %16s' % ('BRUTO (base)', format(b, ',.2f')))
print('   %-22s          RD$ %16s   %.2f%% del bruto' % ('ITBIS', format(i, ',.2f'), pct(i)))
print('   %-22s          RD$ %16s   %.2f%% del bruto' % ('LEY 10%', format(l, ',.2f'), pct(l)))
print('   %-22s          RD$ %16s' % ('TOTAL', format(t, ',.2f')))
mal = [r for r in d if abs(num(r['BRUTO']) + num(r['ITBIS']) + num(r['LEY']) - num(r['TOTAL'])) > 0.01]
print()
msg = '   BRUTO + ITBIS + LEY = TOTAL  ->  %d de %d cuadran' % (len(d) - len(mal), len(d))
print(msg if not mal else msg + '   *** %d NO CUADRAN ***' % len(mal))
PY

echo
echo "4) Exportacion a CSV (para Excel)"
curl -s --max-time 60 "$BASE/documentos?FECHA=gte.$DESDE&FECHA=lte.$HASTA&limit=3" \
     "${H[@]}" -H "Accept: text/csv" | sed 's/^/   /'

echo
echo "5) Seguridad: la key es de SOLO LECTURA"
for m in PATCH DELETE; do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X $m \
      "$BASE/customers?id=eq.00000000-0000-0000-0000-000000000000" "${H[@]}" \
      -H 'Content-Type: application/json' -d '{"name":"x"}')
  if [ "$c" = "403" ]; then echo "   $m rechazado (HTTP 403)  OK"
  else echo "   $m devolvio HTTP $c  *** REVISAR ***"; fi
done
curl -s --max-time 60 "$BASE/documentos_detalle?business_id=neq.$NEGOCIO&select=documento_id" \
     "${H[@]}" > "$TMP/ajenas.json"
n=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$TMP/ajenas.json")
if [ "$n" = "0" ]; then echo "   Datos de otros negocios: 0 filas  OK"
else echo "   *** FUGA: $n filas de otros negocios ***"; fi
