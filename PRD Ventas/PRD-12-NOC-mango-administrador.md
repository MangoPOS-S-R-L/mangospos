# PRD 12 — mango_administrador: NOC y Observabilidad Multi-Tenant

| Campo | Valor |
|---|---|
| **Producto** | mango_administrador (app NOC) |
| **Módulo** | Observabilidad, salud operativa, soporte cross-tenant |
| **Versión del documento** | 1.0 |
| **Fecha** | 2026-05-13 |
| **Autor** | Cristian — Innovech Software LLC |
| **Estado** | Borrador para revisión |
| **Stack** | Flutter (mango_administrador), Supabase (PostgreSQL + RLS bypass vía service role), Realtime |

---

## 1. Resumen ejecutivo

`mango_administrador` es la app/dashboard que el operador de la plataforma MangoPOS (hoy, vos directamente) usa con una cuenta privilegiada para observar la operación de **todos los negocios** que viven sobre el backend Supabase compartido. Funciona como un **NOC (Network Operations Center)** específico para POS: detectar incidentes antes de que el cliente final llame.

Hoy `mango_administrador` ya existe y muestra parte de la actividad de negocios, pero le faltan los paneles que permiten **detectar fallas tempranamente** — cajas zombi, cierres con varianza fuera de rango, impresoras caídas, facturas e-CF stuck, sesiones SQL anómalas, negocios inactivos por churn.

Este PRD consolida en un solo lugar:
1. **Qué métricas críticas hay que monitorear** para garantizar que la plataforma corre sana.
2. **Qué incidentes hay que alertar proactivamente** (no esperar al ticket de soporte).
3. **Qué herramientas de intervención** necesita el NOC (force-close, replay de job, retry de e-CF, etc.).
4. **Cómo se mueve "Salud de cajas"** desde la app MangoPOS hacia mango_administrador.

Decisión arquitectónica clave: la app POS (MangoPOS) queda enfocada en la operación del cajero/manager del negocio individual. **Las funciones de observabilidad cross-tenant y soporte se concentran en mango_administrador.** Esto elimina ruido en la app del cajero y reduce la superficie de permisos sensibles expuesta al cliente final.

---

## 2. Contexto y motivación

### 2.1 Producto actual

- **MangoPOS** (app cliente): Flutter Windows + Android. Cada negocio (restaurante, kiosko, minimarket) opera su POS, ventas, cajas, comandas, etc. Multi-tenant vía RLS por `business_id`.
- **mango_administrador** (app NOC): Flutter desktop usado por el operador de plataforma. Con una sesión de Supabase que tiene rol con bypass de RLS (o service role en algunas ops), ve agregados de todos los `business_id`. Hoy muestra listado de negocios y algunas estadísticas, sin paneles de salud operativa estructurados.

### 2.2 Problema

Cuando algo falla en uno de los negocios, el NOC se entera **reactivamente**: el cliente llama o escribe diciendo "no me imprime", "el cierre no me cuadra", "la factura no salió". Pasan minutos u horas entre el incidente y la detección.

Casos vividos:
1. **Cajas zombi acumuladas** (1 mes 5 días abierta sin cerrar): nadie sabía hasta que se hizo auditoría manual con SQL.
2. **Print agents offline** durante el rush: el cajero descubre cuando ya hay 5 comandas esperando.
3. **Cierres con varianza alta** sin nota: el dueño se entera al revisar el reporte mensual.
4. **e-CF rechazado por DGII** y nadie reacciona: a fin de mes hay 50 documentos sin enviar y posible multa.
5. **Negocio inactivo 30 días** sin renovar: churn que se podría haber prevenido con outreach.
6. **Bug de cálculo replicado en N negocios** (ej. el doble-counting de service fee que descubrimos hoy): se detecta uno a uno mientras se acumulan tickets.

### 2.3 Oportunidad

Centralizar la **observabilidad operativa multi-tenant** en mango_administrador permite:
- **Detección proactiva**: alertas Telegram/email cuando algo crítico falla.
- **Tiempo de respuesta** medible (MTTR) — incidente detectado a las 14:32, resuelto a las 14:51.
- **Forensics**: histórico de incidentes con causa raíz.
- **Soporte preventivo**: contactar al cliente *antes* de que se queje.
- **Métricas de plataforma**: % uptime de impresión, % de cierres OK, etc.
- **Limpieza de UI cliente**: la app POS del cajero queda enfocada, sin paneles que no son para él.

---

## 3. Objetivos

### 3.1 Objetivos de negocio

| ID | Objetivo | Métrica de éxito |
|---|---|---|
| ON-1 | Reducir MTTR de incidentes operativos | < 30 min entre fallo y detección automática |
| ON-2 | Detectar churn antes de que ocurra | % negocios contactados pre-cancelación > 60% |
| ON-3 | Reducir tickets de soporte por bugs replicados | -50% tickets recurrentes en 90 días |
| ON-4 | Mejorar UX del cajero | Quitar 100% de paneles cross-tenant de la app POS |
| ON-5 | Soporte fiscal proactivo | < 24h entre rechazo DGII y reintento exitoso |

### 3.2 Objetivos técnicos

