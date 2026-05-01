# PRD: Modificación del Agente LAN de MangoPOS

| Campo            | Valor                                  |
| ---------------- | -------------------------------------- |
| **Producto**     | MangoPOS                               |
| **Componente**   | Agente LAN (servicio de impresión)     |
| **Autor**        | Cristian                               |
| **Versión**      | 0.2 — Borrador                         |
| **Fecha**        | 2026-04-30                             |
| **Estado**       | En revisión                            |
| **Stakeholders** | Equipo de desarrollo MangoPOS, clientes piloto |

---

## 1. Resumen ejecutivo

El Agente LAN de MangoPOS es el componente que corre en la PC Windows del local y media entre los dispositivos de los meseros (Android) y los periféricos físicos (impresora térmica USB, cajón monedero, etc.). Esta modificación busca convertirlo de un agente acoplado al binario de MangoPOS Desktop en un **servicio de red robusto**, capaz de aceptar trabajos de impresión concurrentes desde múltiples dispositivos en la red local, con cola persistente, idempotencia, descubrimiento automático y un mecanismo de respaldo vía Supabase Realtime para escenarios de falla.

El caso de uso disparador es el escenario típico de operación: **4 meseros con un solo dispositivo de impresión USB**, donde hoy cada mesero debe acercarse físicamente a la PC o re-imprimir manualmente.

---

## 2. Contexto y problema

### 2.1 Estado actual `[POR CONFIRMAR CON CRISTIAN]`

> Esta sección debe completarse con el comportamiento real del agente LAN actual antes de avanzar.

- ¿Qué expone el agente hoy? (HTTP, sockets crudos, IPC interno)
- ¿Cómo lo descubren los clientes Android? (IP manual, broadcast, configuración hardcoded)
- ¿Cómo está acoplado a MangoPOS Desktop? (mismo proceso, proceso aparte, servicio de Windows)
- ¿Qué librería usa para hablar con la impresora USB? (`flutter_pos_printer_platform_image_3`, `esc_pos_utils_plus`, etc.)
- ¿Tiene cola? ¿Es persistente o en memoria?
- ¿Maneja autenticación entre clientes y agente?

### 2.2 Problemas observados

1. **Sin cola formal:** dos meseros imprimiendo simultáneamente pueden producir tickets entrelazados o pérdida de comandos ESC/POS.
2. **Sin idempotencia:** si el WiFi del mesero se corta justo después de enviar un ticket, no hay forma segura de reintentar sin imprimir doble.
3. **Sin descubrimiento dinámico:** los clientes Android dependen de IP hardcoded; un cambio de router obliga a reconfigurar manualmente.
4. **Sin observabilidad:** cuando un ticket "no salió", no hay log estructurado para diagnosticar si fue red, cola, driver o impresora.
5. **Sin resiliencia:** si la PC Windows se reinicia con tickets pendientes, se pierden.
6. **Sin canal de respaldo:** si la red local se cae pero internet funciona, no hay forma de imprimir.

### 2.3 ¿Por qué ahora?

MangoPOS está en fase de prueba con clientes reales y los incidentes de impresión son la fuente principal de fricción operativa reportada por los meseros. Resolverlo es bloqueante para la próxima ola de despliegue.

---

## 3. Objetivos

### 3.1 Objetivos

1. Permitir que **N dispositivos cliente** (meseros) impriman simultáneamente a través de un único agente LAN sin intervención manual.
2. Garantizar **entrega exacta una vez** ("exactly-once") por trabajo de impresión, vía idempotencia con `ticket_id`.
3. Asegurar **persistencia de la cola** ante reinicios del agente o de la PC.
4. Permitir **descubrimiento automático** del agente en la LAN sin configurar IP manual.
5. Proveer un **canal de respaldo vía Supabase Realtime** que garantice impresión cuando la LAN local falla pero internet está disponible.
6. Exponer **logs estructurados y métricas básicas** para diagnóstico remoto.
7. Mantener compatibilidad con la línea actual de impresoras térmicas USB ESC/POS soportadas por MangoPOS.

