# Diseño — F3: Hub Local LAN (KDS offline + consistencia multi-terminal)

> **Tipo:** Diseño técnico para aprobación (antes de implementar). Parte del [roadmap offline 100%](PRD_OFFLINE_100_ROADMAP.md), fase F3.
> **Fecha:** 2026-05-31
> **Estado:** PROPUESTA — requiere decisiones del dueño (§9) antes de codear.

---

## 1. Qué resuelve F3

Hoy, sin internet, cada terminal opera **aislado** (modo "Solo", ya implementado en F1/F2): toma comandas y cobra contra su propia cola local. Pero:

- **La pantalla de cocina (KDS) queda ciega** — depende del Realtime de Supabase.
- **Una mesa abierta en otra caja no se puede cargar** (cada device solo ve sus snapshots).
- **Dos cajas sobre la misma mesa divergen** — no hay autoridad común.

F3 introduce un **Hub Local**: un servicio en la LAN que, cuando no hay internet, es la **fuente de verdad del local** y empuja cambios en vivo a todos los terminales (incluido el KDS). Al reconectar, el Hub —y solo el Hub— sincroniza con Supabase.

---

## 2. Modelo central: el Hub es "la cola, pero compartida y con feed en vivo"

La pieza elegante es **reutilizar el modelo de acciones que ya existe** (`add_item`, `process_payment`, `cash_transaction`, `void_order`, `send_to_kitchen`, …). Hoy esas acciones se encolan por-device; el Hub las eleva a un **log de operaciones compartido en LAN**:

```
Terminal (modo Hub)                 HUB LOCAL (autoridad LAN)
  muta algo  ──POST /ops──────────▶ asigna seq# monotónico
                                    aplica a su estado materializado (SQLite)
  ◀──push (WS) op #N───────────────  difunde la op a TODOS los suscriptores
  actualiza su vista                 (incluido el KDS)

         … al volver internet …
  HUB ──replay del op-log──────────▶ Supabase (único uplink, idempotente
                                      por op_id/fingerprint — ya existe)
  HUB ──pull deltas───────────────◀ Supabase (catálogo/config)
  terminales vuelven a modo Cloud y releen de Supabase
```

**Por qué así:**
- El Hub es un **único punto de serialización** → no hay escrituras concurrentes en conflicto dentro de la ventana offline (él asigna el orden).
- Reutiliza el **replay idempotente** que ya construimos (op_id + fingerprint + mappings local→remoto) para el uplink.
- El **uplink único** (solo el Hub sube a Supabase) elimina la duplicación multi-terminal de raíz.
- El **feed en vivo** (push) es exactamente lo que el KDS necesita para funcionar sin Realtime de Supabase.

---

## 3. Modos de operación por terminal

| Modo | Condición | Escribe en | Lee de | Push |
|---|---|---|---|---|
| **Cloud** | Internet OK | Supabase (como hoy) | Supabase + caches | Realtime Supabase |
| **Hub** | Sin internet, Hub LAN alcanzable | Hub (`POST /ops`) | Hub (`GET /state`) | WS del Hub |
| **Solo** | Sin internet y sin Hub | Cola local propia (F1/F2) | Snapshots locales | — |

**Decisión de diseño (importante):** el modo **Cloud queda intacto** (riesgo bajo — no tocamos el camino online probado). El Hub solo entra cuando se cae internet. Caso común real: el router/WAN cae y **todo el local** baja a modo Hub junto. El caso de conectividad parcial (una tablet con wifi flaky mientras el resto tiene internet) es raro y se trata como borde: esa tablet cae a Solo o reintenta Cloud; se documenta, no se optimiza en v1.

---

## 4. Qué corre el Hub y cómo se descubre

**Reutilizamos** [agent_discovery.dart](../lib/core/printing/agent_discovery.dart) (mDNS `_mangoprint._tcp`, filtrado por `business_id`) y la tabla `device_agents` (ya registra device_name/agent_url/platform/heartbeat).

- El servicio que corre el Hub es una **evolución del agente** ([mobile_print_agent.dart](../lib/core/agent/mobile_print_agent.dart) en móvil, agente Node.js en desktop) — ya levantan un servidor `shelf` en `0.0.0.0:4000`.
- **Falta**: que el agente Dart **se anuncie por mDNS** (hoy solo el Node.js lo hace) y que publique un TXT `role=hub` + `hub_seq` (último seq aplicado, para failover).

**Quién es el Hub (ver decisión §9.A):** propuesta = **primario designado** (configurable; por defecto el equipo con el agente desktop si existe, si no una tablet elegida en Ajustes), con **failover automático** a un backup. Evitamos la complejidad de elección de líder dinámica pura en v1.