| ID | Objetivo |
|---|---|
| OT-1 | Vistas/RPCs nuevas en Supabase (no agregar más lógica a las RPCs de operación) |
| OT-2 | Acceso a datos cross-tenant solo desde sesiones con rol `platform_admin` (verificado en BD, no en cliente) |
| OT-3 | Realtime para paneles con alta volatilidad (impresoras, cajas abiertas) |
| OT-4 | Polling 60s para paneles de volumen (ventas/día, churn) |
| OT-5 | Audit log de quién accede a `mango_administrador` y qué acciones invoca |
| OT-6 | Alertas vía webhook configurable (Telegram, email, Slack) |
| OT-7 | Cero impacto en performance del cliente POS (las queries del NOC corren con cuotas limitadas) |

---

## 4. Usuarios y casos de uso

### 4.1 Roles

| Rol | Descripción | Permisos |
|---|---|---|
| **Operador plataforma** | El dueño/equipo que opera MangoPOS (vos hoy) | Todo: ver, intervenir, exportar |
| **Soporte L1** (futuro) | Atención al cliente que ve métricas pero no interviene | Solo lectura |
| **Auditor externo** (futuro) | Contador / DGII / inspector | Acceso a reportes fiscales firmados |

### 4.2 Casos de uso priorizados

**CU-01 — Monitor de cajas abiertas en tiempo real**
El operador entra a mango_administrador. Ve un widget en el dashboard principal con conteo de cajas abiertas across-tenant + lista de las que necesitan atención (>12h abiertas o varianza pendiente). Cliquea una → ve detalle. Decide: ignorar (cajero está terminando turno) o force-close (cajero abandonó).

**CU-02 — Alerta de impresora caída en un negocio**
Un agent de impresión deja de mandar heartbeat por >5 min. mango_administrador recibe alerta Telegram. El operador llama al cliente: "vemos que tu impresora 'Cocina' está sin reportar — ¿la apagaste?". Cliente: "ah no me había dado cuenta, gracias". Resuelto antes de que se acumule cola.

**CU-03 — e-CF rechazado por DGII**
Alanube responde rechazo por NCF inválido. mango_administrador muestra banner rojo. El operador entra al detalle, ve el error, corrige la secuencia fiscal del negocio, dispara retry. e-CF emitido en < 30 min.

**CU-04 — Negocio inactivo riesgo de churn**
Un negocio no genera ventas hace 14 días. Aparece en dashboard "Riesgo churn". El operador ve histórico, contacta al cliente: "vimos que no usaste el sistema esta semana, ¿algo que mejorar?". Salva la cuenta.

**CU-05 — Variancia recurrente por cajero**
Reporte semanal muestra que el cajero "Juan" del negocio X cierra siempre con faltante promedio $200. mango_administrador lo señala. El operador contacta al dueño con la evidencia.

**CU-06 — Bug replicado detectado**
mango_administrador ejecuta queries de integridad nightly y detecta 12 órdenes con qty fraccional huérfana, distribuidas en 4 negocios. Notifica al operador. Operador identifica que fue una regresión del deploy de ayer y aplica fix.

**CU-07 — Auditoría fiscal por DGII**
Inspector pide reporte de NCFs emitidos en últimos 30 días para un negocio específico. Operador exporta CSV/PDF desde mango_administrador.

---

## 5. Alcance

### 5.1 Dentro del alcance (V1)

**Paneles de salud operativa:**
1. **Salud de cajas** (cross-tenant): el dashboard ya construido en MangoPOS, **migrado** acá.
2. **Salud de impresión**: print agents conectados/desconectados, jobs failed por negocio.
3. **Salud fiscal**: e-CFs pendientes, rechazados; NCFs próximos a agotarse.
4. **Salud de mesas**: mesas atascadas en "pagando" >1h, sesiones sin actividad reciente.
5. **Negocios**: listado activos / inactivos (sin ventas >X días) / suscripción vencida.

**Panel de incidentes:**
6. Banner global con incidentes activos.
7. Timeline de incidentes resueltos (últimos 7d).
8. Botones de intervención: retry job, force-close session, reintento e-CF.

**Alertas:**
9. Webhook configurable: Telegram bot, email, Slack.
10. Reglas configurables: "alertar si X impresoras offline >5min", "alertar si NCF disponibles < 100", etc.

**Auditoría:**
11. Audit log de acciones invocadas por el operador en mango_administrador.
12. Quien entró, qué consultó, qué intervino.

**Migración de MangoPOS:**
13. Quitar la card "Salud de cajas" del shell de cajero.
14. Quitar la ruta `cashierSessionsHealth` del router cliente.
15. Quitar el botón "Forzar cierre" de la UI cliente — solo manage desde el NOC.

### 5.2 Fuera del alcance (V2 o posterior)

- Reportes de tendencias de varianza por cajero (V1.1).
- ML / anomaly detection automatizada (V2).
- Multi-operador con permisos granulares (V2 — hoy todo lo opera Cristian).
- Integración con sistemas externos de monitoreo (Datadog, NewRelic).
- App móvil de mango_administrador (V2 — hoy es desktop only).
- Dashboard público de status (status.mangopos.do) (V2).
- API pública para que el cliente integre alertas a su propio sistema (V2).
- Conciliación bancaria automática.
- Reportes financieros agregados de la plataforma (revenue, MRR, churn rate).