### 3.2 No-objetivos (out of scope para esta versión)

- Soportar impresoras Bluetooth o paralelas.
- Soportar impresión directa desde cliente Android a impresora WiFi/Ethernet (eliminando el agente). Esto es trabajo futuro.
- Soportar múltiples impresoras conectadas al mismo agente. (V2.)
- Soportar drivers no-ESC/POS (Star Graphics, Citizen propietario, etc.).
- Construir UI de administración del agente. Configuración vía archivo `agent.toml` o flags por ahora.
- Multi-tenant: un agente sirve a un solo `restaurant_id`.

---

## 4. Métricas de éxito

| Métrica                                            | Objetivo         |
| -------------------------------------------------- | ---------------- |
| Tasa de impresión exitosa en condiciones normales  | ≥ 99.5 %         |
| Latencia p50 (cliente → papel salido) en LAN       | ≤ 500 ms         |
| Latencia p95 (cliente → papel salido) en LAN       | ≤ 1500 ms        |
| Tickets perdidos tras reinicio del agente          | 0                |
| Tickets duplicados en flujo con reintento          | 0                |
| Tiempo de descubrimiento del agente al abrir la app del mesero | ≤ 3 s |
| Reportes de "no imprimió" del cliente piloto/semana | ≤ 1             |

---

## 5. Usuarios y casos de uso

### 5.1 Personas

- **Mesero**: opera la app Android. No tiene conocimiento técnico. Espera que "darle al botón imprimir" siempre funcione.
- **Dueño/encargado**: opera MangoPOS Desktop. Necesita visibilidad cuando algo no imprime, pero no quiere configurar nada.
- **Soporte técnico (Cristian / equipo)**: debe poder diagnosticar incidentes remotamente con los logs disponibles.

### 5.2 Casos de uso

- **CU-01:** Mesero envía un pedido nuevo desde Android → el ticket sale en la cocina/caja en menos de 1.5 s.
- **CU-02:** Dos meseros envían tickets exactamente al mismo tiempo → ambos salen, completos, en orden de llegada, sin entrelazarse.
- **CU-03:** Mesero envía un ticket, pierde WiFi antes de recibir confirmación, reintenta al reconectar → solo se imprime una vez.
- **CU-04:** La PC Windows se apaga inesperadamente con 3 tickets en cola → al volver a encenderse, los 3 tickets se imprimen automáticamente.
- **CU-05:** El router del local se reinicia y la PC obtiene una nueva IP → los meseros siguen imprimiendo sin reconfigurar nada.
- **CU-06:** La red local cae completamente pero la PC mantiene internet → los meseros imprimen vía Supabase Realtime con latencia degradada pero sin pérdida.
- **CU-07:** El papel se acaba en la impresora → el agente detecta el error, pausa la cola, notifica al cliente Android, y reanuda al detectar papel nuevo.

---

## 6. Requerimientos funcionales

### 6.1 Servidor HTTP del agente

- **RF-01:** El agente debe exponer un servidor HTTP en un puerto configurable (default: `9100`) en todas las interfaces locales (`0.0.0.0`).
- **RF-02:** El servidor debe aceptar al menos los siguientes endpoints:
  - `POST /v1/print` — encolar trabajo de impresión.
  - `GET  /v1/jobs/:job_id` — consultar estado de un trabajo.
  - `GET  /v1/health` — health check sin auth.
  - `GET  /v1/info` — versión, device_id, capacidades, estado de la impresora.
- **RF-03:** Todas las respuestas en JSON con `Content-Type: application/json`.
- **RF-04:** Soportar al menos 50 conexiones concurrentes sin degradación.

### 6.2 Cola de impresión

- **RF-05:** Persistencia en SQLite local en `%APPDATA%/MangoPOS/agent/queue.db`.
- **RF-06:** Estados válidos de un job: `queued | printing | done | failed | cancelled`.
- **RF-07:** Procesamiento estrictamente secuencial (FIFO) por impresora. Una sola operación de impresión activa a la vez.
- **RF-08:** Reintento automático con backoff exponencial (1s, 2s, 4s, 8s, 16s, hasta 5 intentos) ante errores transitorios de la impresora.
- **RF-09:** Trabajos con más de 5 fallos pasan a `failed` y se notifica al cliente.
- **RF-10:** Retención: trabajos en estado terminal se conservan 7 días para auditoría.