---

## 5. Estado autoritativo del Hub

El Hub mantiene en SQLite (drift, ya disponible):

1. **Op-log** append-only: `{seq, op_id, type, payload, device_id, received_at, fingerprint}`. Es la cola de uplink a Supabase.
2. **Estado materializado**: órdenes, items, checks, sesiones de caja y **estado KDS** (item → pending/preparing/ready), reconstruido aplicando el op-log. Sirve las lecturas (`GET /state`, abrir mesa ajena, render del KDS).
3. **Mappings** local→remoto (reusa el formato actual) para el uplink.
4. **NCF**: en F4 el Hub será quien asigne números desde el rango del negocio (un solo asignador local evita colisiones) — F3 deja el hook listo.

---

## 6. Protocolo (API del Hub, sobre `shelf`)

- `GET /hub/health` — vivo + `seq` actual + `role`.
- `GET /hub/state?since=<seq>` — snapshot del estado materializado, o delta desde `seq` (para que un terminal que entra se ponga al día).
- `POST /hub/ops` — recibe una acción (mismo shape que `enqueueAction` hoy); el Hub asigna `seq`, aplica, persiste y difunde. Responde con `seq` + IDs resueltos.
- `WS /hub/events` — feed en vivo: cada op aplicada se emite a los suscriptores (KDS y demás terminales). **Transporte: ver decisión §9.B.**
- Auth LAN: token por negocio (idealmente del paquete de activación de F0; en v1, secreto derivado del device binding). Reemplaza el token hardcoded actual.

---

## 7. KDS offline (cómo se cierra G1)

- El terminal KDS, en modo Hub, **se suscribe a `WS /hub/events`** en vez del Realtime de Supabase, y renderiza desde `GET /hub/state`.
- Cambiar estado (preparando/listo) = `POST /hub/ops` con la op correspondiente → el Hub difunde → todas las pantallas se actualizan.
- Cache local de la última vista para arranque instantáneo aunque el Hub tarde un segundo.

---

## 8. Failover, split-brain y reconciliación

- **Failover:** si el Hub primario no responde, los terminales descubren por mDNS al backup (TXT `role=hub`). El backup arranca su Hub desde su SQLite replicado (los terminales reenvían las ops no confirmadas). Para acotar divergencia, el backup adopta el `hub_seq` más alto visto.
- **Split-brain** (dos Hubs activos): se previene con **un único `role=hub` primario por negocio en mDNS** + *fencing*: las ops llevan el `hub_epoch`; el Hub con epoch menor se cede al detectar otro. (v1: detección + cesión simple; documentar el borde.)
- **Reconciliación al reconectar:** el Hub drena su op-log a Supabase con el **replay idempotente ya existente**, luego baja deltas (catálogo/config). Los terminales vuelven a Cloud y releen. Cero duplicación porque el uplink es único.

---

## 9. Decisiones (RESUELTAS por el dueño 2026-05-31)

- **A. Host del Hub:** ✅ **Primario designado + failover.**
- **B. Feed en vivo:** ✅ **WebSocket** (dep `shelf_web_socket` cuando toque F3c).
- **C. Arranque:** ✅ **F3a primero.**

> **Nota técnica descubierta al implementar F3a:** `multicast_dns` (el paquete actual) solo CONSULTA mDNS, no ANUNCIA servicios. El agente desktop (Node.js) sí se anuncia (bonjour-service). Para que una **tablet** sea un Hub descubrible se necesitaría una dep de registro (`nsd`/`bonsoir`) — decisión diferida. F3a evita esto: descubre el Hub vía el `AgentDiscovery` existente (encuentra el agente desktop) y/o una **dirección de Hub configurable**, sin dep nueva. El anuncio desde tablet se decide al hacer F3d/failover en tablets.

### F3a — alcance concreto (sin dependencias nuevas, detrás de flag apagado)
1. `HubMode` (cloud/hub/solo) + `HubModeController` que resuelve el modo desde conectividad + alcanzabilidad del Hub.
2. `HubClient`: prueba `GET /hub/health` contra la dirección configurada y/o descubierta.
3. `/hub/health` en el agente (`shelf`).
4. Flag `kHubEnabled=false` → no cambia nada en producción hasta cablear F3b+.

### Decisiones originales (para referencia)

**A. ¿Quién corre el Hub?**
- *Primario designado + failover* (recomendado): configurable, por defecto el equipo con agente desktop o una tablet elegida. Simple y predecible.
- *Elección de líder dinámica* entre tablets: cero config, pero más complejo (split-brain, fencing).
- *Mini-PC dedicado*: lo más robusto, requiere hardware del cliente.

