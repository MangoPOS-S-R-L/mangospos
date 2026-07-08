# PRD Técnico — Modo Híbrido: Hub Central LAN-first (caja principal como servidor del local)

> **Tipo:** PRD técnico para aprobación e implementación.
> **Fecha:** 2026-07-08
> **Autor:** Ingeniería MangoPOS.
> **Relacionado:** [PRD_OFFLINE_100_ROADMAP.md](PRD_OFFLINE_100_ROADMAP.md) · [PRD_OFFLINE_F3_HUB_LOCAL.md](PRD_OFFLINE_F3_HUB_LOCAL.md) · [PRD_OFFLINE_F4_NCF.md](PRD_OFFLINE_F4_NCF.md) · [PRD_OFFLINE_ESTADO_ACTUAL.md](PRD_OFFLINE_ESTADO_ACTUAL.md)
> **Estado:** PROPUESTA — decisiones del dueño §4 ya resueltas; requiere validación multi-dispositivo en LAN antes de encender.

---

## 1. Resumen ejecutivo

Los negocios con **internet malo o intermitente** sufren un problema concreto: un mesero abre una mesa y agrega productos en su tablet, todo se ve bien en su equipo, pero **la caja principal no ve esa mesa** porque el dato nunca llegó al servidor. Peor: al "limpiar caché" para forzar recarga, la mesa local desaparece de la vista.

La causa raíz es arquitectónica: **hoy las cajas solo se comunican entre sí a través de Supabase** (nube). No existe ningún canal dispositivo-a-dispositivo. Si el WAN de un equipo falla, su trabajo queda atrapado localmente y es invisible para el resto del local.

Este PRD propone volver el sistema **híbrido** con dos políticas de operación seleccionables desde configuración:

- **Modo Nube (actual, default):** cada caja habla directo con Supabase. Ideal donde la red es buena. No cambia.
- **Modo Hub (nuevo, LAN-first):** una computadora del local —la **caja principal**— se vuelve el **servidor central de la red local**. Todas las cajas escriben y leen de ella por LAN; el Hub es el **único** que sube a Supabase en segundo plano. El internet de cada caja deja de estar en el camino crítico.

**Ventaja clave:** en Modo Hub, las cajas dependen solo del enlace LAN local (cable/wifi interno, rápido y estable) hacia el Hub, no del WAN inestable de cada equipo. La mesa del mesero aparece en la caja principal **al instante** porque ambos leen del mismo Hub.