---

## 6. Decisiones de diseño tomadas

| # | Decisión | Razón |
|---|---|---|
| D1 | mango_administrador conserva su stack (Flutter desktop) | Reutilizar lo que ya existe |
| D2 | Backend compartido con MangoPOS (mismo Supabase, mismas tablas) | Único modelo de datos, sin sync |
| D3 | Acceso cross-tenant vía **rol `platform_admin`** que bypassa RLS en helpers RLS, no service_role en cliente | Mantener auditoría (`auth.uid()` válido) y nunca exponer service_role en client |
| D4 | Vistas dedicadas (`v_admin_*`) en lugar de queries directas | Encapsular agregaciones; refactorear sin tocar app cliente |
| D5 | Alertas via webhook HTTP, NO SMTP propio | Telegram bot / Slack incoming webhook es lo más rápido para V1 |
| D6 | Las acciones del operador (retry job, force-close) usan RPCs ya existentes, no nuevas | DRY con la app POS; agregar `requires_platform_admin` check en RPC |
| D7 | "Salud de cajas" se MUEVE — la migración 0015 ya creó `v_cash_sessions_health`, la app POS deja de consumirla | Vista en BD ya lista, solo cambia el consumidor |
| D8 | Realtime suscripciones se filtran por `business_id IS NOT NULL` (any), no por uno específico | Para que el NOC vea cambios de todos los negocios sin múltiples suscripciones |
| D9 | Histórico de incidentes y audit log en tablas separadas | `noc_incidents`, `noc_audit_log` — no inflar tablas de operación |
| D10 | Polling 60s para paneles de volumen, Realtime para los críticos | Balance entre carga BD y UX vivo |

---

## 7. Requisitos funcionales

### 7.1 Salud de cajas

**RF-CA-01** Dashboard global con: cajas abiertas (total), cajas que necesitan atención (>12h), cajas force-closed últimas 24h, sesiones con `variance_flagged=true` últimas 24h.

**RF-CA-02** Listado por negocio, ordenado por urgencia.

**RF-CA-03** Drill-down: click negocio → lista sus cajas → click caja → kardex de movimientos.

**RF-CA-04** Acciones: force-close, ver desglose, exportar a CSV.

**RF-CA-05** Migrar la ruta `/cashier/sessions-health` de MangoPOS a `/admin/cash-health` en mango_administrador.

**RF-CA-06** Mantener `v_cash_sessions_health` como fuente de verdad — extender con `business_name` join para identificación clara.

### 7.2 Salud de impresión

**RF-IM-01** Listar print agents registrados (`device_agents`) con: business, último heartbeat, online/offline.

**RF-IM-02** Marcar amarillo si último heartbeat 60s-5min, rojo si >5min.

**RF-IM-03** Listar print_jobs no terminales (pending/failed/printing) agrupados por business, con conteo.

**RF-IM-04** Drill-down: ver detalle de job (kind, retry_count, last_error, edad).

**RF-IM-05** Acción: retry job, cancel job, retry todos los failed terminales.

**RF-IM-06** Dashboard de top 10 negocios por jobs failed última hora (detectar negocios con problemas crónicos de impresión).

### 7.3 Salud fiscal (e-CF / NCF)

**RF-FI-01** Listar fiscal_documents con `ecf_status='sent_to_dgii'` >1h sin ACK (probable rechazo silencioso).

**RF-FI-02** Listar `ecf_status='rejected'` últimas 24h con razón.

**RF-FI-03** Listar fiscal_sequences con `available_ncfs < 100` (riesgo de quedarse sin NCFs).

**RF-FI-04** Acción: reenviar a Alanube; cambiar secuencia activa; marcar como manual.

**RF-FI-05** Reporte exportable: NCFs emitidos por negocio en rango (CSV/PDF) — para auditoría DGII.

### 7.4 Salud de mesas

**RF-ME-01** Listar mesas en estado "pagando" >1h sin progreso (probablemente abandonadas).

**RF-ME-02** Listar table_sessions abiertas >24h (no zombi de caja, sino de mesa).

**RF-ME-03** Listar órdenes con items huérfanos (check_id apunta a check cerrado, item con status preparing pero session paid, etc.).

**RF-ME-04** Acción: liberar mesa, anular orden.

### 7.5 Negocios y churn

**RF-NE-01** Listado de todos los negocios activos con: last_sale_at, last_login_at, plan, fecha vencimiento.

**RF-NE-02** Categorización automática: activo (ventas <7d), riesgo (ventas 7-30d), inactivo (>30d), churned (>90d).

**RF-NE-03** Filtros por plan, fecha de alta, región.

**RF-NE-04** Drill-down: dashboard ejecutivo del negocio (ventas semanal, ticket promedio, métodos de pago).

### 7.6 Incidentes y alertas

**RF-IN-01** Tabla `noc_incidents` con: id, type, severity (info/warning/critical), business_id, description, opened_at, closed_at, resolved_by, root_cause.

