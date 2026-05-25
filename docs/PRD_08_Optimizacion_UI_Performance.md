# PRD 8 — Optimización UI / Performance

**Velocidad percibida en MangoPOS**

| | |
|---|---|
| **Producto** | MangoPOS |
| **DRI** | Cristian |
| **Duración estimada** | 2-3 semanas (diagnóstico + ejecución) |
| **Fecha** | Mayo 2026 |
| **Estado** | Draft |
| **Predecesor** | PRD 7 (Evaluación de datos) |

---

## 1. Propósito y alcance

Hoy MangoPOS funciona, pero hay zonas de la UI donde el cajero **siente** que la app va lenta: cold start largo, transiciones con flicker, grids de productos que jankean al scrollear, acciones de pago/cocina que tardan en responder.

Este PRD ataca las 4 dimensiones de velocidad percibida en paralelo, con una **meta cuantitativa**: scrolling consistente a 60 FPS en todas las pantallas críticas (caja, menú, mesas, KDS, dashboard) en Windows y Android.

Es trabajo de optimización, no de features. Si una optimización agrega complejidad pero no mueve la métrica, no entra.

### 1.1 Ejes de dolor a cubrir

1. **Cold start** — abrir la app hasta tener pantalla operable.
2. **Navegación** — cambiar de pantalla / tab sin flicker ni spinner.
3. **Listas/grids** — scrolling de productos, menú, mesas, KDS a 60 FPS.
4. **Acciones de cajero** — agregar item, enviar a cocina, cobrar con respuesta visual inmediata.

### 1.2 Out of scope (explícito)

- Rediseño visual (no es UX, es performance — la UI se queda como está).
- Reescritura de módulos enteros. Solo refactor quirúrgico justificado por profiling.
- Cambios de arquitectura (Riverpod sigue siendo Riverpod, GoRouter sigue siendo GoRouter).
- Server-side performance (Postgres tuning, índices) — eso es PRD 7 Fase 3.
- Reducción de tamaño de APK/MSIX — distinto problema, distinto PRD.

### 1.3 Entregables esperados

- **Reporte baseline:** métricas de hoy (FPS, frame time, build count, memory, startup time) en Windows y Android.
- **Reporte de hallazgos:** top 10 problemas con evidencia (timeline DevTools, frame graph, build counters).
- **Implementación de fixes:** ordenados por ROI, cada uno con before/after de la métrica.
- **Heurísticas documentadas en `CLAUDE.md`** para que código futuro no regrese a los mismos antipatrones.
- **Suite de smoke perf tests** (manual, paso a paso) que cualquier dev pueda correr antes de un release.

### 1.4 Convención de estados

| Estado | Significado |
|---|---|
| 🟢 OK | Pantalla a 60 FPS sin jank visible. Cold start < 5s. Acción < 100 ms. |
| 🟡 OBS | Funciona pero con jank ocasional o frame time > 16 ms. Mejorable, no bloqueante. |
| 🔴 FAIL | Jank obvio (<30 FPS), frames droppeados, freeze visible. Acción correctiva obligatoria. |

---

## 2. Fase 1 — Baseline y profiling

**Duración estimada:** 2 días. **Sin tomar medidas no se puede optimizar.** Esta fase es OBLIGATORIA antes de tocar código.

### 2.1 Sub-fase 1A — Setup de herramientas

#### Checklist

- [ ] Verificar que el proyecto se puede correr en `--profile` mode (Flutter profile mode es lo más cercano a release con DevTools habilitado).
- [ ] Conectar Flutter DevTools al device de Windows y Android.
- [ ] Activar Performance Overlay (`P` en debug menu) para ver FPS en pantalla.
- [ ] Activar Repaint Rainbow para detectar repaints excesivos.
- [ ] Habilitar `debugProfileBuildsEnabled = true` temporalmente para ver builds en el timeline.

#### Comandos

