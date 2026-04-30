# PRD 6 — Responsive, DPI escalable y patrones POS profesional

| Campo | Valor |
|---|---|
| **Programa** | Estabilización Operacional MangoPOS |
| **PRD** | 6 |
| **Versión** | 1.1 |
| **Fecha** | 2026-04-30 |
| **Autor** | Cristian (DRI) |
| **Estado** | Draft revisado — pendiente arrancar F1 |
| **Prioridad** | P1 (bloquea instalaciones en hardware POS estándar) |
| **Esfuerzo estimado** | 3-4 semanas (ampliado vs. v1.0 para incorporar DPI, touch targets y patrones de flujo transaccional) |
| **Riesgo** | Medio (toca todas las pantallas; requiere validación cross-platform en 6 combinaciones físicas/scaling) |
| **Risk Acceptance** | Sin staging — validación contra negocio de prueba en producción + capturas en cada combinación resolución × DPI scaling. |

## Changelog

- **v1.1** (2026-04-30): Incorpora DPI scaling de Windows (100/125/150 %), tolerancia a `MediaQuery.textScaler`, touch targets mínimos 44×44 px, principio de anatomía preservada en modales, patrones POS profesional para acciones transaccionales (estado disabled/loading/error, atajos de denominación, prominencia del input principal), y test matrix extendido a 6 combinaciones. Resuelve open questions 1-3 de v1.0.
- **v1.0** (2026-04-30): Versión inicial. Foco solo en breakpoints de ancho.

---

## 1. Executive Summary

La app fue diseñada y testeada principalmente en monitores ≥1440 px de ancho (Mac dev, monitores de caja modernos a 100 % de scaling). Al instalar en una PC de **1360×768** (resolución muy común en laptops y minis fanless de POS), o en un **1920×1080 con Windows en 150 %** (escenario típico de laptops corporativas con vista cansada), el layout se rompe:

- Sidebar fijo de 224 px deja <1100 px útiles → tablas y panels colapsan o overflow.
- Tipografía y paddings son absolutos (px), no escalan con DPI ni respetan `textScaler`.
- Modales que en 1440 ocupan 60 % del ancho, en 1360 ocupan 100 % y se cortan.
- Botones de acción quedan fuera de viewport en flujos de pago y cocina.
- Touch targets de iconos y tabs son menores a 44 px → frustración en hardware POS táctil.
- Decisiones de layout que usan `MediaQuery.physicalSize` ignoran completamente el DPI scaling de Windows.

Este PRD define **breakpoints**, una **estrategia de escalado** que cascadea correctamente con DPI, **mínimos de touch target**, y los **patrones de UX para flujos transaccionales** que distinguen a un POS profesional de una app responsive genérica. La meta es que MangoPOS sea instalable en cualquier hardware POS estándar (1280×720 hasta 4K, scaling 100-150 %) sin downgrade visual ni operacional.

---

## 2. Goals y Non-Goals

### 2.1 Goals

1. **Soporte first-class** para resoluciones lógicas desde **1280** hasta **3840** px de ancho.
2. **Tres breakpoints** definidos sobre píxeles lógicos (no físicos):
   - **Compact** (<1366 px): sidebar colapsable a icon-only, modales fullscreen con anatomía preservada, tablas con scroll horizontal.
   - **Regular** (1366–1919 px): layout actual, validado.
   - **Wide** (≥1920 px): paneles con más aire, columnas extra opcionales en tablas.
3. **Cascadeo automático con Windows DPI scaling** (100 / 125 / 150 %). Mismo monitor físico cae en breakpoint distinto según scaling, sin código adicional, vía `MediaQuery.sizeOf`.
4. **Tolerancia a `MediaQuery.textScaler`** hasta 1.3× sin overflow ni texto cortado. El cajero con vista cansada puede subir solo el texto sin romper el layout.
5. **Touch targets mínimos de 44×44 px lógicos** en cualquier elemento tappable (botones, tabs, toggles, iconos de close, filas de productos).
6. **Tipografía escalable** vía tokens semánticos (`fontSizes.body`, `fontSizes.h1`, etc.) en vez de literales.
7. **Spacings tokenizados** (`Insets.sm`, `Insets.md`, `Insets.lg`).
8. **Modales con anatomía preservada** entre breakpoints — fullscreen en compact ≠ rediseño.
9. **Patrones POS profesional** en el modal de cobro y flujos transaccionales: total visible siempre, input principal prominente, estados disabled/loading/error, atajos de denominación.
10. **Auditoría completa** de las 12 pantallas críticas: ventas, cocina, KDS, cobros, reportes, productos, ajustes.
11. **Smoke test manual** en **6 combinaciones** (3 resoluciones × scaling relevante) antes de cerrar el PRD.