### 6.3 Descubrimiento automático de red (zero-config)

**Principio rector:** el operador NUNCA configura una IP manualmente. Si la PC del agente cambia de IP (router reiniciado, lease DHCP renovado, cambio de red WiFi), los clientes Android deben re-detectar el agente sin intervención humana ni reinicio de la app.

#### Estrategia de descubrimiento en cascada

Los clientes Android intentan localizar el agente en este orden, deteniéndose en el primero que responda:

1. **Endpoint cacheado** validado con health check — última IP conocida. Latencia esperada: <100 ms.
2. **mDNS / Bonjour** — descubrimiento estándar zero-conf. Latencia esperada: 200–800 ms.
3. **UDP broadcast** — para redes que bloquean multicast (común en WiFi mesh, AP corporativos, algunos routers ISP). Latencia esperada: 500–1500 ms.

Si los tres fallan, el cliente activa automáticamente el fallback Supabase Realtime (sección 6.6). En ningún momento se le pide al usuario una IP.

#### Requerimientos

- **RF-11 (mDNS publish):** El agente publica el servicio `_mangopos-print._tcp.local.` en el puerto HTTP, usando `bonsoir` o equivalente nativo. Se re-publica automáticamente al detectar cambios en las interfaces de red locales.
- **RF-12 (TXT record):** El TXT record del servicio incluye: `version`, `device_id`, `restaurant_id`, `printer_status`, `api_path` (= `/v1`).
- **RF-13 (UDP broadcast secundario):** El agente escucha en UDP `0.0.0.0:9101` paquetes con header mágico `MANGOPOS_DISCOVER_V1` seguido del `restaurant_id`. Responde al remitente con un JSON `{ device_id, restaurant_id, http_endpoint, version, printer_status }`. Los clientes hacen broadcast a `255.255.255.255:9101` cuando mDNS no responde en 1.5 s, reintentando cada 500 ms hasta 3 veces.
- **RF-13.1 (Cache de cliente):** El cliente Android persiste el último `http_endpoint` resuelto con TTL de 24 h en almacenamiento local. Al abrir la app, valida el cache con `GET /v1/health` (timeout 500 ms); si responde, usa ese endpoint inmediatamente y dispara redescubrimiento en background. Si falla, descarta el cache y arranca la cascada (mDNS → UDP).
- **RF-13.2 (Re-descubrimiento ante cambios de red):** El cliente Android se suscribe a `ConnectivityManager.NetworkCallback` y dispara automáticamente la cascada de descubrimiento ante eventos `onAvailable`, `onLost` o `onLinkPropertiesChanged`. Tras un cambio de red, el endpoint cacheado se considera inválido hasta que pase un health check.
- **RF-13.3 (Re-anuncio del agente):** El agente monitorea cambios en sus interfaces de red (polling cada 10 s sobre `NetworkInterface.list` o callback nativo) y, ante cambio de IP, (a) re-publica el servicio mDNS, (b) reabre el socket UDP de descubrimiento, (c) emite el log `agent.ip_changed` con la IP vieja y la nueva, (d) reporta el evento a `agent_incidents` en Supabase.
- **RF-13.4 (Sin entrada manual de IP en UI):** La interfaz del cliente Android NO expone un campo para escribir la IP del agente. La pantalla de configuración solo muestra estado de conexión (`connected | searching | disconnected`) y un botón "Reconectar" que reinicia la cascada de descubrimiento.
- **RF-13.5 (Override avanzado para soporte):** Para diagnóstico, soporte técnico puede forzar un endpoint específico vía un archivo `agent_override.json` colocado manualmente en el almacenamiento de la app. Este flujo NO está documentado al usuario final ni accesible desde la UI normal. Es exclusivamente para troubleshooting remoto.

