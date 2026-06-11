# PRD — Autenticación 3D Secure 2.0 sobre la integración Azul (MangoPOS)

> Documento hijo de [`PRD-Azul-Subscriptions.md`](PRD-Azul-Subscriptions.md).
> **Estado:** Borrador v1 — plan, sin código todavía.
> **Origen:** Azul exigió por correo implementar 3D Secure como requisito (transacciones e-commerce = alto riesgo de fraude/contracargo). Esto **deroga el No-objetivo de la línea 44 del PRD principal** ("❌ 3D Secure … no es bloqueante para v1"): pasa a estar **en alcance**.
> **Doc de referencia:** *"Implementación de autenticación del tarjetahabiente con 3D Secure 2.0 en WebService"* — Servicios Digitales Popular (BPD), 13/12/2022. PDF recibido 2026-06-09.

---

## 1. Contexto y problema

La integración Azul de MangoPOS hoy hace tres cosas con la tarjeta del **comercio** (no del cliente final): tokeniza (`ProcessDataVault CREATE`), verifica la tarjeta al registrarla (`Hold` RD$1 + `Void`), y cobra la mensualidad de la suscripción (`ProcessPayment Sale` con token). Las dos primeras son **CIT** (el tarjetahabiente está presente y digita su tarjeta); el cobro mensual es **MIT** (iniciado por el comercio, sin nadie presente).

Azul exige que las transacciones **CIT de e-commerce** pasen por **3D Secure 2.0** (EMV 3DS), que traslada parte del riesgo de fraude al banco emisor y reduce contracargos. El doc de Azul es explícito en dos cosas que mandan todo el diseño:

1. **3DS solo aplica a CIT e-commerce** — "donde el titular de la tarjeta es quien realiza la transacción … y digita los datos de su tarjeta directamente". **No aplica a MIT.**
2. **Una vez Azul habilita 3DS en el MID, TODA venta (`Sale`) o pre-autorización (`Hold`) pasa por 3DS por defecto**, salvo que se envíe `ForceNo3DS="1"`.

El punto 2 es un riesgo operativo de coordinación (ver §13): el día que Azul "encienda" 3DS en el MID, nuestro `Hold` de verificación de tarjeta —hoy con `ForceNo3DS="1"`— dejará de autenticar justo en el flujo donde sí lo quieren. El encendido y el deploy del flujo nuevo deben coordinarse.

## 2. Objetivos

1. Autenticar con **3DS 2.0** el flujo CIT de **registro/verificación de tarjeta del comercio** (frictionless y challenge).
2. Mantener el **cobro recurrente (MIT) exento de 3DS** (`ForceNo3DS="1"`), conforme al doc — es la excepción para `STANDING_ORDER`.
3. **Cero regresión** sobre la Fase 4 (cobro recurrente ya probado en vivo) ni sobre la tokenización existente.
4. Quedar listos para que Azul "encienda" 3DS en el MID sin romper el registro de tarjeta.

## 3. No-objetivos

- ❌ 3DS sobre cobros recurrentes MIT — exentos por diseño (`ForceNo3DS="1"`).
- ❌ 3DS sobre pagos de **clientes finales del comercio** (pagar la cuenta del restaurante con tarjeta). Eso es otro PRD futuro; si se hace, reusará estos componentes.
- ❌ Apple Pay / Google Pay basados en SDK (el doc los menciona aparte; fuera de alcance acá).
- ❌ Migrar el cobro recurrente a 3DS "por las dudas". Se queda MIT/`ForceNo3DS=1`.

## 4. Decisiones arquitectónicas clave (continúa la numeración del PRD principal)

