# Programa de Estabilización Fiscal — MangoPOS

> Este folder contiene la documentación completa del programa de estabilización fiscal de MangoPOS, dividido en 3 PRDs ejecutables independientemente.

## Cómo usar este folder

**Empezá leyendo:** [`PROGRAM_OVERVIEW.md`](./PROGRAM_OVERVIEW.md)

Después, leé los PRDs en orden:

1. [`PRD_01_stop_the_bleeding.md`](./PRD_01_stop_the_bleeding.md) — 1 semana — empezá acá
2. [`PRD_02_refactor_motor.md`](./PRD_02_refactor_motor.md) — 4-5 semanas — solo después de PRD 1 + 1 semana de observación
3. [`PRD_03_reportes_migracion.md`](./PRD_03_reportes_migracion.md) — 2-3 semanas — solo después de PRD 2 + 1 semana de observación

## Resumen ejecutivo

**Problema:** MangoPOS tiene un bug fiscal activo en producción que afecta a 4-15 negocios piloto. El bug hace que el sistema muestre datos fiscales incorrectos (propinas fantasma, tasas hardcodeadas) por causa de tres sistemas paralelos calculando impuestos.

**Solución:** Programa de 3 fases en 11 semanas que:
1. Detiene el daño inmediato (PRD 1)
2. Unifica el motor de impuestos (PRD 2)
3. Limpia los reportes y datos históricos (PRD 3)

**Por qué dividido:** Un solo dev haciendo 9-10 semanas de refactor continuo es alto riesgo. Dividir en 3 PRDs reduce riesgo, entrega valor incremental, y permite pausa si hace falta.

## Reglas no-negociables del programa

1. **No saltar PRDs.** PRD 3 depende de PRD 2 que depende de PRD 1.
2. **1 semana mínima de observación entre PRDs.** No es opcional.
3. **Cada PRD se valida con la realidad antes de empezarse.** Los documentos viven, no son sagrados.
4. **Si algo se rompe, se revierte y se diagnostica.** No "lo arreglo en el siguiente commit".

## Estado actual

| PRD | Estado | Fecha objetivo |
|---|---|---|
| PRD 1 | Listo para ejecución | Semana 1 |
| PRD 2 | Draft (validar al iniciar) | Semanas 3-7 |
| PRD 3 | Draft (validar al iniciar) | Semanas 9-11 |

## Versión histórica

Este programa **reemplazó** al PRD único `MANGOPOS_TAX_ENGINE_PRD_v1.3` (archivado en `archived/`) cuando una auditoría profunda reveló que el alcance real era 9-10 semanas y que dividir en 3 entregas era más sano profesionalmente.

## Contacto

DRI: Cristian (creador y responsable del programa)