**B. ¿Transporte del feed en vivo (KDS + multi-terminal)?**
- *WebSocket* (recomendado): añade dep `shelf_web_socket` (server); el cliente ya tiene `web_socket_channel`. Bidireccional, baja latencia.
- *SSE / long-poll sobre el `shelf` actual*: sin dep nueva, algo más de latencia/anchura.

**C. ¿Alcance del primer incremento de F3?** (es grande; conviene fasearlo)
- *F3a*: esqueleto del Hub (anuncio mDNS desde Dart + detección de modo + `GET /state` de solo-lectura para "abrir mesa ajena"). Entregable y de bajo riesgo.
- *F3b*: enrutar mutaciones al Hub (`POST /ops`) + op-log + uplink único a Supabase.
- *F3c*: KDS sobre el feed del Hub.
- *F3d*: failover/backup.

---

## 10. Riesgos

| Riesgo | Mitigación |
|---|---|
| Es un mini-backend en LAN: concurrencia, failover, split-brain | Hub = único serializador; primario designado + fencing por epoch; fasear (F3a→d) |
| Tocar el camino Cloud (online) probado | NO se toca: Hub solo entra sin internet |
| Seguridad LAN (hoy token hardcoded) | Token por negocio (de F0) reemplaza el hardcoded |
| Conectividad parcial (una tablet aislada) | Cae a Solo; se documenta como borde |
| Reloj entre dispositivos | El Hub estampa `received_at` y asigna `seq`; el orden lo da el Hub, no el reloj |

---

## 11. Qué se reutiliza vs. qué es nuevo

**Reutilizable (ya existe):** servidor `shelf` del agente, descubrimiento mDNS + filtro por business_id, tabla `device_agents`, drift/SQLite, el **modelo de acciones y el replay idempotente** (op_id/fingerprint/mappings), el detector de conectividad y los modos.

**Nuevo:** anuncio mDNS desde el agente Dart (TXT `role=hub`), servidor WebSocket/feed, op-log compartido + estado materializado en el Hub, enrutado de mutaciones al Hub, suscripción del KDS al Hub, lógica de primario/failover, uplink único Hub→Supabase.

---

## 12. Estado de implementación (al 2026-05-31)

Todo detrás de `kHubModeEnabled=false` → cero impacto en producción.

**Construido y testeado (lado Dart):**
- F3a: `HubMode`/`resolveHubMode`, `HubClient` (descubrir + /hub/health), `HubModeController`.
- F3b: `HubOpLog` (op-log seq+idempotente), endpoints `/hub/ops` y `/hub/state`, `HubClient.postOp/getStateSince`, enrutado de `enqueueAction` al Hub (seam `_hubUploader`), uplink único `syncHubOpLog`.
- F3c-1/2: servidor WS `/hub/events` + difusión, cliente `HubEventStream` (reconexión).
- F3c (proyección): `HubKitchenProjector` — reconstruye `KitchenOrder[]` desde el op-log (pura, 8 tests).

**Pendiente para ACTIVAR F3 (requiere validación en dispositivos reales):**
1. **Wiring del KDS:** que `kds_viewmodel`, en modo hub, cargue desde `HubEventStream` + `GET /hub/state` proyectado con `HubKitchenProjector` (en vez del Realtime de Supabase), y enrute los cambios de estado como ops.
2. **Op `kds_item_status`** + su replay en `_replayAction` (resolver item_id → remoto y llamar `kitchen_repo`), para que los cambios de estado del KDS sin red suban al reconectar.
3. **Baseline:** capturar snapshot de cocina activa al entrar a modo hub (para mostrar comandas previas a la caída, no solo las nuevas).
4. **Triggers (F3b-3c):** que el dispositivo Hub llame `syncHubOpLog` al reconectar; observar `hubModeProvider` en el bootstrap.
5. **Anuncio mDNS desde tablet** (`nsd`/`bonsoir`) si el Hub corre en tablet (el desktop ya se anuncia).
6. **Paridad Node.js:** op-log + endpoints + WS + uplink en `agent/` (JS) para el Hub desktop.
7. **Seguridad LAN:** reemplazar el token hardcoded por token por-negocio (de F0).
8. **Prueba multi-dispositivo** antes de encender el flag.

> Razón de parar el "build" aquí: del punto 1 en adelante todo necesita correr contra dispositivos reales en una LAN para ser confiable (es flujo de cocina, sensible). Construirlo a ciegas sería frágil. La lógica pura (proyector, op-log, resolución) ya está lista y testeada para ese momento.

---

*Diseño basado en el código real al 2026-05-31. Transporte F3 construido tras §9; activación pendiente per §12.*
