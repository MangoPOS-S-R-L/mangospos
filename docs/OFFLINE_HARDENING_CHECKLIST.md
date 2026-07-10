# Checklist — MangoPOS Offline a prueba de caídas

> **Origen:** 2026-07-10 se cayó el VPS de Hostinger por **mantenimiento del host** (fuera de nuestro control) y se cayó *toda* la plataforma a la vez: nadie podía entrar ni trabajar. Un solo VPS = punto único de falla para todos los negocios.
>
> **Meta:** que "no hay internet / server caído" sea **invisible** para el negocio. Todo debe seguir funcionando igual.

---

## 🎯 Norte / criterio de aceptación

**El botón "Modo Offline".** Cuando exista un botón que el usuario pueda presionar y el sistema quede 100% funcional sin tocar la nube, ganamos. Ese botón es la **prueba de aceptación** de toda esta iniciativa: obliga a cerrar *todos* los huecos, porque no se puede soportar a medias.

**Insight arquitectónico:** hoy el modo offline es **reactivo** — se activa por `try/catch` cuando una consulta falla, o cuando el probe detecta el server caído (~30s de retraso). Un botón manual exige volverlo **proactivo y forzable**: un único interruptor global que *toda* lectura y *toda* escritura consulten, para saltar directo a caché/cola **sin intentar la red ni esperar timeouts**. Esa pieza unificadora es la Fase 0.

---

## 🩺 Diagnóstico — por qué se cayó todo (4 sondas de auditoría, 2026-07-10)

La maquinaria offline ya existe y es buena (cola de escritura para todo el ciclo de caja, caché de lectura de mesas/productos/impuestos/config, roster con PIN+permisos TTL 24h). **El problema es el arranque en frío:** el candado está *justo detrás* del login.

1. El splash **no** se cuelga (`Supabase.initialize` no bloquea en red) y el portón de auth es **local** (la sesión persistida se reconoce sin GoTrue). ✅
2. Pero `SessionController.restoreFromSupabaseSession` consulta `profiles`/`user_businesses`/`businesses` → falla → se queda **atascado en `AuthStatus.loading` para siempre** (sin caché, sin reintento). ❌
3. Y el router manda a **`/select-business`**, que consulta `user_businesses` con timeout 10s → tarjeta de error **"No pudimos cargar tus accesos"**; "Reintentar" repite la misma consulta. **Callejón sin salida.** ❌

→ Toda la maquinaria offline (mesas, productos, cobro, PIN) estaba **detrás de esa pared**. Nunca se llegaba a usar.

---

## 🔴 FASE 0 — El interruptor global (habilita el botón Modo Offline)

Sin esto, el botón no puede existir. Es la pieza que unifica todo.

- [ ] **0.1** Interruptor global forzable — un override (p. ej. `forceOfflineProvider` / `ConnectivityService.setManualOffline(bool)`) que haga que `isConnected` devuelva `false` sin importar la red real. Master switch. [connectivity_service.dart](lib/core/network/connectivity_service.dart)
- [ ] **0.2** **Lecturas** consultan el override *antes* de la red — hoy varias rutas intentan la red y solo caen a caché por error (esperando timeouts de 8s). Con el override activo deben ir directo a caché: instantáneo, determinista. (Catálogo ya lo hace; zonas/config van por try/catch → ajustar.)
- [ ] **0.3** **Escrituras** encolan cuando el override está activo — verificar que *toda* mutación (abrir mesa, agregar ítem, cobrar, cerrar) tenga la rama proactiva `!isConnected → enqueue`, no solo la reactiva por error.
- [ ] **0.4** Persistir el toggle entre reinicios — si el equipo arranca en frío con Modo Offline activo, las lecturas van directo a caché (no intentan red).
- [ ] **0.5** UI: botón + banner persistente "Modo Offline (manual)" para que el personal sepa el estado.
- [ ] **0.6** Salir de Modo Offline → drenar la cola (`syncPendingOfflineActions`) y rehidratar caché (`OfflineSyncCoordinator.refreshAll`).
- [ ] **0.7** Guardia de caché fría — al activar el botón, si la caché está vacía, advertir/sembrar primero (enlaza con Fase 2).

