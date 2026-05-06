# PRD — Zonas y Mesas: Estado Actual y Visión Profesional

| Campo | Valor |
|---|---|
| Versión | 1.0 |
| Fecha | 2026-05-06 |
| Autor | Cristian / Innovech Software LLC |
| Estado | Draft — listo para revisión y priorización |
| Producto | MangoPOS (Flutter mobile + Windows desktop) |
| Alcance | Configuración (CRUD) y operación runtime de Zonas y Mesas |

---

## 1. Resumen ejecutivo

El módulo de Zonas y Mesas en MangoPOS hoy cubre el **80% del caso happy-path** (crear zona, crear mesa, abrir cuenta, cerrar cuenta) pero tiene **gaps operacionales críticos** y **deuda técnica acumulada** que limitan su uso profesional en restaurantes con flujo intenso.

Este PRD documenta:

- **Estado actual con evidencia** del repo (no especulación).
- **Pain points reales** detectados en el código.
- **Visión "profesional"** del módulo, alineada a estándares de POS comerciales (Toast, Square for Restaurants, Loyverse).
- **Plan de implementación incremental** que no requiere rewrite.

El esfuerzo total estimado es **5-7 semanas** divididas en 4 fases. La fase 1 (cierre de gaps críticos) entrega valor en 2 semanas.

## 2. Estado actual (hechos del repo)

### 2.1 Modelo de datos