### 2.2 Non-Goals

- Mobile (Android tablet/iPhone) layout — fuera de alcance, ya tiene su propio path responsive.
- Diseño de tema oscuro/claro (otro PRD).
- Soporte para resoluciones lógicas <1280 px de ancho (laptops muy antiguas, no es target comercial).
- Re-diseño visual / brand refresh.
- Dual display (customer-facing screen) — fuera de scope, evaluar en PRD futuro.
- Atajos de teclado (F-keys) — posible stretch goal F3, no compromiso.
- Cambios en lógica de cobro, autenticación o impresión — este PRD es solo UI y layout.

---

## 3. Hallazgos del incidente (1360×768 + escenarios DPI)

### 3.1 Diagnóstico inicial — overflow por breakpoint

| Pantalla | Síntoma | Severidad |
|---|---|---|
| Sales shell | Sidebar 224 px + área de productos no calza | P1 |
| Mesa con orden | Botones "Pagar/Enviar" cortados | P1 |
| Modal de cobro | Form excede viewport vertical, no scrollea | P1 |
| Reportes | Headers de tabla wrap raro, columnas comprimidas | P2 |
| Configuración | Sidebar de submenú + content de 3 columnas no calza | P2 |
| Cocina/KDS | Cards muy comprimidas, texto ilegible | P2 |
| Productos | Grid de productos con tarjetas muy pequeñas | P3 |

(F1.1 expandirá esta tabla con todas las pantallas tras auditoría sistemática × 6 combinaciones.)

### 3.2 Comportamiento bajo DPI scaling

Un mismo monitor físico produce viewports lógicos distintos según el scaling de Windows. El sistema de breakpoints debe reaccionar a píxeles lógicos para que esto cascadee correctamente:

| Monitor físico | Win scaling | Logical | Breakpoint esperado |
|---|---|---|---|
| 1366 × 768 | 100 % | 1366 | Regular |
| 1366 × 768 | 125 % | 1093 | Compact |
| 1920 × 1080 | 100 % | 1920 | Wide |
| 1920 × 1080 | 125 % | 1536 | Regular |
| 1920 × 1080 | 150 % | 1280 | Compact |
| 2560 × 1440 | 100 % | 2560 | Wide |

**Insight clave:** una laptop de cajero 1920×1080 con Windows en 150 % scaling se comporta exactamente como una mini fanless 1280×720. No requieren código distinto — el mismo sistema de breakpoints los cubre, siempre que use `MediaQuery.sizeOf` y nunca `physicalSize`.

### 3.3 Touch targets actuales

Auditoría preliminar (a confirmar en F1.1):

- Iconos de close en modales: estimado ~24 px → **violación**, debe ser ≥44.
- Tabs en configuración: ~32 px de alto → **violación**.
- Botones de quantity ± en orden: ~28 px → **violación**.
- Filas de selección en pickers: ~36 px → **borderline**.

POS hardware típico tiene touchscreens capacitivas que requieren targets generosos para uso rápido sin frustración.

### 3.4 Root cause

1. **Tamaños hardcodeados**: anchos de sidebar, padding de cards, tamaños de fuente y íconos están en literales (`width: 224`, `fontSize: 14`).
2. **Sin LayoutBuilder en pantallas críticas**: el layout no reacciona al ancho real disponible.
3. **Modales con tamaños fijos** (ej. `Container(width: 800)` dentro de un Dialog) que en 1360 quedan al 100 % sin gracia visual.
4. **`MediaQuery.size` ignorado** en widgets que sí lo necesitan (drawer permanente, columnas de tabla).
5. **`physicalSize` mal usado** en al menos un punto del shell — anula el DPI scaling de Windows.
6. **Touch targets** sin tamaño mínimo enforced; iconos y tabs heredan tamaño visual sin extensión de área activa.
7. **Estados de modal** (loading, disabled, error) no implementados en cobro — el cajero no tiene feedback durante procesamiento.