---

## 🔴 FASE 1 (P0) — El candado exacto de arranque en frío

Estos dos arreglos **previenen literalmente el incidente**. Con cualquiera de los dos, un equipo previamente logueado arranca al POS con el server caído; los dos juntos lo blindan.

- [ ] **1.1** Cachear la lista de negocios del usuario en `SelectBusinessView`. Ya persiste `activeBusinessId` pero nunca los negocios → persistir las filas de `user_businesses`; cuando la consulta falle offline, caer a la caché y **auto-seleccionar** el negocio activo guardado. [select_business_view.dart](lib/presentation/auth/login/select_business_view.dart)
- [ ] **1.2** Hidratar rol+permisos+nombre de negocio desde el **roster offline** en `restoreFromSupabaseSession` → llegar a `AuthStatus.authenticated` offline en vez de quedar en `loading`; reintentar al reconectar (`ConnectivityService`). El roster (TTL 24h) ya tiene rol+permisos. [session_controller.dart](lib/services/session/session_controller.dart) · [offline_auth_service.dart](lib/core/auth/offline_auth_service.dart)

---

## 🟠 FASE 2 (P1) — Garantizar caché tibia (para que P0/Fase 0 tengan de dónde leer)

- [ ] **2.1** Sembrar la caché **eager apenas hace login**, sin esperar la transición online→offline. Correr `buildOfflineRefreshers`/`refreshAll()`. [offline_sync_coordinator.dart](lib/core/offline/offline_sync_coordinator.dart) · [offline_refreshers.dart](lib/core/offline/offline_refreshers.dart)
- [ ] **2.2** Arreglar el disparo del `OfflineSyncCoordinator` — en arranque limpio online el init de conectividad usa `emit:false`, así que `_connected` nunca se setea y el timer de 15 min no hidrata. Garantizar que corra al menos una vez tras el arranque online.

---

## 🟡 FASE 3 (P2) — Dependencias de red sueltas

- [ ] **3.1** `table_selector_modal` usa `fetchZones`/`fetchTablesByZone` **sin caché** → cambiar a las variantes `*WithCache`. [table_selector_modal.dart](lib/presentation/sales/table_selector_modal.dart)
- [ ] **3.2** Cash-gate al abrir mesa: permitir el draft offline aunque no haya sesión de caja cacheada; diferir el chequeo de caja al momento del pago. [sales_viewmodel.dart](lib/presentation/sales/viewmodel/sales_viewmodel.dart) · [cashier_viewmodel.dart](lib/presentation/cashier/viewmodel/cashier_viewmodel.dart)
- [ ] **3.3** Floor-map (plano del salón) sin caché → agregar snapshot de `dining_tables` si el plano debe verse offline (la lista/cuadrícula ya funciona).

---

## 🟢 FASE 4 (P3) — Robustez del modo offline

- [ ] **4.1** `isConnected` tarda ~30s en admitir que el server murió (umbral de 2 fallos) → probe inicial más agresivo en arranque para entrar a modo offline rápido. (El botón manual de Fase 0 lo hace instantáneo; esto mejora el modo automático.)
- [ ] **4.2** Documentar el límite esperado: **login por primera vez sin server no es posible** (no se puede autenticar sin GoTrue). El PIN offline solo aplica tras un login online previo en el equipo.

---

## 🔵 FASE 5 (P4) — Fiscal (NCF) y multi-terminal — coronado por el auto-switch a Hub

> **DECISIÓN de diseño (2026-07-10):** al entrar en modo offline (botón o detección), el sistema **auto-activa Hub mode**: la caja principal designada actúa como **asignador ÚNICO de NCF** en la LAN → numeración **secuencial sin huecos** aunque facturen varias cajas. Es el modelo fiscalmente correcto (evita el riesgo de huecos de los sub-rangos por dispositivo). Gran parte de la maquinaria ya existe gateada (allocator concurrencia-safe, `POST /hub/ncf/next`, `HubClient.allocateNcf`, `NcfRangeService`, `OfflineNcfService`).