#### Comportamiento ante falla de descubrimiento

Si tras 5 segundos ningún método (cache, mDNS, UDP) responde:

1. El cliente muestra indicador no-bloqueante "Buscando impresora…" en la UI (no error rojo, no diálogo modal).
2. Sigue reintentando la cascada cada 10 s en background, con jitter para evitar tormentas.
3. En paralelo, activa el modo Supabase Realtime: cualquier nuevo trabajo de impresión se envía vía Supabase mientras se resuelve la conectividad LAN.
4. Al recuperar conectividad LAN, retoma el modo HTTP directo automáticamente y deja Supabase como respaldo pasivo.

#### Casos de cambio de IP cubiertos

| Escenario                                              | Cómo lo detecta el sistema                            |
| ------------------------------------------------------ | ----------------------------------------------------- |
| Router del local se reinicia y entrega nueva IP a la PC | Agente detecta cambio en `NetworkInterface.list` y re-publica mDNS. Android invalida cache al fallar health check y re-descubre. |
| PC se reconecta a WiFi distinto (ej. red de respaldo) | Igual al anterior; agente re-anuncia, clientes re-descubren. |
| Cliente Android cambia entre WiFi y datos móviles       | `NetworkCallback` dispara redescubrimiento; si no encuentra LAN, usa Supabase. |
| Cliente Android se reconecta al mismo WiFi tras corte | Cache responde a health check, conexión instantánea. |
| Lease DHCP expira y renueva con misma IP               | Sin impacto, salvo blip de red transitorio.          |
| Lease DHCP expira y renueva con IP distinta             | Agente detecta cambio y re-anuncia; cache del cliente falla health check, re-descubre. |

### 6.4 Autenticación y autorización

- **RF-14:** Todos los endpoints (excepto `/v1/health`) requieren un header `Authorization: Bearer <jwt>` con el JWT emitido por Supabase.
- **RF-15:** El agente valida el JWT contra el `JWT_SECRET` de Supabase (configurado al instalar el agente).
- **RF-16:** El claim `restaurant_id` del JWT debe coincidir con el `restaurant_id` configurado en el agente; si no, `403 Forbidden`.
- **RF-17:** El agente NO almacena el JWT; solo lo valida en cada request.

### 6.5 Idempotencia

- **RF-18:** Cada trabajo lleva un `ticket_id` UUIDv4 generado por el cliente.
- **RF-19:** Si el agente recibe dos veces el mismo `ticket_id`, devuelve la respuesta del primer envío (sin reimprimir).
- **RF-20:** La tabla de idempotencia retiene `ticket_id` por al menos 24 horas.

### 6.6 Fallback Supabase Realtime

- **RF-21:** El agente se suscribe a una tabla `print_jobs` en Supabase filtrada por su `restaurant_id`.
- **RF-22:** Cuando un cliente Android no puede contactar el agente vía LAN dentro de un timeout configurable (default 2 s), inserta el job en `print_jobs`.
- **RF-23:** El agente recibe el evento de Realtime, lo encola igual que un job HTTP, y al completarlo hace `UPDATE status='done'` en la tabla.
- **RF-24:** Si el job ya entró por LAN y luego llega por Realtime con el mismo `ticket_id`, se aplica la regla de idempotencia (RF-19).

### 6.7 Observabilidad

- **RF-25:** Logs estructurados en JSON a archivo rotativo (max 50 MB, 5 archivos).
- **RF-26:** Cada log incluye: `timestamp`, `level`, `event`, `job_id`, `ticket_id`, `device_id`, `latency_ms`, `error_code`.
- **RF-27:** Endpoint `GET /v1/metrics` expone contadores: jobs_total, jobs_failed, jobs_in_queue, printer_errors_total, uptime_seconds.
- **RF-28:** Los errores críticos (impresora desconectada, cola atascada >5min) se reportan a Supabase en una tabla `agent_incidents` para visibilidad remota.

### 6.8 Estado de la impresora