| Tabla | Ubicación | Notas |
|---|---|---|
| `zones` | [schema.sql:2755](supabase/schema.sql#L2755) | `id`, `business_id`, `branch_id?`, `name`, `sort_index`, `is_active`. **Sin UNIQUE** en `(business_id, name)`. |
| `dining_tables` | [schema.sql:2449](supabase/schema.sql#L2449) | `id`, `zone_id`, `code`, `label?`, `shape` (square\|circle), `state` (available\|occupied\|reserved\|blocked), `capacity`, **`pos_x`, `pos_y`, `width`, `height`, `rotation`** (¡ya soporta layout visual!), `is_active`. UNIQUE `(zone_id, code)`. CASCADE on zone delete. |
| `table_sessions` | [schema.sql:2737](supabase/schema.sql#L2737) | `id`, `table_id`, `opened_by`, `opened_at`, `closed_at?`, `customer_name?`, `note?`, `origin`, `waiter_user_id?`, `people_count`, `business_id?`. CASCADE on table delete. |

**RLS habilitada** en las 3, usando `user_has_business_access`.

**Multi-business**: `zones.business_id` directo. `dining_tables` lo resuelve via JOIN a `zones`. `table_sessions.business_id` redundante (riesgo de drift).

### 2.2 UI existente

| Pantalla | Archivo | Rol |
|---|---|---|
| Configuración CRUD | [lib/presentation/settings/.../zones_tables/view/zones_tables_view.dart](lib/presentation/settings/more%20settings/system%20settings/zones_tables/view/zones_tables_view.dart) | Owner/admin crea/edita/borra zonas y mesas. |
| Vista runtime cajero | [lib/presentation/sales/view/sales_by_zone_view.dart](lib/presentation/sales/view/sales_by_zone_view.dart) | Grid de mesas por zona con estado visual. |
| Selector mesa | [lib/presentation/sales/view/table_selector_modal.dart](lib/presentation/sales/view/table_selector_modal.dart) | Modal para elegir mesa antes de abrir cuenta. |
| Pantalla de orden | [lib/presentation/sales/view/table_order_screen.dart](lib/presentation/sales/view/table_order_screen.dart) | **6666 líneas** — orden abierta, agregar items, cobrar, dividir cuenta. |

**No existe**: editor visual de plano (drag & drop), aunque el schema ya soporta `pos_x/y/width/height/rotation`.

### 2.3 Repository y ViewModels

| Pieza | Archivo | Notas |
|---|---|---|
| `ZonesRepository` | [lib/data/repositories/zones_repository.dart](lib/data/repositories/zones_repository.dart) | CRUD de zonas + estado runtime de mesas via vista `v_zone_table_status`. |
| `salesRepository.openTable()` | [lib/data/repositories/sales_repository.dart:243](lib/data/repositories/sales_repository.dart#L243) | RPC `fn_open_table` retorna session_id, table_id, order_id. |
| `byZoneVmProvider` | [lib/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart:17](lib/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart#L17) | Realtime sub a 5 tablas (table_sessions, orders, order_items, order_checks, payments). |
| `zonesTablesVmProvider` | [lib/presentation/settings/.../zones_tables/viewmodel/](lib/presentation/settings/more%20settings/system%20settings/zones_tables/viewmodel/) | Realtime sub a `zones` y `dining_tables`. |

**Patrón**: Riverpod NotifierProvider, debounce 220ms en realtime, business_id resuelto vía `BusinessResolver`.

### 2.4 Permisos definidos

[lib/core/security/access_control_catalog.dart](lib/core/security/access_control_catalog.dart):

- `ventas.mesas.acceso`, `ventas.mesas.ver_estado`, `ventas.mesas.abrir`, `ventas.mesas.liberar` ✓ implementados.
- `ventas.mesas.mover_unir` ❌ definido pero **no implementado** en cliente.
- `ventas.mesas.marcar_pagando` ❌ definido pero **no implementado**.
- `settings.zonas_mesas.gestionar` ✓ controla acceso al CRUD.

## 3. Pain points (con evidencia)

### 3.1 Críticos (afectan operación real)

**P1. `table_order_screen.dart` tiene 6666 líneas.** Megacomponente que mezcla orden, cobro, NCF, split bill, modificadores. Imposible de mantener, propenso a regresiones, lento de compilar.

**P2. Estado de mesa duplicado.** `dining_tables.state` (enum) + presencia de `table_sessions.closed_at IS NULL`. Pueden quedar inconsistentes (mesa con `state='occupied'` pero sesión cerrada, o viceversa). El [`releaseEmptyTableIfNeeded`](lib/data/repositories/sales_repository.dart#L339) intenta cubrir solo el caso happy. Riesgo: mesas "fantasma" ocupadas sin sesión.

**P3. Permisos `mover_unir` y `marcar_pagando` no implementados.** Definidos en el catálogo, pero ningún call site. Funcionalidades estándar en POS de restaurante:
- **Mover cuenta**: cliente cambia de mesa, queremos mover la sesión sin perder items.
- **Unir mesas**: 2 mesas físicas con 1 sola cuenta (ej. grupo grande).
- **Marcar pagando**: mesera marca mesa "en cobro" para que otro mesero no toque. Hoy mesas están solo `available`/`occupied`, sin estado intermedio.

**P4. Cierre de sesión de caja no libera mesas abiertas.** [`CashierRepository.closeSession()`](lib/data/repositories/cashier_repository.dart) no garantiza que las mesas asignadas a esa sesión queden liberadas. Mesa puede quedar `occupied` con sesión huérfana.

**P5. Virtual zones hardcoded** (sort_index 900 = "ventas manuales", 901 = "ventas rápidas"). [zones_repository.dart:18](lib/data/repositories/zones_repository.dart#L18) las filtra por nombre normalizado. Si alguien renombra la zona, lógica frágil rompe.

### 3.2 Importantes (UX y consistencia)

**P6. Sin UNIQUE en `(business_id, name)` de zones.** Permite 2 zonas "Terraza" en el mismo business. Confunde a meseros.

**P7. No hay editor visual de layout** aunque el schema ya tiene `pos_x/y/width/height/rotation/shape`. Hoy las mesas se ven como grid de tarjetas idénticas, no refleja la disposición física del local. Estándar industrial actual: drag & drop sobre canvas.

**P8. `table_sessions.business_id` es redundante** (ya derivable de `table_id → zone → business`). Riesgo de drift, posible fuente de queries con filtros equivocados.

**P9. ON DELETE CASCADE de zonas borra todas las mesas y sesiones físicamente.** No hay soft-delete real. Si owner borra una zona por error, pierde **todo el histórico** asociado a esas mesas. `is_active=false` existe en zones/tables pero el delete físico CASCADE no la respeta.

**P10. No hay capacidad vs people_count validation client-side.** Schema acepta abrir mesa de 4 plazas con 12 personas sin warning.

### 3.3 Menores

**P11. No hay drag-to-reorder de zonas** en la UI de configuración. Solo `sort_index` en DB pero la UI es lista plana sin ordenar.

**P12. No hay duplicación de zona** ("clonar zona" para crear similar rápidamente).

**P13. Códigos de mesa libres (text)**. Aceptan "T1", "Mesa 1", "M-01" sin convención. Algunos clientes usan numeración estricta, otros nombres temáticos.

## 4. Visión profesional (qué debería ser)

Inspirado en estándares de Toast, Square Restaurants, Loyverse, y restaurantes con multi-zona reales en RD.

### 4.1 Modelo conceptual

```
Business
  └─ Branch (físico, ej. "Bávaro" vs "Cap Cana")
        └─ Zone (área, ej. "Terraza", "Salón principal", "Barra")
              └─ Table (mesa con código único en zona)
                    └─ TableSession (apertura)
                          └─ Order
                                └─ OrderItems / OrderChecks
```

**Branch existe en el schema actual** (`zones.branch_id`) pero **no se está usando**. Ahí hay oportunidad para multi-sucursal real.

### 4.2 Capacidades funcionales que debe tener

| Capacidad | Estado actual | Visión |
|---|---|---|
| CRUD zonas | ✓ básico | + duplicar, drag-reorder, soft-delete, validar nombre único |
| CRUD mesas | ✓ básico | + bulk create ("crear T1-T20"), validar código único, capacidad por defecto configurable |
| Plano visual del local | ❌ | Editor drag & drop con shapes (cuadrado/circular), rotation, dimensiones. Reuso de columnas existentes. |
| Estados de mesa | available/occupied/reserved/blocked | + `paying` (en cobro), + `dirty` (sucia, esperando limpieza), + `unavailable` (mantenimiento). Transiciones validadas. |
| Mover cuenta | ❌ | UI: long-press mesa → "Mover a..." → selecciona mesa destino. RPC SQL atómico. |
| Unir mesas | ❌ | UI: seleccionar 2+ mesas → "Unir" → 1 sesión común. UNDO disponible. |
| Marcar pagando | ❌ | Botón en pantalla de cobro → state=paying → bloquea para otros meseros. |
| Asignación de mesero | parcial (`waiter_user_id`) | UI clara: ver mesero asignado, transferir mesa entre meseros. |
| Reservas | ❌ (state existe pero sin flujo) | Reservar mesa para fecha/hora, libera automáticamente si no llega. |
| Capacidad guardrail | ❌ | Warning si people_count > capacity, bloqueo si es muy grande. |
| Multi-sucursal | parcial (branch_id sin usar) | Activar branch como filtro principal en config y runtime. |
| Historial de uso | ❌ | "Esta mesa rotó X veces hoy", tiempo promedio de ocupación. Útil para optimizar layout. |
| Bulk actions | ❌ | Crear N mesas a la vez, mover/borrar varias en lote. |

### 4.3 UX

**Configuración** (settings):

- Vista lista por zona con drag-reorder.
- **Toggle entre vista lista y vista plano** — vista plano es el editor visual.
- Wizard "Crear N mesas" (selecciona zona, prefijo "T", desde-hasta).
- Estados visuales claros (zona inactiva en gris, mesas inactivas tachadas).

**Runtime** (cajero):

- Vista plano por zona si está configurado (con dispoisición física), fallback a grid si no.
- Color por estado: verde libre, amarillo ocupada, naranja en cobro, azul reservada, rojo bloqueada, gris sucia.
- Indicadores: número de comensales, tiempo desde apertura, mesero asignado, monto acumulado.
- Acciones rápidas con long-press: cobrar, mover, unir, transferir mesero, agregar nota.

## 5. Cambios de modelo de datos propuestos

Cambios **incrementales y additive**, no rewrite. Numeración de migrations sugerida:

### 5.1 `20260507_0001_zones_tables_hardening.sql`

```sql
-- 1. UNIQUE en zones para prevenir duplicados
alter table public.zones
  add constraint zones_business_id_name_active_key
  unique (business_id, name) where (is_active = true);

-- 2. Estados nuevos en dining_tables.state
alter type table_state add value if not exists 'paying';
alter type table_state add value if not exists 'dirty';
alter type table_state add value if not exists 'unavailable';

-- 3. Soft-delete real para zones (NO CASCADE)
alter table public.dining_tables
  drop constraint dining_tables_zone_id_fkey,
  add constraint dining_tables_zone_id_fkey
  foreign key (zone_id) references public.zones(id)
  on delete restrict;
-- (Borrar zona ahora exige primero soft-deletar sus mesas)

-- 4. Validacion capacidad
alter table public.dining_tables
  add constraint dining_tables_capacity_check
  check (capacity > 0 and capacity <= 50);

-- 5. Eliminar redundancia de business_id en table_sessions
-- (mantener columna por compat, pero deprecarla a nivel codigo)
comment on column public.table_sessions.business_id is
  'DEPRECATED: derivar via table_id->zone->business. Mantener por backward-compat.';
```

### 5.2 `20260507_0002_table_state_machine.sql`

Función SQL `fn_transition_table_state(_table_id, _new_state, _user_id, _reason)` que valida transiciones permitidas:

```
available → occupied (open table)
occupied → paying (start payment)
paying → occupied (cancel payment)
paying → available + dirty (close & flag)
dirty → available (mark clean)
available ↔ reserved (reserve / cancel)
* → blocked (admin only)
* → unavailable (maintenance)
```

Audit log: tabla `table_state_events` (table_id, prev_state, new_state, user_id, reason, created_at).

### 5.3 `20260507_0003_move_merge_tables.sql`

RPCs SQL atómicas:

- `fn_move_table_session(_session_id, _to_table_id)`: mueve sesión a otra mesa libre, libera la origen, valida que destino esté `available`.
- `fn_merge_tables(_session_ids[], _primary_table_id)`: une N sesiones en una. Order y items consolidados bajo el primary. Otras quedan referenciadas como "merged_into" en audit.

### 5.4 `20260507_0004_branches_activation.sql`

Si decidimos activar branches:

- Backfill `zones.branch_id` con un branch default por business.
- Hacer NOT NULL.
- UI: filtro por branch en config y runtime.

(Esto es opcional, decisión bloqueante: ¿el negocio piloto necesita multi-sucursal hoy? Si no, postponer.)

## 6. Plan de implementación

### Fase 0 — Decisiones bloqueantes (1 día)

| Decisión | Opciones | Recomendación |
|---|---|---|
| **D1**. ¿Refactor de `table_order_screen.dart` 6666 líneas viene en este PRD o aparte? | Incluir / aparte | **Aparte**. Refactor no debe mezclarse con features nuevas. Tracking en otro PRD. |
| **D2**. ¿Activar branches o postponer? | Activar / postponer | **Postponer** salvo que clientes piloto lo pidan. Schema lo soporta cuando sea necesario. |
| **D3**. ¿Editor visual de plano en MVP o fase 2? | MVP / fase 2 | **Fase 2**. MVP cierra gaps funcionales primero. |
| **D4**. ¿Migrar `dining_tables.state` a state machine completa o mantener enum simple? | Completa / simple | **Completa con audit**. La trazabilidad la pide cualquier auditoría operacional. |

### Fase 1 — Cierre de gaps críticos (2 semanas)

**Entregables**:

1. Migration `20260507_0001` (UNIQUE, nuevos estados, validación capacidad, soft-delete real).
2. Migration `20260507_0002` (state machine + audit log).
3. RPC `fn_release_orphan_table_sessions(_business_id)` para limpieza de sesiones huérfanas (ejecutable manualmente o vía cron).
4. UI: estados nuevos visibles en `sales_by_zone_view` (paying naranja, dirty gris).
5. UI: warning de capacidad al abrir mesa con `people_count > capacity`.
6. Botón "Marcar en cobro" en pantalla de cobro → transición a `paying`.
7. Botón "Marcar limpia" en mesa con `state='dirty'`.

**Definition of Done**:
- 0 mesas con state inconsistente vs sesión en query de validación.
- Permisos `marcar_pagando` y `liberar` funcionando.
- `flutter analyze` limpio.

### Fase 2 — Mover y unir mesas (1.5 semanas)

**Entregables**:

1. Migration `20260507_0003` (RPCs `fn_move_table_session`, `fn_merge_tables`).
2. UI: long-press en mesa ocupada → menú con "Mover", "Unir", "Transferir mesero".
3. UI: modal selector de mesa destino para mover.
4. UI: selección múltiple de mesas para unir.
5. Audit log accesible desde admin (quién movió qué a qué hora).

**Definition of Done**:
- Permiso `mover_unir` funcional.
- Test E2E: abrir mesa A, mover a B, cobrar B → orden e items correctos en B, A vacía.
- Test E2E: unir A+B+C → cobrar consolidado, los 3 tickets van a la misma sesión.

### Fase 3 — Editor visual de plano (2 semanas, opcional)

**Entregables**:

1. Pantalla nueva en config: tab "Plano" en `zones_tables_view`.
2. Canvas con drag & drop, snap a grid, rotation, resize.
3. Persistir cambios en `dining_tables.pos_x/y/width/height/rotation/shape`.
4. Vista runtime: toggle "Lista" / "Plano".
5. Plano renderizado en runtime con estado por color y badge de mesero.

**Definition of Done**:
- Layout sobrevive a refresh, cambios de zona, multi-device.
- Performance: 100 mesas en plano sin lag perceptible.

### Fase 4 — Polish y bulk actions (1 semana)

- Wizard "Crear N mesas" en config.
- Drag-reorder de zonas.
- Duplicar zona.
- Reportes: rotación de mesa por hora/día.

## 7. Riesgos y mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| Migration de state machine rompe flujo de cobro | Baja | Alto | Fase 1 incluye tests E2E. Rollback documentado. |
| Drag & drop performance en 100+ mesas | Media | Medio | Virtualizar canvas. Probar en device más débil del cliente. |
| Realtime drift después de refactor | Media | Medio | Test scenarios: 2 devices abren la misma mesa al mismo tiempo. |
| Histórico se pierde al cambiar CASCADE→RESTRICT | Baja | Alto | Migration valida que no hay zonas borradas físicamente que tengan sesiones referenciadas. |
| Branch activation rompe queries existentes | Media | Alto | **Postponer hasta confirmación de piloto multi-sucursal**. |

## 8. Decisiones pendientes

- [ ] D1-D4 de Fase 0.
- [ ] ¿Quién es el primer cliente piloto que se beneficia de Fase 1? (necesario para priorizar).
- [ ] ¿La Fase 3 (editor visual) entra al roadmap de Q3 2026 o más adelante?
- [ ] ¿Reportes de rotación de mesa van en este PRD o en uno de "Reportes operacionales"?

## 9. Lo que NO está en este PRD (explícito)

- **Refactor de `table_order_screen.dart` 6666 líneas**. Tracking aparte.
- **Reservas online (clientes desde web)**. Eso es un módulo nuevo, no parte de Zonas y Mesas.
- **Integración con sistemas de espera/waitlist**. Idem, módulo aparte.
- **Multi-idioma de nombres de zona**. Hoy nombre es texto libre, suficiente.
- **Permisos granulares por mesa** (ej. mesero X solo ve mesas de su sección). Si llega como requerimiento, se evalúa después.

---

**Próximos pasos sugeridos**:

1. Revisar este PRD y cerrar D1-D4.
2. Confirmar prioridad de Fase 1 vs otros pendientes (e-CF cron, refactor table_order_screen).
3. Si Fase 1 va, crear branch `feature/zones-tables-hardening` y arrancar por la migration 0001.