```bash
# Windows
flutter run -d windows --profile

# Android (con device conectado)
flutter run -d <DEVICE_ID> --profile

# DevTools
flutter pub global activate devtools
flutter pub global run devtools
```

#### Definition of Done — 1A

- [ ] DevTools conectado a Windows y Android.
- [ ] Performance Overlay funcionando.
- [ ] Screenshot del overlay en pantalla de mesas como evidencia.

### 2.2 Sub-fase 1B — Captura de baseline

#### Checklist por pantalla

Para cada pantalla crítica, capturar:

- [ ] **FPS promedio** en idle (sin scroll, sin acción).
- [ ] **FPS promedio** en scroll continuo (deslizar 3 segundos sin parar).
- [ ] **Frame time worst case** (peor frame en la timeline).
- [ ] **Number of jank frames** (>16ms) en una sesión de 30s.
- [ ] **Memory usage** (DevTools → Memory).

Pantallas a medir:

| # | Pantalla | Cómo llegar |
|---|---|---|
| 1 | Login | Cold start |
| 2 | Mesas (sales by zone) | Login → Ventas → Por zona |
| 3 | Caja (cashier dashboard) | Caja |
| 4 | Menú/Productos en venta | Mesa abierta → grid de productos |
| 5 | Cobro (payment modal) | Mesa con items → Pagar |
| 6 | KDS | Cocina |
| 7 | Inventario | Productos → Inventario |
| 8 | Dashboard | Dashboard |

#### Definition of Done — 1B

- [ ] Tabla con FPS/frame time/memory por pantalla, en Windows y Android.
- [ ] Pantallas clasificadas 🟢/🟡/🔴 según los thresholds del §1.4.
- [ ] Screenshots de timeline DevTools cuando hay jank visible.

### 2.3 Sub-fase 1C — Cold start measurement

#### Checklist

- [ ] Cerrar app completamente. Esperar 30s para asegurar cold start.
- [ ] Cronometrar desde tap del icono hasta "primer frame interactivo" (login utilizable).
- [ ] Cronometrar desde login hasta "pantalla de mesas usable".
- [ ] Repetir 5 veces, registrar mediana.
- [ ] Buscar en el timeline qué consume los primeros 5s (Supabase init, MediaKit, font loading, etc.).

#### Definition of Done — 1C

- [ ] Tabla: cold start time, login → mesas time, por plataforma (Windows + Android).
- [ ] Top 3 operaciones más costosas del bootstrap identificadas en el timeline.

---

## 3. Fase 2 — Hallazgos sospechosos (revisión código + perfilado dirigido)

**Duración estimada:** 1-2 días. Mapear sospechosos basado en el código actual antes de empezar a tirar fixes a ciegas.

### 3.1 Antipatrones comunes en MangoPOS — checklist de búsqueda

Para cada uno, grep + análisis estático en `lib/`:

- [ ] **`StatefulWidget` sin `const` constructor**: cualquier `Widget` que recibe data inmutable y no es `const` causa rebuilds innecesarios.
- [ ] **`Consumer` / `ref.watch` demasiado amplios**: si un widget grande hace `ref.watch(orderProvider)` pero solo usa `order.total`, todo el subtree rebuilds en cualquier cambio del order. Usar `ref.watch(orderProvider.select((o) => o.total))`.
- [ ] **`ListView` sin `itemExtent` ni `prototypeItem`**: el motor de scroll tiene que medir cada item al pasar. En grids de productos puede costar.
- [ ] **`ListView` no virtualizado** (`ListView(children: [...])` vs `ListView.builder`): si la lista es larga, el primer caso construye TODO al inicio.
- [ ] **Imágenes sin `cacheWidth`/`cacheHeight`**: descargar una imagen 4K para mostrarla en un thumbnail de 80×80 consume RAM brutalmente.
- [ ] **`SetState` en padres grandes**: si una pantalla tiene un `setState` en el root y modifica algo profundo, todo el árbol rebuilds.
- [ ] **`MediaQuery.of(context)` en build-paths**: cada llamada subscribe al widget a MediaQuery, causando rebuild ante cambios de tamaño/orientación.
- [ ] **`AnimatedBuilder` sin `child:` parameter**: cuando el child no anima, debería pasar como `child` para evitar reconstruirlo en cada tick.
- [ ] **`Future` sin caching en `build`**: `FutureBuilder(future: api.fetchX(), ...)` se relanza en cada build. Cachear el future fuera del build.
- [ ] **`provider.refresh` o invalidate masivo**: si invalidas un provider grande, su entire downstream rebuilds.

