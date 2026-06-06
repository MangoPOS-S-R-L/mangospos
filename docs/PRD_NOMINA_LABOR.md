# PRD — Módulo Labor + Nómina de MangoPOS (paridad Aloha / Toast Payroll)

> **Estado:** Borrador para revisión
> **Fecha:** 2026-06-05
> **Dueño de producto:** Cristian Gómez
> **Ámbito:** Añadir a MangoPOS un módulo de **gestión laboral** (fichaje/asistencia,
> horarios/turnos, propinas) y un **motor de nómina dominicana completo** (TSS, AFP,
> ISR retención asalariados, INFOTEP, regalía pascual, liquidaciones), cerrando la
> brecha con lo que Aloha (NCR) y Toast Payroll ofrecen en su mercado.

---

## 0. Decisiones de alcance (cerradas con el dueño de producto)

| # | Decisión | Resolución |
|---|---|---|
| D1 | Alcance del PRD | **Módulo Labor + Nómina** como unidad coherente y vendible. El resto de la "suite Aloha" (lealtad, gift cards, online ordering, inventario enterprise) queda en PRDs separados. |
| D2 | ¿MangoPOS calcula la nómina o solo exporta? | **Calcula la nómina dominicana completa** de forma nativa: TSS (SFS/AFP), SRL patronal, ISR retención, INFOTEP, regalía pascual, vacaciones, cesantía/preaviso. Este es el foso. |
| D3 | Manejo de propinas | **Solo registro individual** por empleado (sin pooling ni reparto automático en esta versión). Cada empleado acumula sus propias propinas; el reparto/pooling queda fuera de alcance inicial. |

---

## 1. Marco competitivo — de tú a tú con Aloha y Toast

La intención estratégica permanente de MangoPOS es **competir de tú a tú con Toast**
y desplazar a incumbentes legacy como **Aloha (NCR Voyix)** en su propio terreno
operativo, pero ganando por el flanco que ellos no cubren en RD/LatAm.

- **Aloha** tiene labor scheduling, time & attendance y reportería de labor muy
  maduros, pero su nómina real se delega a integradores y **no sabe nada de TSS,
  ISR ni regalía dominicana**. Para nómina RD necesita terceros caros.
- **Toast** vende "Toast Payroll & Team Management" como módulo premium integrado
  al POS — ése es exactamente el patrón a imitar: el POS ya conoce las horas, las
  ventas por empleado y las propinas, así que **la nómina sale del mismo dato**.
- **Diferenciador defensivo que ninguno tiene en RD:** cálculo de nómina dominicana
  **nativo y config-driven** (SDSS/TSS, DGII), más el **offline-first** ya construido.
  Un restaurante/colmado dominicano no puede correr Toast Payroll ni Aloha labor;
  sí puede correr MangoPOS. Ese es el foso.

**Regla de paridad:** el fichaje, los horarios y los volantes de pago deben sentirse
tan terminados como el flujo de caja/cocina existente. Si el dueño compara con
un software de nómina local (Inteligencia de Negocios, Sigma, Nómina Express), el
valor de MangoPOS es que **las horas y propinas ya están en el sistema** — no hay
doble digitación.

---

## 2. Resumen ejecutivo

MangoPOS ya tiene la mitad invisible del problema resuelta: existe la tabla
`employees` (con `user_id`, roles, PIN hasheado, roster offline cacheado por
`device_registrations`), el RBAC con permisos string, la atribución de ventas por
empleado (`order_opener_employee_id`, `sales_by_waiter`, multimesero) y las sesiones
de caja por usuario. **Lo que falta no es identidad de empleado, es el ciclo laboral
y el motor de cálculo:**

1. **Reloj de fichaje (time clock)** que registre entrada/salida desde la terminal
   POS, con el mismo PIN, **funcionando offline** (reusa roster + cola offline).
2. **Horarios/turnos** planificados y publicados.
3. **Propinas individuales** por empleado, capturadas en el cobro.
4. **Motor de nómina RD** config-driven que tome horas + salario base + propinas y
   calcule devengados, deducciones (TSS empleado, ISR), aportes patronales (SFS,
   AFP, SRL, INFOTEP) y **neto a pagar**, generando volantes PDF.
5. **Reportes regulatorios**: planilla TSS, retención DGII (IR-3/IR-13), regalía.
6. **Liquidaciones**: cesantía, preaviso, vacaciones, descargo.

Este PRD define el modelo de datos incremental, los feature flags, las fases de
entrega y los criterios de aceptación. Sigue la filosofía **config-driven** ya
adoptada en el módulo de impuestos: **ningún porcentaje ni escala se hardcodea**;
todo vive en una tabla de parámetros versionada por fecha de vigencia, editable por
el administrador y **firmable por el contador** (mismo patrón de gating que F4 NCF).