**RF-IN-02** Reglas configurables que disparan incidentes automáticos:
- "agent offline >5min" → severity=critical, type='print_agent_down'.
- "varianza > $X en cierre" → severity=warning, type='cash_variance_high'.
- "e-CF rechazado" → severity=critical, type='ecf_rejected'.
- "negocio sin ventas >7d" → severity=info, type='business_inactive'.

**RF-IN-03** Webhook configurable para enviar alertas a Telegram/Slack/email.

**RF-IN-04** Panel de incidentes activos en el dashboard principal.

**RF-IN-05** Cierre manual o automático del incidente cuando la condición revierte.

### 7.7 Audit log

**RF-AU-01** Tabla `noc_audit_log` con: user_id, action, target_resource, target_id, business_id, payload, timestamp.

**RF-AU-02** Logear toda acción de intervención (force-close, retry job, retry e-CF, etc.).

**RF-AU-03** Logear acceso a paneles sensibles (cashier history, fiscal report).

**RF-AU-04** Endpoint de exportación del audit log (compliance interno).

### 7.8 Migración de MangoPOS

**RF-MG-01** Eliminar de la app cliente:
- Ruta `AppRoutes.cashierSessionsHealth`.
- Vista `CashSessionsHealthView` (mover archivo a `mango_administrador`).
- Tarjeta "Salud de cajas" del dashboard de Cajero.
- Botón "Forzar cierre" — solo intervención remota desde el NOC.

**RF-MG-02** Conservar en la app cliente:
- Apertura, cierre normal, lista de movimientos del turno actual.
- Permiso `caja.cerrar` para el cierre normal del cajero/manager.

**RF-MG-03** Conservar el permiso `caja.arqueo_ver` (lectura) para que el manager pueda ver el historial de cierres de SU negocio.

### 7.9 Permisos y seguridad

**RF-SE-01** Rol nuevo `platform_admin` en `user_businesses.role` o en una tabla aparte `platform_admins(user_id)`.

**RF-SE-02** Helper RLS `is_platform_admin(uid uuid)` que retorna true si el user pertenece a esa lista.

**RF-SE-03** Las vistas `v_admin_*` y las RPCs de intervención (`fn_force_close_cash_session`, etc.) verifican `is_platform_admin(auth.uid())` adicionalmente al chequeo de rol per-business.

**RF-SE-04** Cualquier intento de uso desde fuera de mango_administrador con un user que NO es platform_admin debe fallar con 403, aún si tiene rol owner en algún business.

**RF-SE-05** mango_administrador requiere 2FA al hacer login (TOTP/SMS).

---

## 8. Requisitos no funcionales

### 8.1 Rendimiento

- **RNF-1** Dashboard principal carga en < 2s con datos de hasta 200 negocios.
- **RNF-2** Drill-down a negocio carga en < 1s.
- **RNF-3** Queries del NOC no afectan latencia p95 de la app POS (medible en metrics Supabase).

### 8.2 Disponibilidad

- **RNF-4** mango_administrador puede operar offline para consulta de cache local; las intervenciones requieren online.
- **RNF-5** El sistema de alertas (webhook) se reintenta con backoff exp si el endpoint falla.

### 8.3 Seguridad

- **RNF-6** Acceso a `mango_administrador` solo con cuenta `platform_admin` + 2FA.
- **RNF-7** Conexión TLS obligatoria.
- **RNF-8** Service role keys NUNCA en el cliente — todo va por user JWT con bypass RLS via helpers, no service role.

### 8.4 Auditabilidad

- **RNF-9** 100% de acciones de intervención quedan en `noc_audit_log`.
- **RNF-10** Retención mínima de audit log: 1 año.

### 8.5 Compliance

- **RNF-11** Datos personales de cajeros / clientes finales (nombres, emails) NO se exponen en agregados públicos.
- **RNF-12** Reportes fiscales firmados con metadata (operador, fecha, sello).

---

## 9. Arquitectura y modelo de datos

### 9.1 Principios

1. **Backend compartido**: mismo Supabase. mango_administrador consulta las mismas tablas que MangoPOS via `platform_admin`.
2. **Vistas dedicadas**: `v_admin_cash_health`, `v_admin_print_health`, `v_admin_fiscal_health`, `v_admin_table_health`, `v_admin_businesses_status`.
3. **Tablas nuevas**: `noc_incidents`, `noc_audit_log`, `noc_alert_rules`, `noc_webhooks`.
4. **Rol `platform_admin`**: helper SQL `is_platform_admin(uuid)` consultable en RLS y RPC.
5. **Realtime selectivo**: solo paneles críticos (cash health, print health) usan suscripción.

### 9.2 Tablas nuevas

| Tabla | Propósito |
|---|---|
| `platform_admins` | Lista de user_ids con acceso cross-tenant |
| `noc_incidents` | Histórico de incidentes detectados (auto o manual) |
| `noc_audit_log` | Toda acción de intervención |
| `noc_alert_rules` | Reglas configurables (condición + webhook destino) |
| `noc_webhooks` | URLs de Telegram/Slack/email para enviar alertas |

### 9.3 Vistas nuevas

| Vista | Propósito |
|---|---|
| `v_admin_cash_health` | Extiende `v_cash_sessions_health` con `business_name` y filtros pre-armados |
| `v_admin_print_health` | Agents + jobs failed por negocio |
| `v_admin_fiscal_health` | e-CFs pendientes/rechazados + NCFs por vencer |
| `v_admin_table_health` | Mesas y órdenes en estados anómalos |
| `v_admin_businesses_status` | Listado de negocios con categorización churn |