### 3.2 Sospechosos específicos de MangoPOS (basado en lectura previa)

- [ ] Grid de productos en `menu_browser_view`: ¿usa `GridView.builder`? ¿imágenes con `cacheWidth`?
- [ ] Lista de mesas en `sales_by_zone_view`: ¿rebuild completo cuando una mesa cambia de estado?
- [ ] `MainShell` (topbar): el badge offline (Fase 6) polea cada 5s. Si causa rebuild del topbar entero → flicker.
- [ ] `payment_modal`: tiene `state.copyWith` con muchos campos. ¿Sub-widgets observan campos específicos o el state entero?
- [ ] `current_order_view` (carrito de orden activa): cada cambio de item rebuild el header + footer + lista. Hay oportunidad de granularidad.
- [ ] **Realtime callbacks**: el `_queueRealtimeRefresh` que armamos en sales_by_zone es bueno (debounce + zone-targeted), pero hay otros (KDS, menu_browser) que pueden estar recargando demás.
- [ ] Splash screen: `lib/main.dart` tiene bootstrap pesado (Supabase, MediaKit, agent process, fullscreen, orientation lock). ¿Algunos son secuenciales cuando podrían ser paralelos?

### 3.3 Definition of Done — Fase 2

- [ ] Lista de antipatrones encontrados con `archivo:línea` y severidad estimada.
- [ ] Match con la baseline de Fase 1 (¿qué antipatrón está conectado a qué pantalla 🔴?).
- [ ] Top 10 oportunidades de fix ordenadas por ROI (impacto × facilidad).

---

## 4. Fase 3 — Cold start

**Duración estimada:** 2-3 días. Objetivo: < 5s desde tap hasta pantalla operable, en Windows y Android.

### 4.1 Sub-fase 3A — Trim del bootstrap

#### Checklist

- [ ] Identificar cuáles inits del `main.dart` son **bloqueantes** vs cuáles pueden ser **fire-and-forget**.
- [ ] **Bloqueantes obligatorios**: Supabase auth (sin esto no se sabe a qué pantalla ir), routes init.
- [ ] **Fire-and-forget**: agent process startup, fullscreen mode, orientation lock, MediaKit init, printer scan.
- [ ] Mover cualquier fire-and-forget que esté siendo `await`-ado a `unawaited(...)`.
- [ ] Si hay providers eager que cargan data al boot (catálogo entero, business profile, etc.), volverlos lazy.

#### Hallazgos esperados

- `_lockOrientationByDevice`: viable como fire-and-forget si la app arranca en landscape por defecto.
- `MediaKit.ensureInitialized()`: si solo se usa para video del onboarding, retrasarlo hasta que el usuario abra esa pantalla.
- `printer_heartbeat_scheduler`: puede arrancar después del primer frame.
- Pre-warm de impresoras (Fase Toast offline): ya está como `unawaited`. ✓

#### Definition of Done — 3A

- [ ] Lista de inits clasificados (bloqueante vs fire-and-forget).
- [ ] Refactor de `main.dart` con los `unawaited(...)` apropiados.
- [ ] Re-medir cold start después del cambio. Diferencia documentada.

### 4.2 Sub-fase 3B — Splash con contenido inmediato

#### Checklist