- **RF-29:** El agente realiza polling cada 30 s al estado físico de la impresora (status DLE EOT n para ESC/POS).
- **RF-30:** Detecta y reporta: `online | offline | out_of_paper | cover_open | cutter_error`.
- **RF-31:** El estado se expone en `/v1/info` y se publica en el TXT record de mDNS.

---

## 7. Requerimientos no-funcionales

| Categoría          | Requerimiento                                                                 |
| ------------------ | ----------------------------------------------------------------------------- |
| **Performance**    | Encolar un job y devolver `job_id` en ≤ 100 ms (p95).                         |
| **Disponibilidad** | El agente debe correr como **servicio de Windows** con auto-restart.          |
| **Resiliencia**    | Recuperación completa de cola pendiente al inicio en ≤ 5 s.                   |
| **Compatibilidad** | Windows 10 (1809+) y Windows 11.                                              |
| **Seguridad**      | Sin endpoints sin auth excepto `/v1/health`. Logs no contienen el JWT.        |
| **Instalación**    | Instalador MSIX (alineado con el flujo actual de Microsoft Store).            |
| **Tamaño**         | Binario del agente ≤ 30 MB (excluyendo runtime de Flutter).                   |
| **Recursos**       | Uso en idle: ≤ 80 MB RAM, ≤ 1 % CPU.                                          |

---

## 8. Diseño técnico

### 8.1 Arquitectura propuesta

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Mesero 1 (And) │     │  Mesero 2 (And) │     │  Mesero N (And) │
└────────┬────────┘     └────────┬────────┘     └────────┬────────┘
         │ POST /v1/print        │                       │
         └───────────────────────┼───────────────────────┘
                                 │ WiFi LAN
                                 ▼
                  ┌──────────────────────────────┐
                  │   PC Windows                 │
                  │  ┌────────────────────────┐  │
                  │  │  Agente LAN (servicio) │  │
                  │  │  ┌──────────────────┐  │  │
                  │  │  │ HTTP API (shelf) │  │  │
                  │  │  └────────┬─────────┘  │  │
                  │  │           ▼            │  │
                  │  │  ┌──────────────────┐  │  │
                  │  │  │ Cola SQLite      │◄─┼──┼── Realtime sub.
                  │  │  └────────┬─────────┘  │  │   (fallback)
                  │  │           ▼            │  │
                  │  │  ┌──────────────────┐  │  │
                  │  │  │ Worker imprenta  │  │  │
                  │  │  └────────┬─────────┘  │  │
                  │  └───────────┼────────────┘  │
                  │              ▼               │
                  │   USB ──► Impresora térmica  │
                  └──────────────────────────────┘
                                 ▲
                                 │ (fallback)
                                 │
                       ┌─────────┴───────┐
                       │   Supabase      │
                       │   (Realtime +   │
                       │   tabla jobs)   │
                       └─────────────────┘