### 9.4 Helpers RLS

```sql
create or replace function public.is_platform_admin(uid uuid)
returns boolean
language sql
stable
security definer
as $$
  select exists (
    select 1 from public.platform_admins where user_id = uid
  );
$$;
```

Las vistas `v_admin_*` tienen una política RLS:
```sql
create policy admin_only on v_admin_*
  for select using (public.is_platform_admin(auth.uid()));
```

### 9.5 RPCs nuevas o extendidas

| RPC | Propósito |
|---|---|
| `fn_force_close_cash_session` | Ya existe (migración 0016). Agregar check `is_platform_admin` y log a audit. |
| `fn_retry_print_job` | Wrap del retry actual + audit log. |
| `fn_retry_ecf_submission` | Reenviar e-CF a Alanube. Nueva. |
| `fn_noc_open_incident` | Crear incidente manual desde la UI. |
| `fn_noc_close_incident` | Cerrar incidente con resolución. |
| `fn_log_admin_action` | Helper interno para audit log. |

---

## 10. Flujos clave

### 10.1 Alerta de print agent caído

```
[Cron job 1min] → Verifica device_agents con last_heartbeat_at > 5min
    → INSERT noc_incidents(type='print_agent_down', severity='critical', business_id)
    → Trigger after insert → llama webhooks configurados
    → Telegram bot envía mensaje al operador
    → Operador entra a mango_administrador → ve banner rojo
    → Drill-down → llama al cliente
    → Resuelto → operador cierra incidente con resolution_note
    → noc_audit_log registra
```

### 10.2 Force-close de caja zombi cross-tenant

```
Operador entra a mango_administrador → Salud de cajas
    → Filtra "necesitan atención" → ve 3 cajas >12h en 2 negocios
    → Decide force-close 1 → ingresa razón "cajero no respondió a 3 llamadas"
    → mango_administrador llama fn_force_close_cash_session
    → RPC verifica is_platform_admin(auth.uid()) ✓
    → Cierra sesión con notes='[FORCE_CLOSED by NOC: ...]'
    → noc_audit_log → action='force_close_session', target_id=session_id
    → UI refresca → caja desaparece de la lista
```

### 10.3 e-CF rechazado por DGII

```
Alanube responde rechazo → webhook entra a fn_handle_alanube_callback
    → UPDATE fiscal_documents SET ecf_status='rejected'
    → Trigger → INSERT noc_incidents(type='ecf_rejected', severity='critical')
    → Webhook a Telegram
    → Operador entra → ve detalle → identifica error (NCF duplicado)
    → Corrige secuencia fiscal del negocio
    → Click "Reintentar" → fn_retry_ecf_submission
    → Si OK → incidente se cierra automático (trigger update)
```

---

## 11. UI/UX guidelines

### 11.1 Lineamientos generales

- **Dashboard único**: una pantalla principal con 4-5 tarjetas grandes (Cajas, Impresión, Fiscal, Mesas, Negocios) + banner de incidentes al tope.
- **Semáforo universal**: verde (OK), amarillo (atención), rojo (crítico). Coherente en todos los paneles.
- **Drill-down**: 2 niveles. Dashboard → Panel temático → Detalle.
- **Tabla densa**: el NOC necesita ver mucho en una pantalla, no diseño "amigable" tipo Square. Filas compactas, sortable, filtros en columnas.

### 11.2 Pantallas principales

1. **Dashboard NOC**: tarjetas con KPIs + banner incidentes activos + timeline 24h.
2. **Salud de cajas**: lista filtrable + drill-down.
3. **Salud de impresión**: agents map + jobs pendientes.
4. **Salud fiscal**: e-CFs problemáticos + NCFs por agotarse.
5. **Negocios**: tabla con categorización churn.
6. **Incidentes**: histórico + filtros por severity/business/type.
7. **Audit log**: tabla searchable.
8. **Configuración**: webhooks, alert rules, platform_admins.

### 11.3 Tema y branding

- mango_administrador conserva su identidad visual (no necesariamente naranja MangoPOS).
- Color de severidad sí estándar (verde/amarillo/rojo).
- Modo oscuro recomendado por defecto (uso prolongado, NOC).

---

## 12. Plan de release por fases

| Fase | Entregable | Días estimados | Acumulado |
|---|---|---|---|
| **0** | Schema: platform_admins, noc_incidents, noc_audit_log, noc_alert_rules, noc_webhooks, helpers RLS | 2 | 2 |
| **1** | Migración: mover Salud de cajas de MangoPOS a mango_administrador (extender vista, quitar de cliente) | 2 | 4 |
| **2** | Panel Salud de impresión (agents + jobs) | 3 | 7 |
| **3** | Panel Salud fiscal (e-CFs + NCFs) | 3 | 10 |
| **4** | Panel Salud de mesas + Panel Negocios | 3 | 13 |
| **5** | Sistema de incidentes (auto-detección + webhooks Telegram) | 4 | 17 |
| **6** | Audit log + reportes exportables | 2 | 19 |
| **7** | Configuración (webhooks, reglas, admins) | 2 | 21 |
| **8** | Hardening: 2FA, RLS audit, performance | 2 | 23 |