---

## 4. Arquitectura propuesta

### 4.1 Sistema de breakpoints

Crear `lib/app/theme/breakpoints.dart`:

```dart
class Breakpoints {
  static const double compact = 1366;
  static const double regular = 1920;

  // CRÍTICO: usar siempre MediaQuery.sizeOf (lógicos), nunca physicalSize.
  // El DPI scaling de Windows ya está aplicado en sizeOf.
  static bool isCompact(BuildContext c) =>
      MediaQuery.sizeOf(c).width < compact;
  static bool isRegular(BuildContext c) {
    final w = MediaQuery.sizeOf(c).width;
    return w >= compact && w < regular;
  }
  static bool isWide(BuildContext c) =>
      MediaQuery.sizeOf(c).width >= regular;
}
```

**Regla absoluta:** `MediaQuery.physicalSize`, `window.physicalSize`, y similares están **prohibidos** para decisiones de layout. Solo `MediaQuery.sizeOf` o `LayoutBuilder` constraints. Lint rule a agregar en F1.2.

### 4.2 Tokens de spacing y tipografía

Crear `lib/app/theme/sizes.dart`:

```dart
class Insets {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  // En compact, escalar 0.85x via helper.
}

class FontSizes {
  static const double caption = 12;
  static const double body = 14;       // mínimo legal en compact
  static const double subtitle = 16;
  static const double title = 20;
  static const double display = 28;
}
```

**Reglas de tipografía:**

- Mínimo absoluto **14 pt body**, no bajar a 12 ni en compact.
- Todo `Text` debe respetar `MediaQuery.textScalerOf(context)`. **Prohibido** hardcodear `textScaleFactor: 1.0` para "evitar problemas" — eso bloquea la accesibilidad del cajero con vista cansada.
- Widgets con altura fija deben usar `IntrinsicHeight` o `minHeight` en vez de `height: X` literal, para tolerar `textScaler` hasta 1.3× sin recortar.

### 4.3 Layout reglas

| Componente | Regular/Wide | Compact |
|---|---|---|
| Sidebar | 224 px expandido | 64 px icon-only (con tooltip) |
| Tablas | Todas las columnas | Scroll horizontal o columnas colapsables |
| Botones acción | Inline derecha | Stack vertical full-width |
| Cards de productos | 4 columnas | 3 columnas |
| Touch targets mínimos | 44×44 px lógicos | 44×44 px lógicos (nunca menor) |

### 4.4 Modales — anatomía preservada (estándar industria POS)

Patrón que usan Toast, Square, Lightspeed y guías Material/iOS HIG. La regla
es por **tipo de tarea**, no solo por tamaño de pantalla:

| Tipo de modal | Compact (<1366) | Regular/Wide | Ejemplos en MangoPOS |
|---|---|---|---|
| Confirmación / alerta (1 pregunta, ≤3 botones) | Card centrada (~400 px) | Card centrada (~400 px) | "¿Anular orden?", "¿Eliminar producto?", "¿Cerrar caja?" |
| Picker simple (1 dato a elegir) | Card centrada (~500 px) | Card centrada (~500 px) | Selector de mesero, cliente, fecha, mesa |
| Form con secciones | **Fullscreen** | Card grande (~80 % screen, max 1100 px) | Cobro, split bill, factura/NCF, edit producto, edit menu item |
| Wizard multi-step | **Fullscreen** | Card grande (~80 % screen) | Setup inicial, alta de impresora, configuración de tax |

**Razones del split:**

- Confirmaciones son one-shot (≤1s): card chica preserva el contexto del fondo (ej: el cajero ve la orden detrás del "¿Eliminar?").
- Forms y wizards requieren foco completo: fullscreen quita distracción y aprovecha el viewport vertical limitado de 768 px.
- Pickers son intermedios — card chica funciona bien hasta 1280 px.

**Principio de anatomía preservada:**

> **Fullscreen en compact ≠ rediseño del modal.** La anatomía interna (header, body en columnas, footer) se mantiene idéntica entre los tres breakpoints. Lo único que escala es el contenedor (57 % wide → 80 % regular → 98 % compact) y el padding interno (14 → 11 → 9 px). Esto preserva el modelo mental del cajero — un usuario entrenado en 1366 abre el mismo modal en 1280 y reconoce todo.

