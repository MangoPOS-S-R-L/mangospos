# PRD — Modo Oscuro de MangoPOS

> **Estado:** Borrador para revisión
> **Fecha:** 2026-06-02
> **Dueño de producto:** Cristian Gómez
> **Ámbito:** Añadir soporte completo de tema oscuro (dark mode) a MangoPOS —
> seleccionable por el usuario (Sistema / Claro / Oscuro), persistente, y aplicado
> de forma consistente en todas las superficies de la app sin degradar el modo claro
> actual ni romper cajero, ventas, impresión, auth ni scoping de negocio.

---

## 1. Resumen ejecutivo

MangoPOS hoy es **light-only**. El `MaterialApp.router` en
[lib/main.dart:949](../lib/main.dart#L949) usa `theme: buildMangoTheme()` y **no
declara** `darkTheme` ni `themeMode`. No existe detección del brillo del sistema, no
hay provider de tema, no hay preferencia persistida y la pantalla de Ajustes no tiene
toggle de tema.

El problema **no es de arquitectura sino de cobertura**: el repo ya tiene dos sistemas
de color (el moderno y semántico `AppColors` en
[lib/core/theme/app_colors.dart](../lib/core/theme/app_colors.dart), y el antiguo
`MangoColors` en [lib/app/theme/mango_colors.dart](../lib/app/theme/mango_colors.dart)),
pero la mayoría de las vistas pintan con **~1,795 referencias `Color(0xFF…)`
hardcodeadas** repartidas en **~291 archivos de `lib/presentation/`**. Esos valores
asumen fondo claro y se romperían en oscuro (texto negro sobre fondo negro, bordes
invisibles, fondos crema ilegibles).

La infraestructura de persistencia **ya existe**: `StorageService` envuelve
`SharedPreferences` ([lib/core/storage/storage_service.dart](../lib/core/storage/storage_service.dart)),
y hay una pantalla de Ajustes con 18+ secciones donde encaja un toggle
([lib/presentation/settings/view/settings_view.dart](../lib/presentation/settings/view/settings_view.dart)).

Este PRD define el alcance, el modelo de tokens, la estrategia de migración de
colores, las fases de entrega y los criterios de aceptación para llegar a un modo
oscuro **de calidad de producto**, no un parche.

---

## 2. Objetivos y no-objetivos

### 2.1 Objetivos
- **O1.** El usuario puede elegir tema: **Sistema** (sigue el brillo del SO), **Claro**, **Oscuro**.
- **O2.** La elección **persiste** entre sesiones y reinicios (por dispositivo).
- **O3.** El modo oscuro se ve **terminado** en las superficies de alto tráfico:
  shell/navegación, ventas (POS), cajero/cuadre, ajustes, dashboard, login/registro,
  diálogos y toasts.
- **O4.** Contraste accesible: cumplir **WCAG AA** (≥4.5:1 texto normal, ≥3:1 texto grande
  e iconografía funcional).
- **O5.** **Cero regresión** en el modo claro actual: el light theme debe verse pixel-igual
  a hoy tras la migración de colores.
- **O6.** Transición de tema sin reinicio de app y sin "flash" blanco al arrancar.

### 2.2 No-objetivos (fuera de alcance de v1)
- **N1.** Temas personalizables por el usuario (color de marca configurable, "true black" OLED, alto contraste). Se contemplan como evolución futura (§9).
- **N2.** Programación automática por horario ("oscuro de noche") más allá de lo que da "Seguir Sistema".
- **N3.** Tema oscuro en artefactos **impresos** (tickets ESC/POS, PDFs, etiquetas): los recibos siguen imprimiéndose en su formato actual. El tema es solo de la UI en pantalla.
- **N4.** Reescritura del sistema de diseño. Unificamos hacia `AppColors`, pero no rehacemos `MangoColors`/`mango_theme` desde cero.

---

## 3. Estado actual (línea base verificada en código)

| Aspecto | Estado | Evidencia |
|---|---|---|
| `ThemeData` | ❌ Solo claro | `buildMangoTheme()` retorna un único tema con `ColorScheme.light()` — [lib/app/theme/mango_theme.dart](../lib/app/theme/mango_theme.dart) |
| `themeMode` / `darkTheme` | ❌ No existe | [lib/main.dart:949](../lib/main.dart#L949) solo pasa `theme:` |
| Detección de brillo del SO | ❌ No existe | sin `platformBrightness` ni `MediaQuery` de brightness |
| Provider de tema (Riverpod) | ❌ No existe | — |
| Preferencia persistida | ❌ No existe | pero `StorageService` + `SharedPreferences` listos |
| Toggle en Ajustes | ❌ No existe | [settings_view.dart](../lib/presentation/settings/view/settings_view.dart) sin opción de tema |
| Tokens de color centralizados | ⚠️ Parcial | `AppColors` (semántico, HSL documentado) existe pero no se usa en todas las vistas |
| Colores hardcodeados | 🔴 Masivo | ~1,795 `Color(0xFF…)` en ~291 archivos de `presentation/` |

**Archivos de mayor impacto** (más colores duros = más trabajo de migración):
- [lib/presentation/shell/main_shell.dart](../lib/presentation/shell/main_shell.dart) (~100) — fondo `Color(0xFFFBFAF9)`, bordes `Color(0xFFE5E7EB)`
- [lib/presentation/shell/mobile_shell.dart](../lib/presentation/shell/mobile_shell.dart) (~57) — bottom nav, drawer
- [lib/presentation/settings/view/settings_view.dart](../lib/presentation/settings/view/settings_view.dart) (~50) — `_SettingsSurface` con `background`/`foreground` fijos, gradientes
- [lib/presentation/dashboard/dashboard_view.dart](../lib/presentation/dashboard/dashboard_view.dart) (~16)
- `lib/presentation/sales/*` (~40), `lib/presentation/cashier/*` (~35)

---

## 4. Experiencia de usuario

### 4.1 Selector de tema
- Ubicación: **Ajustes → Ajustes Generales**, nueva opción "Apariencia" / "Tema".
- Control: tres opciones mutuamente excluyentes — **Seguir sistema** (default), **Claro**, **Oscuro**.
- Efecto **inmediato** al seleccionar (sin reinicio), animado por el rebuild de `MaterialApp`.
- Copy en español latinoamericano (tú/necesitas), sin voseo, consistente con la guía del proyecto.

### 4.2 Arranque sin flash
- El `themeMode` se lee de `SharedPreferences` **antes** del primer frame (o el splash
  usa color neutro) para evitar el flash blanco→oscuro al iniciar en modo oscuro.

### 4.3 Comportamiento "Seguir sistema"
- Si el usuario elige "Seguir sistema", la app reacciona a cambios de brillo del SO en
  caliente (Flutter ya entrega esto vía `ThemeMode.system` + `MaterialApp.darkTheme`).

---

## 5. Diseño técnico

### 5.1 Arquitectura de tema
1. **Refactor de `mango_theme.dart`** para exponer dos constructores:
   - `buildMangoTheme()` → light (comportamiento actual, **sin cambios visuales**).
   - `buildMangoThemeDark()` → dark, con `ColorScheme.dark()` y todos los component
     themes (botones, inputs, dialogs, cards, appbar, bottomnav) reconfigurados.
   - Extraer los valores compartidos (radios, tipografía, formas) para que ambos temas
     deriven de una base común y no se dupliquen tokens estructurales.
2. **`MaterialApp.router`** en [lib/main.dart](../lib/main.dart#L945-L951) pasa a:
   ```dart
   theme: buildMangoTheme(),
   darkTheme: buildMangoThemeDark(),
   themeMode: ref.watch(themeModeProvider),
   ```

### 5.2 Provider y persistencia
- Nuevo **`themeModeProvider`** (Riverpod, `StateNotifier<ThemeMode>` o `Notifier`),
  ubicado junto a la infraestructura de tema (p. ej. `lib/core/theme/theme_mode_provider.dart`).
- Lee el valor inicial de `StorageService` con una key nueva en `StorageKeys`
  (p. ej. `theme_mode` con valores `system|light|dark`).
- Al cambiar, escribe en `StorageService` y notifica → `MaterialApp` rebuild.
- `MyApp` pasa de `ConsumerWidget` a observar `themeModeProvider` (ya es `ConsumerWidget`).

### 5.3 Estrategia de color — el verdadero trabajo
El reto no es el theme; son los **~1,795 colores duros**. Estrategia en capas:

1. **`AppColors` se vuelve `Brightness`-aware.** Hoy define tokens estáticos claros.
   Se introducen los pares dark de cada token semántico (background, foreground,
   surface, primary, success, warning, info, destructive, border, muted…). Dos caminos
   posibles, a decidir en diseño técnico:
   - **(A, recomendado)** Resolver tokens vía `Theme.of(context).colorScheme` y
     `extension MangoColorsX on ColorScheme` / `ThemeExtension<MangoPalette>`, de modo
     que el color correcto salga del tema activo automáticamente.
   - **(B)** Métodos `AppColors.background(context)` que devuelven claro/oscuro según
     `Theme.of(context).brightness`.
2. **Migración por superficie, no big-bang.** Se migran las vistas por orden de tráfico
   (§7 fases). En cada vista, los `Color(0xFF…)` se reemplazan por el token semántico
   equivalente o por `Theme.of(context).colorScheme.*`.
3. **Regla de oro:** cuando un color es **semántico** (fondo, texto, borde, superficie)
   debe venir del tema. Cuando es **de marca fija** (naranja MangoPOS, verde de éxito de
   estado) puede permanecer constante en ambos temas, validando contraste sobre fondo oscuro.
4. **Lint/guardarraíl:** considerar una regla (custom lint o script de CI) que advierta
   sobre nuevos `Colors.white`/`Colors.black`/`Color(0xFF…)` en `lib/presentation/` para
   frenar la regresión una vez migrado.

### 5.4 Casos especiales a auditar
- **Gradientes** (p. ej. settings line 859, `app_gradients.dart`) → necesitan variante oscura.
- **Sombras** (`app_shadows.dart`) → en oscuro las sombras se perciben distinto; revisar elevación.
- **`SystemUiOverlayStyle`** (status bar / nav bar Android) → debe invertir iconos según tema.
- **Iconos/ilustraciones PNG/SVG** con fondo claro embebido → identificar los que necesitan versión oscura o tinte.
- **Estados de conectividad / badges** (online verde, offline rojo) → mantener semántica, validar contraste.
- **Splash / pantalla de carga** → color neutro para evitar flash.

---

## 6. Áreas sensibles (precaución explícita)

Por las reglas del repo, se marca riesgo en módulos críticos. El modo oscuro **no debe
cambiar lógica**, solo presentación, pero estas áreas tocan colores y hay que tener cuidado:

- **`lib/main.dart`** — solo se añaden `darkTheme`/`themeMode`; no tocar bootstrap, Supabase, auth recovery ni arranque del agente de impresión.
- **Cajero / cuadre de caja** — vistas con muchos colores duros; cambiar solo color, jamás cálculo ni flujo.
- **Ventas (POS)** — idem; el escáner, el carrito y el cobro no deben verse afectados funcionalmente.
- **Impresión** — **no entra en alcance** (N3); verificar que ningún cambio de tema altere las previews/plantillas de ticket.
- **Auth / router guards / tenant scoping** — sin cambios de lógica; solo color en pantallas de login/registro/selección de negocio.

---

## 7. Fases de entrega

> Cada fase es entregable y verificable de forma independiente. El modo claro debe
> permanecer idéntico tras cada fase.

### Fase 0 — Cimientos (sin UI visible aún)
- `themeModeProvider` + key en `StorageKeys` + lectura/escritura en `StorageService`.
- `buildMangoThemeDark()` inicial (ColorScheme + component themes base).
- Cablear `darkTheme` + `themeMode` en `MaterialApp`.
- `AppColors` brightness-aware (tokens dark definidos).
- **Criterio:** forzando `themeMode: dark` la app arranca en oscuro sin crashear (aunque haya vistas aún claras).

### Fase 1 — Selector + Shell
- Toggle "Apariencia" en Ajustes Generales (Sistema/Claro/Oscuro), funcional y persistente.
- Migrar `main_shell.dart` y `mobile_shell.dart` (navegación, drawer, bottom nav, appbar).
- `SystemUiOverlayStyle` reactivo al tema.
- **Criterio:** el usuario puede cambiar tema desde Ajustes; el chrome de la app (shell + nav) se ve correcto en oscuro.

### Fase 2 — Flujos de alto tráfico
- Migrar **Ventas (POS)**, **Cajero/cuadre**, **Dashboard**.
- Auditar diálogos y toasts compartidos.
- **Criterio:** un turno completo (abrir caja → vender → cobrar → cerrar caja) se ve correcto en oscuro.

### Fase 3 — Auth, Ajustes y resto
- Login, registro (step1/step2), selección de negocio.
- `settings_view.dart` completo (incluido `_SettingsSurface` y gradientes).
- Resto de módulos (inventario, productos, reportes, KDS/kitchen, clientes, promos, compras).
- **Criterio:** barrido completo de la app sin "islas claras" en oscuro.

### Fase 4 — Pulido y guardarraíles
- Auditoría de contraste WCAG AA en pantallas clave.
- Variantes oscuras de gradientes/sombras/ilustraciones pendientes.
- Lint/CI contra nuevos colores hardcodeados.
- **Criterio:** checklist de QA (§8) en verde.

---

## 8. Criterios de aceptación / QA

- [ ] El selector en Ajustes ofrece Sistema/Claro/Oscuro y aplica al instante.
- [ ] La preferencia persiste tras cerrar y reabrir la app.
- [ ] "Seguir sistema" reacciona a cambiar el brillo del SO en caliente.
- [ ] No hay flash blanco al arrancar en modo oscuro.
- [ ] **Modo claro idéntico a hoy** (comparación visual antes/después en shell, ventas, cajero, ajustes).
- [ ] Recorrido de turno completo (abrir caja → venta con escáner → cobro → cierre) legible y sin glitches en oscuro.
- [ ] Sin texto ilegible (negro sobre negro), bordes invisibles ni fondos crema en oscuro.
- [ ] Diálogos, toasts, snackbars y badges de estado (online/offline) correctos en ambos temas.
- [ ] Status bar / nav bar del SO con iconos del color correcto según tema.
- [ ] Contraste WCAG AA verificado en login, shell, ventas, cajero, ajustes.
- [ ] Impresión (tickets/PDF/etiquetas) sin cambios.
- [ ] `flutter analyze` limpio; `flutter test` en verde.
- [ ] Verificado en las plataformas objetivo (al menos macOS + web; móvil si aplica).

---

## 9. Evolución futura (post-v1)
- Tema "true black" para pantallas OLED (ahorro de batería).
- Modo alto contraste (accesibilidad).
- Color de marca/acento configurable por negocio (tenant theming).
- Programación por horario propia (oscuro automático en rango de horas).

---

## 10. Riesgos y mitigaciones

| Riesgo | Impacto | Mitigación |
|---|---|---|
| Volumen de colores hardcodeados (~1,795) hace el barrido largo y propenso a "islas claras" | Alto | Migración por fases priorizada por tráfico; lint que frene nueva deuda |
| Regresión visual del modo claro durante la migración | Alto | Light theme = comportamiento actual sin cambios; QA comparativo por fase |
| Tocar módulos sensibles (cajero/ventas/auth) introduce bugs de lógica | Alto | Cambios estrictamente de presentación; revisión enfocada; no tocar cálculos/flujo |
| Contraste insuficiente en oscuro (texto poco legible) | Medio | Tokens con valores validados WCAG AA; auditoría en Fase 4 |
| Flash de tema al arrancar | Bajo | Leer `themeMode` antes del primer frame / splash neutro |
| Dualidad `AppColors` vs `MangoColors` genera inconsistencias | Medio | Unificar hacia `AppColors` brightness-aware; `MangoColors` solo para marca fija |

---

## 11. Estimación de esfuerzo (orden de magnitud)
- **Fase 0–1 (cimientos + shell + selector):** lo más mecánico, base sólida rápida.
- **Fase 2–3 (barrido de ~291 vistas):** el grueso del trabajo; escalable y paralelizable por módulo.
- **Fase 4 (pulido/contraste/CI):** acotada.

El cuello de botella no es el theming sino la **migración de color por vista**; conviene
abordarla módulo a módulo, reutilizando el patrón establecido en Fase 1.