```

### 8.2 Contratos de API

#### `POST /v1/print`

Request:

```json
{
  "ticket_id": "550e8400-e29b-41d4-a716-446655440000",
  "device_id": "tablet-mesero-03",
  "type": "kitchen_order",
  "priority": "normal",
  "payload": {
    "lines": [
      { "type": "text", "value": "PEDIDO #042", "style": "bold_double" },
      { "type": "text", "value": "Mesa 7 — Mesero: Juan" },
      { "type": "separator" },
      { "type": "item", "qty": 2, "name": "Chivo guisado", "notes": "sin picante" },
      { "type": "cut", "mode": "partial" }
    ]
  }
}
```

Response 202 Accepted:

```json
{
  "job_id": "job_01HXYZ...",
  "ticket_id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "queued",
  "queue_position": 2,
  "estimated_print_at": "2026-04-30T14:22:15-04:00"
}
```

Response 200 OK (idempotencia, mismo `ticket_id`):

```json
{
  "job_id": "job_01HXYZ...",
  "ticket_id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "done",
  "duplicate": true,
  "printed_at": "2026-04-30T14:22:18-04:00"
}
```

Errores:

| Código | Significado                                |
| ------ | ------------------------------------------ |
| 400    | Payload mal formado o `ticket_id` ausente  |
| 401    | JWT inválido o ausente                     |
| 403    | `restaurant_id` no coincide                |
| 409    | Conflicto de idempotencia con payload distinto |
| 503    | Impresora offline / cola pausada           |

#### `GET /v1/jobs/:job_id`

```json
{
  "job_id": "job_01HXYZ...",
  "status": "done",
  "printed_at": "2026-04-30T14:22:18-04:00",
  "attempts": 1,
  "last_error": null
}
```

#### `GET /v1/info`

```json
{
  "agent_version": "2.0.0",
  "device_id": "agent-mango-001",
  "restaurant_id": "rest_abc123",
  "printer": {
    "model": "EPSON TM-T20III",
    "status": "online",
    "paper": "ok"
  },
  "queue": { "pending": 0, "processing": 0 },
  "uptime_seconds": 84521
}
```

### 8.3 Modelo de datos (SQLite local)

```sql
CREATE TABLE jobs (
  job_id        TEXT PRIMARY KEY,
  ticket_id     TEXT NOT NULL UNIQUE,
  device_id     TEXT NOT NULL,
  type          TEXT NOT NULL,
  priority      TEXT NOT NULL DEFAULT 'normal',
  payload       TEXT NOT NULL,           -- JSON
  status        TEXT NOT NULL,           -- queued|printing|done|failed|cancelled
  attempts      INTEGER NOT NULL DEFAULT 0,
  last_error    TEXT,
  enqueued_at   INTEGER NOT NULL,        -- unix ms
  started_at    INTEGER,
  finished_at   INTEGER
);

CREATE INDEX idx_jobs_status_enqueued ON jobs(status, enqueued_at);
CREATE INDEX idx_jobs_ticket_id      ON jobs(ticket_id);

CREATE TABLE incidents (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  occurred_at INTEGER NOT NULL,
  severity    TEXT NOT NULL,             -- info|warn|error|critical
  code        TEXT NOT NULL,
  detail      TEXT
);
```

### 8.4 Modelo de datos (Supabase, fallback)

```sql
CREATE TABLE print_jobs (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id     UUID NOT NULL,
  restaurant_id UUID NOT NULL REFERENCES restaurants(id),
  device_id     TEXT NOT NULL,
  payload       JSONB NOT NULL,
  status        TEXT NOT NULL DEFAULT 'queued',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  printed_at    TIMESTAMPTZ,
  agent_id      TEXT,
  UNIQUE (restaurant_id, ticket_id)
);