**Implementación**: helper único `MangoModal.showAdaptive(context, type, builder)` que aplica la regla según `type` (`confirmation | picker | form | wizard`) y el breakpoint actual. Todas las pantallas migran a este helper en F2.

### 4.5 Touch targets

Cualquier elemento tappable debe tener mínimo **44×44 px lógicos** de área activa. Esto cubre:

- Botones primarios y secundarios
- Tabs
- Toggle switches
- Iconos de close (X de modales, botones de eliminar fila)
- Items de listas seleccionables
- Filas de productos en grid
- Botones ± de cantidad

Cuando el elemento visual es más chico (icono de 16 px), el área activa se extiende vía `padding` o `Container` envolvente. **No usar `IconButton` con `iconSize` chico sin extender el `splashRadius` o el padding**.

Para componentes que ya están definidos en el design system, agregar test de widget que falle si el `Size` final del `RenderBox` es menor a 44×44.

### 4.6 DPI scaling y textScaler

**Dos sistemas de escalado independientes:**

1. **Windows display scaling** (100 %, 125 %, 150 %, 175 %): el sistema operativo multiplica el factor antes de entregar el viewport a Flutter. `MediaQuery.sizeOf` ya devuelve píxeles lógicos = físicos / scaling. Si los breakpoints usan `sizeOf`, todo cascadea solo (ver tabla en sección 3.2).

2. **`textScaler`** (factor 1.0 a 1.3× típicamente): independiente del scaling de OS. El cajero puede subir solo el texto vía Windows Accessibility sin cambiar layout. Widgets con altura fija deben usar `IntrinsicHeight` o `minHeight` para tolerar texto agrandado.

**Reglas duras:**

- Ningún widget calcula layout con `physicalSize`.
- Ningún widget hardcodea `textScaleFactor` ni envuelve un `MediaQuery` con `textScaler: TextScaler.linear(1.0)` para "estabilizar".
- Ninguna altura crítica está en literal absoluto — usar `IntrinsicHeight`, `minHeight`, o cálculo desde `TextStyle.fontSize`.

### 4.7 Patrones POS profesional para flujos transaccionales

Aplicables al modal de cobro, split bill, anulación, y cualquier flujo que involucre dinero o NCF. Estos patrones son lo que separa visualmente "app responsive" de "POS profesional":

- **Total visible siempre**: en header y footer del modal. El cajero debe poder leer el monto en cualquier momento sin scroll.
- **Input prominente para entrada principal**: el campo "Monto recibido" en cobro de efectivo debe ser visualmente más grande (altura 48 px, font 18 pt) que campos secundarios (NCF, propina). Es donde el dedo va primero en cada cobro.
- **Atajos de denominación**: botones rápidos `[Exacto] [200] [500] [1000] [2000]` arriba del campo "Monto recibido". Acelera el flujo más común. RD$ tiene un set fijo de denominaciones, hacer hardcoded sin overingeniería.
- **Estado disabled hasta válido**: "Confirmar pago" disabled mientras el monto recibido sea menor al total o inválido. Evita cobros parciales accidentales. Mensaje inline al lado del botón explicando por qué está disabled ("falta RD$ 100").
- **Estado loading durante procesamiento**: spinner inline en el botón + bloqueo de inputs durante procesamiento de tarjeta o impresión de NCF. No mostrar éxito hasta que la transacción esté confirmada por el provider.
- **Estado error explícito**: si la tarjeta es declinada o el NCF se agotó, mostrar mensaje en línea con el botón, no toast que se va. El cajero necesita ver el error mientras decide qué hacer (cambiar método de pago, reintentar, etc.).
- **Color de acción más allá del hue**: el botón "Confirmar pago" se distingue de "Cancelar" no solo por color sino por peso, posición, tamaño y posiblemente icono. El daltonismo afecta al ~5 % de cajeros hombres; un POS profesional no falla en ese caso.
- **NCF type siempre visible**: el tipo de NCF (Consumo Final / Crédito Fiscal / Gubernamental / Régimen Especial) debe estar visible en el modal de cobro, no oculto en un dropdown. Si el cliente pide cambiar el tipo después de tappear "Confirmar", el cajero debe poder hacerlo en un tap.

