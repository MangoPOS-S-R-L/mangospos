# Programa de Estabilización Fiscal — MangoPOS

| Campo | Valor |
|---|---|
| **Programa** | Estabilización del Motor de Impuestos |
| **Producto** | MangoPOS |
| **Versión del documento** | 1.0 |
| **Fecha** | 2026-04-26 |
| **Autor** | Cristian (DRI) |
| **Estado** | Aprobado para ejecución |
| **Reemplaza a** | `archived/MANGOPOS_TAX_ENGINE_PRD_v1.3_DEPRECATED.md` |

---

## Tabla de Contenidos

1. [Por qué este programa existe](#1-por-qué-este-programa-existe)
2. [Arquitectura del programa](#2-arquitectura-del-programa)
3. [Los tres PRDs](#3-los-tres-prds)
4. [Timeline integrado](#4-timeline-integrado)
5. [Dependencias entre PRDs](#5-dependencias-entre-prds)
6. [Criterios de éxito del programa](#6-criterios-de-éxito-del-programa)
7. [Riesgos del programa](#7-riesgos-del-programa)
8. [Decisión: por qué 3 PRDs en vez de 1](#8-decisión-por-qué-3-prds-en-vez-de-1)
9. [Governance y revisión](#9-governance-y-revisión)

---

## 1. Por qué este programa existe

MangoPOS tiene un bug fiscal **activo en producción** afectando a 4-15 negocios piloto. El bug se manifiesta de dos formas:

1. **Propina fantasma en cuentas:** el sistema cobra propina aunque no esté configurada
2. **Reporte fiscal con tasa hardcodeada:** el reporte muestra `service_fee_rate: 10%` independientemente de la configuración real

La causa raíz es estructural: existen **tres sistemas paralelos** calculando propina en el código (frontend, backend RPCs, sistema de reportes), cada uno con sus propios defaults silenciosos y heurísticas implícitas.

Inicialmente este trabajo se planificó como un solo proyecto de 5 semanas. Una auditoría profunda del código y schema reveló que el alcance real era de 9-10 semanas de refactor continuo — un riesgo inaceptable para un solo desarrollador trabajando sin staging probado y sin equipo de revisión.

**La decisión arquitectónica fue dividir el trabajo en tres PRDs entregables independientemente**, cada uno con valor propio, riesgo controlado, y posibilidad de pausa entre fases.

---

## 2. Arquitectura del programa

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│   PRD 1: STOP-THE-BLEEDING                                       │
│   ├─ Duración: 1 semana                                          │
│   ├─ Riesgo: Bajo                                                │
│   ├─ Objetivo: Detener el daño inmediato sin tocar arquitectura  │
│   └─ Entregable: Sistema sin defaults peligrosos, fail-loud      │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼  [+1 semana de observación]
                              │
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│   PRD 2: REFACTOR DEL MOTOR DE IMPUESTOS                         │
│   ├─ Duración: 4-5 semanas                                       │
│   ├─ Riesgo: Alto                                                │
│   ├─ Objetivo: Modelo unificado, una sola fuente de verdad       │
│   └─ Entregable: Backend y frontend con un solo motor coherente  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼  [+1 semana de observación]
                              │
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│   PRD 3: REPORTES Y MIGRACIÓN DE DATOS                           │
│   ├─ Duración: 2-3 semanas                                       │
│   ├─ Riesgo: Medio                                               │
│   ├─ Objetivo: Reportes refactorizados + datos históricos OK     │
│   └─ Entregable: Sistema fiscal completo, sin deuda heredada     │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘

Total programa: ~9 semanas de trabajo + 2 semanas de observación = 11 semanas
```

---

## 3. Los tres PRDs

### PRD 1 — Stop-the-bleeding

**Documento:** `PRD_01_stop_the_bleeding.md`

**Objetivo:** Detener el daño fiscal inmediato a operadores piloto sin refactorizar arquitectura.

**Entregables:**
- Eliminación del hardcode `'service_fee_rate': 10.0` en reports_repository
- Eliminación de defaults `_defaultTaxRatePct` y `_defaultServiceFeeRatePct` en sales_viewmodel
- Implementación de fail-loud cuando la configuración fiscal falla
- Bloqueo de pago si la configuración no está disponible
- Tests dorados básicos del comportamiento actual (red de seguridad para PRD 2)
- Drop de trigger duplicado en `order_items`

**Lo que NO hace:**
- Refactor del motor de cálculo
- Cambios al schema de DB
- Migración de datos
- Modelo unificado de impuestos

**Tiempo:** 5 días full-time. **Riesgo:** Bajo. **Reversible:** Sí.

### PRD 2 — Refactor del motor de impuestos

**Documento:** `PRD_02_refactor_motor.md`

**Objetivo:** Eliminar las tres rutas paralelas de cálculo de propina y consolidar en un modelo unificado.

**Entregables:**
- Consolidación de `calculate_order_totals` y `calculate_check_totals` en función única
- Eliminación de lectura de `business_settings.service_fee_*` (deprecación)
- Limpieza de CASE statements con valores que no existen en el enum `order_origin`
- Eliminación de fallbacks de 10% en `fn_add_item_from_menu`
- Modelo unificado: solo `taxes` con `is_service_fee` deprecado en frontend
- Decisión sobre `self_service` (pospuesta hasta implementación)
- Tests dorados completos del nuevo motor
- Creación de tabla `order_item_tax_lines`
- Estandarización de precisión (2 decimales)

**Lo que NO hace:**
- Refactor de UI de reportes
- Backfill de datos históricos
- Eliminación de columnas legacy de `business_settings`

**Tiempo:** 4-5 semanas full-time. **Riesgo:** Alto. **Reversible:** Sí (con backup).

### PRD 3 — Reportes y migración de datos

**Documento:** `PRD_03_reportes_migracion.md`

**Objetivo:** UI de reportes refactorizada + migración completa de datos históricos al modelo unificado.

**Entregables:**
- Refactor de `reports_repository` para leer de `taxes` y `order_item_tax_lines`
- Refactor de `tax_report_view` para mostrar líneas dinámicas
- Backfill de `order_item_tax_lines` para órdenes históricas
- Migración: `service_fee → tax` en `orders` y `order_checks`
- DROP de columnas deprecadas en `business_settings`
- Eliminación de columnas legacy (`original_tax_rate`, etc.)

**Tiempo:** 2-3 semanas full-time. **Riesgo:** Medio. **Reversible:** Parcial (con backup).

---

## 4. Timeline integrado

```
Semana 1:           PRD 1 ejecución completa            [5 días]
Semana 2:           Observación post PRD 1              [5 días]
Semanas 3-7:        PRD 2 ejecución                     [25 días]
Semana 8:           Observación post PRD 2              [5 días]
Semanas 9-11:       PRD 3 ejecución                     [10-15 días]
Semana 12:          Observación post PRD 3              [5 días]
Semanas 13-16:      Estabilización background           [observación pasiva]
Semana 17:          Cleanup final (DROP COLUMN)         [1 día]
```

**Hitos del programa:**

| Hito | Semana | Criterio |
|---|---|---|
| H1 | Fin semana 1 | PRD 1 deployado, sin defaults peligrosos en producción |
| H2 | Fin semana 2 | Sin regresiones detectadas en observación de PRD 1 |
| H3 | Fin semana 7 | PRD 2 deployado, motor unificado en producción |
| H4 | Fin semana 8 | Sin regresiones de PRD 2 |
| H5 | Fin semana 11 | PRD 3 deployado, datos migrados |
| H6 | Semana 17 | Cleanup completado, deuda fiscal cerrada |

---

## 5. Dependencias entre PRDs

### PRD 1 → PRD 2

**Dependencias duras (PRD 2 no puede empezar sin):**
- Tests dorados del PRD 1 funcionando (red de seguridad)
- Fail-loud implementado (necesario para detectar bugs durante PRD 2)
- 1 semana mínima de observación post PRD 1

**Dependencias blandas (recomendable pero no bloqueante):**
- Documentación de comportamiento actual completada
- Métricas de línea base capturadas

### PRD 2 → PRD 3

**Dependencias duras:**
- `order_item_tax_lines` creada (PRD 2 lo crea, PRD 3 lo consume)
- Motor unificado deployado y estable
- 1 semana mínima de observación post PRD 2

**Dependencias blandas:**
- Métricas del motor nuevo capturadas
- Decisión sobre `self_service` tomada (si aplica)

### PRD 1 → PRD 3 (sin paso por PRD 2)

**No es válido.** PRD 3 depende del modelo unificado del PRD 2. **No se puede saltar el PRD 2.**

---

## 6. Criterios de éxito del programa

### Métricas duras (medibles al final)

| # | Métrica | Objetivo |
|---|---|---|
| M1 | Cuentas con propina cuando no debería haberla | 0 |
| M2 | Reportes que muestran tasa hardcodeada | 0 |
| M3 | Defaults numéricos en código | 0 |
| M4 | Funciones que calculan propina paralelamente | 1 (consolidada) |
| M5 | Tests dorados pasando | 100% |
| M6 | Diferencia entre suma de checks y total de orden | 0 (tolerancia ±0.01) |
| M7 | Pagos bloqueados por config rota | Investigados al 100% |

### Métricas blandas (cualitativas)

- Operadores piloto reportan que los reportes "se ven bien" (encuesta post PRD 3)
- Cualquier dev nuevo puede entender el motor en menos de 30 minutos leyendo el código
- Agregar un impuesto nuevo requiere 0 cambios de código

### Criterios de fallo del programa

El programa se considera **fallido** si al final:
- Sigue habiendo defaults numéricos en cualquier path de cálculo
- Hay más de un sistema calculando propina en paralelo
- Los reportes pueden mostrar valores que no coincidan con `orders.total`

---

## 7. Riesgos del programa

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| Solo dev se queda sin energía hacia PRD 3 | Alta | Medio | Observación entre PRDs no es opcional. Permite descanso real. |
| Bug introducido en PRD 1 se descubre durante PRD 2 | Media | Alto | 1 semana de observación entre PRDs. Tests dorados capturan regresión. |
| PRD 2 dura más de 5 semanas | Media | Medio | Si llega a 6 semanas, parar y reevaluar. No empujar más allá. |
| Operador piloto se queja durante observación | Media | Bajo | Comunicación previa: "Estamos haciendo cambios, podés notar mejoras incrementales." |
| Migración de PRD 3 corrompe datos | Baja | Crítico | Backup obligatorio. Probado en staging. Rollback documentado. |
| Aparece un cuarto sistema oculto que afecta cálculos | Media | Alto | Cada PRD incluye auditoría inicial. Si aparece, se reevalúa el plan. |

---

## 8. Decisión: por qué 3 PRDs en vez de 1

Esta decisión se documentó formalmente. Las razones:

### 8.1 Reduce riesgo

Un solo dev haciendo 9-10 semanas de refactor continuo sobre un sistema fiscal en producción tiene alta probabilidad estadística de fallar a mitad de camino. Dividir en 3 entregas reduce el blast radius de cualquier error.

### 8.2 Entrega valor incrementalmente

PRD 1 ya soluciona el bug **visible** a operadores en 1 semana. No tienen que esperar 9-10 semanas para ver mejoras. Es lo que un PM senior llamaría "shipping early, shipping often".

### 8.3 Permite calibración

Después del PRD 1, podemos medir cómo se comportó. Si introdujo problemas no previstos, los arreglamos antes del PRD 2. Si funcionó perfecto, podemos ajustar el alcance del PRD 2 con confianza.

### 8.4 Permite parar

Si por alguna razón (motivos personales, oportunidad de WFM, lo que sea) tenés que pausar después del PRD 1 o PRD 2, **el sistema queda en un estado coherente**. Si fuera un solo PRD de 9 semanas y parás en la 5, el sistema queda peor que al inicio.

### 8.5 Permite revertir

Cada PRD tiene su propio rollback plan. Revertir uno no afecta a los otros. En un proyecto monolítico, revertir significa perder todo el trabajo.

### 8.6 Reduce carga cognitiva

Un PRD de 9 semanas con 30 archivos afectados es difícil de mantener mentalmente para un solo dev. Tres PRDs de scope acotado son manejables.

### 8.7 Mejora la calidad de cada entregable

Cuando sabés que vas a pausar y observar entre fases, **te tomás más tiempo en hacer cada entrega bien**. No hay presión de "tengo que llegar a la semana 9".

---

## 9. Governance y revisión

### 9.1 Quién aprueba qué

- **Cristian (DRI)** aprueba cada PRD antes de iniciarse
- Cada PRD tiene su propia versión y se versiona en git
- Cambios significativos al alcance generan nueva versión del PRD afectado

### 9.2 Cuándo se revisa el programa

- **Después de cada PRD:** retrospectiva de 1 día
- **Al final de cada observación:** decisión go/no-go formal antes del siguiente PRD
- **Al final del programa:** post-mortem completo

### 9.3 Cuándo se rediseña el programa

Si durante la ejecución descubrimos algo que invalida el plan (como pasó con la auditoría que generó este programa), **se pausa, se redocumenta, se redecide**. La improvisación no es aceptable en un proyecto fiscal P0.

### 9.4 Comunicación a operadores piloto

| Momento | Mensaje |
|---|---|
| Antes de PRD 1 | "Vamos a hacer ajustes técnicos. Pueden notar que algunas operaciones se bloquean temporalmente si la configuración no está completa — es intencional." |
| Después de PRD 1 | "Listo, ajustes aplicados. Si algo no funciona, avisame inmediatamente." |
| Antes de PRD 2 | "Próximas 5 semanas vamos a renovar el motor fiscal. Pueden notar mejoras en consistencia de cuentas. Avisanos cualquier irregularidad." |
| Antes de PRD 3 | "Última fase: vamos a actualizar los reportes. Pueden ver cambios en cómo se muestran los números, pero los totales no cambian." |

---

## 10. Decision Log del programa

| # | Fecha | Decisión | Razón |
|---|---|---|---|
| PD-1 | 2026-04-26 | Dividir el trabajo en 3 PRDs en vez de 1 | Reduce riesgo, entrega valor incrementalmente, permite pausa |
| PD-2 | 2026-04-26 | 1 semana mínima de observación entre PRDs | Sin observación, los bugs del PRD anterior se confunden con los del siguiente |
| PD-3 | 2026-04-26 | PRD 1 deploya antes de tocar arquitectura | El stop-the-bleeding tiene urgencia diferente al refactor |
| PD-4 | 2026-04-26 | Posponer decisión sobre `self_service` origin | Hoy es stub; cualquier decisión es especulativa |
| PD-5 | 2026-04-26 | El PRD anterior v1.3 se archiva, no se borra | Trazabilidad histórica de decisiones |
| PD-6 | 2026-04-26 | Cada PRD tiene su propio Decision Log | Decisiones técnicas viven en el PRD donde se aplican |

---

## 11. Próximos pasos

Para iniciar el programa:

1. **Leer y aprobar este documento** completo
2. **Leer y aprobar PRD 1** (`PRD_01_stop_the_bleeding.md`)
3. **Validar prerrequisitos:** ambiente staging, backups probados (ver sección "Antes de empezar" en PRD 1)
4. **Empezar PRD 1**

PRD 2 y PRD 3 se aprueban formalmente cuando llegue su turno, no ahora. Los documentos existen para que el plan completo sea visible, pero **cada PRD se valida con la realidad del momento en que se ejecuta**.

---

*Documento del programa generado el 2026-04-26.*
*Próxima revisión: post-PRD 1, semana 2.*