- [ ] El splash actual ¿es nativo (Android: launch screen) o Flutter widget?
- [ ] Si es Flutter widget: el motor tiene que cargar el engine entero antes de mostrarlo. Considerar splash nativo + transición.
- [ ] Verificar que la primera pantalla útil (login o mesas) renderiza con datos cacheados (no espera red).
- [ ] Si requiere red al arrancar (ej. revalidar sesión Supabase), hacerlo en background mientras se muestra UI con cache.

#### Definition of Done — 3B

- [ ] Splash mostrado en <500 ms desde tap.
- [ ] Primer frame interactivo en <3 s.

---

## 5. Fase 4 — Navegación entre pantallas

**Duración estimada:** 2 días. Objetivo: cambio entre pantallas <200 ms, sin flicker.

### 5.1 Sub-fase 4A — Auditoría de rutas

#### Checklist

- [ ] Revisar `app_router.dart`. ¿Hay `redirect` síncrono pesado en cada navegación?
- [ ] ¿Los `pageBuilder` son `const` cuando posible?
- [ ] ¿Hay loaders síncronos antes del build (auth check, business resolve)? Si sí, ¿se ejecutan en cada navegación o solo una vez?
- [ ] ¿La pantalla destino tiene su propia query inicial (`initState → ref.read`)? Si sí, ¿hay loading state inmediato o flicker mientras llega?

### 5.2 Sub-fase 4B — Preserve scroll position

#### Checklist

- [ ] Al volver atrás de una pantalla, ¿el scroll del padre se preserva? Si no, agregar `AutomaticKeepAliveClientMixin` o `PageStorage`.
- [ ] Verificar que `IndexedStack` (si se usa) no rebuild las pantallas inactivas.

### 5.3 Definition of Done — Fase 4

- [ ] Tiempo de navegación entre 5 transiciones críticas medido (Login→Mesas, Mesas→Menú, Menú→Pago, etc.).
- [ ] Cualquier flicker o loading visible identificado y eliminado.

---

## 6. Fase 5 — Listas y grids a 60 FPS (la meta)

**Duración estimada:** 3-4 días. Es el bloque de mayor ROI según la métrica objetivo.

### 6.1 Sub-fase 5A — Grid de productos (menu_browser)

#### Checklist

- [ ] Confirmar que usa `GridView.builder` (no `GridView(children:)`).
- [ ] Confirmar `cacheWidth`/`cacheHeight` en `Image.network` / `CachedNetworkImage`.
- [ ] Si cada tile tiene varios `Consumer` independientes (stock badge, modificadores, precio), pasar a `select` específico.
- [ ] Los modifier groups / variants se construyen lazy (al tocar el producto, no al renderizar el grid).
- [ ] Considerar `RepaintBoundary` por tile si hay animaciones por hover/tap.

### 6.2 Sub-fase 5B — Lista de mesas (sales by zone)

#### Checklist

- [ ] El header de zona (chip) se separa del listado.
- [ ] Cada tile de mesa observa solo su propio estado (color, timer, mesero), no el state global.
- [ ] El timer "tiempo desde apertura" no causa rebuild de toda la mesa cada segundo. Usar `ValueNotifier` o `Stream<Duration>` aislado.

### 6.3 Sub-fase 5C — KDS

#### Checklist

- [ ] Cada ticket es un widget independiente con su propio Realtime callback.
- [ ] El timer "tiempo en cocina" igual que arriba.
- [ ] `AnimatedSwitcher` para entrada/salida de tickets sin reflow de todo el board.

### 6.4 Sub-fase 5D — Lista de inventario

#### Checklist

- [ ] Si tiene más de 50 items por warehouse, virtualizar (`ListView.builder` con `itemExtent`).
- [ ] Búsqueda con debounce 200 ms para no rebuilds en cada keystroke.

### 6.5 Definition of Done — Fase 5

- [ ] Cada pantalla del §6 mide 60 FPS estable en scroll continuo de 30s.
- [ ] Sin frames droppeados visibles en Repaint Rainbow.