---

## 3. Dominio: nómina dominicana (modelo de referencia, NO hardcodear)

> ⚠️ **Estos valores son de referencia y deben vivir en `payroll_parameters`
> versionada por vigencia.** Las tasas, topes y escala ISR cambian por resolución
> y deben ser configurables y verificados con el contador antes de producción
> (gating tipo F4). El motor lee parámetros; nunca constantes en código.

### 3.1 Seguridad Social (SDSS / TSS) — descuento sobre salario cotizable

| Concepto | Aporte empleado | Aporte empleador | Tope (salario cotizable) |
|---|---|---|---|
| **SFS** — Seguro Familiar de Salud | ~3.04% | ~7.09% | hasta 10 salarios mínimos cotizables |
| **AFP** — Pensiones (vejez/discapacidad/sobrevivencia) | ~2.87% | ~7.10% | hasta 20 salarios mínimos cotizables |
| **SRL** — Seguro de Riesgos Laborales | — | ~1.10% (variable) | hasta 4 salarios mínimos cotizables |

- El **empleado** solo aporta SFS + AFP (~5.91% combinado, sujeto a topes).
- El **empleador** aporta SFS + AFP + SRL (costo patronal, no se descuenta al empleado).

### 3.2 INFOTEP

- Empleador: **1%** sobre el total de la nómina.
- Empleado: **0.5%** únicamente sobre **bonificaciones** (regalía/utilidades), no sobre el salario ordinario.

### 3.3 ISR — retención de asalariados (escala anual, parametrizable)

Base imponible = (salario bruto − aportes TSS del empleado) **anualizado**. Escala
progresiva de referencia (valores históricamente congelados; verificar vigencia):

| Renta neta anual (RD$) | Retención |
|---|---|
| Hasta 416,220.00 | Exento |
| 416,220.01 – 624,329.00 | 15% del excedente de 416,220.00 |
| 624,329.01 – 867,123.00 | 31,216.00 + 20% del excedente de 624,329.00 |
| Desde 867,123.01 | 79,776.00 + 25% del excedente de 867,123.00 |

La escala se almacena como JSON de tramos en `payroll_parameters` para poder
actualizarla sin desplegar código.

### 3.4 Regalía pascual (salario de Navidad / "13")

- = 1/12 de la suma de salarios ordinarios devengados en el año calendario.
- Pagadera antes del **20 de diciembre**.
- **Exenta de ISR y de TSS** (hasta el límite legal de exención de regalía para ISR).

### 3.5 Horas extras y recargos (Código de Trabajo)

- Jornada estándar **44 h/semana**.
- Horas extra hasta 68 h/semana: **+35%**.
- Horas que excedan 68 h/semana: **+100%**.
- Trabajo nocturno (≈9pm–7am): **+15%**.
- Domingos/feriados: reglas especiales.

### 3.6 Vacaciones y liquidación (al egreso)

- **Vacaciones:** 14 días tras 1 año; 18 días tras 5 años.
- **Preaviso** y **cesantía** (auxilio): escala por antigüedad (días de salario por
  año trabajado) en desahucio.

---

## 4. Modelo de datos (incremental, todo `business_id`-scoped + RLS)

Se construye **encima** de `employees`. No se crea una identidad de empleado paralela.

### 4.1 Identidad y compensación
- **`employee_compensation`** (1:1 con `employees`): `employee_id`, `business_id`,
  `tipo_pago` (`mensual` | `quincenal` | `semanal` | `por_hora`), `salario_base`,
  `tarifa_hora`, `fecha_ingreso`, `cargo`, `departamento`, `nss` (Nº Seguridad Social),
  `afp_id`, `ars_id`, `banco`, `cuenta`, `metodo_pago` (`efectivo`|`transferencia`),
  `estatus` (`activo`|`suspendido`|`egresado`), `fecha_egreso`.

### 4.2 Asistencia
- **`time_punches`**: `employee_id`, `business_id`, `device_id`, `clock_in`,
  `clock_out`, `break_minutes`, `cash_session_id` (nullable, link al cuadre),
  `horas_calculadas`, `origen` (`pos`|`manual`|`offline`), `estado`
  (`abierto`|`cerrado`|`editado`), `editado_por`, `created_offline_at`.
  *Debe poder crearse offline y sincronizar (reusa cola offline + roster).*

### 4.3 Horarios
- **`work_schedules`**: `employee_id`, `fecha`, `hora_inicio`, `hora_fin`,
  `rol_estacion`, `publicado` (bool), `notas`.
