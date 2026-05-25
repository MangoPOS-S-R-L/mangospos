# PRD 8 — Reporte Fase 2

**Antipatrones de performance en el codebase**

| | |
|---|---|
| **Fecha** | 2026-05-24 |
| **Alcance** | `lib/` (excluyendo databasecode/, examples/, tests, docs) |
| **Metodología** | Grep + análisis estático sobre 10 antipatrones definidos en el PRD 8 |
| **Total hits** | 34 |
| **Distribución** | 🔴 5 · 🟡 12 · 🟢 17 |

---

## 1. Veredicto rápido

**Estado general: 🟡 OBS — sano con 5 puntos concretos de mejora alto ROI**

La app NO tiene un problema sistemático de performance, pero hay **5 lugares específicos** donde el costo es visible y el fix es barato. Si arreglamos esos 5, la app entra cómodamente al rango Toast (60 FPS scrolling, sin jank perceptible).

**Patrón recurrente #1**: `Timer.periodic + setState` en 6 widgets. Es el origen del jank intermitente que se siente en cashier y KDS.

**Patrón recurrente #2**: `ref.watch(provider)` sin `.select()` en 1 lugar crítico (cart bar). Solo 1 instancia es problemática real — el resto está bien.

**Patrón recurrente #3**: `CachedNetworkImage` sin `cacheWidth`/`cacheHeight` en grid de productos y catálogo. RAM brutal con catálogos grandes.

---

## 2. Hallazgos 🔴 Críticos (5)

### C.1 — `cashier_view.dart:46` — Timer.periodic 30s causa rebuild del cashier completo

```dart
Timer.periodic(Duration(seconds: 30), (_) => refreshSilently());
// → setState() en árbol con 10+ widgets anidados
```

**Por qué importa**: cada 30s, todo el dashboard de caja se reconstruye (header, stats, lista de movimientos, gráficos). Si el cajero está mirando la pantalla justo en ese tick, ve un flicker. Si está animando algo, frame droppeado.

**Fix**: mover el polling a un Riverpod provider con `Stream.periodic` + `notifyListeners`. Los sub-widgets se suscriben solo a lo suyo via `.select()`. Subviews que no cambian no rebuild.

**Esfuerzo**: 2h · **Impacto**: alto (cashier siempre visible)

### C.2 — `kds/widgets/timer_widget.dart:22` — N timers en KDS

```dart
Timer.periodic(Duration(seconds: 1), (_) => setState(() => _elapsed = ...));
```

**Por qué importa**: KDS típicamente tiene 10-30 órdenes activas. Cada una instancia un `_TimerWidgetState` con su propio `Timer.periodic(1s)`. Resultado: 10-30 `setState` simultáneos por segundo. **CPU spike sostenido en KDS con muchas órdenes.**

**Fix**: extraer el conteo del tiempo a un único `ValueNotifier<DateTime>` global que tickeé cada segundo. Cada `_TimerWidgetState` usa `ValueListenableBuilder` para reaccionar solo a su sub-tree. Un único timer global, N rebuilds aislados sin setState explícito.

**Esfuerzo**: 2h · **Impacto**: muy alto en KDS con carga real

### C.3 — `payment_success_dialog.dart:76` — Countdown con setState

```dart
Timer.periodic(Duration(seconds: 1), (_) => setState(() => _remaining--));
```

**Por qué importa**: el modal de "Pago exitoso" muestra una cuenta regresiva de 3s antes de auto-cerrar. Cada segundo rebuild todo el dialog. No es crítico (3 ticks total) pero es feo y educativo.

**Fix**: `AnimationController(duration: 3s)` + `AnimatedBuilder` solo sobre el Text del contador.

**Esfuerzo**: 45 min · **Impacto**: bajo pero limpia código

### C.4 — `table_order_screen.dart:6799` — `AnimatedBuilder` sin `child:`

```dart
AnimatedBuilder(
  animation: ctrl,
  builder: (ctx, _) => Transform.scale(
    scale: ctrl.value,
    child: ComplejoWidget(),  // ← rebuild en cada frame
  ),
)
```

**Por qué importa**: 60 rebuilds por segundo de `ComplejoWidget` durante la animación, cuando el widget NO depende de `ctrl.value`. Solo la transformación lo hace.

**Fix**: pasar `ComplejoWidget` como `child:` del AnimatedBuilder. El motor lo cachea y solo lo envuelve con la transformación.

**Esfuerzo**: 30 min · **Impacto**: medio (durante animación)

### C.5 — `table_order_screen.dart:1157` — `ref.watch(currentOrderProvider)` sin `.select` en CartBar

```dart
final order = ref.watch(currentOrderProvider);
return Text('Total: ${order.total}');
// → cualquier cambio en items, checks, origin, customer, etc. rebuild CartBar
```

**Por qué importa**: `currentOrderProvider` cambia muchas veces por acción del cajero (agregar item, modificar qty, aplicar descuento). Cada cambio rebuilds `_MobileCartBar` que solo usa `state.items` y `state.total`.

**Fix**:
```dart
final total = ref.watch(currentOrderProvider.select((s) => s.total));
final itemCount = ref.watch(currentOrderProvider.select((s) => s.items.length));
```

**Esfuerzo**: 1.5h · **Impacto**: alto (cart bar siempre visible cuando hay orden)

