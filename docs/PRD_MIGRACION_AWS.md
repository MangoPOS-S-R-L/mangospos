# PRD — Migración de Infraestructura a AWS (Supabase self-hosted → ECS Fargate + RDS)

> **Estado:** Borrador para revisión **Fecha:** 2026-06-26 **Dueño de
> producto:** Cristian Gómez **Autor del documento base de infraestructura:**
> Nicholas — _"Infraestructura en AWS y Plan de Migración Inicial"_ (21
> jun 2026) **Ámbito:** Migrar el Supabase autohospedado (hoy en VPS de
> Hostinger sobre Coolify) hacia AWS, usando **ECS Fargate** para los
> contenedores de Supabase, **RDS PostgreSQL** como base de datos administrada,
> y servicios de red/almacenamiento/observabilidad de AWS. **El objetivo NO es
> agregar features**: es mover la plataforma a una infraestructura escalable y
> con redundancia, **sin romper** cashier, auth, impresión, pagos (Azul), fiscal
> (Alanube/DGII), Realtime/KDS ni el scoping por negocio. **Restricción
> central:** las apps Flutter en producción (Android/Windows/iOS/macOS) ya
> instaladas en ~22 negocios deben **seguir funcionando sin reinstalar**. Eso
> condiciona casi todas las decisiones de abajo.

---

## 0. Decisiones de alcance

### 0.1 Decisiones cerradas (tomadas del documento de Nicholas)

| #   | Decisión              | Resolución                                                                                                                                                                 |
| --- | --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | Proveedor destino     | **AWS**, región `us-east-1`.                                                                                                                                               |
| D2  | Cómputo               | **ECS Fargate** (serverless de contenedores), no EC2 administrado a mano.                                                                                                  |
| D3  | Base de datos         | **RDS PostgreSQL**, `db.t3.medium` (2 vCPU, 4 GB), almacenamiento `gp3` 100 GB. **Single-AZ** en esta primera etapa; Multi-AZ se evalúa cuando crezca la base de clientes. |
| D4  | Storage               | **Amazon S3** como backend nativo de Supabase Storage (`STORAGE_BACKEND=s3`).                                                                                              |
| D5  | Entrada de tráfico    | **ALB** (capa 7) con path-based routing + terminación TLS con cert **ACM** wildcard `*.mangopos.do`.                                                                       |
| D6  | DNS                   | Migrar el dominio `mangopos.do` a **Route 53**.                                                                                                                            |
| D7  | Secretos              | **AWS Secrets Manager** para JWT_SECRET, credenciales de DB, ANON_KEY, SERVICE_ROLE_KEY, SMTP.                                                                             |
| D8  | Observabilidad        | **CloudWatch** centraliza logs y métricas (reemplaza ver logs en Coolify/Portainer).                                                                                       |
| D9  | NO sobredimensionar   | Single-AZ + 1 NAT Gateway por ahora. Multi-AZ, segundo NAT y Aurora Serverless quedan para una etapa "macro" con más clientes/capital.                                     |
| D10 | Estrategia de cutover | Sistema viejo (Hostinger) se mantiene intacto y activo hasta confirmar estabilidad; rollback = revertir DNS.                                                               |

### 0.2 Decisiones técnicas que el documento NO resuelve y propongo cerrar antes de tocar nada

Estas son las que de verdad determinan si la migración rompe o no la app. Las
propongo con recomendación; confírmalas o cámbialas antes de ejecutar.