| # | Decisión | Justificación |
|---|---|---|
| **D14** | **3DS solo en CIT; el MIT recurrente sigue con `ForceNo3DS="1"`.** | El cobro mensual no tiene tarjetahabiente presente para resolver un desafío. El doc lo confirma. No tocar [`chargeWithToken`](supabase/functions/_shared/azul-api.ts#L191). |
| **D15** | **El CIT 3DS corre en un navegador real** (no en el form nativo de Flutter + sidecar). | 3DS 2.0 necesita: capturar `BrowserInfo` con JS, renderizar el iframe oculto `MethodForm`, y mostrar la pantalla de desafío del ACS. Nada de eso se puede hacer desde el `ProcessDataVault` server-to-server actual. |
| **D16** | **Página 3DS propia, hospedada por nosotros** (Edge Functions), no la Payment Page de Azul. | Mantiene el camino API-directa del pivot v2 (PCI SAQ D ya asumido). Es "hosted page" pero bajo nuestro control: orquesta los pasos y rinde el HTML que el navegador necesita. |
| **D17** | **El CIT de registro = `Hold` RD$1 con `SaveToDataVault="1"` autenticado por 3DS, luego `Void`.** | Unifica autenticación + tokenización en un solo round-trip CIT y conserva la lógica de D3 del PRD principal (Hold + Void, el cliente nunca ve cargo real). Reemplaza el `ProcessDataVault CREATE` + `Hold` separado **solo para el registro con tarjetahabiente presente**. |
| **D18** | **App Flutter abre la página 3DS en el navegador del sistema (`url_launcher`, ya está) y escucha por Realtime** el cambio de estado en `azul_payment_sessions` / `azul_payment_methods`. **No** se agrega paquete de WebView embebido. | MangoPOS corre en Windows y `webview_flutter` no soporta Windows. El navegador del sistema da la mejor compatibilidad para el desafío del ACS (redirect a app del banco, OTP) y reusa el patrón que ya tiene [`payment_method_view.dart`](lib/presentation/billing/view/payment_method_view.dart). |
| **D19** | **Dos endpoints de servidor nuevos para los POST del ACS:** `MethodNotificationUrl` y `TermUrl`, ambos **por-sesión**, correlacionados por un `sid` no adivinable (uuid v4 = la PK de `azul_payment_sessions`). | El ACS postea sin autenticación; el `sid` único en el query string es lo único que asocia el callback con la transacción. El backend valida que el `sid` exista y esté en el estado esperado. |
| **D20** | **`RequestorChallengeIndicator = "01"`** (sin preferencia) por defecto. Nunca `"04"`. | "04" (desafío mandatorio) no aplica en RD según el doc. "01" deja que el emisor decida (mejor tasa de aprobación frictionless). Configurable si más adelante se quiere `"03"` para montos altos. |
| **D21** | **`BrowserInfo` se arma en parte en el cliente y en parte en el servidor.** Los campos JS (`Language`, `ColorDepth`, `ScreenWidth/Height`, `TimeZone`, `JavaScriptEnabled`) los captura el script del doc en la página; `AcceptHeader`, `IPAddress`, `UserAgent` los completa el backend desde los headers de la request. | Es el patrón exacto del ejemplo .NET del doc (pág. 10). Todos los 9 campos son **obligatorios** para autenticar. |
| **D22** | **Persistir `threeDSServerTransID` (de Azul) + nuestro `sid` por intento.** La correlación de `ProcessThreeDSMethod` / `ProcessThreeDSChallenge` es por `AzulOrderId`. | Trazabilidad y reconciliación. `threeDSServerTransID` llega con la respuesta del nodo `ThreeDSMethod` y vuelve en el POST a `MethodNotificationUrl`. |
| **D23** | **Subir el timeout del sidecar a ≥120 s** (hoy 30 s) para las llamadas 3DS, y esperar **mínimo 10 s** la notificación del `MethodForm` antes de mandar `MethodNotificationStatus`. | El doc de WS pide timeout de 120 s; el flujo 3DS espera la notificación del ACS hasta 10 s. Con 30 s el sidecar corta a media autenticación. Ver [`index.js`](supabase/azul-proxy/index.js#L172). |

## 5. Contratos nuevos del WebService Azul

### 5.1 Campos nuevos en el mensaje `ProcessPayment` (Sale / Hold)

Tres nodos/objetos nuevos se agregan al `Sale`/`Hold` CIT (no van en MIT):

**`ThreeDSAuth`**

| Subcampo | Descripción |
|---|---|
| `TermUrl` | URL nuestra donde el ACS postea el resultado del desafío (`cres`). Por-sesión, con `sid` único. |
| `MethodNotificationUrl` | URL nuestra donde el ACS notifica que terminó el `MethodForm` (trae `threeDSServerTransID`). Por-sesión, con `sid` único. |
| `RequestorChallengeIndicator` | Preferencia de desafío. Usamos `"01"` (D20). Valores: 01 sin preferencia, 02 no desafío, 03 prefiere desafío, 04 mandatorio (no aplica RD). |

**`CardHolderInfo`** (Name + Email **obligatorios**; el resto opcional — omitir el campo si va vacío, no enviarlo en blanco)

`Name`, `Email`, `PhoneHome`, `PhoneMobile`, `PhoneWork`, `BillingAddressLine1/2/3`, `BillingAddressCity`, `BillingAddressState`, `BillingAddressCountry` (ISO 2), `BillingAddressZip`, y los equivalentes `ShippingAddress*`. Límites: 96 chars direcciones/ciudad/estado/nombre, 24 zip, 254 email, 32 teléfonos, país ISO 2 caracteres.

**`BrowserInfo`** (los 9 **obligatorios**)

`AcceptHeader`, `IPAddress`, `Language`, `ColorDepth`, `ScreenWidth`, `ScreenHeight`, `TimeZone`, `UserAgent`, `JavaScriptEnabled`.

### 5.2 Métodos nuevos del WebService

| Método | Endpoint JSON (prod) | Cuándo |
|---|---|---|
| `ProcessThreeDSMethod` | `…/WebServices/JSON/default.aspx?processthreedsmethod` | Tras renderizar el `MethodForm`, para informar `MethodNotificationStatus` y continuar. |
| `ProcessThreeDSChallenge` | `…/WebServices/JSON/default.aspx?processthreedschallenge` | Tras el desafío, enviando el `CRes` del ACS para completar la autorización. |

Para pruebas: dominio `pruebas.azul.com.do`. El **sidecar pasa la operación como flag sin valor** (`?processthreedsmethod`), igual que `?ProcessPayment` — no `?Method=...` (aprendizaje ya documentado del fix del proxy).

### 5.3 Respuestas de Azul (IsoCode)

| `IsoCode` | `ResponseMessage` | Significado | Acción |
|---|---|---|---|
| `3D2METHOD` | `3D_SECURE_2_METHOD` | Frictionless con `MethodForm` | Renderizar iframe oculto → esperar ≤10 s → `ProcessThreeDSMethod`. |
| `3D` | `3D_SECURE_CHALLENGE` | Requiere desafío | Auto-POST `creq` al `RedirectPostUrl` → recibir `cres` en `TermUrl` → `ProcessThreeDSChallenge`. |
| `00` | `APROBADA` | Autorizada (frictionless sin method, o paso final) | Éxito → (si fue Hold) `Void` → tarjeta `verified` + token. |
| (otro) | — | Declinada / error | Marcar sesión `declined`, mostrar motivo. |

**Casing sensible:** el campo `creq` es **case-sensitive y va en minúscula**. Otros: `cres`, `threeDSMethodData` (base64 con `threeDSServerTransID`), `MethodNotificationStatus` ∈ {`RECEIVED`, `EXPECTED_BUT_NOT_RECEIVED`, `NOT_EXPECTED`}.

## 6. Máquina de estados 3DS (el corazón de la implementación)

```
                    ┌─────────────────────────────────────────────────────────────┐
  Registro tarjeta  │  ProcessPayment Hold (RD$1, SaveToDataVault=1)               │
  (CIT, navegador)  │   + ThreeDSAuth + CardHolderInfo + BrowserInfo               │
                    └──────────────┬──────────────────────────────────────────────┘
                                   │ IsoCode =
            ┌──────────────────────┼───────────────────────┬─────────────────────┐
            ▼                      ▼                        ▼                     ▼
       3D2METHOD                  3D                       00                  (otro)
   (frictionless+method)     (challenge directo)       APROBADA              DECLINADA
            │                      │                        │                     │
   render MethodForm              │                         │                     │
   (iframe oculto)                │                         │                     │
   esperar ≤10s notif ACS        │                         │                     │
   → MethodNotificationUrl        │                         │                     │
            │                      │                         │                     │
   ProcessThreeDSMethod           │                         │                     │
   (status RECEIVED/…)            │                         │                     │
            │ IsoCode =           │                         │                     │
       ┌────┼─────┐               │                         │                     │
       ▼    ▼     ▼               ▼                         ▼                     ▼
      00    3D  (otro) ─────► auto-POST creq → RedirectPostUrl (ACS UI)      sesión
   APROB. CHALL DECLIN          │ tarjetahabiente: OTP / app banco          declined
                                ▼                                            
                          ACS postea cres → TermUrl                         
                                │                                           
                          ProcessThreeDSChallenge (CRes)                    
                                │ IsoCode =                                  
                          ┌─────┴─────┐                                      
                          ▼           ▼                                      
                         00         (otro)                                   
                       APROBADA    DECLINADA                                 
                          │                                                  
              (fue Hold) → Void → tarjeta verified + DataVaultToken guardado 
```

**Soporte del emisor (rama EXPECTED_BUT_NOT_RECEIVED):** no todos los emisores soportan el `MethodForm`. Si no llega la notificación al `MethodNotificationUrl` en 10 s, se manda `MethodNotificationStatus = EXPECTED_BUT_NOT_RECEIVED` y el flujo continúa (normalmente hacia challenge). Si nunca se mandó `MethodNotificationUrl`, va `NOT_EXPECTED`.

## 7. Componentes a construir

| Componente | Tipo | Responsabilidad |
|---|---|---|
| `azul-3ds-page?sid=…` | Edge Function (HTML) | Sirve la página servida en el navegador. Corre el JS de `BrowserInfo`, lo postea al backend, y re-renderiza paso a paso (form de tarjeta o token, iframe `MethodForm`, auto-submit del `creq`, pantalla final). |
| `azul-3ds-orchestrate` | Edge Function (JSON) | Lógica server-side de la máquina de estados §6: arma el `ProcessPayment` con los 3 nodos, llama `ProcessThreeDSMethod` / `ProcessThreeDSChallenge` vía sidecar, decide el siguiente render, persiste estado en `azul_payment_sessions`. (Puede ir embebida en `azul-3ds-page` por endpoint/acción; se separa solo si conviene.) |
| `azul-3ds-method-notify?sid=…` | Edge Function | Recibe el POST del ACS (`MethodNotificationUrl`) con `threeDSServerTransID`; marca `method_notification_received_at`. |
| `azul-3ds-term?sid=…` | Edge Function | Recibe el POST del ACS (`TermUrl`) con `cres` + `threeDSSessionData`; dispara `ProcessThreeDSChallenge`. |
| Sidecar [`azul-proxy/index.js`](supabase/azul-proxy/index.js) | Node.js | Agregar soporte de `?processthreedsmethod` y `?processthreedschallenge`; subir timeout a ≥120 s. |
| [`_shared/azul-api.ts`](supabase/functions/_shared/azul-api.ts) | TS | Extender `AzulMethod`; tipos `ThreeDSAuth` / `CardHolderInfo` / `BrowserInfo`; builders del payload Sale/Hold con nodos 3DS; helpers `processThreeDSMethod()` / `processThreeDSChallenge()`. |
| Registro de tarjeta en Flutter | Dart | Reemplazar el submit nativo del paso "registrar tarjeta" por: abrir `azul-3ds-page` en navegador (`url_launcher`) + escuchar Realtime el resultado. |

## 8. Modelo de datos (cambios)

Strangler-fig: **solo se altera una tabla `azul_` propia** (`azul_payment_sessions`), con `ADD COLUMN IF NOT EXISTS`. Cero ALTER a tablas no-`azul_`.

```sql
-- migración YYYYMMDD_NNNN_azul_3ds.sql  (+ _ROLLBACK.sql)
alter table azul_payment_sessions
  add column if not exists threeds_flow text
    check (threeds_flow in ('none','frictionless','challenge')),
  add column if not exists threeds_server_trans_id text,
  add column if not exists threeds_method_status text
    check (threeds_method_status in ('RECEIVED','EXPECTED_BUT_NOT_RECEIVED','NOT_EXPECTED')),
  add column if not exists threeds_auth_status text,        -- resultado de autenticación del ACS
  add column if not exists threeds_eci text,                -- E-Commerce Indicator
  add column if not exists browser_info jsonb,              -- los 9 campos (sin PAN)
  add column if not exists cardholder_info jsonb,           -- Name/Email/dir (sin PAN)
  add column if not exists method_notification_received_at timestamptz,
  add column if not exists cres_received_at timestamptz,
  add column if not exists challenge_started_at timestamptz;
```

`azul_webhook_events`: nuevos `event_type` aceptados — `threeds_method_notification`, `threeds_term_callback`, `threeds_ws_response`. (Append-only, como hoy.)

**Nunca** se persiste PAN/CVC. `browser_info` y `cardholder_info` (sin tarjeta) sí se loguean para análisis de riesgo y forense.

## 9. Seguridad

- **`sid` no adivinable** (uuid v4): los callbacks del ACS llegan sin auth; el backend valida que el `sid` exista y esté en el estado esperado, y registra cada callback en `azul_webhook_events` antes de procesar.
- **PCI:** con API-directa estamos en **SAQ D** (ya asumido en el pivot v2). El PAN solo transita página → backend → sidecar → Azul; nunca se persiste ni se loguea.
- **MIT exento documentado:** mantener `ForceNo3DS="1"` en el recurrente asume el riesgo de contracargo para esas transacciones (excepción regulatoria `STANDING_ORDER`). Dejar el comentario en código.
- **`TermUrl` / `MethodNotificationUrl`** deben ser HTTPS públicas y **por-sesión** (no estáticas).
- Subir timeout del sidecar no debe relajar el resto de validaciones (token `x-proxy-auth`, tamaño de body).

## 10. Plan de fases con definiciones de hecho

### Fase 3DS.0 — Sidecar + tipos + builders (offline, sin riesgo)

**Trabajo:**
1. Extender `AzulMethod` con `ProcessThreeDSMethod` y `ProcessThreeDSChallenge`; mapear los flags `?processthreedsmethod` / `?processthreedschallenge` en el sidecar.
2. Subir `UPSTREAM_TIMEOUT_MS` del sidecar a ≥120 s.
3. Tipar `ThreeDSAuth`, `CardHolderInfo`, `BrowserInfo` y las respuestas (`3D2METHOD`, `3D`).
4. Builders: `processPaymentWith3DS()` (Hold/Sale + 3 nodos), `processThreeDSMethod()`, `processThreeDSChallenge()` en `_shared/azul-api.ts`.
5. Unit tests del armado de payload (campos obligatorios presentes, omisión de opcionales vacíos, casing de `creq`).

**Bloqueado por:** nada (todo offline).

**Definición de hecho:**
- ✅ El sidecar acepta los dos métodos nuevos y responde sin error de formato.
- ✅ Tests de armado de payload en verde.
- ✅ MIT (`chargeWithToken`) intacto — sin regresión.

**Estimación:** 6-10 horas.

### Fase 3DS.1 — Esquema

**Trabajo:** migración `ADD COLUMN IF NOT EXISTS` sobre `azul_payment_sessions` + nuevos `event_type` + `_ROLLBACK.sql`.

**Bloqueado por:** nada.

**Definición de hecho:** ✅ migración aplica y revierte limpio en local; ✅ RLS sin cambios de exposición de campos sensibles.

**Estimación:** 2-3 horas.

### Fase 3DS.2 — Flujo frictionless E2E (página + orquestación + callbacks)

**Trabajo:**
1. `azul-3ds-page` con captura de `BrowserInfo` (script del doc) + render por pasos.
2. `azul-3ds-orchestrate`: `ProcessPayment` con 3DS → manejo `3D2METHOD` → render `MethodForm` → `ProcessThreeDSMethod` → `00`.
3. `azul-3ds-method-notify` (recibe `threeDSServerTransID`).
4. Persistencia de estado en `azul_payment_sessions`; logging en `azul_webhook_events`.

**Bloqueado por:** 3DS.0, 3DS.1, y **habilitación de 3DS en el MID de pruebas + tarjeta frictionless** (Azul, ver §12). Código se escribe sin esperar; el E2E sí espera.

**Definición de hecho:**
- ✅ Frictionless completo contra `pruebas.azul.com.do` con tarjeta SF → `IsoCode:00`.
- ✅ Hold queda `Void`; `azul_payment_methods.status='verified'` con token.
- ✅ Rama `EXPECTED_BUT_NOT_RECEIVED` manejada (emisor sin MethodForm).

**Estimación:** 16-22 horas.

### Fase 3DS.3 — Flujo de desafío (challenge)

**Trabajo:** manejo `IsoCode:3D` → auto-POST `creq` → `RedirectPostUrl`; `azul-3ds-term` recibe `cres` → `ProcessThreeDSChallenge` → `00`.

**Bloqueado por:** 3DS.2 + **tarjeta de prueba 3DS challenge + credenciales Auth de 3DS** (Azul). En notas: `4005…0129`, Auth1/Auth2 = `3dsecure` — **confirmar con Azul**.

**Definición de hecho:**
- ✅ Challenge E2E: OTP correcto → `00`; OTP incorrecto / abandono → `declined` manejado.
- ✅ Casing de `creq` minúscula respetado.

**Estimación:** 10-14 horas.

### Fase 3DS.4 — Integración Flutter (registro de tarjeta)

**Trabajo:** en el paso "registrar tarjeta", abrir `azul-3ds-page` con `url_launcher` + escuchar Realtime sobre `azul_payment_sessions` / `azul_payment_methods`; cerrar y refrescar al terminar; manejar cancelación/timeout.

**Bloqueado por:** 3DS.2 (frictionless mínimo funcionando).

**Definición de hecho:** ✅ registro de tarjeta con 3DS funciona en Android, iOS y Windows (navegador del sistema); ✅ la app refleja `verified` por Realtime; ✅ cancelar no deja sesión colgada.

**Estimación:** 8-12 horas.

### Fase 3DS.5 — Hardening + corte a producción

**Trabajo:** timeouts y reintentos; reconciliación con `VerifyPayment` cuando se pierde el callback; auditoría completa; **coordinar el "encendido" de 3DS en el MID con el deploy** (ver §13); failover `pagos`→`contpagos` y `CustomOrderId` (del doc WS principal).

**Bloqueado por:** 3DS.2-3DS.4.

**Definición de hecho:** ✅ matriz de pruebas §11 completa; ✅ runbook del encendido coordinado; ✅ sin sesiones colgadas tras 24 h de prueba.

**Estimación:** 10-14 horas.

## 11. Plan de pruebas

Correr desde **localhost o IP whitelisted** — Incapsula bloquea la IP del VPS solo en pruebas (ver memoria `project-azul-incapsula-blocker`).

| Caso | Tarjeta / condición | Esperado |
|---|---|---|
| Frictionless sin method | tarjeta SF | `00` directo, tarjeta `verified` |
| Frictionless con method | tarjeta SF + emisor con MethodForm | `3D2METHOD` → method → `00` |
| Emisor sin MethodForm | tarjeta SF sin soporte method | `EXPECTED_BUT_NOT_RECEIVED` → continúa |
| Challenge OK | `4005…0129` (confirmar), OTP correcto | `3D` → challenge → `00` |
| Challenge fallido | challenge, OTP incorrecto / abandono | `declined`, sin token |
| Declinada base | tarjeta que declina | `declined` manejado |
| Doble callback | reenviar callback ACS | idempotente, sin doble efecto |

## 12. Solicitudes a Azul (checklist)

1. **Habilitar el servicio 3DS en el MID de pruebas `39038540035`** y confirmar la **fecha** (coordinar con nuestro deploy — ver §13).
2. **Tarjetas de prueba 3DS** (frictionless y challenge) + **credenciales Auth1/Auth2 de 3DS** (en notas: `3dsecure`; confirmar).
3. Confirmar endpoints exactos de pruebas para `?processthreedsmethod` y `?processthreedschallenge`.
4. Confirmar si en **producción** el MID tendrá 3DS **obligatorio** (define si `ForceNo3DS="1"` seguirá permitido en la verificación cuando no se quiera challenge).
5. Comportamiento esperado en `EXPECTED_BUT_NOT_RECEIVED` (emisores sin MethodForm).

## 13. Riesgos y mitigaciones

| Riesgo | Prob. | Impacto | Mitigación |
|---|---|---|---|
| **Azul "enciende" 3DS en el MID antes de desplegar el flujo** → el `Hold` de verificación recibe `3D2METHOD`/`3D` y nadie lo maneja → registro de tarjeta roto. | Media | Alto | Coordinar fecha (§12.1). Mientras el flujo no esté desplegado, mantener `ForceNo3DS="1"` en el `Hold` de verificación; quitarlo recién en el corte de 3DS.5. |
| **WebView no soportado en Windows** | — | Medio | D18: navegador del sistema + Realtime, no WebView embebido. |
| **Navegador se cierra durante el challenge** → sesión colgada | Media | Medio | Reconciliación con `VerifyPayment` + job de timeout de sesión (3DS.5); el `sid` permite reanudar/cerrar. |
| **Sidecar corta a los 30 s** durante autenticación | Alta si no se arregla | Alto | D23: subir a ≥120 s en 3DS.0. |
| **Redirect del ACS a app del banco** (out-of-band) no retorna limpio al navegador | Media | Medio | El `TermUrl` recibe el `cres` server-side independientemente del navegador; la app refresca por Realtime. |

## 14. Apéndice — mapeo al doc de Azul

- **Pasos del doc:** §"Flujo sin fricción (SF)" pasos 1-6; §"Flujo de desafío" variantes D (sin ThreeDSMethod) y DM (con ThreeDSMethod), pasos 1-9.
- **Campos:** `ThreeDSAuth` (pág. 6-7), `CardHolderInfo` (pág. 8), `BrowserInfo` + script de captura (pág. 9-10).
- **Respuestas:** `3D2METHOD`/`3D_SECURE_2_METHOD` (pág. 16), `3D`/`3D_SECURE_CHALLENGE` (pág. 20), `00`/`APROBADA` (pág. 22-23).
- **Casing crítico:** `creq` en minúscula, case-sensitive (pág. 20-21).
- **`MethodNotificationStatus`:** RECEIVED / EXPECTED_BUT_NOT_RECEIVED / NOT_EXPECTED (pág. 19).
</content>
</invoke>