- **`schedule_templates`**: plantillas semanales reutilizables.

### 4.4 Propinas (registro individual — D3)
- **`tip_entries`**: `employee_id`, `business_id`, `order_id` (nullable),
  `cash_session_id` (nullable), `monto`, `metodo` (`efectivo`|`tarjeta`),
  `fecha`, `origen`. **Sin pooling**: cada propina pertenece a un único empleado.

### 4.5 Parámetros de nómina (config-driven, versionados)
- **`payroll_parameters`**: `business_id` (nullable = global/país), `vigencia_desde`,
  `sfs_emp`, `sfs_pat`, `afp_emp`, `afp_pat`, `srl_pat`, `infotep_pat`,
  `infotep_emp_bonif`, `tope_sfs`, `tope_afp`, `tope_srl`, `salario_minimo_cotizable`,
  `isr_escala_anual` (JSONB de tramos), `firmado_por`, `firmado_at`.
  *Patrón idéntico al modelo de impuestos config-driven; nada hardcodeado.*

### 4.6 Procesamiento de nómina
- **`payroll_periods`**: `business_id`, `tipo`, `fecha_inicio`, `fecha_fin`,
  `fecha_pago`, `estado` (`abierto`|`calculado`|`aprobado`|`pagado`|`contabilizado`).
- **`payroll_slips`** (volante/recibo, 1 por empleado por periodo): totales
  devengados, deducciones, aportes patronales, **neto**, `parametros_version`
  (snapshot del `payroll_parameters` usado — auditable e inmutable tras aprobar).
- **`payroll_slip_lines`**: `slip_id`, `concepto`, `tipo` (`devengado`|`deduccion`|
  `aporte_patronal`|`informativo`), `base`, `tasa`, `monto`.
- **`payroll_adjustments`**: avances, préstamos (con cuotas), deducciones recurrentes,
  otros ingresos por empleado.

### 4.7 Liquidaciones
- **`severance_calculations`**: `employee_id`, `causa` (`desahucio`|`despido`|
  `renuncia`|`mutuo`), `fecha_egreso`, desglose (preaviso, cesantía, vacaciones no
  disfrutadas, proporción de regalía, salarios pendientes), `total`.

---

## 5. RPCs / lógica de servidor (Supabase, `security definer`, scoping por business)

- `fn_clock_in(p_employee_id, p_device_token)` / `fn_clock_out(...)` — fichaje;
  validan PIN/device; idempotentes; tolerantes a llegada offline tardía.
- `fn_payroll_calculate(p_period_id)` — **motor central**: lee horas, salario,
  propinas y `payroll_parameters` vigentes → genera `payroll_slips` +
  `payroll_slip_lines`. **Idempotente** (recalcular reemplaza, no duplica).
- `fn_calc_isr(p_renta_neta_anual, p_param_version)` — helper escala progresiva.
- `fn_calc_tss(p_salario_cotizable, p_param_version)` — SFS/AFP/SRL con topes.
- `fn_payroll_approve(p_period_id)` / `fn_payroll_mark_paid(p_period_id)` — transición
  de estado; congela el snapshot de parámetros.
- `fn_severance(p_employee_id, p_causa, p_fecha_egreso)` — liquidación.

---

## 6. Integración con lo existente

| Punto | Reuso |
|---|---|
| Identidad/roles | `employees`, `user_business`, `roles` + permisos string |
| Fichaje offline | roster cacheado (`fn_sync_roster`), `device_registrations`, cola offline |
| Propinas / caja | `cash_sessions` (link `cash_session_id`), cuadre de efectivo |
| Costo laboral vs ventas | `sales_by_waiter`, `order_opener_employee_id` → reporte labor% sobre ventas |
| Volantes PDF | módulo de impresión/PDF existente (mismo pipeline que comprobantes) |
| Permisos nuevos | strings `nomina.*` y `labor.*` bajo el RBAC actual (ver §8) |

---

## 7. Feature flags

Un solo producto, gateado. Sugerido bajo `business` settings / plan:
- `labor_timeclock_enabled` — fichaje y horas.
- `labor_scheduling_enabled` — horarios/turnos.
- `labor_tips_enabled` — captura de propinas individuales.
- `payroll_enabled` — motor de nómina y volantes.
- `payroll_compliance_reports_enabled` — TSS/DGII/regalía (puede gatearse por plan superior).

---

## 8. Permisos (RBAC, nuevos strings)

- `labor.fichar` (cualquier empleado, propio), `labor.fichaje.editar` (manager+),
  `labor.horarios.ver` / `labor.horarios.editar` / `labor.horarios.publicar`,
  `labor.propinas.registrar` / `labor.propinas.ver`,