**MVP vendible: Fases 0-2 (~7 días)**. Permite monitoreo proactivo de cajas e impresión, los dos pilares de la operación diaria.

**Release completo V1: 21-23 días** trabajando a ritmo sostenible.

### 12.1 Hitos

- **M1 — NOC MVP** (fin Fase 2): cajas + impresión monitoreadas. Webhook básico.
- **M2 — NOC Fiscal** (fin Fase 3): e-CFs y NCFs cubiertos. Crítico para mercado DR.
- **M3 — NOC Completo** (fin Fase 5): incidentes auto-detectados con alertas configurables.
- **M4 — V1 final** (fin Fase 8): hardening, audit, exportables.

---

## 13. Métricas de éxito y KPIs

### 13.1 KPIs operativos

- MTTR (mean time to resolve) de incidentes críticos < 30 min.
- % de incidentes detectados ANTES del ticket del cliente > 70%.
- % de print agents con uptime > 95%.
- 0 e-CFs rechazados sin reintento dentro de 24h.

### 13.2 KPIs de negocio

- Tickets de soporte por negocio activo / mes (objetivo: tendencia decreciente).
- Churn rate mensual (correlación con outreach proactivo).
- # negocios contactados pre-cancelación > 60% del riesgo identificado.

### 13.3 KPIs de adopción interna

- # operadores usando mango_administrador (inicialmente 1, escala con equipo).
- # acciones de intervención por semana.
- Tiempo promedio de sesión activa por operador.

---

## 14. Riesgos y mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| Exponer datos cross-tenant a operador equivocado | Baja | Crítico | platform_admins en BD, RLS forzada, 2FA obligatoria, audit log |
| Queries del NOC degradan performance del cliente | Media | Alto | Vistas indexadas, polling 60s, limits, slow query monitoring |
| Alertas spam (false positives) | Alta | Medio | Tunable thresholds, cooldown 5min entre alertas del mismo tipo |
| Operador interviene en negocio sin avisar al cliente | Media | Alto | Audit log + política interna: notificar al cliente antes de intervenir salvo emergencia |
| Webhook caído pierde alertas | Media | Medio | Retry con backoff, fallback a cola en BD, alerta de "webhook unhealthy" |
| Acceso a service_role expuesto en cliente | Baja | Crítico | Verificación en review, deploy sin SUPABASE_SERVICE_ROLE_KEY en mango_administrador build |
| Adopción lenta del NOC dentro del equipo | Media | Medio | Onboarding documentado, runbooks para incidentes comunes |

---

## 15. Dependencias

### 15.1 Internas

- mango_administrador app ya operativa con auth Supabase.
- Backend MangoPOS estable (vistas y RPCs no rotos).
- Sistema de roles existente (`user_businesses.role`).

### 15.2 Externas

- Telegram Bot API (gratis, ilimitado para uso interno).
- Webhook endpoint para Slack/Discord (opcional V1).
- Servicio de email transaccional (Resend/Postmark) si se quiere alerts por mail.

### 15.3 Bloqueos potenciales

- `platform_admins` debe sembrarse manualmente con el user_id de Cristian al deploy.
- 2FA en Supabase auth: hoy MangoPOS no la exige; agregar para mango_administrador requiere configuración separada o middleware.
- Si Supabase no tiene Realtime habilitado para algunas tablas del NOC, hay que activarlo (Coolify config).

---

## 16. Glosario

- **NOC**: Network Operations Center. Centro de monitoreo continuo.
- **MTTR**: Mean Time To Resolve. Tiempo promedio para resolver un incidente.
- **Cross-tenant**: Visibilidad/acción que cruza el límite de un solo negocio.
- **RLS**: Row Level Security (Postgres).
- **Service Role**: Llave Supabase que bypassa RLS. NUNCA en cliente.
- **Platform Admin**: Rol de operador de la plataforma, NO de un negocio individual.
- **Churn**: Cliente que deja de usar el servicio.
- **e-CF**: Comprobante Fiscal Electrónico (DGII República Dominicana).
- **NCF**: Número de Comprobante Fiscal.
- **Webhook**: Endpoint HTTP que recibe notificaciones automáticas.

---

## 17. Anexos

### 17.1 Estado actual de la migración "Salud de cajas"

Lo construido hoy en MangoPOS:
- `lib/presentation/cashier/cash_sessions_health/cash_sessions_health_view.dart` — la vista.
- Ruta `AppRoutes.cashierSessionsHealth`.
- Card en el dashboard de Cajero (gateada por `caja.arqueo_ver`).
- Vista BD `v_cash_sessions_health` (migración 0015).
- RPC `fn_force_close_cash_session` (migración 0016).

Para migrar:
1. Copiar `cash_sessions_health_view.dart` al repo mango_administrador, adaptando imports.
2. En MangoPOS: remover ruta + card + archivo.
3. En BD: crear `v_admin_cash_health` que extienda `v_cash_sessions_health` con `business_name` y filtros cross-tenant.
4. En mango_administrador: consumir la vista nueva con filtros y polling.

