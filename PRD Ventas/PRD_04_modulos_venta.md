# PRD 4 — Unificación de Modos de Venta (Zone / Manual / Quick)

| Campo | Valor |
|---|---|
| **Programa** | Estabilización Fiscal MangoPOS |
| **PRD** | 4 de 4 |
| **Versión** | 1.0 |
| **Fecha** | 2026-04-28 |
| **Autor** | Cristian (DRI) |
| **Estado** | Listo para ejecución |
| **Prioridad** | P1 (no bloqueante de operación pero crítico para piloto) |
| **Esfuerzo estimado** | 3-5 días full-time |
| **Riesgo** | Medio |

---

## Tabla de Contenidos

1. [Executive Summary](#1-executive-summary)
2. [Antes de empezar (prerrequisitos)](#2-antes-de-empezar-prerrequisitos)
3. [Goals y Non-Goals](#3-goals-y-non-goals)
4. [Plan por fases](#4-plan-por-fases)
5. [Test Plan](#5-test-plan)
6. [Rollout Plan](#6-rollout-plan)
7. [Rollback Plan](#7-rollback-plan)
8. [Risks](#8-risks)
9. [Open Questions](#9-open-questions)
10. [Definition of Done](#10-definition-of-done)
11. [Decision Log](#11-decision-log)

---

## 1. Executive Summary

PRD 1, 2 y 3 unificaron el motor fiscal y el sistema de reportes. **El motor unificado vive en producción y funciona correctamente para Venta por Zona (mesa).**

Este PRD ataca la **última deuda funcional**: los modos **Venta Manual** y **Venta Rápida** están a medio implementar. Sus paths del frontend no enganchan correctamente con el motor unificado del PRD 2, lo que produce:

- Tickets que no se envían a cocina.
- Cobros que fallan por "no hay secuencia fiscal activa".
- Cálculos de impuestos inconsistentes con lo que muestra Venta por Zona.

**Cambio principal:** Venta Manual y Venta Rápida deben tener **exactamente las mismas features** que Venta por Zona, con dos diferencias de flujo:

| Modo | Flujo | Tiene mesa? |
|---|---|---|
| **Zona** (existe) | Mesa → productos → cocina → cobro | Sí, al inicio |
| **Manual** (a completar) | Productos → mesa → cocina → cobro | Sí, al final |
| **Quick** (a completar) | Productos → cocina → cobro | No, nunca |

**Resultado esperado:** un solo motor de venta con 3 puntos de entrada distintos. El operador puede vender desde cualquier modo con la misma garantía fiscal y operativa.

---

## 2. Antes de empezar (prerrequisitos)

- [x] PRD 1 y PRD 2 cerrados con motor unificado en producción
- [x] Branch `prd/01-stop-the-bleeding-frontend-wip` mergeado a main (o el branch activo tiene todo el código)
- [ ] Branch dedicado `prd/04-modulos-venta` creado
- [ ] Comunicación a operadores piloto: "Venta Manual y Rápida estarán intermitentes esta semana mientras completamos features"
- [ ] Datos podridos del PRD 2 (8 LEY duplicados) **NO bloquean** este PRD pero conviene conocerlos al testear

---

## 3. Goals y Non-Goals

### 3.1 Goals

**G1.** Venta Quick puede **enviar a cocina** (genera comanda igual que mesa).

**G2.** Venta Quick puede **cobrar** (genera NCF, registra pago, imprime ticket fiscal).

**G3.** Venta Manual puede agregar productos **antes** de seleccionar mesa, y al cobrar pide la mesa.

**G4.** Venta Manual puede enviar a cocina y cobrar igual que mesa.

**G5.** Los 3 modos (Zone, Manual, Quick) usan **el mismo motor de cálculo fiscal** (PRD 2: `fn_add_item_from_menu`, `fn_recalc_totals`, `order_item_tax_lines`).

**G6.** Los 3 modos comparten el mismo `sales_viewmodel.dart` y el mismo `currentOrderProvider`. Los paths divergen sólo en la UI y en los puntos de entrada/salida del flujo (selección de mesa).

**G7.** Eliminar paths paralelos del frontend que no usan la RPC unificada (si existen).

**G8.** Tests dorados que cubren los 3 modos lado a lado para evitar regresiones futuras.

### 3.2 Non-Goals

**N1.** **No** se rediseña la UI de Venta por Zona (esa funciona).

**N2.** **No** se cambia el motor fiscal del backend (PRD 2 ya cerró eso).

**N3.** **No** se ataca el cleanup de los 8 LEY duplicados (eso queda en backlog operativo o PRD 3).

**N4.** **No** se implementa `self_service` (sigue siendo fail-loud, decisión OQ2-1 del PRD 2).

**N5.** **No** se cambia el modelo de impuestos (`is_service_fee` queda como está hasta PRD 3).

**N6.** **No** se hace migración de órdenes históricas (regla "no tocar historia" sigue vigente).

---

## 4. Plan por fases

### F4.1 — Investigación (0.5 día)

Mapear el código actual lado a lado:

- ¿Qué features tiene Venta por Zona hoy? (UI, viewmodel, repo)
- ¿Qué features tiene Venta Manual hoy? ¿Qué falta?
- ¿Qué features tiene Venta Rápida hoy? ¿Qué falta?
- ¿Hay paths paralelos que no usan `fn_add_item_from_menu`?
- ¿Cómo se inicia el flujo en cada modo? (`_openManualOrQuick`, etc.)

**Output:** documento `Sales-Module-PRD4/f4.1_gap_analysis.md` con tabla feature × modo y lista de cambios concretos.

**Go/No-Go:** sin gap analysis claro, no se avanza a F4.2.

### F4.2 — Diseño (0.5 día)

Decidir cómo unificar los paths. Opciones:

- **A**: Misma view, mismo viewmodel, parámetro de modo.
- **B**: Views distintas, mismo viewmodel.
- **C**: Refactor mayor para extraer un controller común.

**Output:** sección de "Cambios técnicos" agregada al PRD 4. Mock-up textual del flujo unificado.

**Go/No-Go:** la decisión de arquitectura debe ser revisada con el DRI antes de implementar.

### F4.3 — Construcción Quick (1.5 día)

Implementar las features faltantes en venta rápida en este orden:

1. Selección de productos desde menú (si no funciona ya).
2. Cálculo de impuestos vía `fn_add_item_from_menu` (eliminar paths paralelos).
3. Envío a cocina (impresión de comanda).
4. Cobro con NCF.
5. Impresión de ticket fiscal.
6. Reset de estado al pagar (próxima venta).

**Output:** Quick funcional end-to-end. Smoke test manual + golden tests.

**Go/No-Go:** Quick debe poder cobrar y enviar a cocina sin errores antes de pasar a manual.

### F4.4 — Construcción Manual (1 día)

Manual = Quick + paso adicional de selección de mesa al cobrar. Reutilizar lo de F4.3.

**Output:** Manual funcional end-to-end con paso de mesa.

**Go/No-Go:** Manual debe permitir agregar productos sin mesa, y al pagar pedir mesa con dropdown/picker.

### F4.5 — Tests + Analyze (0.5 día)

- Golden tests para cada modo (zone, manual, quick).
- `flutter analyze` limpio sobre los archivos tocados.
- Test de regresión: Venta por Zona sigue funcionando idéntico (no se rompió nada).

**Output:** suite de tests verde + analyze 0 errors/warnings nuevos.

### F4.6 — Smoke test + commit + deploy (0.5 día)

- Probar los 3 modos en la app local.
- Commit con mensaje descriptivo (incluir referencias al PRD).
- Push al branch del PRD 4.
- PR a main.
- Deploy a piloto.

---

## 5. Test Plan

### 5.1 Tests dorados

**Archivo nuevo:** `test/sales/modes_unification_test.dart`

```dart
group('PRD 4 — Modos de venta unificados', () {
  test('Q1: Quick agrega producto y calcula totales correctos', () {});
  test('Q2: Quick envía a cocina genera comanda', () {});
  test('Q3: Quick cobra genera NCF y ticket fiscal', () {});
  test('M1: Manual permite agregar productos sin mesa', () {});
  test('M2: Manual pide mesa al cobrar', () {});
  test('M3: Manual hereda totales calculados al asignar mesa', () {});
  test('Z1 (regresión): Zona sigue funcionando idéntico', () {});
});
```

### 5.2 UAT manual

| Caso | Pasos | Esperado |
|---|---|---|
| UAT-Q1 | Iniciar venta rápida, agregar 1 producto, cobrar | Total correcto, NCF impreso, comanda enviada |
| UAT-Q2 | Iniciar venta rápida, agregar 2 productos, dividir cuenta, cobrar cada parte | Cobro correcto por check |
| UAT-M1 | Iniciar venta manual, agregar productos, intentar cobrar sin mesa | Bloqueo con "Selecciona una mesa" |
| UAT-M2 | Iniciar venta manual, agregar productos, asignar mesa, cobrar | Total correcto, NCF impreso |
| UAT-Z1 (regresión) | Hacer una venta normal por mesa | Idéntico a antes del PRD 4 |

---

## 6. Rollout Plan

### Día 1
- F4.1 Investigación + F4.2 Diseño.
- Branch `prd/04-modulos-venta` creado.

### Día 2-3
- F4.3 Quick implementación.
- Smoke test Quick.

### Día 4
- F4.4 Manual implementación.
- Smoke test Manual.

### Día 5
- F4.5 Tests + F4.6 Deploy.
- PR a main.
- Deploy a 1 negocio piloto, observación 4 horas, deploy resto.

---

## 7. Rollback Plan

PRD 4 es 100% frontend (no toca SQL). Rollback es trivial:

```bash
git revert <commit>
```

Y redeploy. Riesgo cero de pérdida de datos. El motor backend sigue funcionando idéntico.

---

## 8. Risks

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| El refactor rompe Venta por Zona | Media | Alto | Test Z1 (regresión) obligatorio antes de PR |
| Manual y Quick siguen sin coincidir con Zona en algún caso edge | Media | Medio | Tests dorados que cubren los 3 modos lado a lado |
| Datos podridos (8 LEY duplicados) confunden al testear | Alta | Bajo | Documentar; usar productos linkeados a 1 sola configuración |
| Operadores piloto venden mientras se hace el refactor | Alta | Bajo | Comunicación pre-deploy + ventana de despliegue acotada |

---

## 9. Open Questions

**OQ4-1.** RESUELTA (2026-04-28): **A** — al seleccionar mesa después del pedido, la session se reasigna y la orden "se convierte en una mesa" (mismo flujo que zona desde ese punto).

**OQ4-2.** RESUELTA (2026-04-28): **B** — Quick permite venta con RNC y comprobantes fiscales igual que zona. La diferencia es sólo en el flujo de inicio (sin paso de mesa).

**OQ4-3.** RESUELTA (2026-04-28): **A** — Quick permite split bill exactamente como zona.

**Alcance final del PRD 4:** Paridad completa con Zona en los 3 modos. No es MVP, es construcción profesional.

---

## 10. Definition of Done

PRD 4 se considera completado cuando:

- [ ] Quick puede cobrar end-to-end (NCF + comanda + ticket).
- [ ] Manual puede agregar productos sin mesa y cobrar al asignar mesa.
- [ ] Los 3 modos usan el mismo motor (`fn_add_item_from_menu`, `fn_recalc_totals`).
- [ ] Tests dorados de §5.1 pasan al 100%.
- [ ] UAT de §5.2 ejecutado con éxito.
- [ ] `flutter analyze` 0 errores/warnings nuevos.
- [ ] Deploy a producción completado sin rollback.
- [ ] 48 horas de observación sin regresiones reportadas.

---

## 11. Decision Log

| # | Fecha | Decisión | Razón |
|---|---|---|---|
| AD4-1 | 2026-04-28 | Quick antes que Manual en orden de implementación | Quick es más simple (sin paso mesa). Si funciona, Manual = Quick + paso adicional. |
| AD4-2 | 2026-04-28 | Mismo motor backend para los 3 modos | Coherencia con PRD 2. Evita re-introducir paths paralelos. |
| AD4-3 | 2026-04-28 | NO atacar `is_service_fee` cleanup acá | Eso es PRD 3. PRD 4 es construcción de features, no cleanup de modelo. |

---

*PRD 4 generado el 2026-04-28.*