---

## 7. Fase 6 — Acciones de cajero con feedback inmediato

**Duración estimada:** 1-2 días. Objetivo: tap → respuesta visual en <100 ms, aunque la operación de red tome más.

### 7.1 Checklist

- [ ] Cada botón crítico (Agregar, Enviar a cocina, Pagar, Cobrar) tiene feedback inmediato (loading state, disable, ripple).
- [ ] Las operaciones largas (process_payment, send_to_kitchen) muestran spinner mientras corre el RPC.
- [ ] El optimistic update ya está en `addItem` (cubierto en código actual ✓). Verificar que en `cancelPayment`, `voidOrder`, `applyDiscount` también.
- [ ] Confirmar que ningún botón haga `await rpc` antes del `setState` que muestra el loading.

### 7.2 Definition of Done — Fase 6

- [ ] Acción crítica → respuesta visual en <100 ms (validado con grabación de pantalla a 60 FPS).
- [ ] Ningún tap "muerto" detectable.

---

## 8. Fase 7 — Heurísticas y documentación

**Duración estimada:** 0.5 días. Cierre.

### 8.1 Checklist

- [ ] Documentar en `CLAUDE.md` las heurísticas anti-rebuild que el sistema debe respetar:
  - Usar `ref.watch(provider.select((s) => s.field))` siempre que sea posible.
  - `const` en widgets puros.
  - `cacheWidth`/`cacheHeight` obligatorio en `Image.network`.
  - `ListView.builder` con `itemExtent` para listas largas.
  - `RepaintBoundary` para widgets con animación local.
- [ ] Smoke perf test manual (paso a paso) para correr antes de cada release: abrir cada pantalla crítica, scrollear 10s, verificar FPS overlay verde.

### 8.2 Definition of Done — Fase 7

- [ ] `CLAUDE.md` actualizado.
- [ ] Smoke test documentado en `docs/PERF_SMOKE_TEST.md`.

---

## 9. Cronograma sugerido

| Día | Fase | Actividad |
|---|---|---|
| 1-2 | 1 | Baseline + setup DevTools (Windows + Android) |
| 3-4 | 2 | Hallazgos sospechosos (grep + lectura código) |
| 5-7 | 3 | Cold start (trim bootstrap + splash) |
| 8-9 | 4 | Navegación (rutas + preserve scroll) |
| 10-13 | 5 | Listas/grids a 60 FPS (la meta principal) |
| 14-15 | 6 | Acciones de cajero |
| 16 | 7 | Heurísticas + docs + cierre |

### 9.1 Compromiso mínimo aceptable

Si el calendario aprieta, corte por valor:

1. **Fase 1 (baseline)**: sin esto, no se mide. Imposible saltar.
2. **Fase 5 (listas/grids)**: el dolor más visible del cajero diario. Mayor ROI.
3. **Fase 3 (cold start)**: visible cada apertura, alto impacto subjetivo.
4. **Fase 6 (acciones)**: importante pero menos crítico que las anteriores.
5. **Fase 4 (navegación)**: si no es 🔴, puede esperar.
6. **Fase 7 (docs)**: si no hay tiempo, los hallazgos quedan en este PRD.

---

## 10. Estado final esperado (Definition of Done global)

- [ ] Reporte baseline antes/después comparable.
- [ ] **Meta primaria**: 60 FPS scrolling consistente en las 4 pantallas top (menú, mesas, KDS, inventario), Windows + Android.
- [ ] **Meta secundaria**: cold start < 5s en Windows, < 7s en Android (tablet mid-range).
- [ ] **Meta secundaria**: navegación < 200 ms entre tabs del shell.
- [ ] **Meta secundaria**: acciones críticas con feedback visual < 100 ms.
- [ ] Heurísticas en `CLAUDE.md` para preservar lo ganado.
- [ ] Smoke test manual ejecutable en <10 min antes de cada release.