---

## 5. Fases

### F1 — Auditoría + sistema base (semana 1)

- **F1.1**: Auditoría completa con capturas en las **6 combinaciones** de la sección 3.2: 1280×720@100 %, 1366×768@100 %, 1366×768@125 %, 1920×1080@100 %, 1920×1080@125 %, 1920×1080@150 %. Cubre las 12 pantallas críticas. Documentar también auditoría de touch targets actuales (cuáles violan los 44 px). Output: tabla extendida en sección 3.1 + screenshots versionados.
- **F1.2**: Implementar `breakpoints.dart`, `sizes.dart`, `font_sizes.dart`. Agregar lint rule custom contra `MediaQuery.physicalSize` y `textScaleFactor: 1.0`. Wirear al ThemeData.
- **F1.3**: Migrar `SalesShellView` y sidebar a usar breakpoints (sidebar colapsable). Validar cascadeo DPI con monitor 1920 + Windows 150 %.

### F2 — Pantallas críticas P1 (semana 2)

- **F2.1**: Mesa con orden — botones acción + summary panel responsive. Validar touch targets ≥44 px.
- **F2.2**: Modal de cobro + split bill — fullscreen en compact con anatomía preservada. Implementar atajos de denominación, prominencia del input "Monto recibido", estados disabled/loading/error. Auditar plugins de impresión por si abren diálogos con tamaño fijo que rompen DPI.
- **F2.3**: Cocina/KDS — cards adaptativas con touch targets adecuados.
- **F2.4**: Smoke test manual en las **6 combinaciones**, fix follow-ups.

### F3 — Pantallas P2/P3 + edge cases (semana 3-4)

- **F3.1**: Reportes (tablas), configuración, productos.
- **F3.2**: Pop-ups, snackbars, toasts — verificar no se corten y respeten `textScaler` 1.3×.
- **F3.3**: Test en hardware real: PC del incidente actual (1366×768@100 %) + un monitor 1920×1080 con Windows en 150 % scaling. Sign-off del usuario y del cajero (no solo del dev/PM).
- **F3.4**: Documentar guidelines en `docs/RESPONSIVE_GUIDELINES.md` para que pantallas nuevas cumplan desde el día uno (incluye reglas de touch targets, prohibiciones, y patrones POS de sección 4.7).

---

## 6. Definition of Done

1. **Test matrix**: 0 mensajes de overflow (`A RenderFlex overflowed by ...px`) en debug log al recorrer las 12 pantallas críticas en las **6 combinaciones** de sección 3.2.
2. **Botones de acción** visibles y clickeables en las 6 combinaciones.
3. **Modal de cobro** funcional sin scroll vertical roto, con anatomía preservada en los 3 breakpoints.
4. **Tipografía**: mínimo 14 pt body en todos los breakpoints, máximo 28 pt display.
5. **textScaler**: pantallas críticas funcionan con `textScaler` hasta 1.3× sin overflow ni texto cortado.
6. **Touch targets**: 100 % de elementos tappables ≥44×44 px lógicos. Test de widget que falle si no.
7. **Lint rule** activa contra `MediaQuery.physicalSize` y similares. Build falla si alguien la introduce.
8. **Estados del modal de cobro** implementados y testeados: disabled (monto insuficiente), loading (procesando), error (tarjeta declinada / NCF agotado).
9. **Atajos de denominación** funcionando en cobro de efectivo.
10. **Capturas comparativas** before/after versionadas en `docs/responsive/`, una por cada combinación × pantalla crítica.
11. **PR de cierre** incluye lista chequeada por pantalla × combinación + sign-off de un cajero real.

---

## 7. Riesgos y mitigación

