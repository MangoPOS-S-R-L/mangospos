# Validar Azul desde localhost (sandbox)

Azul (2026-06-09) confirmó que **no** whitelistean la IP del VPS en pruebas y que el
bloqueo de Incapsula **solo ocurre en el ambiente de pruebas**. La forma de probar es
**desde tu localhost o una IP pública que no sea la del servidor**. En producción ese
bloqueo no aplica.

> **Secretos:** ningún valor real (AZUL_AUTH_KEY, AuthKey de producción, service_role)
> va en este archivo ni en el repo. Usa tus valores reales solo en tu shell/`.env.local`.
> En pruebas, `Auth1/Auth2 = splitit/splitit` son placeholders públicos de sandbox.

---

## Dos caminos a Azul (importante)

| Camino | POST lo hace | Endpoint | Incapsula |
|---|---|---|---|
| **Payment Page** (tokenizar) | el navegador del cliente | `pruebas.azul.com.do/PaymentPage/` | no bloquea (browser real) |
| **Web Services mTLS** (cobro, VerifyPayment) | el `azul-proxy` (servidor) | `pruebas.azul.com.do/webservices/JSON/...` | **bloqueaba** la IP del VPS |

El correo de Azul aplica al **segundo** camino. La tokenización (primer camino) es flujo de
navegador y se puede probar ya.

---

## TRACK 1 — Smoke test mTLS desde localhost (el camino que Azul desbloqueó)

Prueba directa proxy → Azul. No necesita Supabase ni edge functions.

### Requisitos
- Node 18+ (el proxy no tiene dependencias npm).
- El **cert + key** firmados por BPD-SCA en tu máquina local (cópialos del VPS:
  `/data/coolify/services/<id>/volumes/azul-certs/`). Protégelos: `chmod 600 la key`.

### Correr el proxy localmente
```bash
cd supabase/azul-proxy

AZUL_PROXY_AUTH_TOKEN=local-test-token \
AZUL_API_URL=https://pruebas.azul.com.do/webservices/JSON/Default.aspx \
AZUL_AUTH1=splitit \
AZUL_AUTH2=splitit \
AZUL_CERT_PATH=/ruta/local/mangopos-azul.crt \
AZUL_KEY_PATH=/ruta/local/mangopos-azul.key \
node index.js
# Esperado: "[azul-proxy] loaded cert (...) and key (...)"
#           "[azul-proxy] listening on 0.0.0.0:3000 → pruebas.azul.com.do (mTLS)"
```

### Pegarle a Azul (en otra terminal)
```bash
curl -s -X POST http://localhost:3000/call \
  -H "Content-Type: application/json" \
  -H "x-proxy-auth: local-test-token" \
  -d '{"method":"VerifyPayment","body":{"Channel":"EC","Store":"39038540035","CustomOrderId":"mp_smoketest_local"}}' | jq
```

### Cómo leer el resultado
| Resultado | Significa |
|---|---|
| `{ "ok": ..., "httpStatus": 200, "body": { "IsoCode": "00", "Found": "0" } }` | ✅ Pasamos Incapsula **y** VerifyPayment funciona. Camino mTLS validado. |
| `httpStatus: 200` con `IsoCode` distinto / otro body JSON | ✅ Pasamos Incapsula; el método responde (revisar payload). |
| `httpStatus: 500` / `NotImplementedException` / HTML ASP.NET | 🟡 **Pasamos Incapsula** (llegó al backend Azul) pero la firma de VerifyPayment no es la correcta → pendiente que Azul aclare el método. |
| `error.code: upstream_error` con `detail.httpStatus: 403`, o body con `incident_id` / `_Incapsula_` / `visid_incap` | ❌ Incapsula sigue bloqueando esta IP. Probar desde otra IP pública (no VPS, no la misma red). |
| `error.code: network_error` / TLS | ❌ Problema de cert/key o red, no de Incapsula. |

El log del proxy imprime `status=... headers=...` de cada call — ahí se ve el WAF.

---

## TRACK 2 — Tokenización E2E con tarjeta (Payment Page, navegador)

Valida: crear sesión → form → Azul Payment Page → callback → `azul_payment_methods` verificado → void del Hold.

### Pre-requisitos
1. Migración `20260526_0002_azul_subscriptions_schema.sql` aplicada en el Supabase contra
   el que vas a probar (las 5 tablas `azul_*` + `plans`).