**Buena noticia de arranque:** gran parte del transporte de este Hub **ya está construido, probado y apagado** en el código (fase F3 del roadmap offline), gateado tras `kHubModeEnabled=false` en [hub_mode.dart:14](../lib/core/offline/hub/hub_mode.dart#L14). Este PRD reencuadra ese trabajo (de "respaldo cuando no hay internet" a "autoridad LAN permanente por configuración"), completa las piezas faltantes y define el camino a producción.

---

## 2. El problema en detalle

### 2.1 Cómo se comunican hoy las cajas (solo por la nube)

- **Mesero abre mesa / agrega producto** → escritura **directa a Supabase** (`fn_open_table_and_load`, `addItemFromMenu`) desde [sales_viewmodel.dart:938](../lib/presentation/sales/viewmodel/sales_viewmodel.dart#L938) y [:1846](../lib/presentation/sales/viewmodel/sales_viewmodel.dart#L1846). Solo si falla cae a una **cola local del propio dispositivo**.
- **Caja principal lee el salón** → lee la vista `v_zone_table_status` **directo de Supabase** ([zones_repository.dart:125](../lib/data/repositories/zones_repository.dart#L125)) + Realtime de Supabase ([sales_by_zone_viewmodel.dart:204](../lib/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart#L204)). Solo usa caché local si su propia consulta falla.

No hay canal LAN entre el dispositivo del mesero y el de la caja. Confirmado: el Hub existe en código pero está apagado ([hub_mode.dart:14](../lib/core/offline/hub/hub_mode.dart#L14), [hub_mode_controller.dart:43](../lib/core/offline/hub/hub_mode_controller.dart#L43)).

### 2.2 Las dos formas en que se pierde la mesa

**Caso A — Sin internet (`isConnected == false`):**
El mesero abre mesa → el RPC falla → se crea un borrador `local-order-…` que vive **solo en la tablet del mesero** ([createLocalDraft, offline_pos_service.dart:467](../lib/core/offline/offline_pos_service.dart#L467)). Los ítems van a la cola local. **Nada** se inserta en el servidor. La caja lee del servidor → no existe la fila → no la ve. Realtime nunca dispara porque ninguna fila cambió en el servidor.

**Caso B — "Conectado pero malo" (la ventana peligrosa, `isConnected` sigue en `true`):**
`isConnected = adapterUp && reachable`, y `reachable` se decide con un sondeo cada 30 s, timeout de 8 s y **2 fallos consecutivos** antes de marcar offline ([connectivity_service.dart:72](../lib/core/network/connectivity_service.dart#L72), [:115](../lib/core/network/connectivity_service.dart#L115)). Justo después de un sondeo exitoso, `isConnected` sigue en `true` aunque un RPC real ahora expire.
- **Abrir mesa:** el `catch` exige `!isConnected` para crear el borrador local ([sales_viewmodel.dart:983](../lib/presentation/sales/viewmodel/sales_viewmodel.dart#L983)); como `isConnected` es `true`, no crea borrador y solo muestra error. La mesa no queda ni en servidor ni local.
- **Agregar ítem:** `isOffline` evalúa `false` ([sales_viewmodel.dart:1902](../lib/presentation/sales/viewmodel/sales_viewmodel.dart#L1902)), así que **no encola**: revierte el ítem optimista ([:1940](../lib/presentation/sales/viewmodel/sales_viewmodel.dart#L1940)) y **el ítem se pierde**.

> **El Caso B es el corazón del reporte del usuario.** El Modo Hub lo resuelve de raíz (las cajas no dependen del WAN), pero también proponemos un **hardening del Modo Nube** (§10) que ayuda a TODOS los negocios: encolar ante un error de transporte real, no solo cuando el flag `isConnected` ya cayó.

### 2.3 Por qué "limpiar caché" parece borrar las mesas

Auditado: el botón **"Limpiar caché del sistema"** ([settings_view.dart:903](../lib/presentation/settings/view/settings_view.dart#L903) → [cache_manager.dart:50](../lib/core/cache/cache_manager.dart#L50)) borra por lista blanca los prefijos `cache_`, `metadata_`, `hash_`, `offline_catalog_`, `printing_cached_*`. **NO toca** la cola offline ni los borradores (`offline_queue_*`, `offline_snapshot_*`, mapas), que viven en otro namespace / en SQLite. En papel, no debería borrar mesas.

El mecanismo real más probable del síntoma: al limpiar `cache_` se borra el snapshot de estado de mesas, lo que **fuerza una recarga fresca desde el servidor**. Si el equipo está "conectado", el grid se repuebla solo con las mesas del servidor — y la mesa local (que nunca subió) **desaparece de la vista** aunque el borrador siga en disco. El grid del salón hoy **no muestra las mesas locales/pendientes**; solo refleja `v_zone_table_status` del servidor. Esa es la brecha visual real.

Además existen dos rutas que sí borran estado sin sincronizar, hoy contenidas pero a vigilar:
- `clearOfflineBusinessData(preservePending:false)` — destructiva, con comentario de advertencia propio ([offline_pos_service.dart:738](../lib/core/offline/offline_pos_service.dart#L738)); su único invocador (logout) pasa `preservePending:true` ([session_controller.dart:924](../lib/services/session/session_controller.dart#L924)) → no borra pendientes.
- `_checkCacheVersion()` en instalación/bump de versión ([cache_manager.dart:185](../lib/core/cache/cache_manager.dart#L185)) borra el prefijo legacy `queue_`, **no** el `offline_queue_` actual.

§11 endurece todo esto para que la pérdida de datos sea **imposible por diseño** y las mesas pendientes **nunca desaparezcan** de la vista.

---

## 3. Objetivos y no-objetivos

### Objetivos
1. **Un modo Hub activable desde configuración** en el que la caja principal es el servidor central de la LAN.
2. En Modo Hub, **la mesa del mesero es visible al instante en la caja principal** y en cualquier otra caja del local, con o sin internet.
3. El Hub es la **única subida a Supabase**; el internet inestable de cada caja deja de romper la operación.
4. **KDS en vivo por LAN** sin depender del Realtime de Supabase.
5. **NCF fiscal asignado por el Hub** en la LAN, secuencial y sin huecos (decisión §4, gateado por firma del contador).
6. **Cero regresión** en Modo Nube (el camino actual probado no se toca).
7. **Módulo offline full-compatible con los procedimientos del POS** (§12): cerrar los gaps que hoy dejan flujos sin cobertura.
8. **Pérdida de datos imposible por diseño**: ningún wipe borra datos sin sincronizar; las mesas pendientes siempre visibles.

### No-objetivos (v1)
- No es un backend LAN genérico ni un reemplazo de Supabase. El Hub sirve la **ventana operativa del día**; los reportes históricos de rango largo siguen requiriendo nube.
- No hay elección de líder dinámica pura entre tablets. El Hub es un **primario designado + backup** (§8.7).
- No se soporta conectividad parcial optimizada (una sola tablet aislada mientras el resto está bien): esa tablet cae a modo Solo; se documenta, no se optimiza.
- No se re-arquitecta el modelo de datos del servidor. El uplink **reusa los RPCs existentes** (restricción vigente: no tocar BD salvo lo mínimo de §13).

---

## 4. Decisiones del dueño (RESUELTAS 2026-07-08)

| # | Decisión | Elección | Implicación |
|---|---|---|---|
| **D1** | ¿Dónde corre el Hub? | **App POS en la caja principal** (servidor Dart embebido, en proceso) | Reusa TODO el Hub Dart ya construido; cero paridad Node.js. Riesgo: si cierran la app se cae el Hub → mitigado con backup/failover (§8.7) y arranque automático del servidor. |
| **D2** | Política de ruteo con modo Hub ON | **Siempre por el Hub (LAN-first)**, aunque haya internet | El Hub es autoridad LAN permanente y única subida. Resuelve el Caso B de raíz. Es un modelo más fuerte que el F3 original ("Hub solo sin internet"). |
| **D3** | Alcance v1 | **Todo, incluido NCF fiscal en LAN** | El Hub asigna NCF secuencial (modelo F4 §9). Requiere **firma del contador** y cableado en el flujo de pago (zona sensible) → se entrega gateado y se enciende tras validación fiscal. |

> **Consecuencia de D2:** el `resolveHubMode` actual ([hub_mode.dart:19](../lib/core/offline/hub/hub_mode.dart#L19)) —que solo devuelve `hub` cuando NO hay internet— debe evolucionar a una **política de negocio**: si el local está configurado en Modo Hub, el ruteo es LAN-first **independiente de la conectividad**. Ver §6.2.

---

## 5. Estado actual: qué ya está construido y apagado

Todo detrás de `kHubModeEnabled=false` → cero impacto en producción hoy.

**Construido y probado (lado Dart), reutilizable tal cual o con evolución menor:**

| Pieza | Archivo | Estado |
|---|---|---|
| Enum de modos + resolutor | [hub_mode.dart](../lib/core/offline/hub/hub_mode.dart) | ✅ (evoluciona a política, §6.2) |
| Controlador de modo (Riverpod) | [hub_mode_controller.dart](../lib/core/offline/hub/hub_mode_controller.dart) | ✅ (cablear a config) |
| Cliente HTTP del Hub (`postOp`, `getStateSince`, `allocateNcf`, descubrimiento) | [hub_client.dart](../lib/core/offline/hub/hub_client.dart) | ✅ (token LAN a endurecer) |
| Op-log append-only, seq + idempotente | [hub_op_log.dart](../lib/core/offline/hub/hub_op_log.dart) | ⚠️ persistido en SharedPreferences JSON → **migrar a drift durable** (§8.6) |
| Cliente WebSocket con reconexión | [hub_event_stream.dart](../lib/core/offline/hub/hub_event_stream.dart) | ✅ |
| Proyector de cocina (op-log → KitchenOrder[]) | [hub_kitchen_projector.dart](../lib/core/offline/hub/hub_kitchen_projector.dart) | ✅ (limitación: solo órdenes creadas en la ventana, [:26](../lib/core/offline/hub/hub_kitchen_projector.dart#L26)) |
| Servidor `/hub/ops`, `/hub/state`, WS `/hub/events`, `/hub/ncf/next` | [mobile_print_agent.dart](../lib/core/agent/mobile_print_agent.dart) | ✅ (endpoints existen) |
| Seam de enrutado en la cola | `_hubUploader` en [offline_pos_service.dart:186](../lib/core/offline/offline_pos_service.dart#L186), `setHubUploader` [:196](../lib/core/offline/offline_pos_service.dart#L196) | ✅ |
| Uplink único Hub→Supabase | `syncHubOpLog` [offline_pos_service.dart:993](../lib/core/offline/offline_pos_service.dart#L993) | ✅ (replay idempotente reusado) |
| Asignador NCF concurrencia-safe + orquestador | [ncf_offline_allocator.dart](../lib/core/offline/ncf_offline_allocator.dart), [offline_ncf_service.dart](../lib/core/offline/offline_ncf_service.dart) | ✅ gateado `kOfflineNcfEnabled=false` |

**Lo que FALTA construir (el núcleo de este PRD):**
1. **Proyector de órdenes/mesas/checks** en el Hub (hoy solo hay proyector de cocina). Es la pieza que hace visible la mesa del mesero en la caja: el Hub debe materializar y servir el estado del salón (`GET /hub/state` para el grid) y el bundle de una orden.
2. **Ruteo LAN-first permanente** por política de negocio (no por conectividad).
3. **Rutas de lectura del salón y de la orden** apuntando al Hub en Modo Hub (hoy leen `v_zone_table_status` de Supabase).
4. **Uplink continuo en segundo plano** (hoy `syncHubOpLog` corre al reconectar; en Modo Hub debe drenar constantemente mientras haya internet).
5. **Persistencia durable del op-log** (drift, no SharedPreferences) — el Hub custodia TODO lo no subido del local.
6. **Configuración + designación del Hub** (UI de Ajustes, rol de dispositivo, descubrimiento).
7. **Failover/backup** cuando la caja principal se apaga.
8. **Cableado de emisión NCF en el flujo de pago** (gated contador).
9. **mDNS anuncio desde el equipo Hub** si corre en tablet (`multicast_dns` solo consulta; en escritorio ya se anuncia).
10. **Hardening del Modo Nube** (§10) y **anti-pérdida de datos** (§11).

---

## 6. Arquitectura propuesta

### 6.1 Dos políticas de operación seleccionables

```
                 ┌─────────────────────── CONFIGURACIÓN DEL LOCAL ───────────────────────┐
                 │  business_settings.network_mode ∈ { 'cloud', 'hub' }                  │
                 └───────────────────────────────────────────────────────────────────────┘
                          │                                              │
              network_mode = 'cloud' (default)              network_mode = 'hub'  (nuevo)
                          │                                              │
        ┌─────────────────▼─────────────────┐        ┌───────────────────▼───────────────────────┐
        │ MODO NUBE (actual, sin cambios)   │        │ MODO HUB (LAN-first, permanente)           │
        │                                   │        │                                            │
        │  Caja ──▶ Supabase (directo)      │        │  Mesero ─LAN▶ HUB ─(background)▶ Supabase   │
        │  Caja ◀── Realtime Supabase       │        │  Caja   ─LAN▶ HUB                           │
        │  (sin internet → cola local Solo) │        │  Caja   ◀WS── HUB (grid + KDS en vivo)      │
        └───────────────────────────────────┘        │  Sin LAN al Hub → cola local Solo          │
                                                      └────────────────────────────────────────────┘
```

### 6.2 Matriz de ruteo por modo (evolución de `resolveHubMode`)

| Política (config) | Estado de red | Escribe en | Lee de | Feed en vivo | Sube a Supabase |
|---|---|---|---|---|---|
| **Nube** | Internet OK | Supabase | Supabase + cachés | Realtime Supabase | cada caja |
| **Nube** | Sin internet | Cola local (Solo) | Snapshots locales | — | al reconectar (cada caja) |
| **Hub** (no es el Hub) | Hub LAN alcanzable | **Hub** `POST /ops` | **Hub** `GET /state` | **WS del Hub** | — (lo hace el Hub) |
| **Hub** (no es el Hub) | Hub LAN caído | Cola local (Solo) | Snapshots locales | — | vía Hub al recuperarlo |
| **Hub** (ES el Hub) | Internet OK | Op-log local (autoridad) | Estado materializado | difunde a todos | **sí, único uplink continuo** |
| **Hub** (ES el Hub) | Sin internet | Op-log local (autoridad) | Estado materializado | difunde a todos | buffer, sube al reconectar |

**Diferencia central con F3 original:** en Modo Hub el ruteo LAN-first es **permanente y por configuración**, no disparado por pérdida de conectividad. Un dispositivo en Modo Hub habla con el Hub **aunque tenga internet**. Esto elimina el Caso B (§2.2) porque el WAN de cada caja ya no participa en la operación.

### 6.3 Modelo de datos del Hub (op-log compartido, ya existente)

Se reutiliza el **modelo de acciones que ya existe** (`add_item`, `process_payment`, `send_to_kitchen`, `void_order`, `open_cash_session`, …). Cada mutación:

```
Terminal (modo Hub) ──POST /hub/ops──▶ HUB: asigna seq# monotónico, idempotente por op_id
                                            aplica a estado materializado (drift)
                    ◀──WS /hub/events──── HUB: difunde la op #N a TODOS (cajas + KDS)
                                            
        … con internet (continuo, background) …
HUB ──replay del op-log──▶ Supabase (uplink ÚNICO, idempotente por op_id/fingerprint,
                                      resuelve local-id → uuid y guarda el mapping)
HUB ◀──pull deltas──────── Supabase (catálogo/config/roster vía OfflineSyncCoordinator)
```

El Hub es el **único serializador**: asigna el orden, no hay escrituras concurrentes en conflicto dentro del local. El **uplink único** elimina de raíz la duplicación multi-terminal. El replay idempotente (op_id + fingerprint + mappings) ya está construido y probado.

---

## 7. El Hub en detalle (decisión D1: corre en la app POS de la caja principal)

### 7.1 Dónde y cómo corre
- El **MangoPOS de la caja principal** levanta su **servidor `shelf` embebido en proceso** ([mobile_print_agent.dart](../lib/core/agent/mobile_print_agent.dart), ya corre en escritorio para impresión) en `0.0.0.0:4000`, ahora también sirviendo los endpoints del Hub.
- El servidor arranca en el bootstrap si el dispositivo tiene rol Hub (§7.2). Debe ser resiliente a que la app pase a segundo plano (en escritorio corre en proceso; en macOS/Windows la ventana puede minimizarse pero el proceso sigue).
- **Requisito operativo:** la caja principal debe **permanecer con la app abierta** durante el servicio. Se muestra un banner "Este equipo es el Hub del local" y una advertencia al intentar cerrar la app con ops sin subir. El failover (§8.7) cubre el cierre accidental.

### 7.2 Designación y descubrimiento
- **Rol de dispositivo** nuevo: `device_role ∈ { pos, hub, hub_backup }`, guardado local (por instalación) y reflejado en `device_agents` (ya registra device/url/heartbeat).
- En Ajustes → Red local: seleccionar "Este equipo es el Hub" (uno por local) y opcionalmente un "Hub de respaldo".
- **Descubrimiento por las cajas:** se reusa [agent_discovery.dart](../lib/core/printing/agent_discovery.dart) (mDNS `_mangoprint._tcp` filtrado por `business_id`) + **dirección de Hub configurable** (IP fija recomendada para la caja principal) como respaldo robusto. `HubClient.findReachableHub` ([hub_client.dart:46](../lib/core/offline/hub/hub_client.dart#L46)) ya implementa esto; valida `GET /hub/health`.
- El Hub publica en su anuncio/health un TXT `role=hub` + `hub_seq` (último seq aplicado) para failover.
- **Nota mDNS:** `multicast_dns` solo CONSULTA, no anuncia. En escritorio (caja principal) el agente ya se anuncia; como el Hub v1 corre en la caja principal (escritorio), **no necesitamos anuncio desde tablet**. La IP fija configurable es el camino principal.

### 7.3 Estado materializado del Hub — **la pieza que hace visible la mesa** (NUEVO)
Hoy el Hub tiene op-log + proyector de **cocina**. Falta el proyector del **salón/órdenes**. Se construye:

- **`HubOrderProjector`**: pliega el op-log en el estado de órdenes/ítems/checks/sesiones y lo mantiene en drift. Sirve:
  - `GET /hub/salon` (o `GET /hub/state?view=salon`) → equivalente LAN de `v_zone_table_status`: zonas, mesas, ocupación, mozo, total. Esto alimenta el grid de la caja principal **sin tocar Supabase**.
  - `GET /hub/order?table_id=…` → bundle de la orden (ítems + modifiers + tax_lines), equivalente LAN de `fn_get_order_bundle`/`fn_open_table_and_load`.
- **Baseline al entrar a Modo Hub:** al activar el Hub (o al reconectar una caja al Hub), el Hub siembra su estado materializado con un snapshot de las órdenes/mesas activas desde Supabase (si hay internet) o desde el último snapshot, para que las mesas abiertas **antes** de entrar al Modo Hub también sean visibles (no solo las nuevas). Mismo patrón que el baseline pendiente de cocina en F3 §12.3.
- **Difusión en vivo:** cada op aplicada se emite por `WS /hub/events`; el grid del salón y el KDS se actualizan al instante (reemplaza el Realtime de Supabase dentro de la LAN).

> Esta es la pieza que resuelve el reporte: mesero y caja **leen del mismo Hub**, así que la mesa aparece en la caja en cuanto el mesero la crea, sin depender de que el dato viaje a la nube y vuelva.

### 7.4 Uplink único continuo (NUEVO comportamiento)
- Hoy `syncHubOpLog` ([offline_pos_service.dart:993](../lib/core/offline/offline_pos_service.dart#L993)) drena el op-log del Hub a Supabase **al reconectar**. En Modo Hub debe drenar **continuamente** mientras haya internet (por op o en micro-lotes), para que el servidor quede fresco para reportes, dashboard y otras sucursales.
- Si el Hub pierde internet, **buffer**: sigue operando la LAN y sube al recuperar. Sin bloqueo del POS.
- Idempotente y con resolución local-id → uuid centralizada en el Hub (FIFO garantiza crear-antes-de-mutar; ya validado en F3b-3b).

### 7.5 NCF fiscal por el Hub (decisión D3, gateado por contador)
- El Hub es el **asignador único de NCF** de la LAN (modelo preferido [PRD_OFFLINE_F4_NCF.md](PRD_OFFLINE_F4_NCF.md) §9): numeración **secuencial sin huecos** aunque facturen varias cajas, muy superior a sub-rangos por dispositivo.
- Endpoint `POST /hub/ncf/next` (atómico, ya existe) + `HubClient.allocateNcf` ([hub_client.dart:135](../lib/core/offline/hub/hub_client.dart#L135)); allocator serializado y probado con 50 concurrentes.
- **Cableado faltante (zona sensible):** al cobrar en Modo Hub, pedir NCF al Hub → crear `fiscal_document` con ese NCF → imprimir → encolar; y **reconciliar** `ncf_sequences.current_number` en el uplink sin regenerar el número.
- **Gate:** se entrega apagado (`kOfflineNcfEnabled=false`) hasta la **firma del contador** (modelo de series a/b, contingencia e-CF/Alanube, política de caja aislada). One-pager listo: [F4_NCF_OFFLINE_CONSULTA_CONTADOR.md](F4_NCF_OFFLINE_CONSULTA_CONTADOR.md). Riesgo fiscal central: huecos de numeración → DGII.

### 7.6 Seguridad LAN
- Reemplazar el **token hardcoded** del agente ([hub_client.dart:34](../lib/core/offline/hub/hub_client.dart#L34)) por un **token por-negocio** derivado del binding del dispositivo (o del paquete de activación F0). Todo endpoint del Hub lo exige.
- El Hub solo escucha en la LAN; no se expone a WAN. Recomendación de despliegue: subred/VLAN del POS.

### 7.7 Persistencia durable (NUEVO — crítico)
El op-log del Hub hoy se guarda como **JSON en SharedPreferences** ([hub_op_log.dart](../lib/core/offline/hub/hub_op_log.dart)). Para un Hub de producción que **custodia todo lo no subido del local**, eso es frágil. Se migra a **drift/SQLite** (append-only, seq, idempotente por op_id), con la misma API `append/since/clear`. Justificación: durabilidad ante crash/reinicio, escrituras atómicas, consultas por rango de seq.

---

## 8. Cambios por capa

### 8.1 Configuración (BD + UI)
- `business_settings.network_mode text default 'cloud'` (`'cloud' | 'hub'`) — política del local. (Migración §13.)
- Local por dispositivo: `device_role` (`pos | hub | hub_backup`) + `hub_address` (IP configurable) en almacenamiento local.
- **UI Ajustes → "Red local (Hub)":** conmutador de modo, designar Hub/backup, IP fija, estado de salud del Hub y contador de ops sin subir. Reusa el patrón de cacheo de `business_settings` ([BusinessSettingsOfflineCache](../lib/core/offline/business_settings_offline_cache.dart)) para que el modo sobreviva sin internet.

### 8.2 Ruteo (política, no conectividad)
- Evolucionar `resolveHubMode` ([hub_mode.dart:19](../lib/core/offline/hub/hub_mode.dart#L19)) → `resolveNetworkMode(policy, isHubDevice, hubReachable, isConnected)`:
  - `policy == cloud` → comportamiento actual (cloud/solo por conectividad).
  - `policy == hub` y no soy Hub → `hub` si el Hub es alcanzable; si no, `solo`.
  - `policy == hub` y soy Hub → `hub_host` (autoridad local).
- `HubModeController` ([hub_mode_controller.dart](../lib/core/offline/hub/hub_mode_controller.dart)) observa la config + salud del Hub y cablea `OfflinePosService.setHubUploader(...)` ([:196](../lib/core/offline/offline_pos_service.dart#L196)). Ya existe el seam; hoy inerte por el flag.

### 8.3 Escritura (ya casi lista)
- `enqueueAction` ([offline_pos_service.dart:510](../lib/core/offline/offline_pos_service.dart#L510)) ya enruta al Hub cuando hay `_hubUploader`. En Modo Hub el uploader está **siempre activo** (no solo sin internet). Confirmar que **todas** las mutaciones de venta pasan por este seam (hoy el camino online las hace directas a Supabase antes del `catch`).
  - **Cambio clave:** en Modo Hub, las mutaciones NO intentan Supabase directo primero; van directo al Hub por LAN. Se añade una bifurcación temprana en los viewmodels de venta que consulta el modo antes de decidir el destino (en vez de "intenta nube, cae a cola en el catch").

### 8.4 Lectura del salón y de la orden (NUEVO)
- `ZonesRepository.fetchByZone` ([zones_repository.dart:121](../lib/data/repositories/zones_repository.dart#L121)): en Modo Hub, leer de `GET /hub/salon` en vez de `v_zone_table_status`. Mantener el fallback a snapshot local si el Hub no responde.
- `sales_by_zone_viewmodel` ([:204](../lib/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart#L204)): en Modo Hub, suscribirse a `WS /hub/events` en lugar del Realtime de Supabase para actualizar el grid.
- Apertura/carga de orden ([sales_viewmodel.dart:938](../lib/presentation/sales/viewmodel/sales_viewmodel.dart#L938)): en Modo Hub, leer bundle del Hub.

### 8.5 KDS por LAN (F3c, wiring pendiente)
- `kds_viewmodel` consume `HubEventStream` + `GET /hub/state` proyectado con `HubKitchenProjector` ([hub_kitchen_projector.dart](../lib/core/offline/hub/hub_kitchen_projector.dart)) en Modo Hub, en vez del Realtime de Supabase.
- Nueva op `kds_item_status` (preparando/listo/servido) + su replay en `_replayAction` ([offline_pos_service.dart:1385](../lib/core/offline/offline_pos_service.dart#L1385)) para que los cambios de estado suban al reconectar.
- Baseline de cocina activa al entrar a Modo Hub (comandas previas a la activación).

### 8.6 Persistencia del op-log → drift (§7.7).

### 8.7 Failover / Hub caído
- **Detección:** las cajas sondean `GET /hub/health`; si el Hub primario no responde, descubren por mDNS/IP al `hub_backup` (TXT `role=hub`).
- **Backup:** arranca su Hub desde su op-log replicado; las cajas reenvían las ops no confirmadas (idempotentes por op_id → sin duplicar). El backup adopta el `hub_seq` más alto visto.
- **Split-brain** (dos Hubs activos): se previene con **un único `role=hub` primario por negocio** + *fencing* por `hub_epoch` (el Hub con epoch menor se cede al detectar otro). v1: detección + cesión simple, documentar el borde.
- **Sin backup disponible:** las cajas caen a **modo Solo** (cola local propia, ya existente) y reconcilian por el Hub al recuperarlo. Nunca se pierde: cada caja retiene sus ops localmente hasta confirmación del Hub.
- **Replicación del op-log al backup:** el Hub primario empuja su op-log al backup por el mismo WS/endpoint (best-effort continuo) para acotar la divergencia.

---

## 9. Diagrama de flujo — "mesero abre mesa" en Modo Hub

```
1. Mesero (tablet, Modo Hub) abre mesa 5 y agrega 2 cervezas.
2. Tablet ──POST /hub/ops (open_table)──▶ HUB  → seq 101, materializa mesa 5 ocupada
   Tablet ──POST /hub/ops (add_item x2)─▶ HUB  → seq 102-103, materializa ítems
3. HUB ──WS /hub/events (101,102,103)──▶ TODAS las cajas + KDS
      → la CAJA PRINCIPAL ve la mesa 5 ocupada con 2 cervezas AL INSTANTE
      → el KDS muestra la comanda
4. (background, si hay internet) HUB ──replay 101-103──▶ Supabase
      → crea table_session/order/items reales, guarda mapping local→uuid
5. (sin internet) HUB retiene 101-103 en su op-log drift; sube al reconectar.
      La operación del local NUNCA se detuvo.
```

Compárese con hoy (§2.2): en el mismo escenario con red mala, la mesa se pierde o queda invisible.

---

## 10. Hardening del Modo Nube — la ventana "conectado pero malo" (beneficia a TODOS)

Independiente del Hub, se corrige el Caso B (§2.2) para los negocios que sigan en Modo Nube:

- **Encolar ante error de transporte real, no solo cuando `isConnected` ya cayó.** Hoy el `catch` de agregar ítem ([sales_viewmodel.dart:1902](../lib/presentation/sales/viewmodel/sales_viewmodel.dart#L1902)) evalúa `isOffline` con el flag `isConnected`, que va 2 sondeos atrás. Cambio: si el error es de **transporte** (timeout, socket, 5xx, `ClientException`), **encolar** aunque `isConnected` siga en `true`, y disparar `forceReachabilityCheck()` ([connectivity_service.dart:328](../lib/core/network/connectivity_service.dart#L328)) para revaluar la conectividad de inmediato.
- Igual para **abrir mesa**: crear borrador local ante error de transporte, no exigir `!isConnected` ([sales_viewmodel.dart:983](../lib/presentation/sales/viewmodel/sales_viewmodel.dart#L983)).
- Resultado: en Modo Nube, un bache de red **encola** en vez de **perder** el ítem; sube solo al reconectar. Esto solo mejora robustez; no cambia el camino feliz.

> Este ítem es de **alto valor y bajo riesgo**; se puede entregar **antes** que el Hub para aliviar el dolor inmediato de los negocios con red mala.

---

## 11. Anti-pérdida de datos: que las mesas nunca desaparezcan

1. **Mostrar mesas locales/pendientes en el grid del salón.** Hoy el grid solo refleja `v_zone_table_status` del servidor; una mesa `local-order-…` no aparece como ocupada. Cambio: el grid **fusiona** el estado del servidor/Hub con los borradores locales pendientes, marcándolas visualmente ("pendiente de sincronizar"). Así, aunque se limpie caché, la mesa **no desaparece**.
2. **"Limpiar caché" nunca toca datos sin sincronizar.** Ya es así por lista blanca ([cache_manager.dart:57](../lib/core/cache/cache_manager.dart#L57)); se añade **verificación explícita**: antes de limpiar, contar borradores/cola pendientes y, si hay, **advertir** ("Tienes N mesas sin sincronizar; no se borrarán, pero espera a que suban"). Reusa el conteo de [offline_logout_guard.dart:14](../lib/presentation/shell/offline_logout_guard.dart#L14).
3. **Indicador global de pendientes** siempre visible (ya existe [OfflineQueueStatusController](../lib/core/offline/offline_queue_status_provider.dart), badge en el topbar): elevar a un chip claro "N sin subir" con acceso a ver/reintentar, para que nadie limpie/cierre a ciegas.
4. **Blindar los wipes destructivos:** `clearOfflineBusinessData(preservePending:false)` ([offline_pos_service.dart:738](../lib/core/offline/offline_pos_service.dart#L738)) y cualquier ruta futura deben **rechazar** borrar si hay pendientes sin subir, salvo confirmación explícita con conteo. `_checkCacheVersion` ([cache_manager.dart:185](../lib/core/cache/cache_manager.dart#L185)) nunca debe tocar `offline_*` (verificar el prefijo `queue_` legacy).
5. **Investigar el reporte con el usuario:** confirmar si la pérdida ocurre tras *limpiar caché*, *logout*, *cambio de negocio* o *actualización de la app*, para atacar el mecanismo exacto (el análisis apunta a la recarga forzada que oculta mesas locales, ítem 1).

---

## 12. Revisión del módulo offline para full-compatibilidad con los procedimientos

El usuario pidió "revisar el módulo offline para que sea full compatible con los procedimientos". Auditoría de cobertura actual vs. lo necesario para que el Modo Hub sea completo:

| Procedimiento | Estado offline hoy | Acción para Modo Hub v1 |
|---|---|---|
| Abrir mesa / agregar-editar-borrar ítems | ✅ cola + snapshot (por-device) | Enrutar al Hub; visible entre cajas |
| Enviar a cocina / KDS | ⚠️ ticket papel; KDS depende de Realtime | KDS por WS del Hub (§8.5) |
| Cobro / pago | ✅ `process_payment` encolable | Enrutar al Hub; NCF por Hub (D3) |
| NCF fiscal | ❌ diferido al sync (`kOfflineNcfEnabled=false`) | Hub asignador (gated contador) |
| Abrir/cerrar caja | ✅ offline | Enrutar al Hub |
| Movimientos de caja | ⚠️ encolado pero `created_at` se estampa al sync ([offline_pos_service.dart:1470]) | Estampar `occurred_at` del momento (Hub lo preserva) |
| Cola de impresión | ⚠️ se guarda; drenado parcial | Verificar drenado en Modo Hub |
| Reportes del día | ✅ caché offline (F5) | Servir desde el Hub cuando aplique |
| Mesa abierta en otra caja | ❌ invisible sin red | ✅ resuelto por el Hub (§7.3) |
| CRUD catálogo/zonas/clientes/ajustes | ❌ falla offline (no encolable, `UnsupportedError`) | Fuera de v1; documentar (config se hace online) |
| Web (navegador) | ⚠️ sin SQLite: cola en SharedPreferences, sin poda | Modo Hub recomendado solo en escritorio/tablet; documentar límite web |

**Conclusión de la revisión:** el flujo crítico (vender/cobrar/caja) ya es offline-capaz por-dispositivo; lo que falta para "full compatible con los procedimientos" en un local multi-caja es exactamente la **visibilidad y serialización compartida** que aporta el Hub, más el drenado de impresión, el timestamp de caja y el gate fiscal.

---

## 13. Migraciones de BD (mínimas — reusa RPCs)

1. `business_settings.network_mode text not null default 'cloud'` — política del local. **Nueva.**
2. **NCF infra** (`20260601_0004`, ya escrita, **SIN APLICAR**): `ncf_sequences.device_id` + `fiscal_documents.offline_issued`. Aplicar cuando se encienda D3.
3. **Restricción de red al uplink de NCF:** `UNIQUE(business_id, ncf_number)` como salvaguarda anti-duplicado (parte de F4 activación).
4. Sin cambios en el modelo de órdenes/mesas: el uplink reusa `fn_open_table_and_load`, `fn_process_payment_v3`, etc. (restricción vigente: no tocar BD fuera de lo anterior).

> Verificar contra `supabase/schema.sql` antes de aplicar (la BD viva diverge del repo — ver nota histórica). Entregar las migraciones al dueño para correr en Supabase (no hay acceso a prod desde dev).

---

## 14. Fases de entrega y criterios de activación

| Fase | Alcance | Riesgo | Gate para encender |
|---|---|---|---|
| **H0 — Hardening Nube** (§10) | Encolar por error de transporte real + borrador de mesa; anti-pérdida (§11 ítems 1-3) | Bajo | Ninguno; sale ya, ayuda a todos |
| **H1 — Config + rol** | `network_mode`, `device_role`, UI Ajustes Red local, descubrimiento/IP fija | Bajo | Migración `network_mode` aplicada |
| **H2 — Op-log durable** | Migrar `HubOpLog` a drift; persistencia atómica | Medio | Tests de durabilidad/crash |
| **H3 — Proyector de salón** (§7.3) | `HubOrderProjector`, `GET /hub/salon`, `GET /hub/order`, baseline | **Alto** | Prueba multi-dispositivo LAN: mesa del mesero visible en caja |
| **H4 — Ruteo LAN-first + lecturas** | Bifurcación temprana por modo; grid/orden leen del Hub; WS reemplaza Realtime | **Alto** | Paridad de datos Hub vs Supabase validada |
| **H5 — Uplink continuo** | Drenado background + resolución central de IDs + reconciliación | **Alto** | Cero duplicados en uplink; reportes frescos |
| **H6 — KDS por LAN** (§8.5) | `kds_viewmodel` ↔ Hub, op `kds_item_status`, baseline cocina | Medio | Prueba en cocina real |
| **H7 — Failover/backup** (§8.7) | Backup, fencing por epoch, replicación op-log | **Alto** | Prueba de apagar la caja principal en vivo |
| **H8 — NCF por el Hub** (§7.5, D3) | Emisión en flujo de pago + reconciliación `current_number` | **Alto (fiscal)** | **Firma del contador** + migración `20260601_0004` + prueba multi-caja + DGII |
| **H9 — Token LAN por-negocio** (§7.6) | Reemplaza token hardcoded | Medio | — |

**Orden recomendado:** H0 (inmediato) → H1 → H2 → H3 → H4 → H5 → (H6 ∥ H7) → H9 → **H8 al final** (bloqueado por fiscal).

**El flag maestro `kHubModeEnabled`** ([hub_mode.dart:14](../lib/core/offline/hub/hub_mode.dart#L14)) solo se enciende tras **H3-H5 validados en LAN real con varios equipos**. `kOfflineNcfEnabled` solo tras H8 + firma del contador.

---

## 15. Riesgos y mitigaciones

| Riesgo | Impacto | Mitigación |
|---|---|---|
| El Hub es un mini-backend LAN (concurrencia, failover, split-brain) | Alto | Hub = único serializador; primario+backup; fencing por epoch; fasear H1→H7 |
| La caja principal (Hub) se apaga/cierra la app | Alto | Op-log durable (H2) + failover a backup (H7) + banner/advertencia; nunca se pierde (cada caja retiene sus ops) |
| Tocar el camino Nube probado | Alto | Modo Nube **no se toca**; el ruteo LAN-first es una bifurcación por config; H0 solo añade encolado en el `catch` |
| Riesgo fiscal (NCF por Hub) | Alto | Gate por firma del contador; entregar apagado; `UNIQUE(business,ncf)` de red |
| Persistencia frágil del op-log (SharedPreferences hoy) | Alto | Migrar a drift (H2) antes de confiar operación al Hub |
| Divergencia Hub↔Supabase en el uplink | Medio | Replay idempotente ya probado; resolución central de IDs; reconciliación |
| Web sin SQLite | Medio | Modo Hub recomendado en escritorio/tablet; documentar límite web |
| Reloj entre dispositivos | Bajo | El Hub estampa `received_at` y asigna `seq`; el orden lo da el Hub, no el reloj |
| Seguridad LAN (token hardcoded) | Medio | Token por-negocio (H9) |

---

## 16. Plan de pruebas / QA (multi-dispositivo en LAN real)

Prerrequisito ineludible: **no se enciende nada sin prueba en una LAN con varios equipos** (es flujo de caja/cocina/fiscal, sensible).

1. **Visibilidad de mesa:** mesero abre mesa en tablet → aparece en la caja principal en < 2 s (con y sin internet del local).
2. **Ventana "conectado pero malo":** degradar el WAN (no cortarlo) → verificar que ningún ítem se pierde (H0) y que en Modo Hub la operación no se entera.
3. **Uplink sin duplicados:** operar 30 min sin internet → reconectar → verificar en Supabase que no hay órdenes/pagos duplicados y los mappings son correctos.
4. **Failover:** apagar la caja principal en plena operación → el backup toma el control → las cajas siguen; al volver el primario, sin split-brain.
5. **KDS:** comandas nuevas y previas visibles; cambios de estado propagados por WS.
6. **NCF (H8):** numeración secuencial sin huecos entre varias cajas; reconciliación de `current_number` correcta.
7. **Anti-pérdida:** limpiar caché / logout / cambio de negocio con pendientes → nada se pierde, se advierte, las mesas siguen visibles.
8. **Regresión Modo Nube:** batería completa con `network_mode='cloud'` → comportamiento idéntico al actual.

Reusar y ampliar [OFFLINE_SMOKE_TEST.md](OFFLINE_SMOKE_TEST.md).

---

## 17. Métricas de éxito

- **0** mesas/ítems perdidos por red mala en negocios en Modo Hub.
- **< 2 s** de latencia mesa-creada → visible-en-caja dentro de la LAN.
- **0** órdenes/pagos duplicados tras uplink.
- **0** huecos de numeración NCF en Modo Hub (H8).
- Reducción medible de tickets de soporte por "la mesa no aparece en la caja".

---

## 18. Decisiones abiertas / dependencias externas

1. **Firma del contador** para NCF por Hub (H8) — one-pager listo ([F4_NCF_OFFLINE_CONSULTA_CONTADOR.md](F4_NCF_OFFLINE_CONSULTA_CONTADOR.md)).
2. **IP fija de la caja principal** por local (recomendado) vs. depender solo de mDNS.
3. **¿Hub de respaldo obligatorio u opcional?** Recomendado: opcional pero fuertemente sugerido; sin backup, caída del Hub = modo Solo por-caja.
4. **Confirmar el mecanismo exacto** del síntoma "limpiar caché borra mesas" con el usuario (§11.5).
5. **Aplicar migraciones** pendientes en Supabase (el dueño las corre): `network_mode` (nueva) y `20260601_0004` (NCF, para H8).

---

*Basado en lectura directa del código al 2026-07-08. Reutiliza el transporte del Hub ya construido (F3) y lo reencuadra de "respaldo sin internet" a "autoridad LAN permanente por configuración" (LAN-first), con NCF por el Hub (D3, gated fiscal).*
