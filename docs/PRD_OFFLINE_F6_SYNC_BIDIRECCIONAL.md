# Diseño — F6: Sync bidireccional (foco: la "bajada" proactiva)

> Diseño para aprobación. Roadmap offline, fase F6. Fecha: 2026-06-01.

---

## 1. El insight: NO hay conflicto de merge

"Bidireccional" suena complejo, pero en MangoPOS las dos direcciones **poseen
datos disjuntos**, así que **no hay conflictos reales que resolver**:

- **Subida (device → server):** TRANSACCIONES (órdenes, items, pagos, caja,
  inventario). **Ya implementada** — cola offline + uplink en reconexión
  (F1/F2) y, en LAN, el Hub (F3). El device es dueño; el server las acepta.
- **Bajada (server → device):** DATOS DE CONFIGURACIÓN/CATÁLOGO (productos,
  precios, modificadores, categorías, roster, config fiscal, secuencias NCF).
  El server es dueño; el device solo los **lee/cachea**.

Como cada lado posee lo suyo, la "resolución de conflictos" es trivial:
**subida = la cola (hecho); bajada = sobrescribir el cache local.** No se
pisan.

## 2. Qué ya baja hoy (y qué falta)

| Dato | Bajada hoy | Gap |
|---|---|---|
| **Roster (usuarios/PIN)** | ✅ background sync (periódico 1h + en reconexión) | — |
| **Catálogo (productos/menú)** | ⚠️ solo al abrir la pantalla de venta online | no se refresca proactivamente |
| **Zonas/mesas** | ⚠️ solo al abrir el salón online | idem |
| **Inventario** | ⚠️ solo al abrir inventario online | idem |
| **Config / fiscal / secuencias NCF** | ⚠️ al usarlas | idem |

**El gap:** si el cajero NO abre esas pantallas mientras hay internet, el cache
queda viejo y al caer la red opera con datos desactualizados (precios viejos,
producto nuevo ausente, etc.).

## 3. Propuesta F6: refresco proactivo en reconexión

Un **`OfflineSyncCoordinator`** que, al **reconectar** (y periódicamente),
refresca los caches de lectura clave **sin depender de qué pantallas se
abrieron** — igual que ya hace el roster. Así el device siempre está "listo
para el próximo corte".

```
Reconexión (connectionStream false→true)  o  timer periódico
   │
   ├─ subir cola pendiente (YA existe)
   └─ bajar/refrescar caches (F6):
        ├─ roster            (ya: OfflineAuthService.startBackgroundSync)
        ├─ catálogo          (fetch menú + OfflineCatalogService.saveSnapshot)
        ├─ zonas/mesas       (fetch + ZonesOfflineCache)
        ├─ inventario        (fetch + InventoryOfflineCache)
        └─ config/fiscal/NCF (settings + ncf_sequences seed para F4)
```

**Incremental donde aplique:** el snapshot del catálogo ya guarda
`last_product_updated_at` → se puede pedir solo el delta (productos con
`updated_at` mayor) en vez de todo. Para datos chicos (config, zonas) un
refresh completo es aceptable.

## 4. Resolución (trivial, por diseño)

- Bajada **sobrescribe** el cache local (el server es la verdad para catálogo/
  config). No hay edición local de catálogo que se pueda perder.
- Las transacciones del device **nunca** se tocan en la bajada (viven en la
  cola/snapshots, suben por su cuenta).
- **Excepción a vigilar:** si en el futuro hubiera datos editables localmente
  Y en server (no es el caso hoy), ahí sí habría que decidir LWW. Hoy no aplica.

## 5. Plan de build (incremental)

- **F6-1:** `OfflineSyncCoordinator` con el trigger de reconexión + periódico,
  orquestando refrescos inyectados (testeable). Cablea primero los que ya
  tienen "fetch+cache" listo (roster) y el **catálogo** (el de mayor valor:
  asegura vender con precios/productos al día offline).
- **F6-2:** sumar zonas, inventario, config/fiscal/secuencias NCF.
- **F6-3:** refresco incremental del catálogo por `updated_at` (eficiencia).

## 6. Riesgos / notas

| Tema | Nota |
|---|---|
| Doble disparo (reconexión + timer) | Guard de "refresh en vuelo" para no solapar |
| Ancho de banda al reconectar | Incremental (catálogo por delta); escalonar refrescos |
| Multi-negocio | Refrescar solo el negocio activo |
| No romper el arranque | Refresco en background, best-effort, nunca bloquea la UI |

---

*Diseño basado en el código real al 2026-06-01. La subida ya existe (F1/F2/F3);
F6 cierra la bajada proactiva. Sin cambios de base de datos.*