2. Edge functions corriendo. Dos opciones:
   - **Deploy al VPS** (HTTPS real para el callback) — recomendado, porque Azul suele
     rechazar `ApprovedUrl` en `http://localhost`. El navegador (tu IP residencial) hace el
     POST a Azul → pasa Incapsula. Solo el `void-hold` corre desde el VPS (ver nota).
   - **Local** (`supabase functions serve`) — solo si Azul acepta callback a `localhost`.
3. Un `business_id` real donde tu usuario sea `owner`/`admin`, y tu JWT de Supabase.

### Variables de entorno que necesitan las functions
Requeridas por [`env.ts`](functions/_shared/env.ts) (aunque la tokenización no use el proxy,
`getAzulEnv()` valida todo de una):
```
AZUL_ENV=test
AZUL_MERCHANT_ID=39038540035
AZUL_MERCHANT_NAME=MangoPOS
AZUL_MERCHANT_TYPE=ECommerce
AZUL_CURRENCY_CODE=$
AZUL_AUTH_KEY=<AuthKey de Payment Page de Azul — SECRETO>   # imprescindible para el AuthHash
AZUL_PAYMENT_PAGE_URL=https://pruebas.azul.com.do/PaymentPage/
AZUL_PROXY_URL=http://localhost:3000          # dummy ok aquí; real para TRACK 1/Fase 4
AZUL_PROXY_AUTH_TOKEN=local-test-token
PUBLIC_CALLBACK_BASE_URL=https://<host-functions>/functions/v1
PUBLIC_RETURN_BASE_URL=https://mangopos.do
SUPABASE_URL=<tu supabase>
SUPABASE_SERVICE_ROLE_KEY=<service_role — SECRETO>
```

### Flujo
```bash
BIZ=<tu_business_id>
JWT=<tu_jwt_supabase>
BASE=https://<host-functions>/functions/v1

# 1) Crear la sesión de tokenización
curl -s -X POST "$BASE/azul-create-tokenization-session" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d "{\"business_id\":\"$BIZ\"}" | jq
# → { "session_id", "order_number", "payment_page_url", "expires_at" }

# 2) Abrir payment_page_url EN EL NAVEGADOR (no curl). Auto-submitea a Azul.
# 3) Digitar una tarjeta de prueba (PRD §C):
#      4035 8740 0042 4977  Exp 202812  CVV 977
# 4) Azul redirige al callback (approved). El backend crea el payment_method y dispara void-hold.
```

### Verificar en DB
```sql
-- Debe quedar una tarjeta verified
select id, status, is_default, card_number_masked, data_vault_brand, created_at
from azul_payment_methods where business_id = '<BIZ>'
order by created_at desc limit 1;

-- La sesión debe quedar approved
select id, status, callback_count, updated_at
from azul_payment_sessions order by created_at desc limit 1;

-- Todo lo que llegó de Azul (callback + void) queda acá
select event_type, processed, processing_error, received_at
from azul_webhook_events order by received_at desc limit 10;
```

### Casos a cubrir (PRD §12.2)
1. Aprobada → `payment_method.status='verified'`, void ejecutado.
2. Cancela en Azul → `session.status='cancelled'`.
3. AuthHash de respuesta inválido (modificar query) → `session.status='tampered'`, sin payment_method.
4. Doble callback → el segundo no duplica side effects (`callback_count`).

### Nota sobre el void-hold e Incapsula
[`azul-void-hold`](functions/azul-void-hold/index.ts) hace un POST **server-to-server** a
Payment Page. Si las functions corren en el VPS, ese POST sale de la IP bloqueada y puede
fallar (lo verás como `processing_error` en `azul_webhook_events`). La tokenización igual
queda verificada (el void es fire-and-forget). Para validar el void sin bloqueo, corré las
functions desde localhost. Además sigue **sin confirmar** que Azul acepte el Void por
Payment Page server-to-server (es una hipótesis del código, PRD §13) — este test lo resuelve.

---

## Qué desbloquea cada track

- **TRACK 1 verde** → el camino mTLS funciona desde una IP no-VPS ⇒ podemos construir e
  iterar la **Fase 4 (cobro recurrente)** y probarla. En prod no habrá bloqueo.
- **TRACK 2 verde** → tokenización + verificación de tarjeta completas; queda la UI de
  Flutter lista para enchufar contra el backend real.