### 17.2 Schema preliminar de tablas nuevas

```sql
create table public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  added_by uuid references auth.users(id),
  added_at timestamptz default now() not null,
  notes text
);

create table public.noc_incidents (
  id uuid primary key default gen_random_uuid(),
  type text not null,
  severity text not null check (severity in ('info', 'warning', 'critical')),
  business_id uuid references public.businesses(id),
  title text not null,
  description text,
  payload jsonb,
  opened_at timestamptz default now() not null,
  closed_at timestamptz,
  resolved_by uuid references auth.users(id),
  resolution_note text
);

create table public.noc_audit_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  action text not null,
  target_resource text,
  target_id uuid,
  business_id uuid references public.businesses(id),
  payload jsonb,
  created_at timestamptz default now() not null
);

create table public.noc_alert_rules (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  type text not null,
  condition_sql text not null,
  webhook_id uuid references public.noc_webhooks(id),
  enabled boolean default true not null,
  cooldown_minutes int default 5 not null,
  last_fired_at timestamptz
);

create table public.noc_webhooks (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  kind text not null check (kind in ('telegram', 'slack', 'discord', 'email', 'generic')),
  url text not null,
  config jsonb,
  enabled boolean default true not null,
  created_at timestamptz default now() not null
);
```

### 17.3 Próximos pasos inmediatos