| Riesgo | Probabilidad | Mitigación |
|---|---|---|
| Romper layout actual al introducir breakpoints | Alta | Cambios feature-flagged por pantalla. PRs pequeños. Smoke test en cada merge. |
| Asumir que web/desktop comparten misma lógica que mobile | Media | Validar en cada plataforma antes de cierre F2. |
| Algún widget usa `physicalSize` y rompe DPI cascading | Media | Lint rule + grep manual en F1.2. Revisar plugins terceros (impresión, scanner, payment SDK). |
| Plugins de impresión/POS muestran diálogos con tamaño fijo que ignoran nuestro sistema | Media | Auditar en F2.2 cuando se toque cobro. Si rompen, envolver en wrapper propio o postergar y documentar como deuda. |
| Tipografía se ve mal en compact (muy chica) | Media | Mantener mínimo 14 pt body, 16 pt botones primarios. |
| Cambios afectan estabilidad de cobros (P0) | Baja-Media | Tests E2E manuales del flujo completo en cada combinación antes de DoD. Cobros tocados solo por UI, lógica intocable. |
| `textScaler` 1.3× rompe alturas hardcodeadas | Media | Auditar `height:` literales en F1.1. Reemplazar por `IntrinsicHeight` o `minHeight`. |
| Touch targets ≥44 px hacen que la UI se vea "más espaciada" y el cliente no le guste | Baja | Validar diseño con cliente al cierre de F1.3 antes de aplicar a todas las pantallas. |
| Estados loading/error del modal de cobro generan regresión en flujo feliz | Media | Asegurar que el estado idle es indistinguible del actual. Estados nuevos solo aparecen ante eventos específicos. |

---

## 8. Métricas

- **Pre-PRD baseline**: 7 pantallas con overflow en 1366×768@100 %; touch targets <44 px en al menos 4 componentes (ver F1.1 audit). DPI scaling 125 %/150 % no validado.
- **Post-PRD target**: 0 pantallas con overflow en cualquiera de las 6 combinaciones. 100 % touch targets ≥44×44 px. textScaler 1.3× tolerado en pantallas críticas. Modal de cobro con estados disabled/loading/error funcionales.
- **Time-to-install** en una PC nueva 1366×768@125 % (laptop típica de oficina con Windows scaling default): <30 min sin tener que justificar bugs visuales al cliente.
- **Reducción de tickets visuales** post-deploy: target -80 % vs. baseline trimestral.

---

## 9. Open questions

**Resueltas en v1.1:**

1. ~~¿El hardware POS típico del cliente es siempre 1366×768 o hay 1024×768 también?~~ → 1024×768 NO es target. Listado en non-goals.
2. ~~¿Soportar zoom del sistema (Windows display scaling 125 %/150 %)?~~ → SÍ, vía cascadeo automático con `MediaQuery.sizeOf`. Tabla en sección 3.2.
3. ~~¿Migrar a `flutter_screenutil` o quedarnos con MediaQuery puro?~~ → MediaQuery puro + tokens propios. Menos dependencia, control total.

**Nuevas:**

4. ¿Soportar pantallas táctiles capacitivas viejas con jitter (taps fantasma)? Si sí, agregar debounce 100 ms en taps de botones de cobro. Decidir en F2.2.
5. ¿Dual display (customer-facing screen para mostrar total)? Fuera de scope de este PRD pero hay que decidir si bloquea futuras versiones del PRD de hardware.
6. ¿Atajos de teclado (F-keys) para power users? Posible F3 stretch goal, no compromiso.
7. ¿Sound feedback en confirmación de cobro? POS profesionales suelen tener un "ding" al imprimir. Decidir con cajero en F3.3.

---

## 10. Notas de implementación

- Empezar por `Breakpoints` + `Insets` + lint rules antes de tocar UI. Sin esos tokens cualquier fix es ad-hoc.
- Cada pantalla migrada documenta su comportamiento por breakpoint en un comentario header.
- **Nunca** `MediaQuery.physicalSize` para layout decisions.
- **Nunca** hardcodear `textScaleFactor: 1.0` para "evitar problemas".
- **Nunca** `height: X` literal en widgets que muestren texto — usar `IntrinsicHeight` o `minHeight`.
- Touch targets siempre ≥44×44 lógicos. Cuando el ícono es chico, el padding extiende área activa.
- No tocar lógica de cobros, autenticación o impresión en este PRD — solo UI y layout.
- Para el modal de cobro, los estados nuevos (disabled/loading/error) deben ser aditivos: el estado idle debe ser pixel-perfect igual al actual para no introducir regresión.
- Smoke test en hardware real (no solo simuladores ni emuladores) es **obligatorio** antes de cerrar.
- Validar con cajero real (no solo con product/dev) antes de cerrar F2 — los patrones POS profesional son evaluables solo por quien usa el producto 8 horas al día.