#!/usr/bin/env bash
# Manda un pedido de prueba al endpoint de Pincer, firmado como lo hara ellos.
#
# POR QUE UN SCRIPT: la firma va sobre el cuerpo CRUDO. Armarla a mano en la
# terminal es como se pierde media hora: basta un espacio de mas, que la shell
# expanda algo, o que el cuerpo que se firma no sea byte por byte el que se
# manda, para recibir un 401 que parece de credencial y no lo es.
#
# Uso:
#   export PINCER_API_KEY='mgp_sand_...'
#   export PINCER_SECRET='...'
#   export PINCER_MENU_ITEM='<uuid de un producto del negocio>'
#   ./scripts/test_pincer_order.sh                  # pedido en efectivo
#   ./scripts/test_pincer_order.sh --paid           # pedido ya cobrado, con propina
#   ./scripts/test_pincer_order.sh --catalog        # solo lee el catalogo
#   ./scripts/test_pincer_order.sh --status pnc_x   # estado de un pedido
#
# El id del pedido lleva un sufijo de tiempo para no chocar con la idempotencia.
# Para PROBAR la idempotencia, pasa el mismo id dos veces:
#   PINCER_ORDER_ID=pnc_fijo ./scripts/test_pincer_order.sh

set -euo pipefail

BASE="${PINCER_BASE:-https://supabase.mangopos.do/functions/v1}"
KEY="${PINCER_API_KEY:?falta PINCER_API_KEY}"
SECRET="${PINCER_SECRET:?falta PINCER_SECRET}"

sign() {  # sign <cuerpo> -> imprime el header de firma
  local body="$1" t sig
  t=$(date +%s)
  sig=$(printf '%s' "${t}.${body}" \
        | openssl dgst -sha256 -hmac "$SECRET" -hex \
        | sed 's/^.*= //')
  printf 't=%s,v1=%s' "$t" "$sig"
}

case "${1:-}" in
  --catalog)
    echo "GET $BASE/pincer-catalog"
    curl -sS -D- -o /tmp/pincer-catalog.json \
      -H "X-Api-Key: $KEY" \
      -H "X-Pincer-Signature: $(sign '')" \
      "$BASE/pincer-catalog" | head -1
    echo "Productos: $(grep -o '"id"' /tmp/pincer-catalog.json | wc -l | tr -d ' ')"
    echo "Guardado en /tmp/pincer-catalog.json"
    exit 0
    ;;
  --status)
    ID="${2:?falta el external_order_id}"
    curl -sS -H "X-Api-Key: $KEY" -H "X-Pincer-Signature: $(sign '')" \
      "$BASE/pincer-orders/$ID"
    echo
    exit 0
    ;;
esac

ITEM="${PINCER_MENU_ITEM:?falta PINCER_MENU_ITEM (uuid de un producto)}"
ORDER_ID="${PINCER_ORDER_ID:-pnc_test_$(date +%s)}"

# OJO con el monto: `fn_process_payment_v3` tiene un guard de cobertura que
# RECHAZA el cobro si lo pagado no cubre los items (tolerancia: 3% o RD$5). Si
# PINCER_SUBTOTAL queda por debajo del precio real del producto, el pedido entra
# igual pero con payment_state='failed'. Eso NO es un bug: es el POS negandose a
# cerrar una venta cobrada de menos.
SUBTOTAL="${PINCER_SUBTOTAL:-1000.00}"
TIP="${PINCER_TIP:-50.00}"
TOTAL=$(awk -v a="$SUBTOTAL" -v b="$TIP" 'BEGIN{printf "%.2f", a+b}')

if [[ "${1:-}" == "--paid" ]]; then
  PAYMENT="{\"status\":\"paid\",\"subtotal\":${SUBTOTAL},\"tip_amount\":${TIP},\"total\":${TOTAL},\"method\":\"card\",\"reference\":\"azul-prueba-001\"}"
else
  PAYMENT="{\"status\":\"pending\",\"total\":${SUBTOTAL}}"
fi

# Una sola linea, sin saltos: lo que se firma es EXACTAMENTE lo que se manda.
BODY="{\"external_order_id\":\"${ORDER_ID}\",\"external_number\":\"901\",\"service_type\":\"delivery\",\"accepted_by\":\"prueba@pincer\",\"customer\":{\"name\":\"Cliente de Prueba\",\"phone\":\"809-000-0000\",\"address\":\"Prueba, no despachar\"},\"payment\":${PAYMENT},\"lines\":[{\"menu_item_id\":\"${ITEM}\",\"quantity\":1,\"notes\":\"PEDIDO DE PRUEBA\"}]}"

echo "POST $BASE/pincer-orders"
echo "Pedido: $ORDER_ID"
echo
curl -sS -w '\nHTTP %{http_code}\n' \
  -X POST "$BASE/pincer-orders" \
  -H "X-Api-Key: $KEY" \
  -H "X-Pincer-Signature: $(sign "$BODY")" \
  -H "Content-Type: application/json" \
  -d "$BODY"