1. Aprobar este PRD.
2. Sembrar `platform_admins` con tu user_id en producción.
3. Empezar Fase 0 (schema + helpers RLS).
4. Decidir el formato del Telegram bot (mango_noc_bot vs notification channel ya existente).
5. Identificar otros KPIs de plataforma que quieras ver (revenue agregado, # comandas hoy, etc.) — Fase 9.

---

## 18. Módulos extras (Roadmap V1.1+)

Los siguientes módulos quedan **fuera del alcance de V1** pero documentados acá para que el roadmap esté completo. Se trabajarán en iteraciones posteriores cuando V1 esté estabilizado y haya feedback de uso real del NOC.

### 18.1 Módulo M1 — Business Intelligence agregado

**Motivación**: el NOC operativo (V1) detecta fallas. Falta una capa de **inteligencia de negocio cross-tenant** que responda preguntas como: ¿cuánto factura la plataforma en total hoy? ¿qué negocios crecen más? ¿qué productos son top vendidos globalmente?

**Alcance V1.1**:
- Dashboard ejecutivo con KPIs agregados:
  - Revenue total / día / semana / mes (suma de payments.amount cross-tenant).
  - Ticket promedio por negocio.
  - Volumen de transacciones (# payments).
  - Top 10 productos vendidos a nivel plataforma (con anonymización si aplica).
  - Peak hours global y por negocio.
  - Conversion rate (órdenes abiertas → pagadas).
  - Growth MoM por negocio.
- Filtros: rango de fechas, zona horaria, plan, tipo de negocio.
- Exportable a CSV/PDF para boards investors / análisis interno.

**Tablas/vistas nuevas**:
- `v_admin_revenue_daily`: suma diaria de payments por business.
- `v_admin_top_products`: ranking de menu_items cross-tenant.
- `v_admin_growth_metrics`: MoM por negocio.

**Decisión pendiente**: si esto va como sub-módulo de mango_administrador o como PRD-13 dedicado a "Reportes Ejecutivos / BI". Probablemente lo segundo si el alcance crece.

**Estimación**: 5-7 días.

---

### 18.2 Módulo M2 — Monitoreo de infraestructura Supabase

**Motivación**: hoy si Supabase tiene un slow query, alta CPU, storage explotando o edge functions con error rate, nos enteramos por reportes manuales o cuando rompe. El NOC operativo necesita visibilidad de la capa de infraestructura para correlacionar fallas funcionales con problemas de plataforma.

**Alcance V1.1**:
- Panel "Infrastructure Health" con:
  - DB CPU/RAM/connections en vivo (vía Supabase Management API o pg_stat_*).
  - Storage usage growth (imágenes de productos, logos, backups).
  - Slow queries top 10 (vía `pg_stat_statements`).
  - Edge functions error rate (si se usan).
  - Realtime channels conectados / lag.
  - Cost projection (Supabase Cloud) o resource utilization (Coolify self-hosted).
- Alertas configurables: "DB CPU > 80% por 5min", "storage > 90%", "slow query > 1s p95".
- Histórico de capacidad para forecasting.

**Tablas/vistas nuevas**:
- `noc_infra_snapshots`: snapshot cada 1min de métricas clave de DB.
- `noc_slow_queries`: top queries del día con plan de ejecución.

**Dependencias externas**:
- Acceso a Supabase Management API (PAT del proyecto).
- O extensión `pg_stat_statements` habilitada en Postgres.

**Decisión pendiente**: si esto se integra al panel NOC o vive en herramienta separada (Grafana ya tirando de Postgres exporter, por ejemplo). Recomendación: Grafana separado + alertas Telegram, no reinventar dashboards de DB.

**Estimación**: 4-5 días si se integra al panel; 1-2 días si solo se configura Grafana.

---

### 18.3 Módulo M3 — Runbooks de respuesta a incidentes

**Motivación**: hoy V1 detecta y alerta, pero la respuesta es ad-hoc. Cuando el equipo crezca (soporte L1 + L2), necesitamos procedimientos documentados para cada tipo de incidente — qué validar, a quién contactar, cuándo escalar.

**Alcance V1.1**:
- Tabla `noc_runbooks` con: incident_type, severity, steps (markdown), escalation_chain, sla_minutes.
- Cada incidente abierto muestra el runbook asociado al lado del detalle.
- Checklist interactivo: el operador marca pasos hechos, queda en audit log.
- Runbooks iniciales documentados:
  - `print_agent_down`: validar heartbeat, llamar cliente, escalar a Cristian si >30min.
  - `ecf_rejected`: identificar error, corregir secuencia, reenviar a Alanube, validar.
  - `cash_zombie`: contactar cajero, force-close si >30min sin respuesta.
  - `business_inactive`: outreach por WhatsApp/email, identificar bloqueante.
  - `db_high_cpu`: identificar slow query, kill si es crítico.
- SLA tracking: medir tiempo runbook step-by-step vs sla_minutes.

**Beneficio adicional**: facilita onboarding de soporte nuevo (operador L1 sigue checklist sin necesidad de saber el sistema completo).

**Estimación**: 3 días (estructura + 4-5 runbooks iniciales).

---

### 18.4 Módulo M4 — Backup y Disaster Recovery

**Motivación**: el backend vive en Coolify self-hosted con Supabase. Si el VPS muere, los backups deberían estar al día y restaurables. Hoy no hay visibilidad de eso desde el NOC — se asume que Coolify hace su trabajo.

**Alcance V1.1**:
- Panel "Backup & DR" con:
  - Último backup OK timestamp (DB + storage).
  - Tamaño de cada backup.
  - Verificación de integridad (checksum match).
  - Test de restore mensual automatizado en VPS staging.
  - Reporte de RPO (Recovery Point Objective) actual: cuánta data se perdería en disaster.
  - Reporte de RTO (Recovery Time Objective) medido: cuánto tarda restaurar.
- Alerta crítica si último backup OK > 24h.
- Documentación inline del procedimiento de restore (sub-runbook).

**Tablas/vistas nuevas**:
- `noc_backup_log`: timestamp, kind (db/storage), status, size, checksum.
- Integration con Coolify webhook o pg_dump cron + report a Supabase.

**Decisión pendiente**: si hacemos restore tests reales (caro, requiere VPS staging) o solo monitoreo de existencia.

**Estimación**: 5 días con restore test; 2 días solo monitoreo.

---

### 18.5 Módulo M5 — Política de retención y privacidad

**Motivación**: V1 menciona "audit log 1 año mínimo" pero no formaliza:
- Política de purga automática de datos viejos (cumplir Ley DR 172-13 de Protección de Datos Personales).
- Anonimización de datos personales en reportes agregados (nombre del cajero, customer email, etc.).
- Derecho al olvido (cliente solicita borrado de su data).
- Compliance fiscal: NCFs deben conservarse 10 años por DGII, pero datos operativos pueden purgarse antes.

**Alcance V1.1**:
- Tabla `noc_retention_policies` con: table_name, retention_days, anonymize_columns, hard_delete (bool).
- Job cron mensual que ejecuta purgas según políticas.
- Endpoint en mango_administrador para "Derecho al olvido": dado un user_id, anonimiza sus datos en todas las tablas operativas (mantiene NCFs por compliance fiscal).
- Reporte mensual: cuánto data se purgó, qué tablas, cumplimiento de SLAs.
- Documento legal: política pública en mangopos.do/privacy con detalles de retención.

**Tablas/vistas nuevas**:
- `noc_retention_policies`: configuración por tabla.
- `noc_purge_log`: histórico de purgas ejecutadas.
- `noc_data_subject_requests`: requests de derecho al olvido / portabilidad.

**Compliance específico DR**:
- Ley 172-13: derecho de acceso, rectificación, oposición, cancelación.
- Norma DGII: NCFs 10 años.
- Cód. Laboral: payroll data 10 años.

**Estimación**: 4-5 días + revisión legal externa.

---

### 18.6 Orden de prioridad sugerido

Cuando V1 esté estable, recomiendo trabajar los módulos en este orden:

1. **M3 Runbooks** (3 días) — el más rápido, multiplica el valor de V1 al hacerlo más operable.
2. **M1 Business Intelligence** (5-7 días) — alto valor de negocio, te da métricas para investors / decisiones.
3. **M4 Backup & DR** (2-5 días) — crítico antes de crecer a >50 negocios.
4. **M5 Retención y Privacidad** (4-5 días) — necesario antes de incidente legal o auditoría.
5. **M2 Infrastructure Monitoring** (1-5 días) — útil pero hay alternativas externas (Grafana).

Cada módulo puede tener su propio PRD detallado si el alcance lo requiere; este PRD-12 los registra como **roadmap** para que ninguno se pierda.

---

**Aprobaciones**

| Rol | Nombre | Fecha | Firma |
|---|---|---|---|
| Product Owner | Cristian | 2026-05-13 | _________ |
| Tech Lead | Cristian | 2026-05-13 | _________ |

---

*Fin del documento.*