- `nomina.periodo.ver` / `nomina.periodo.calcular` / `nomina.periodo.aprobar` /
  `nomina.periodo.pagar`, `nomina.parametros.editar` (owner/admin),
  `nomina.reportes.ver`, `nomina.liquidacion.calcular`.

Default: fichaje propio para todos; cálculo/aprobación/parámetros solo owner/admin;
edición de fichaje y horarios para manager+.

---

## 9. Fases de entrega

| Fase | Entrega | Vendible por sí sola |
|---|---|---|
| **Fase 0** | Esquema base (tablas §4, `payroll_parameters` seed de referencia, RLS, migración + ROLLBACK). Sin UI. | No (cimiento) |
| **Fase 1** | **Reloj de fichaje** desde POS con PIN + cálculo de horas + **offline**. Vista de asistencia. | ✅ Control de asistencia |
| **Fase 2** | **Horarios/turnos** + plantillas + publicación. | ✅ Scheduling |
| **Fase 3** | **Propinas individuales** capturadas en cobro + reporte por empleado. | ✅ |
| **Fase 4** | **Motor de nómina RD** (devengados, TSS, ISR, INFOTEP, horas extra) + periodos + **volantes PDF**. | ✅ Nómina |
| **Fase 5** | **Reportes regulatorios**: planilla TSS, retención DGII (IR-3/IR-13), regalía pascual. | ✅ Cumplimiento |
| **Fase 6** | **Liquidaciones** (cesantía/preaviso/vacaciones) + préstamos/avances. | ✅ |

Patrón de migración por fase: `YYYYMMDD_NNNN_*.sql` + `_ROLLBACK.sql`, idempotente,
RLS desde el día 1 (igual que el resto del repo).

---

## 10. Criterios de aceptación

- **Fichaje:** un empleado ficha entrada/salida con su PIN en una terminal **sin
  internet**, y al reconectar el `time_punch` sincroniza sin duplicar ni perder horas.
- **Motor:** dado un salario base + horas + propinas + `payroll_parameters` vigentes,
  `fn_payroll_calculate` produce un volante cuyo SFS/AFP/ISR/INFOTEP/neto **coincide
  al centavo** con el cálculo manual del contador para casos de prueba acordados.
- **Idempotencia:** recalcular un periodo no calculado dos veces no duplica slips.
- **Auditoría:** un periodo aprobado conserva el snapshot de parámetros usado; cambiar
  `payroll_parameters` después no altera volantes ya aprobados.
- **Config-driven:** cambiar una tasa/escala en `payroll_parameters` (sin desplegar
  código) cambia el siguiente cálculo. Cero porcentajes hardcodeados en el código.
- **Regulatorio:** la planilla TSS y la retención DGII exportadas cuadran con la
  suma de los volantes del periodo.

---

## 11. Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| **Exactitud fiscal/legal** (errores en nómina = multas y conflictos laborales) | Todo config-driven + **gating de firma del contador** (patrón F4) antes de habilitar `payroll_enabled` en prod. Casos de prueba validados por contador. |
| Tasas/topes/escala cambian por resolución | `payroll_parameters` versionada por `vigencia_desde`; nunca constantes en código. |
| Fichaje offline duplicado o perdido | Idempotencia por device + ventana; reuso de la cola offline ya probada (F5/F6). |
| Datos sensibles (salarios, NSS, cuentas) | RLS estricta por `business_id` + permisos `nomina.*` restringidos a owner/admin; auditar acceso. |
| Alcance se desborda a "toda la suite Aloha" | Este PRD se limita a Labor + Nómina (D1). Lealtad/gift cards/online ordering = PRDs separados. |
| Propinas: expectativa de pooling | Documentado como fuera de alcance (D3). El esquema `tip_entries` no impide añadir pooling después sin migración destructiva. |

---

## 12. Métricas de éxito

- % de negocios con `labor_timeclock_enabled` que ficha ≥80% de turnos vía POS.
- Tiempo de cierre de nómina (objetivo: < 30 min para un negocio de 20 empleados).
- 0 discrepancias > RD$0.01 entre volante MangoPOS y validación del contador en casos certificados.
- Adopción de `payroll_enabled` como upsell de plan.

---

## 13. Fuera de alcance (esta versión)

- Pooling/reparto automático de propinas (solo registro individual — D3).
- Participación en beneficios/utilidades (10%) automatizada — puede ser Fase 7.
- Integración bancaria directa para dispersión de pagos (se exporta archivo).
- Biometría/huella para fichaje (solo PIN en v1).
- Nómina de otros países (motor es RD-específico; arquitectura config-driven deja la puerta abierta).