- [ ] **5.1** Cablear el **auto-switch**: al activar offline, enrutar la asignación de NCF (y el op-log de órdenes) por el **Hub host de la LAN** en vez de Supabase.
- [ ] **5.2** **Emisión real** offline en el flujo de pago: al cobrar offline, `OfflineNcfService.allocate` (vía Hub) → crear `fiscal_document` local con el NCF + imprimir **factura** (no precuenta) + encolar.
- [ ] **5.3** **Reconciliación al reconectar**: subir los `fiscal_document` con su NCF **sin regenerar** + reconciliar `ncf_sequences.current_number`; red de seguridad UNIQUE (business+ncf_number).
- [ ] **5.4** **Hub host + failover** — *DECIDIDO (2026-07-10):* la **caja principal designada** sirve la LAN y asigna NCF; un respaldo designado toma el relevo si el primario cae. Negocio de **1 solo equipo** = él mismo es su Hub.
- [ ] **5.5** **Continuidad de la secuencia offline** — *DECIDIDO:* las cajas interconectadas **persisten localmente y replican el último comprobante emitido** (cursor de la secuencia), para que offline pueda salir el siguiente sin el server. ⚠️ **RIESGO CRÍTICO a blindar:** debe haber **un solo emisor activo a la vez**. Si dos cajas particionadas emiten "el siguiente" desde su copia local → **NCF DUPLICADO** (peor que un hueco ante la DGII). Regla: solo el Hub host emite; el failover promueve **únicamente** con el primario confirmado caído (lease/token que impide dos emisores). La copia local del cursor alimenta al failover, **no** licencia a cada caja a emitir por su cuenta.
- [ ] **5.5b** Mecanismo de promoción del failover (lease/token vs promoción manual) — *sub-decisión abierta*, cerrar con prueba multi-dispositivo + contador.
- [ ] **5.6** Alerta de **agotamiento de rango al 80%** + política de rango agotado.
- [ ] **5.7** **Papel B0x vs e-CF**: offline emite NCF de papel; e-CF se difiere al sync (contingencia Alanube server-side). Confirmar alcance por negocio.
- [ ] **5.8** **GATE:** `kOfflineNcfEnabled=true` SOLO tras **firma del contador** (one-pager [docs/F4_NCF_OFFLINE_CONSULTA_CONTADOR.md](docs/F4_NCF_OFFLINE_CONSULTA_CONTADOR.md)) + prueba multi-dispositivo en LAN real.
- [ ] **5.9** Visibilidad cross-terminal offline (mesa abierta en otra caja) — la habilita el mismo Hub mode.
- [ ] **5.10** Caché de impuestos independiente (hoy solo atados al catálogo).

---

## ⚪ FASE 6 (P5) — Verificación y operación

- [ ] **6.1** Prueba de fuego por plataforma: bloquear el host en firewall y correr el ciclo completo **en frío** (arrancar app → PIN → ver mesas → abrir mesa → agregar → cobrar → imprimir) en **móvil, Windows y macOS**.
- [ ] **6.2** Prueba del botón: activar Modo Offline manual con internet presente y verificar que *nada* toca la nube y todo funciona.
- [ ] **6.3** Monitoreo/alertas de caída del server a tu teléfono (para reaccionar aunque los locales sigan trabajando offline).

---

## ✅ Criterio de "terminado"

El botón **Modo Offline** se activa (o el server se cae) y un cajero puede: **arrancar la app en frío → entrar por PIN → ver mesas y productos con precios/impuestos correctos → abrir mesa → tomar orden → cobrar → imprimir recibo** — sin un solo error de red, en las tres plataformas. Al reconectar, todo sube solo, sin duplicados.

---

## Orden de ataque recomendado

**Fase 1 (P0) primero** (2 arreglos acotados que previenen el incidente) → **Fase 2 (P1)** que los respalda → **Fase 0** (el interruptor manual, que corona la meta del botón) → Fases 3–4 (pulido) → Fase 6 (verificación). Fase 5 son decisiones de negocio: no se tocan sin OK del dueño.