-- RLS: cliente Android solo INSERT/SELECT de su restaurant_id
-- Agente: SELECT/UPDATE de su restaurant_id
```

### 8.5 Stack técnico

- **Lenguaje:** Dart (mismo runtime que MangoPOS Desktop, compartiendo modelos).
- **HTTP:** `shelf` + `shelf_router`.
- **Persistencia:** `sqlite3` (paquete oficial Dart) o `drift`.
- **mDNS:** `bonsoir` o `multicast_dns`.
- **USB ESC/POS:** la librería actual usada por MangoPOS Desktop (`[POR CONFIRMAR]`).
- **Realtime:** `supabase_flutter` (mismo cliente que el resto del sistema).
- **Servicio Windows:** envoltorio con `nssm` o instalación nativa vía MSIX con tarea programada al login.

---

## 9. Riesgos y mitigaciones

| Riesgo                                                               | Impacto | Probabilidad | Mitigación                                                                          |
| -------------------------------------------------------------------- | ------- | ------------ | ----------------------------------------------------------------------------------- |
| Driver USB de la impresora se cuelga y bloquea la cola               | Alto    | Media        | Worker con timeout duro (10 s) y reset del handle USB ante timeout.                 |
| mDNS bloqueado por firewall de Windows o multicast filtrado en el router | Medio | Media | Excepción de firewall añadida en el instalador MSIX para mDNS y UDP/9101. UDP broadcast cubre el caso de routers que filtran multicast. Supabase Realtime cubre el caso extremo. |
| IP de la PC cambia y los Android se quedan sin imprimir              | Alto    | Media        | Cascada cache → mDNS → UDP → Supabase (sección 6.3). Re-anuncio automático del agente al detectar cambio de interfaz. Cero intervención del operador. |
| Reloj desincronizado entre Android y PC genera inconsistencias en logs | Bajo  | Alta         | Todos los timestamps del agente en UTC, los del cliente como referencia secundaria. |
| Supabase Realtime no entrega el evento (ej. corte de internet)       | Alto    | Media        | Job persiste en `print_jobs`; agente hace polling cada 30 s como red de seguridad.  |
| Conflicto de versión entre agente viejo y app Android nueva          | Medio   | Alta         | Versionado de API (`/v1/`); `/v1/info` expone versión para que el cliente decida.   |
| JWT expira durante una sesión larga del mesero                       | Medio   | Alta         | Refresh token rotation ya configurado en Supabase (heredado del trabajo previo).    |
| Impresora apagada físicamente sin avisar                             | Medio   | Alta         | Detección por polling y push de incidente; cola pausa hasta recuperación.           |

---

## 10. Plan de entrega por fases

### Fase 1 — Fundación (semana 1-2)

- Extraer el agente LAN a un binario independiente del Desktop.
- Servidor HTTP con `POST /v1/print` y `/v1/health` funcionando.
- Cola SQLite básica con worker secuencial.
- Auth JWT.
- **Hito:** un Android puede imprimir vía HTTP, con auth.

### Fase 2 — Robustez (semana 3-4)

- Idempotencia.
- Reintentos con backoff.
- Detección de estado de impresora.
- Logs estructurados.
- Servicio de Windows con auto-restart.
- **Hito:** dos Android imprimen concurrentemente sin colisión y reinicios no pierden trabajos.

### Fase 3 — Descubrimiento y resiliencia (semana 5)

- mDNS publicado y consumido por la app Android.
- Fallback Supabase Realtime.
- Tabla `agent_incidents` y observabilidad remota.
- **Hito:** prueba de campo: desconectar router → seguir imprimiendo vía Supabase.

### Fase 4 — Pulido y despliegue (semana 6)

- Instalador MSIX con configuración inicial guiada.
- Migración de clientes piloto.
- Documentación operativa.
- **Hito:** rollout completo a clientes piloto.

---

## 11. Preguntas abiertas

1. ¿El agente LAN se distribuye **separado** de MangoPOS Desktop o queda **embebido**? (Recomendación del PRD: separado, mismo MSIX-bundle.)
2. ¿La librería actual de impresión USB soporta polling de estado (DLE EOT) en Windows? Si no, requiere reemplazo o capa adicional.
3. ¿El JWT que usan los Android es el del usuario mesero o uno de "device"? Si es de usuario, ¿qué pasa con tickets generados al cambiar de turno?
4. ¿Necesitamos soportar simultáneamente la versión vieja del agente y la nueva durante el rollout, o se puede hacer corte limpio?
5. ¿El cliente piloto tiene política de red restrictiva (firewall corporativo, VLAN separada para Android)? Esto afecta mDNS.
6. ¿Hay requisitos legales/fiscales (DGII, comprobante fiscal) que afecten el contenido o ruteo de los tickets en la versión nueva?
7. Para V2: ¿múltiples impresoras por agente (cocina + caja + bar)? Si sí, hay que reservar `printer_id` en el contrato desde ya.

---

## 12. Apéndice: glosario

- **Agente LAN:** servicio que corre en la PC Windows del local y atiende solicitudes de impresión de los dispositivos en la red local.
- **Job / trabajo de impresión:** unidad atómica de trabajo encolado, que se traduce en un ticket impreso.
- **Ticket ID:** UUID generado por el cliente, único por intento lógico de impresión, base de la idempotencia.
- **ESC/POS:** estándar de comandos de control para impresoras térmicas (Epson Standard Code for Point of Sale).
- **mDNS / Bonjour:** protocolo de descubrimiento de servicios en red local sin configuración.