---

## 3. Hallazgos 🟡 Importantes (12)

### Imágenes sin `cacheWidth`/`cacheHeight`

| Archivo | Contexto |
|---|---|
| `products/widgets/add_edit_product_dialog.dart:1639` | Preview de producto en editor |
| `settings/business_profile/business_profile_screen.dart:641` | Logo del negocio |
| `sales/view/menu_browser_sheet.dart:574` | **Grid de productos en venta** (el más caliente) |

**Impacto**: una foto 2000×2000 renderizada en 150×150 consume **178× más RAM** que comprimida al display size. En un catálogo de 100 productos, eso son ~100 MB extra fácil.

**Fix**: agregar `cacheWidth: 300, cacheHeight: 300` (3× el tamaño físico para retina).

**Esfuerzo total**: 1h · **Impacto**: alto en menu_browser, medio en los otros

### `ref.watch` sin `.select` en otros viewmodels

- `cashier/view/cashier_view.dart:77` — `cashierViewModelProvider` completo, sub-widgets usan campos puntuales.

### `Timer.periodic` en main_shell

- `shell/main_shell.dart:741` — chequeo de internet cada 5s con `setState` en el shell. Si el resultado no cambia, NO debería rebuild. Agregar guard `if (newValue != _online) setState(...)`.

### `ListView` sin `.builder` en reports

6 archivos en `presentation/reports/` con `ListView(children: [...])` para listas que pueden crecer a 500+ filas. Refactor batch.

### `MediaQuery.of()` repetido

- `cashier_view.dart:68-75` — 3 llamadas a `MediaQuery.of(context)` en el mismo build. Consolidar.

---

## 4. Hallazgos 🟢 Menores (17)

`StatelessWidget` sin `const` constructor en widgets utility (`ResponsiveText`, `_DrawerNavTile`, etc.). Impacto bajo individual, pero como hábito ayuda. Lo dejamos para una pasada de limpieza al final.

---

## 5. Top 10 — Plan ordenado por ROI

| # | Fix | Esfuerzo | Severidad | Impacto subjetivo |
|---|---|---|---|---|
| 1 | C.1 Timer cashier → Riverpod polling | 2h | 🔴 | Cashier deja de flickerear cada 30s |
| 2 | C.2 KDS timer global con ValueNotifier | 2h | 🔴 | KDS suave con 20+ órdenes |
| 3 | C.5 `.select` en CartBar | 1.5h | 🔴 | Cart bar fluído mientras agregás items |
| 4 | Imágenes con `cacheWidth/Height` en menu_browser | 1h | 🟡 | RAM cae ~60% en grid de productos |
| 5 | C.4 `AnimatedBuilder` con `child:` | 30m | 🔴 | Animación de transición suave |
| 6 | Resto de imágenes con cacheWidth (editor + logo) | 30m | 🟡 | Defensivo |
| 7 | Main shell timer con guard de "cambió o no" | 30m | 🟡 | -1 rebuild/5s del topbar |
| 8 | C.3 Countdown dialog con AnimationController | 45m | 🔴 | Educativo + limpio |
| 9 | ListView.builder en reports | 3h | 🟡 | Escalable a futuro |
| 10 | Consolidar `MediaQuery.of` en cashier | 30m | 🟡 | Limpieza |

**Total esfuerzo Top 10**: ~13 horas (~2 días).
**Output esperado**: app subjetivamente más rápida + 60 FPS estable en las pantallas frecuentes.

---

## 6. Áreas más críticas detectadas

### `table_order_screen.dart` (12K líneas)

Es el archivo más caliente: tiene 2 de los 5 hallazgos 🔴 (CartBar sin `.select` y AnimatedBuilder sin child). Vale considerar después del PRD 8 un **refactor estructural** que lo divida en widgets más chicos. NO en este sprint — es trabajo de otra magnitud.

### KDS

Por la naturaleza de "20 timers simultáneos", es donde más se sentirá la mejora del fix C.2.

### Cashier

Por el Timer global cada 30s, es donde el flicker es más visible al usuario.

---

## 7. Lo que SÍ está bien (para no olvidarlo)

- **`AnimatedBuilder` con `child:` correcto** en `app/widgets/skeleton_loading.dart:188` ✓
- **`ListView.builder`** se usa correctamente en la mayoría de listas dinámicas (mesas, items, etc.)
- **`StatefulWidget` con `dispose()`** está bien implementado en casi todos los `_State` (el audit anterior de Fase 4.1 lo confirmó)
- **Riverpod providers** están bien diseñados a nivel arquitectura — el problema solo es de uso (no de diseño)
- **No hay anti-patrón de "Future literal en build"** en lugares críticos

---

## 8. Siguiente paso

**Recomendación**: empezar por el Top 3 (Timer cashier + KDS + CartBar). Es ~5.5h de trabajo focused y elimina los 3 puntos más visibles de jank.

**Antes** de tocar código, idealmente:
- Correr Fase 1 del PRD 8 (baseline con DevTools) para tener métricas before/after.
- Sin baseline, no podemos validar objetivamente que el fix funcionó.

Si no podemos correr baseline (requiere `flutter run --profile` + DevTools en máquinas reales), igual podemos hacer los fixes — los antipatrones son objetivamente malos, el fix es objetivamente bueno. Solo perdemos la métrica before/after.
