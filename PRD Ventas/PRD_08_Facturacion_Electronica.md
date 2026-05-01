# PRD 8 — Integración de Facturación Electrónica DGII (e-CF) en MangoPOS

| Campo | Valor |
|---|---|
| **ID** | PRD-08 |
| **Título** | Integración de Facturación Electrónica DGII (e-CF) en MangoPOS |
| **Autor** | Cristian — MangoPOS |
| **Estado** | Borrador v1.0 |
| **Fecha** | Abril 2026 |
| **Producto** | MangoPOS (Flutter — Windows desktop & Android) |
| **Stack backend** | Node.js (microservicio nuevo) + Self-hosted Supabase + Coolify + Traefik + Cloudflare |
| **Dominio** | `mangopos.do` |
| **Librería base** | [`dgii-ecf`](https://github.com/victors1681/dgii-ecf) (Victor Santos) |

---

## 1. Resumen ejecutivo (TL;DR)

MangoPOS necesita habilitar **Facturación Electrónica (e-CF)** ante la DGII para todos sus clientes en República Dominicana, dado que la Ley 32-23 establece la obligatoriedad gradual del e-CF para todos los contribuyentes del país.

La integración será **completa**: emisión, recepción y aprobaciones comerciales, manejada en una arquitectura **multi-tenant** donde cada sucursal/negocio se trata como un emisor independiente con su propio RNC y certificado digital `.p12`.

Como la librería elegida (`dgii-ecf`) es de Node.js, se introducirá un **microservicio backend nuevo** (`ecf.mangopos.do`) que actúa como puente entre el cliente Flutter y los servicios de DGII, gestionando autenticación, firma, envío, recepción, almacenamiento de XMLs y monitoreo de estatus.

El rollout será gradual: **TesteCF → CertECF → Producción**, con certificación formal ante DGII como gate obligatorio antes de liberar a producción.

---

## 2. Contexto y problema

### 2.1 Contexto regulatorio

- La **Ley 32-23 de Facturación Electrónica** obliga a todos los contribuyentes de República Dominicana a emitir e-CF en lugar de facturas tradicionales, con cronograma escalonado por tamaño de contribuyente.
- DGII expone un set de APIs SOAP/REST para autenticación con certificado, envío de comprobantes firmados (XML), consulta de estatus y aprobaciones comerciales.
- Los comprobantes electrónicos deben ir firmados digitalmente con un certificado emitido por una autoridad autorizada (DigiFirma — Cámara de Comercio de Santo Domingo).

### 2.2 Problema actual

- MangoPOS **hoy emite facturas tradicionales** (NCF físicos), sin integración con DGII.
- Los clientes de MangoPOS están comenzando a recibir notificaciones de DGII para migrar a e-CF, lo que representa **riesgo de churn** si MangoPOS no provee la solución.
- Sin una integración nativa, los clientes tendrían que usar plataformas externas (Odoo, ecf.mseller.app, Cresco, Conducto, etc.), duplicando data entry y rompiendo el flujo POS.

### 2.3 Oportunidad

- Convertir el e-CF en una **feature diferenciadora** y un upsell pago dentro del SaaS.
- Reducir fricción para clientes nuevos: alta + onboarding de certificado + facturación en un solo flujo.
- Posicionar MangoPOS como solución integral para retail/restaurantes en RD.

---

## 3. Objetivos y métricas de éxito

### 3.1 Objetivos de negocio

1. **Cumplimiento legal** para todos los clientes de MangoPOS antes de la fecha de obligatoriedad aplicable a cada uno.
2. **Retención** del 100% de los clientes activos durante la transición a e-CF.
3. **Adopción** del módulo e-CF por al menos el 80% de los clientes elegibles dentro de los 6 meses post-lanzamiento.

### 3.2 Métricas técnicas

| Métrica | Meta |
|---|---|
| Tasa de aceptación de e-CF en primer envío | ≥ 98% |
| Latencia P95 de emisión (POS → DGII Aceptado) | < 8 segundos |
| Disponibilidad del microservicio e-CF | ≥ 99.5% mensual |
| Tasa de errores no recuperables | < 0.5% |
| Tiempo medio de re-procesamiento ante caída DGII | < 5 minutos tras restablecimiento |

### 3.3 Métricas de producto

- # de RNCs activos emitiendo e-CF / mes
- # de e-CFs emitidos / día por tenant
- # de e-CFs recibidos de proveedores / día por tenant
- # de aprobaciones comerciales procesadas / día

---

## 4. Alcance

### 4.1 Dentro del alcance (In-scope)

**Emisión de comprobantes (todos los tipos relevantes para retail/restaurante):**
- Factura de Crédito Fiscal (e-CF tipo **31**)
- Factura de Consumo (e-CF tipo **32**) — con **RFCE** para montos < RD$250,000
- Nota de Débito (tipo **33**)
- Nota de Crédito (tipo **34**)
- Comprobante de Compras (tipo **41**)
- Comprobante de Gastos Menores (tipo **43**)
- Comprobante para Regímenes Especiales (tipo **44**)
- Comprobante Gubernamental (tipo **45**)
- Comprobante de Exportaciones (tipo **46**) — si el negocio aplica

**Recepción de comprobantes:**
- Endpoint público para que DGII y emisores envíen e-CFs al receptor (cuando un cliente de MangoPOS es comprador).
- Acuse de recibo automático (`ARECF`).
- Almacenamiento del XML recibido y vinculación con el módulo de cuentas por pagar.

**Aprobaciones comerciales:**
- Flujo para que el receptor apruebe o rechace comercialmente un e-CF recibido (`ACECF`).
- UI para revisión y decisión por parte del usuario.

**Operaciones auxiliares:**
- Autenticación con DGII (seed → firma → JWT) por tenant.
- Anulación de rangos no usados (`voidENCF`).
- Consulta de estatus por trackId y por eNCF.
- Generación de QR para impresión en receipts.
- Directorio de receptores DGII (caché).

**Multi-tenancy:**
- Cada sucursal = negocio independiente con su propio RNC, eNCF range, certificado y URL de recepción.
- Aislamiento total de datos por tenant (RLS en Supabase).

### 4.2 Fuera del alcance (Out-of-scope)

- ❌ Emisión de e-CF desde el frontend Flutter directamente (siempre vía microservicio Node).
- ❌ Onboarding/emisión del certificado `.p12` (lo hace DigiFirma, MangoPOS solo lo carga).
- ❌ Reportes contables avanzados (605, 606, 607) — futuro PRD.
- ❌ Integración con sistemas contables externos (QuickBooks, etc.) — futuro PRD.
- ❌ App standalone para gestión de e-CF — todo se integra dentro de MangoPOS.

---

## 5. Stakeholders y usuarios

| Rol | Necesidad |
|---|---|
| **Dueño de negocio (cliente MangoPOS)** | Cumplir con DGII sin complicaciones; emitir desde el POS sin pasos extra. |
| **Cajero / staff** | Que la emisión de factura sea tan rápida como antes; que no falle frente al cliente. |
| **Contador del cliente** | Acceder a XMLs firmados, ver estatus DGII, descargar reportes. |
| **Equipo MangoPOS (soporte)** | Diagnosticar fallos rápidamente, reintentar envíos, ver logs por tenant. |
| **DGII** | Recibir comprobantes válidos, firmados, en formato XML según especificación vigente. |

---

## 6. Requisitos funcionales

### 6.1 Onboarding del tenant (RNC + certificado)

**RF-01.** El admin del negocio debe poder cargar su archivo `.p12` y passphrase desde el panel de MangoPOS.

**RF-02.** El sistema debe **validar** el certificado al momento de cargarlo:
- Que sea un `.p12` válido.
- Que la passphrase sea correcta.
- Que el certificado **no esté expirado** y tenga al menos 30 días de vigencia restante.
- Extraer y mostrar: subject, issuer, validFrom, validTo, serialNumber (usando `P12Reader.getCertificateInfoFromBase64`).

**RF-03.** El certificado debe almacenarse **encriptado en reposo** (no en plaintext) — ver sección 8.1 (Seguridad).

**RF-04.** El admin debe configurar por sucursal:
- RNC del emisor
- Razón social
- Rangos de eNCF asignados por DGII (por tipo de comprobante)
- URL de recepción de e-CF (autogenerada por MangoPOS, una por tenant)
- Ambiente DGII activo (TesteCF / CertECF / Producción)

**RF-05.** El sistema debe **alertar al admin con 30 días de anticipación** cuando un certificado esté próximo a expirar.

### 6.2 Emisión de e-CF

**RF-06.** Al cerrar una venta en el POS, el usuario debe poder elegir entre:
- Comprobante de Consumo (32) — default para venta a consumidor final.
- Comprobante de Crédito Fiscal (31) — cuando se ingresa RNC del comprador.
- Otros tipos (33, 34, 41, 43, 44, 45, 46) según contexto.

**RF-07.** El POS debe construir un payload JSON con la estructura del e-CF y enviarlo al microservicio `ecf.mangopos.do`.

**RF-08.** El microservicio debe:
1. Convertir JSON → XML (usando `Transformer.json2xml`).
2. Firmar el XML con el certificado del tenant (`Signature.signXml`).
3. Si es tipo 32 < 250K: generar también el RFCE y firmarlo.
4. Enviar el XML firmado a DGII (`sendElectronicDocument` o `sendSummary`).
5. Persistir el XML firmado, el trackId, el código de seguridad y el estatus inicial.
6. Retornar al POS: trackId, eNCF asignado, código de seguridad, URL de QR.

**RF-09.** El POS debe imprimir/mostrar el receipt con:
- eNCF
- QR generado (`generateFcQRCodeURL` o `generateEcfQRCodeURL` según tipo)
- Código de seguridad
- Fecha de emisión y firma

**RF-10.** Si DGII no responde en < 5 segundos, el POS debe permitir entregar el receipt **provisional** marcado como "Pendiente DGII", y reintentar el envío en background.

**RF-11.** Si DGII rechaza el comprobante, el sistema debe:
- Notificar al usuario con el detalle del error.
- Permitir corregir y re-emitir (consumiendo el siguiente eNCF, no reusando).
- Loggear el rechazo para auditoría.

### 6.3 Recepción de e-CF

**RF-12.** Cada tenant tendrá una URL única de recepción: `https://ecf.mangopos.do/r/{tenant_id}/fe/recepcion/api/ecf`.

**RF-13.** Esta URL debe estar registrada en el directorio de receptores de DGII (manual u automático según corresponda).

**RF-14.** El microservicio debe implementar:
- Endpoint `/fe/autenticacion/api/semilla` — genera seed (`CustomAuthentication.generateSeed`).
- Endpoint `/fe/autenticacion/api/validacioncertificado` — valida seed firmado y emite JWT (`verifySignedSeed`).
- Endpoint `/fe/recepcion/api/ecf` — recibe e-CFs entrantes, valida JWT y firma, persiste XML.

**RF-15.** Al recibir un e-CF válido, el sistema debe **automáticamente** generar y enviar el `ARECF` (acuse de recibo) al emisor.

**RF-16.** Los e-CFs recibidos deben aparecer en una bandeja dentro de MangoPOS, con estatus: `Recibido` / `Aprobado comercial` / `Rechazado comercial`.

### 6.4 Aprobación comercial

**RF-17.** El usuario receptor debe poder aprobar o rechazar comercialmente cada e-CF recibido desde la UI.

**RF-18.** Al aprobar/rechazar, el microservicio genera el `ACECF`, lo firma y lo envía al emisor (`sendCommercialApproval`).

**RF-19.** Razones de rechazo soportadas (códigos DGII):
- 1: Error de especificación
- 2: Error de Firma Digital
- 3: Envío duplicado
- 4: RNC Comprador no corresponde

### 6.5 Anulación de rangos

**RF-20.** El admin debe poder anular rangos de eNCF no utilizados desde el panel (`voidENCF`).

**RF-21.** Razón de anulación debe ser registrada en log de auditoría.

### 6.6 Consulta y monitoreo

**RF-22.** Cada e-CF debe ser consultable por:
- trackId (`statusTrackId`)
- eNCF (`trackStatuses`)
- Estado de validez (`inquiryStatus`) — útil para verificar e-CFs recibidos de proveedores.

**RF-23.** Background worker debe consultar DGII automáticamente cada 60 segundos para e-CFs en estado `EnProceso` hasta obtener resolución final.

**RF-24.** Dashboard de monitoreo por tenant con: emitidos hoy/mes, aceptados, rechazados, en proceso, recibidos, pendientes de aprobación comercial.

---

## 7. Arquitectura técnica propuesta

### 7.1 Diagrama lógico

```
┌─────────────────────────┐         ┌─────────────────────────┐
│   MangoPOS Flutter      │         │   MangoPOS Mobile       │
│   (Windows Desktop)     │         │   (Android)             │
└──────────┬──────────────┘         └──────────┬──────────────┘
           │                                   │
           │  HTTPS + JWT (Supabase Auth)     │
           └───────────────┬───────────────────┘
                           │
                           ▼
                ┌──────────────────────┐
                │   Supabase           │
                │   (Postgres + RLS    │
                │   + Realtime)        │
                └──────┬───────────────┘
                       │ Triggers / Edge Functions
                       ▼
        ┌──────────────────────────────────┐
        │   ecf.mangopos.do                │
        │   (Node.js microservice)         │
        │   - dgii-ecf library             │
        │   - Cert vault                   │
        │   - Job queue (BullMQ)           │
        │   - Auth manager                 │
        └────┬─────────────────────────┬───┘
             │                         │
             ▼                         ▼
   ┌──────────────────┐      ┌──────────────────────┐
   │  DGII APIs       │      │  Customer Receivers  │
   │  - TesteCF       │      │  (other taxpayers)   │
   │  - CertECF       │      │                      │
   │  - eCF (Prod)    │      └──────────────────────┘
   └──────────────────┘
```

### 7.2 Componentes

#### 7.2.1 Microservicio `ecf-service` (nuevo)

- **Stack:** Node.js 20 LTS, TypeScript, Fastify (o Express), `dgii-ecf` v más reciente, BullMQ + Redis para colas.
- **Deploy:** Coolify en el VPS existente, detrás de Traefik.
- **Subdominio:** `ecf.mangopos.do` (DNS gestionado por Cloudflare, certificado Let's Encrypt vía DNS-01 challenge — tener cuidado de que el dominio esté bien configurado en Cloudflare como ya pasó con `realplay.do`).
- **Endpoints internos** (autenticación con MangoPOS por API key + IP allowlist):
  - `POST /api/v1/invoices` — emitir e-CF
  - `GET /api/v1/invoices/:trackId` — estatus
  - `POST /api/v1/invoices/:id/void` — anular
  - `POST /api/v1/commercial-approval` — aprobar/rechazar e-CF recibido
  - `POST /api/v1/certificates` — cargar `.p12`
  - `GET /api/v1/certificates/:tenantId/info` — metadata cert
- **Endpoints públicos** (para DGII y emisores externos):
  - `GET /r/:tenantId/fe/autenticacion/api/semilla`
  - `POST /r/:tenantId/fe/autenticacion/api/validacioncertificado`
  - `POST /r/:tenantId/fe/recepcion/api/ecf`
  - `POST /r/:tenantId/fe/aprobacioncomercial/api/ecf`

#### 7.2.2 Cert Vault

- Los certificados `.p12` se almacenan **encriptados con AES-256-GCM** usando una llave maestra gestionada por **Supabase Vault** (o variables de entorno con rotación si Vault no está disponible).
- La passphrase del `.p12` también se encripta por separado.
- Cargados a memoria solo durante la operación, nunca persistidos en disco descifrados.

#### 7.2.3 Auth manager

- Cada tenant mantiene su propio JWT de DGII (TTL de 1 hora aprox.).
- Cache en Redis con expiración automática.
- Refresh transparente: si el token va a expirar en < 5 min, se renueva proactivamente.
- En caso de 401, retry una vez con nueva autenticación antes de fallar.

#### 7.2.4 Job queue

- Cola `ecf:send` — envío de comprobantes.
- Cola `ecf:status-poll` — polling de estatus en proceso.
- Cola `ecf:receive-arecf` — generación y envío de acuses.
- Reintentos con backoff exponencial (5s, 30s, 2m, 10m, 1h).
- Dead letter queue para fallos definitivos.

#### 7.2.5 Cliente Flutter (MangoPOS)

- Nuevo módulo `ecf/` en el código Flutter.
- Pantallas:
  - Configuración inicial e-CF (carga de certificado, RNC, rangos)
  - Bandeja de e-CFs emitidos
  - Bandeja de e-CFs recibidos
  - Aprobación comercial
  - Reportes / monitoreo
- Comunicación con `ecf-service` vía REST (no usar la lib `dgii-ecf` directamente — Flutter no la soporta y exponer certificados al cliente sería un riesgo enorme).
- Realtime updates de estatus vía Supabase Realtime subscriptions.

### 7.3 Modelo de datos (Supabase Postgres)

```sql
-- Cada tenant es una sucursal/negocio independiente
create table ecf_tenants (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references businesses(id), -- cliente padre
  rnc varchar(11) not null unique,
  razon_social text not null,
  environment text check (environment in ('TEST','CERT','PROD')) default 'TEST',
  certificate_blob bytea, -- encrypted .p12
  certificate_password_encrypted text,
  certificate_subject text,
  certificate_valid_from timestamptz,
  certificate_valid_to timestamptz,
  receiver_url text generated always as ('https://ecf.mangopos.do/r/' || id::text) stored,
  active boolean default false,
  created_at timestamptz default now()
);

-- Rangos de eNCF asignados
create table ecf_sequences (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references ecf_tenants(id),
  ecf_type varchar(2) not null, -- '31','32','33',etc
  range_from bigint not null,
  range_to bigint not null,
  next_number bigint not null,
  active boolean default true,
  unique(tenant_id, ecf_type, range_from)
);

-- Comprobantes emitidos
create table ecf_documents (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references ecf_tenants(id),
  ecf_type varchar(2) not null,
  encf varchar(13) not null,
  rnc_comprador varchar(11),
  monto_total numeric(14,2),
  fecha_emision timestamptz,
  fecha_firma timestamptz,
  security_code varchar(6),
  track_id text,
  status text check (status in (
    'pending','sent','accepted','rejected','approved_commercial','rejected_commercial','voided'
  )),
  status_message text,
  signed_xml text, -- almacenamiento XML completo
  qr_url text,
  invoice_id uuid references invoices(id), -- referencia al POS
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique(tenant_id, encf)
);

-- Comprobantes recibidos
create table ecf_received_documents (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references ecf_tenants(id),
  rnc_emisor varchar(11) not null,
  ecf_type varchar(2),
  encf varchar(13) not null,
  monto_total numeric(14,2),
  fecha_emision timestamptz,
  received_xml text,
  arecf_sent boolean default false,
  arecf_xml text,
  commercial_status text check (commercial_status in (
    'pending','approved','rejected'
  )) default 'pending',
  commercial_response_xml text,
  created_at timestamptz default now()
);

-- Log de auditoría
create table ecf_audit_log (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references ecf_tenants(id),
  action text not null, -- 'send','receive','approve','void','auth','cert_upload'
  document_id uuid,
  user_id uuid,
  request_payload jsonb,
  response_payload jsonb,
  success boolean,
  error_detail text,
  created_at timestamptz default now()
);
```

**RLS:** todas las tablas con `tenant_id` deben tener policies que filtren por el `business_id` del usuario autenticado.

---

## 8. Requisitos no funcionales

### 8.1 Seguridad

- **NFR-S01.** Certificados `.p12` encriptados en reposo (AES-256-GCM).
- **NFR-S02.** Passphrase de certificado nunca expuesta al cliente Flutter ni almacenada en plaintext.
- **NFR-S03.** Comunicación cliente-servidor solo sobre HTTPS (TLS 1.2+).
- **NFR-S04.** Endpoints internos protegidos con API key + JWT del usuario MangoPOS.
- **NFR-S05.** Endpoints públicos de recepción usan el flujo seed/JWT estándar de DGII.
- **NFR-S06.** Logs de auditoría inmutables (append-only) para todas las operaciones e-CF.
- **NFR-S07.** Rate limiting en endpoints públicos para prevenir abuso (Traefik middleware).
- **NFR-S08.** RLS estricto en Supabase: ningún tenant puede ver datos de otro.
- **NFR-S09.** Rotación de la llave maestra de encriptación documentada y probada.

### 8.2 Performance

- **NFR-P01.** Latencia P95 de emisión POS → DGII Aceptado: < 8s.
- **NFR-P02.** Throughput sostenido: ≥ 50 e-CF/segundo agregado entre todos los tenants.
- **NFR-P03.** Cold start del microservicio: < 10s.

### 8.3 Disponibilidad y resiliencia

- **NFR-A01.** Disponibilidad del microservicio: ≥ 99.5% mensual.
- **NFR-A02.** Si DGII está caído, los e-CFs se encolan y reintentan automáticamente sin perder ventas.
- **NFR-A03.** Healthcheck y autorestart configurados en Coolify.
- **NFR-A04.** Backup diario de `ecf_documents` y `ecf_received_documents` (XMLs son evidencia legal).

### 8.4 Cumplimiento

- **NFR-C01.** Retención de XMLs firmados: mínimo 10 años (requerimiento DGII).
- **NFR-C02.** Trazabilidad completa de cada e-CF desde POS hasta DGII.
- **NFR-C03.** Conformidad con la especificación XML vigente de DGII (validar contra XSD).

### 8.5 Observabilidad

- **NFR-O01.** Logs estructurados (JSON) enviados a un agregador (Loki, Datadog, o equivalente).
- **NFR-O02.** Métricas Prometheus expuestas: req/s, latencia, error rate, queue depth.
- **NFR-O03.** Alertas automáticas a soporte cuando: error rate > 5%, queue backlog > 100, certificado expira en < 30 días.

---

## 9. Flujos de usuario clave

### 9.1 Onboarding de e-CF para un tenant nuevo

1. Admin del negocio entra a Configuración → Facturación Electrónica.
2. Sube su archivo `.p12` y escribe passphrase.
3. Sistema valida y muestra info del certificado (subject, vigencia).
4. Admin ingresa RNC, razón social, rangos de eNCF asignados por DGII.
5. Admin selecciona ambiente: TesteCF (default).
6. Admin copia la URL de recepción autogenerada y la registra en el portal de DGII.
7. Sistema realiza un test de autenticación contra DGII y muestra ✅ o ❌.
8. Admin puede activar emisión.

### 9.2 Emisión durante una venta (caso happy path — Consumo 32)

1. Cajero cierra venta, monto RD$1,500.
2. POS envía JSON al microservicio.
3. Microservicio: asigna eNCF → JSON→XML → firma → envía a DGII → recibe trackId.
4. POS imprime receipt con eNCF + QR + código seguridad. **Latencia objetivo: 3-5s**.
5. Background: poll a DGII → estatus pasa a `accepted` en ~10-30s.
6. Realtime push a Flutter actualiza el indicador en la bandeja.

### 9.3 Caída de DGII durante una venta

1. Cajero cierra venta.
2. Microservicio intenta enviar pero DGII responde 5xx o timeout.
3. e-CF queda en estatus `pending`, encolado para retry.
4. POS imprime receipt provisional con leyenda "Pendiente de validación DGII".
5. Worker reintenta cada 5s → 30s → 2m → 10m → 1h.
6. Cuando DGII vuelve, se procesa la cola y el receipt se actualiza a `accepted`.
7. Si en 24h no se resuelve, alerta a soporte.

### 9.4 Recepción de e-CF de un proveedor

1. Proveedor envía e-CF a `https://ecf.mangopos.do/r/{tenant_id}/fe/recepcion/api/ecf`.
2. Microservicio valida firma y certificado (`validateXMLCertificate`).
3. Si es válido: persiste, genera ARECF, lo firma y lo retorna en la respuesta.
4. e-CF aparece en bandeja del receptor con estatus `pending` (aprobación comercial).
5. Realtime push notifica al usuario.

### 9.5 Aprobación comercial

1. Usuario abre bandeja de recibidos.
2. Selecciona un e-CF y revisa detalle.
3. Click en `Aprobar` (o `Rechazar` con razón).
4. Microservicio genera ACECF, firma y envía a emisor (`sendCommercialApproval`).
5. Estatus cambia y se vincula al módulo de cuentas por pagar.

---

## 10. Plan de rollout

### 10.1 Fase 0 — Setup (Sprint 0, 2 semanas)

- [ ] Crear repositorio `ecf-service` (Node + TypeScript).
- [ ] Configurar deploy en Coolify, dominio `ecf.mangopos.do` con Traefik + Cloudflare.
- [ ] Crear esquema de tablas en Supabase con RLS.
- [ ] Implementar Cert Vault con encriptación AES-256-GCM.
- [ ] Setup de BullMQ + Redis.
- [ ] Logs y métricas básicas.

### 10.2 Fase 1 — Emisión básica en TesteCF (Sprints 1–2, 4 semanas)

- [ ] UI Flutter: onboarding de certificado y configuración del tenant.
- [ ] Endpoint de emisión para tipos 31, 32 (con RFCE), 33, 34.
- [ ] Generación de QR.
- [ ] Polling de estatus.
- [ ] Bandeja de emitidos en Flutter con Realtime.
- [ ] **Gate:** 100 e-CFs emitidos exitosamente en TesteCF con un negocio piloto interno.

### 10.3 Fase 2 — Tipos adicionales y anulación (Sprint 3, 2 semanas)

- [ ] Tipos 41, 43, 44, 45, 46.
- [ ] Anulación de rangos.
- [ ] Reintentos y dead letter queue.

### 10.4 Fase 3 — Recepción y aprobación comercial (Sprints 4–5, 4 semanas)

- [ ] Endpoints públicos de seed/JWT/recepción por tenant.
- [ ] Generación automática de ARECF.
- [ ] UI de bandeja de recibidos.
- [ ] Flujo de aprobación comercial (ACECF).
- [ ] Validación de firma de e-CFs entrantes.

### 10.5 Fase 4 — Certificación CertECF (Sprint 6, 3 semanas)

- [ ] Migrar tenant piloto a CertECF.
- [ ] Pasar el set de pruebas oficial de DGII.
- [ ] Documentación de soporte para clientes.
- [ ] Capacitación interna de equipo de soporte.

### 10.6 Fase 5 — Producción (Sprint 7+)

- [ ] Habilitar `Producción` para tenant piloto.
- [ ] Onboarding gradual de clientes (cohortes de 5-10 por semana).
- [ ] Monitoreo intensivo primeras 4 semanas.
- [ ] Iteración de UX según feedback.

---

## 11. Riesgos y mitigaciones

| Riesgo | Impacto | Probabilidad | Mitigación |
|---|---|---|---|
| DGII cambia especificación XML sin previo aviso | Alto | Media | Suscripción a changelog DGII; abstraer Transformer; tests automatizados contra schemas. |
| Cliente carga certificado expirado o incorrecto | Medio | Alta | Validación al cargar + alertas proactivas 30/15/7 días antes. |
| Caída prolongada de DGII | Alto | Media | Cola de reintentos + receipts provisionales + dashboard de salud DGII. |
| Compromiso del Cert Vault | Crítico | Baja | Encriptación robusta + rotación + auditoría + acceso restringido. |
| Latencia alta en emisión rompe UX del POS | Alto | Media | Pre-firma asíncrona, receipt provisional, optimización de cold paths. |
| Repositorio `dgii-ecf` queda sin mantenimiento | Medio | Media | Fork interno; contribuir upstream; eventualmente reescribir core en propio. |
| Conflicto entre rangos de eNCF asignados | Alto | Baja | Locks pesimistas en `ecf_sequences.next_number` durante asignación. |
| SSL expira y tumba `ecf.mangopos.do` | Alto | Baja | Recordatorio del problema previo con `realplay.do`: validar que el dominio esté correctamente registrado en Cloudflare antes del primer despliegue para que el DNS-01 challenge de Traefik funcione. |
| Cliente con tablet ARM falla en recibir push (caso T10M Pro) | Medio | Media | Push de estatus también vía polling como fallback; telemetría por dispositivo. |

---

## 12. Dependencias

- **Externas:**
  - DGII APIs (TesteCF / CertECF / Producción).
  - DigiFirma (emisión de certificados de los clientes).
  - Cloudflare (DNS).
- **Internas:**
  - Supabase self-hosted operativo y con backups.
  - Coolify con espacio para nuevo contenedor.
  - Equipo de soporte capacitado para troubleshooting de e-CF.
- **Librerías:**
  - `dgii-ecf` (npm) — versión más reciente; pin de versión por release.
  - `bullmq`, `redis`, `fastify`, `pino`, `zod`.
- **Documentación de referencia:**
  - [DGII — Documentación oficial e-CF](https://dgii.gov.do/cicloContribuyente/facturacion/comprobantesFiscalesElectronicosE-CF/)
  - Formatos XML oficiales DGII (versión vigente)
  - `dgii-ecf` README

---

## 13. UX / cambios en MangoPOS

### 13.1 Pantallas nuevas

1. **Configuración → Facturación Electrónica** (sub-secciones: Certificado, Rangos, Recepción, Logs).
2. **Bandeja e-CF Emitidos** — filtrable por estado, tipo, fecha.
3. **Bandeja e-CF Recibidos** — con flujo de aprobación inline.
4. **Detalle de e-CF** — XML, QR, historial de eventos, descarga.
5. **Dashboard e-CF** — métricas del día/mes.

### 13.2 Cambios en flujo de cobro existente

- Selector de tipo de comprobante en el momento de cierre de venta.
- Campo opcional de RNC del comprador (con validación contra directorio DGII si aplica).
- Estado del e-CF visible en el ticket de cierre (✓ Aceptado / ⏳ Pendiente / ✗ Rechazado).

### 13.3 Impresión de receipts

- Diseño actualizado del ticket para incluir QR, eNCF, código de seguridad, leyenda legal.
- Mantener compatibilidad con impresoras térmicas USB existentes.

---

## 14. Open questions / Decisiones pendientes

1. **Modelo de pricing del módulo e-CF**: ¿feature incluida o upsell? ¿Por volumen de e-CFs?
2. **Onboarding del certificado**: ¿se ofrece servicio asistido para clientes que no saben cómo obtenerlo de DigiFirma?
3. **Multi-rango por tipo de comprobante**: ¿permitimos varios rangos activos simultáneamente o solo uno?
4. **Notificaciones al comprador**: ¿enviamos el e-CF por email automáticamente al RNC comprador? ¿WhatsApp?
5. **Cancelación de e-CF emitido** (no solo void de rango): la DGII no permite "borrar" un e-CF aceptado, solo emitir nota de crédito. ¿Cómo lo modelamos en el POS?
6. **Histórico pre-migración**: ¿migramos NCFs físicos viejos al sistema nuevo o solo emisión nueva?
7. **Soporte offline en POS**: ¿qué pasa si el POS Windows pierde internet pero quiere seguir vendiendo? ¿Cola local?
8. **Reportes 605/606/607**: ¿en este PRD o en uno separado?

---

## 15. Criterios de aceptación globales

El PRD se considera completado cuando:

- [ ] Un negocio piloto interno emite y recibe e-CFs en producción durante 30 días sin incidentes mayores.
- [ ] La tasa de aceptación en primer envío es ≥ 98%.
- [ ] Existe documentación pública (manual de usuario) para clientes.
- [ ] El equipo de soporte tiene runbooks para los 10 errores más comunes.
- [ ] Se han realizado al menos 5 pruebas de carga simulando 50 RPS.
- [ ] Auditoría de seguridad interna del Cert Vault completada.

---

## 16. Anexos

### 16.1 Tabla de tipos de e-CF

| Código | Nombre | Uso típico |
|---|---|---|
| 31 | Crédito Fiscal | B2B con RNC del comprador |
| 32 | Consumo | B2C; usa RFCE si < 250K |
| 33 | Nota de Débito | Ajustes a favor del emisor |
| 34 | Nota de Crédito | Devoluciones, descuentos |
| 41 | Compras | Compras a PF no inscritas |
| 43 | Gastos Menores | Caja chica |
| 44 | Regímenes Especiales | Zonas francas, etc. |
| 45 | Gubernamental | Ventas al Estado |
| 46 | Exportaciones | Ventas al exterior |

### 16.2 Mapeo de wrappers XML para firma

| Wrapper | Uso |
|---|---|
| `ECF` | Comprobante normal (31, 32, 33, 34, etc.) |
| `RFCE` | Resumen de factura de consumo (32 < 250K) |
| `ARECF` | Acuse de recibo |
| `ACECF` | Aprobación comercial |
| `ANECF` | Anulación |

### 16.3 Variables de entorno del microservicio

```env
NODE_ENV=production
PORT=3000
SUPABASE_URL=...
SUPABASE_SERVICE_ROLE_KEY=...
REDIS_URL=...
CERT_VAULT_MASTER_KEY=...
DGII_ENV=TEST # TEST | CERT | PROD
LOG_LEVEL=info
SENTRY_DSN=...
```

---

**Fin del PRD-08**