| #      | Tema                                          | Riesgo si se ignora                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Recomendación                                                                                                                                                                                                                                                                                                                      |
| ------ | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **T1** | **Continuidad del JWT_SECRET / ANON_KEY**     | **Rompe TODAS las apps instaladas.** El `SUPABASE_ANON_KEY` viene **horneado en cada build** ([lib/env/env.dart](../lib/env/env.dart)). Está firmado con el `JWT_SECRET` actual del VPS. Si en AWS se genera un JWT_SECRET nuevo, el anon key embebido queda inválido → ninguna app autentica.                                                                                                                                                                                                                                             | **Reusar EXACTAMENTE el mismo `JWT_SECRET`, `ANON_KEY` y `SERVICE_ROLE_KEY` del VPS.** No regenerar. Copiarlos tal cual a Secrets Manager.                                                                                                                                                                                         |
| **T2** | **Continuidad del hostname**                  | Si el endpoint cambia de host, hay que **recompilar y redistribuir** las 4 plataformas.                                                                                                                                                                                                                                                                                                                                                                                                                                                    | **Mantener `supabase.mangopos.do`** apuntando al ALB (ese es el `SUPABASE_URL` por defecto de la app, [env.dart:6](../lib/env/env.dart#L6)). Así el cutover es solo DNS: cero rebuilds. El dominio de cookies web `.mangopos.do` ([cookie_local_storage.dart](../lib/core/network/cookie_local_storage.dart)) también se preserva. |
| **T3** | **Contenedor `functions` (Edge Runtime)**     | **El doc lista 5 contenedores (kong, postgrest, gotrue, realtime, storage) y OMITE `functions`.** Sin él se caen **pagos Azul** (3DS, tokenización, cobros, suscripciones) y **e-CF Alanube**. Ver [supabase/functions/](../supabase/functions/).                                                                                                                                                                                                                                                                                          | **Migrar también el contenedor `functions`** como 6.º task de ECS, con su ruta en Kong (`/functions/v1/*`) y todos sus secretos (incl. Azul). No es opcional.                                                                                                                                                                      |
| **T4** | **Migración de los OBJETOS de Storage**       | El doc migra la **DB** (pg_dump) pero **no menciona mover los archivos** ya subidos del disco del VPS al bucket S3. Con `STORAGE_BACKEND=s3` la tabla `storage.objects` apuntaría a archivos que **no existen** en S3 → imágenes rotas. Buckets confirmados en la app: **`menu-items`** ([storage_repository.dart](../lib/data/repositories/storage_repository.dart)) y **`business-logos`** ([business_profile_repository.dart](../lib/data/repositories/business_profile_repository.dart)); verificar en el server si hay más (recibos). | **Sincronizar el volumen de Storage del VPS → bucket S3** (`aws s3 sync`) **antes** del cutover, preservando las mismas keys/paths que tiene `storage.objects`. Validar que `getPublicUrl` resuelve.                                                                                                                               |
| **T5** | **IP de egress para Azul (mTLS) e Incapsula** | Azul producción usa **mTLS con cert cliente** y **whitelist de IP**. Hoy la IP saliente es la del VPS. En AWS el egress sale por el **NAT Gateway (EIP nueva)** → Azul/Incapsula la rechazarán hasta re-whitelistear. (Ver bloqueo Incapsula previo: IP `31.97.40.114`.)                                                                                                                                                                                                                                                                   | **Asignar una EIP fija al NAT Gateway** y **solicitar whitelist de esa IP a Azul** con anticipación. Mover los certs mTLS de Azul a Secrets Manager / montaje seguro en el task `functions`. Bloquea el go-live de pagos si no se coordina.                                                                                        |
| **T6** | **No arrastrar el bloat de Logflare (75 GB)** | El disco del VPS está dominado por `_supabase._analytics.log_events` (**~75 GB, 51.8M filas, sin retención**). La DB de negocio (`postgres`) son **~200 MB**.                                                                                                                                                                                                                                                                                                                                                                              | **`pg_dump` SOLO de la base `postgres`** (negocio). **NO migrar `_supabase`/analytics.** En AWS, reemplazar Logflare por CloudWatch (D8) o, si se mantiene, configurar **retención desde el día 1**.                                                                                                                               |
| **T7** | **Extensiones y `pg_cron` en RDS**            | La app usa `pg_trgm`, `btree_gist` (constraint EXCLUDE de Reservas) y **varios `cron.schedule`** (heartbeat stale-cleanup, cobro de suscripciones Azul, liberar mesas vacías). RDS no habilita extensiones ni `pg_cron` por defecto.                                                                                                                                                                                                                                                                                                       | **Inventariar extensiones**, habilitarlas en el **parameter group** de RDS (`shared_preload_libraries=pg_cron`), y **recrear los `cron.schedule`** tras restaurar (no siempre sobreviven al dump).                                                                                                                                 |
| **T8** | **`imgproxy`**                                | El doc lo menciona en el contexto actual pero no en la lista de contenedores a migrar. Si Storage sirve transformaciones de imagen, falta.                                                                                                                                                                                                                                                                                                                                                                                                 | Verificar si la app pide transformaciones (`/render/image/...`). Si sí, migrar `imgproxy` como task adicional; si no, omitir explícitamente.                                                                                                                                                                                       |
| **T9** | **WebSocket de Realtime por el ALB**          | KDS, mesas y heartbeats dependen de Realtime (WSS). Si el target group no soporta WS o el idle timeout es bajo, se cae el tiempo real.                                                                                                                                                                                                                                                                                                                                                                                                     | ALB soporta WebSocket nativo; **subir el idle timeout** del ALB (p. ej. 300 s) y health-check correcto para `/realtime/*`. Aprovechar para **bajar la tormenta de heartbeats** (ver §4.4).                                                                                                                                         |

---

## 1. Estado actual

### 1.1 Infraestructura (origen)

- **1 servidor** Ubuntu 24.04 en Hostinger: 4 vCPU, 16 GB RAM, 200 GB disco.
  ~USD $75/mes.
- **Supabase self-hosted sobre Coolify**, Traefik como reverse proxy + Let's
  Encrypt, todos los servicios como contenedores Docker: **PostgreSQL, Kong,
  PostgREST, GoTrue (Auth), Realtime, Storage, imgproxy, Edge Functions, y el
  stack de logs (Vector → Logflare/analytics)**.
- **~22 negocios** activos en RD.
- **Limitaciones:** punto único de falla, solo escala vertical (manual), DB no
  separada del app server, sin recuperación automática.
- **Deuda conocida (de diagnósticos previos):**
  - `_supabase._analytics.log_events` = **~75 GB sin retención** (Logflare) —
    _no migrar_.
  - **Tormenta de heartbeats/Realtime**: `printer_heartbeat_scheduler` corre
    cada 30 s en cada dispositivo; `printers` está en la publicación Realtime →
    fan-out grueso de egress (~18.7 GB/día de WAL). Oportunidad de limpiar en la
    migración.

### 1.2 Lado de la app (lo que condiciona la migración)

- **Endpoint:** `SUPABASE_URL = https://supabase.mangopos.do`, `ANON_KEY`
  **horneado en el build** ([env.dart](../lib/env/env.dart)). Inicialización en
  [main.dart:522-526](../lib/main.dart#L522).
- **Storage:** subidas vía `supabase.storage.from('menu-items')` y
  `getPublicUrl`
  ([storage_repository.dart](../lib/data/repositories/storage_repository.dart),
  [business_profile_repository.dart](../lib/data/repositories/business_profile_repository.dart)).
  Hay un **rewrite legacy** de URLs viejas
  `sqdwjjewdqzxglvqerqt.supabase.co → supabase.mangopos.do` en
  [menu_items_view.dart:428](../lib/presentation/settings/more%20settings/menus/menu%20items/view/menu_items_view.dart#L428)
  que asume el host actual.
- **Edge Functions:** Azul (3DS, charge-now, charge-subscription, tokenize,
  void-hold, payment-form) y Alanube e-CF. Sensibles y con secretos (mTLS Azul).
- **Realtime:** KDS, estado de mesas/salón, heartbeats de impresoras.
- **Offline queue:** la app encola transacciones offline y nunca las borra al
  cerrar sesión. **Esto es una red de seguridad para el cutover**: durante el
  downtime, las cajas siguen vendiendo y sincronizan al volver.

---

## 2. Objetivo y métricas de éxito

**Objetivo:** la plataforma corre 100% en AWS con la misma funcionalidad, **sin
que ningún negocio tenga que reinstalar la app**, y con downtime de cutover ≤ 3
h.

**Métricas / criterios de aceptación:**

- **Cero rebuilds** de la app para el cambio de infra (gracias a T2: mismo
  hostname).
- **Paridad de conteo de filas** por tabla principal entre Hostinger y RDS
  post-restore (validación obligatoria de Fase 2).
- **Auth funciona** con el ANON_KEY embebido existente (valida T1).
- **Storage:** una imagen de menú vieja y una nueva cargan correctamente
  post-cutover (valida T4).
- **Pagos Azul** procesan un cobro de prueba desde la nueva IP (valida T3 + T5).
- **Realtime:** un ítem nuevo aparece en KDS en < 10 s (valida T9).
- **Downtime de cutover:** 1–3 h, en ventana de madrugada.
- **Rollback probado:** revertir DNS restaura servicio en minutos.

---

## 3. Arquitectura propuesta (resumen)

Distribuye el monolito-VPS en servicios administrados de AWS, todos en una VPC
con subredes públicas (ALB, NAT GW) y privadas (ECS, RDS):

```
Usuario/App Flutter (Android/Win/iOS/macOS)
        │ HTTPS 443 (supabase.mangopos.do → ALB, cert ACM)
        ▼
   ALB (path-based routing, capa 7)
        ▼
   Kong API Gateway (ECS Fargate)
   ├── /auth/*       → GoTrue
   ├── /rest/*       → PostgREST
   ├── /realtime/*   → Realtime (WebSocket)
   ├── /storage/*    → Storage API ───────► S3 (objetos) ──► CloudFront (CDN/OTA)
   └── /functions/*  → Edge Functions  ◄── (T3: NO omitir)
        ▼
   RDS PostgreSQL (db.t3.medium, gp3 100GB, subred privada)
```

| Servicio        | Rol                                              | Costo base aprox.    |
| --------------- | ------------------------------------------------ | -------------------- |
| Route 53        | DNS de `mangopos.do`                             | $0.50/zona + queries |
| ACM             | Cert wildcard `*.mangopos.do`                    | Gratis               |
| ALB             | Balanceo L7 + TLS + WebSocket                    | ~$18.40 + LCU        |
| ECS Fargate     | 5–6 contenedores de Supabase                     | ~$54                 |
| ECR             | Registro de imágenes Docker                      | ~$0.15               |
| RDS PostgreSQL  | DB administrada, backups, parches                | ~$52.56              |
| NAT Gateway     | Egress de subred privada (ECR, logs, SMTP, Azul) | ~$32.85 + uso        |
| S3              | Objetos: recibos, imágenes, `appcast.xml`, MSIX  | ~$1                  |
| CloudFront      | CDN para S3 / descargas OTA                      | ~$0.04               |
| Secrets Manager | JWT, DB pass, ANON/SERVICE keys, Azul certs      | ~$2.40               |
| CloudWatch      | Logs + métricas + alertas                        | ~$4–8                |
| VPC/Subnets/SG  | Red privada aislada                              | Gratis               |

**Costo estimado:** ~**$208/mes** con 20 clientes (vs $75/mes actual). El delta
compra SLA, backups automáticos, redundancia del ALB (multi-AZ) y capacidad de
escalar a 1,000+ clientes reajustando, no rediseñando.

> **Nota de honestidad técnica (del propio documento):** esta primera etapa
> **no** garantiza Multi-AZ en datos ni Multi-Región. RDS es Single-AZ y ECS
> arranca con tasks mínimos. Es una decisión deliberada para no sobredimensionar
> sin ingresos que lo sostengan; el camino a Multi-AZ queda abierto sin
> rediseño.

---

## 4. Plan de migración por fases

> **Principio:** todo el trabajo se hace **en paralelo** con producción viva en
> Hostinger. Hostinger no se toca hasta el cutover, y se mantiene intacto hasta
> confirmar estabilidad. **Tiempo total estimado: 3–4 semanas. Downtime solo en
> cutover: 1–3 h.**

### Fase 1 — Red (VPC) · 2–3 días · sin downtime

Crear VPC, subredes públicas/privadas en ≥2 AZ, Internet Gateway, **NAT Gateway
con EIP fija** (T5), Security Groups (ECS↔RDS, ALB↔ECS), route tables, **VPC
Endpoint de S3** (ahorra tráfico NAT), y hosted zone de Route 53 para
`mangopos.do` (sin delegar todavía).

### Fase 2 — Base de datos · 2–3 días · sin downtime · **la más delicada**

> **Antes de empezar, lee
> [§4.6 Gotchas de ejecución](#46-gotchas-de-ejecución-supabase-self-hosted--rds--léelo-antes-de-fase-2).**
> No es un `pg_restore` y listo.

1. Provisionar RDS `db.t3.medium`, gp3 100 GB.
2. **`pg_dump` SOLO de la base `postgres`** (negocio). **Excluir
   `_supabase`/analytics** (T6).
3. Transferir vía S3/SCP y `pg_restore` en RDS.
4. **Habilitar extensiones** (`pg_trgm`, `btree_gist`, `pgcrypto`, …) y
   **`pg_cron`** en el parameter group; **recrear los `cron.schedule`** (T7).
5. Crear los roles internos de Supabase (`authenticator`, `supabase_auth_admin`,
   `supabase_storage_admin`, `supabase_realtime_admin`) con sus passwords.
6. **Validar integridad:** comparar `count(*)` por tabla principal Hostinger vs
   RDS.

### Fase 3 — Imágenes Docker en ECR · 4–7 días · sin downtime

1. Crear repos ECR:
   `mango-supabase-{kong,postgrest,gotrue,realtime,storage,functions}` (**6, no
   5** — T3). Más `imgproxy` si aplica (T8).
2. `docker pull` de las versiones EXACTAS que corren hoy en Coolify (documentar
   digests SHA).
3. Aplicar modificaciones: Storage→S3, Functions con sus secretos/mTLS, cadenas
   de conexión a RDS.
4. `docker push` a ECR.

### Fase 4 — ECS Fargate + ALB · 3–5 días · sin downtime

1. Guardar **todos** los secretos en Secrets Manager — **reusando
   JWT/ANON/SERVICE exactos** (T1).
2. Task Definitions de los 6 servicios, ECS Service, cluster.
3. ALB en subredes públicas, listener HTTPS:443 con cert ACM, target groups +
   health checks, **idle timeout alto para WebSocket** (T9).
4. **Sincronizar objetos de Storage del VPS → S3** (`aws s3 sync`) (T4).
5. Validación end-to-end contra el **DNS temporal del ALB** (sin tocar el DNS
   real): login, crear orden, **subir imagen**, **cobro Azul de prueba desde la
   EIP nueva** (T5), evento Realtime en KDS.

### Fase 5 — Cutover de DNS y go-live · 1 día · downtime 1–3 h

1. **24 h antes:** bajar TTL del registro DNS a 60 s.
2. Ventana de madrugada (domingo). **Dump final** del Postgres de Hostinger para
   capturar las últimas transacciones → restaurar en RDS.
3. Delegar nameservers de `mangopos.do` a Route 53; apuntar
   `supabase.mangopos.do` al ALB (T2). Configurar CloudFront para S3.
4. Monitorear CloudWatch 24–48 h. Mantener Hostinger intacto.
5. **Red de seguridad:** durante el corte, las cajas siguen vendiendo gracias a
   la **cola offline** de la app; sincronizan al reconectar.

> **Rollback:** si hay error crítico post-cutover, **revertir el DNS a la IP de
> Hostinger** restaura el servicio en minutos. Hostinger se mantiene **sin
> cambios** hasta cerrar el período de estabilización.

### 4.6 Gotchas de ejecución (Supabase self-hosted → RDS) — léelo antes de Fase 2

Esto es lo que **no aparece en ningún tutorial genérico** y es donde se traba
una migración de Supabase autohospedado a RDS. No bloquean la decisión, pero sí
la ejecución.

1. **RDS no te da superusuario.** El dump de Supabase asume un Postgres con
   `supabase_admin` superusuario. En RDS el usuario maestro es `rds_superuser`
   (privilegiado, **no** super).
   - Restaura por partes (no un `pg_restore` monolítico): **primero roles**,
     luego schema, luego datos. Espera errores de
     _ownership_/`ALTER ... OWNER TO supabase_admin` y de `COMMENT ON EXTENSION`
     — son esperables y se ignoran o se ajustan.
   - **Crea los roles ANTES de restaurar:** `supabase_admin`, `authenticator`,
     `anon`, `authenticated`, `service_role`, `supabase_auth_admin`,
     `supabase_storage_admin`, `supabase_realtime_admin`, `dashboard_user`. Sin
     ellos, los `GRANT` del dump fallan.

2. **Realtime exige replicación lógica explícita en RDS.** La app depende de la
   publicación **`supabase_realtime`** con `REPLICA IDENTITY FULL` en
   `printers`, `inventory_stock` y `menu_items` (migs `20260517_0003` y
   relacionadas). El `pg_dump` **no recrea de forma fiable la membresía de la
   publicación ni el slot**. En RDS:
   - Parameter group: **`rds.logical_replication = 1`** (requiere reboot).
   - El rol que usa Realtime necesita **`rds_replication`**.
   - **Recrear la publicación** y re-agregar las tablas +
     `REPLICA IDENTITY FULL` tras el restore. Validar con
     `SELECT * FROM pg_publication_tables WHERE pubname='supabase_realtime';`.

3. **Extrae el inventario EXACTO del server vivo** (no asumas). Antes de Fase
   2/3, corre en el VPS:
   - Extensiones: `SELECT extname, extversion FROM pg_extension;`
   - Cron jobs (a recrear, T7):
     `SELECT jobname, schedule, command FROM cron.job;`
   - Publicaciones Realtime: `SELECT * FROM pg_publication_tables;`
   - Buckets de Storage: `SELECT id, name, public FROM storage.buckets;`
   - Versiones Docker exactas: `docker compose images` (o el
     `docker-compose.yml` de Coolify) — anota los **digests SHA** (Fase 3).
   - Path del volumen de Storage en disco (para el `aws s3 sync` de T4).

4. **`pg_cron` vive en una sola base.** En RDS los jobs de `cron.job` se
   ejecutan desde la base configurada en `cron.database_name`. Verifica que
   apunte a `postgres` (negocio) y recrea ahí los `cron.schedule` (T7).

5. **`search_path` y schema `storage`/`auth`/`realtime`.** El restore debe
   preservar los schemas `auth`, `storage`, `realtime`, `graphql_public` y
   `extensions`. Confirma que `PGRST_DB_SCHEMA` y los `GRANT` por schema
   quedaron intactos (si no, PostgREST devuelve 404/permiso denegado).

> **En resumen:** Fase 2 no es "un `pg_restore` y listo". Es restaurar por
> capas, recrear roles/publicaciones/cron a mano, y habilitar replicación lógica
> en el parameter group. Planifica medio día extra ahí.

---

## 5. Variables de entorno (resumen por servicio)

> Las credenciales van a **Secrets Manager**; la config no sensible, a las Task
> Definitions. **CRÍTICO (T1): `JWT_SECRET`, `ANON_KEY` y `SERVICE_ROLE_KEY`
> deben ser idénticos a los del VPS.**

- **PostgreSQL (RDS):** sin env en ECS; las cadenas
  `DB_HOST/PORT/USER/PASSWORD/NAME` se inyectan por task como secretos.
- **Kong:** `KONG_DATABASE=off`,
  `KONG_DECLARATIVE_CONFIG=/var/lib/kong/kong.yml`, `KONG_LOG_LEVEL=warn`.
  **Agregar la ruta `/functions/v1/*`** al `kong.yml` (T3).
- **PostgREST:** `PGRST_DB_URI` (rol `authenticator`),
  `PGRST_DB_SCHEMA=public,storage,graphql_public`, `PGRST_DB_ANON_ROLE=anon`,
  `PGRST_JWT_SECRET` (Secrets), `PGRST_DB_USE_LEGACY_GUCS=false`.
- **GoTrue:** `GOTRUE_DB_DRIVER=postgres`, `GOTRUE_DB_DATABASE_URL` (rol
  `supabase_auth_admin`), `GOTRUE_SITE_URL` (confirmar `https://mangopos.do` vs
  `app.mangopos.do`), `GOTRUE_JWT_SECRET` (= el actual),
  `GOTRUE_JWT_EXP=604800`, `GOTRUE_SMTP_*` (Secrets).
- **Realtime:** `DB_HOST/USER(=supabase_realtime_admin)/PASSWORD/NAME`,
  `PORT=4000`, `JWT_SECRET` (= el actual).
- **Storage:** `STORAGE_BACKEND=s3`, `AWS_DEFAULT_REGION=us-east-1`,
  `STORAGE_S3_BUCKET=mango-pos-storage`, credenciales IAM (preferible **rol IAM
  del task**, no llaves), `PGRST_JWT_SECRET`, `DATABASE_URL` (rol
  `supabase_storage_admin`).
- **Edge Functions (T3):** `SUPABASE_URL` interno, `SUPABASE_SERVICE_ROLE_KEY`,
  `SUPABASE_ANON_KEY`, `JWT_SECRET`, + **secretos de Azul (incl. cert/key mTLS)
  y Alanube**. Egress por la EIP whitelisteada (T5).

---

## 6. Riesgos y mitigaciones (resumen)

| Riesgo                                              | Severidad              | Mitigación                                                      |
| --------------------------------------------------- | ---------------------- | --------------------------------------------------------------- |
| JWT/ANON regenerados → apps muertas                 | **Crítica**            | T1: reusar idénticos.                                           |
| Falta el contenedor `functions` → pagos/fiscal caen | **Crítica**            | T3: migrarlo como 6.º task.                                     |
| Objetos de Storage no migrados → imágenes rotas     | Alta                   | T4: `aws s3 sync` antes del cutover + validar.                  |
| Azul rechaza la IP nueva (mTLS/Incapsula)           | **Crítica para pagos** | T5: EIP fija + whitelist coordinada con Azul antes del go-live. |
| `pg_cron`/extensiones no recreadas → jobs muertos   | Alta                   | T7: habilitar en parameter group + recrear schedules.           |
| Realtime no fluye por ALB                           | Media                  | T9: WebSocket + idle timeout alto.                              |
| Migrar el bloat de Logflare (75 GB)                 | Media (costo/tiempo)   | T6: dump solo `postgres`, dejar analytics atrás.                |
| Single-AZ = sigue habiendo SPOF en datos            | Aceptada en esta etapa | D3/D9: documentado; Multi-AZ en etapa macro.                    |

---

## 7. Preguntas abiertas

- **P1 (T5):** ¿Cuál es el proceso/tiempo de Azul para re-whitelistear una IP de
  producción? ¿Se puede pre-aprobar la EIP del NAT antes del cutover?
  _(bloqueante de pagos)_
- **P2 (T1):** Confirmar dónde está hoy el `JWT_SECRET` del VPS y exportarlo de
  forma segura.
- **P3 (T8):** ¿La app pide transformaciones de imagen (`imgproxy`)? Si no, se
  omite el contenedor.
- **P4:** `GOTRUE_SITE_URL` — ¿`https://mangopos.do` o
  `https://app.mangopos.do`? Verificar contra el flujo de recovery/confirm de la
  app.
- **P5:** ¿Se mantiene Logflare (con retención) o se reemplaza 100% por
  CloudWatch? (T6/D8.)
- **P6:** ¿Aprovechamos la migración para aplicar las reducciones de
  heartbeat/Realtime (heartbeat 30s→120s, sacar `printers` de la publicación)?
  Reduce egress y costo de NAT/CloudWatch desde el día 1.

---

## 8. Referencias

- Documento base de infraestructura: _"Infraestructura en AWS y Plan de
  Migración Inicial"_, Nicholas, MANGO POS S.R.L., 21 jun 2026.
- Guía AWS citada por Nicholas:
  <https://builder.aws.com/content/3EJOGbyWNAqZkG06Yy31LTiIasu/from-vibe-to-production-a-startups-guide-to-graduating-from-supabase-to-aws>
- Storage S3 self-hosted:
  <https://supabase.com/docs/guides/self-hosting/self-hosted-s3> ·
  <https://supabase.com/docs/guides/storage/s3/compatibility>
- Contexto interno relacionado: diagnóstico de disco/WAL (Logflare 75 GB),
  bloqueo Incapsula Azul (IP `31.97.40.114`), PRD Azul Subscriptions (mTLS
  prod).

---

> **Resumen para Cristian:** el plan de Nicholas es sólido en la capa de
> infraestructura AWS. Lo que falta y agrego aquí es la **perspectiva de la
> app**: (1) **no regenerar JWT/ANON** o se mueren todas las instalaciones, (2)
> **mantener `supabase.mangopos.do`** para cero rebuilds, (3) **migrar también
> `functions`** o se caen Azul/Alanube, (4) **mover los objetos de Storage**, no
> solo la DB, y (5) **coordinar la IP de egress con Azul** antes del go-live.
> Cerrar T1–T9 y P1–P6 antes de ejecutar Fase 1.
