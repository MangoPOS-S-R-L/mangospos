# PRD 7 — Evaluación del Status Actual

**Manejo de Datos en MangoPOS**

| | |
|---|---|
| **Producto** | MangoPOS |
| **DRI** | Cristian |
| **Duración estimada** | 1-2 semanas (no es proyecto de implementación) |
| **Fecha** | Mayo 2026 |
| **Estado** | Draft |

---

## 1. Propósito y Alcance

Este PRD define un ejercicio de evaluación del estado actual del manejo de datos en MangoPOS. El entregable **no es código en producción** — es un conjunto de reportes diagnósticos que permiten tomar decisiones informadas sobre qué implementar después.

Hoy MangoPOS opera con 15 negocios sobre Supabase self-hosted en Coolify. El stack tiene capacidad sobrada en recursos físicos (CPU 20%, RAM 27%, disco 40/200GB). Sin embargo, hay zonas grises críticas que no se han auditado de manera estructurada: integridad multi-tenant a nivel de queries, eficiencia de índices, salud de RLS por tabla, peso real de Storage, comportamiento de queries en producción, y cobertura de backups verificados.

Tomar decisiones de optimización, escalamiento o refactor sin haber hecho esta evaluación lleva a optimizar lo equivocado. Este PRD cierra ese vacío en 1-2 semanas de trabajo concentrado en auditoría, **sin tocar producción** más allá de queries de lectura y comandos diagnósticos.

### 1.1 Out of scope (explícito)

- Implementar mejoras detectadas. Eso es trabajo del PRD siguiente, alimentado por los hallazgos de este.
- Refactor de código del cliente Flutter. Solo auditoría de queries con grep/análisis estático.
- Migración de Storage a R2 o cualquier proveedor. Solo medición del estado actual.
- Cambios de schema. Solo lectura del schema vigente.
- Auditoría fiscal/DGII (NCFs, 606/607). Merece su propio PRD por la complejidad regulatoria.

### 1.2 Entregables esperados

Al finalizar este PRD, Cristian debe tener en su poder los siguientes artefactos, cada uno fechado y con evidencia (queries ejecutados, output de comandos, screenshots cuando aplique):

- **Reporte de Integridad Multi-Tenant:** tabla por tabla, estado de `business_id`, RLS y policies.
- **Reporte de Storage:** tamaño total, distribución por negocio, top de carpetas pesadas.
- **Reporte de Performance Postgres:** top 20 queries por tiempo y por frecuencia, índices usados vs muertos.
- **Reporte de Realtime:** inventario de canales y suscripciones por dominio.
- **Reporte de Backups:** estado, frecuencia, último restore probado, RTO/RPO real.
- **Resumen Ejecutivo** con código de semáforo por dimensión y top 5 acciones recomendadas para el PRD siguiente.

### 1.3 Convenciones del checklist

Cada ítem se marca con uno de tres estados al cerrarse:

| Estado | Significado | Acción de seguimiento |
|---|---|---|
| ✅ OK | Verificado y bien | Ninguna. Anotar la evidencia (query, output, screenshot) en el reporte de la sección. |
| ⚠️ OBS | Existe con observaciones | Documentar la observación en lenguaje claro. No es bloqueador hoy pero es deuda técnica conocida. |
| ❌ FAIL | No existe o está roto | Documentar el riesgo concreto y agregar al top 5 de acciones recomendadas del resumen ejecutivo. |

---

## 2. Fase 1 — Integridad Multi-Tenant

**Duración estimada:** 2 días. Es la auditoría con mayor asimetría riesgo/esfuerzo. Un solo agujero detectado aquí justifica el PRD completo.

### 2.1 Sub-fase 1A — Inventario de tablas

#### Checklist

- [ ] Listar todas las tablas del schema `public`.
- [ ] Clasificar cada tabla en uno de los dominios: ventas, productos, fiscal, operativo, telemetría, multimedia, lookup.
- [ ] Para cada tabla, registrar tamaño en disco y conteo de filas aproximado.
- [ ] Identificar tablas "huérfanas" sin dominio claro (potencial deuda técnica).

#### Query base

```sql
SELECT
  schemaname, tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
  n_live_tup AS approx_rows
FROM pg_stat_user_tables
WHERE schemaname='public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

#### Definition of Done — 1A

- [ ] Hoja de cálculo o tabla en el reporte con todas las tablas, dominio asignado, tamaño y filas.
- [ ] Tablas huérfanas marcadas con justificación de por qué existen o decisión de evaluarlas para drop.

### 2.2 Sub-fase 1B — Auditoría de `business_id`

#### Checklist

- [ ] Verificar para cada tabla de dominio de negocio si tiene columna `business_id`.
- [ ] Verificar que `business_id` es `NOT NULL` (un NULL es agujero de aislamiento).
- [ ] Verificar que `business_id` tiene FK al catálogo de negocios.
- [ ] Verificar el `ON DELETE` de la FK (debe ser `RESTRICT` en la mayoría de casos, nunca `CASCADE` en tablas transaccionales).
- [ ] Documentar excepciones legítimas (catálogos globales, lookup tables como países, monedas, etc.).

#### Query base

```sql
SELECT t.table_name,
       EXISTS (SELECT 1 FROM information_schema.columns c
               WHERE c.table_schema='public' AND c.table_name=t.table_name
                 AND c.column_name='business_id') AS tiene_business_id,
       (SELECT is_nullable FROM information_schema.columns c
        WHERE c.table_schema='public' AND c.table_name=t.table_name
          AND c.column_name='business_id') AS nullable
FROM information_schema.tables t
WHERE t.table_schema='public' AND t.table_type='BASE TABLE'
ORDER BY tiene_business_id, t.table_name;
```

#### Definition of Done — 1B

- [ ] Tabla en el reporte con columnas: nombre de tabla, tiene `business_id`, nullable, tiene FK, `ON DELETE`, estado (OK/OBS/FAIL).
- [ ] Lista de excepciones documentadas y justificadas.
- [ ] Tablas con `business_id` nullable o sin FK marcadas como FAIL con descripción del riesgo.

### 2.3 Sub-fase 1C — Auditoría de RLS

#### Checklist

- [ ] Listar todas las tablas con `rowsecurity = true`.
- [ ] Confirmar que toda tabla con `business_id` tiene RLS habilitada.
- [ ] Listar todas las policies y revisar el `USING` y `WITH CHECK` de cada una.
- [ ] Detectar policies con `USING (true)` o equivalente.
- [ ] Verificar que las policies filtran por `business_id` correctamente, no por `user_id` o algún otro proxy.
- [ ] **Test manual:** crear un usuario de test en negocio A, intentar leer datos de negocio B desde SQL client autenticado, confirmar que devuelve 0 filas.

#### Queries base

```sql
-- Tablas con RLS
SELECT schemaname, tablename, rowsecurity, forcerowsecurity
FROM pg_tables
WHERE schemaname='public'
ORDER BY rowsecurity, tablename;

-- Policies activas
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies
WHERE schemaname='public'
ORDER BY tablename, policyname;
```

#### Definition of Done — 1C

- [ ] Inventario de policies con análisis de cada una.
- [ ] Test manual de aislamiento ejecutado con resultado documentado.
- [ ] Cualquier policy con `USING (true)` o sin filtro de `business_id` marcada FAIL.

### 2.4 Sub-fase 1D — Auditoría de queries del cliente

#### Checklist

- [ ] Grep en el codebase Flutter por todas las llamadas a Supabase: `supabase.from`, `client.from`, `.select(`, `.insert(`, `.update(`, `.delete(`.
- [ ] Para cada hit, evaluar si el query incluye filtro explícito por `business_id` o si solo depende de RLS.
- [ ] Clasificar: **A)** tiene filtro explícito, **B)** confía solo en RLS, **C)** caso de catálogo global legítimo.
- [ ] Documentar los hits de categoría B como deuda técnica accionable.

#### Definition of Done — 1D

- [ ] Lista de queries clasificados con archivo y línea.
- [ ] Conteo de queries en cada categoría.
- [ ] Si hay queries categoría B, recomendación de regla de código y review process para prevenir nuevas.

---

## 3. Fase 2 — Storage y Multimedia

**Duración estimada:** 1 día. Objetivo: saber exactamente cuánto pesa el Storage hoy, cómo está distribuido entre negocios, y si las fotos están optimizadas.

### 3.1 Sub-fase 2A — Tamaño y distribución

#### Checklist

- [ ] SSH al VPS de Coolify.
- [ ] Identificar el volumen Docker del Storage de Supabase.
- [ ] Medir tamaño total del Storage.
- [ ] Listar top 20 carpetas/buckets más pesados.
- [ ] Para los 3 negocios más pesados, contar archivos y obtener tamaño promedio.
- [ ] Calcular ratio: si el promedio por foto > 200 KB, hay un problema claro de optimización.

#### Comandos base

```bash
docker volume ls | grep supabase
docker inspect $(docker ps -q --filter "name=storage") | grep -A 5 Mounts
du -sh /path/al/storage/
du -sh /path/al/storage/* | sort -h | tail -20

# Para un negocio específico:
find /path/al/storage/negocio-X -type f | wc -l
du -sh /path/al/storage/negocio-X
```

#### Definition of Done — 2A

- [ ] Reporte con: tamaño total, distribución por negocio (top 10), tamaño promedio por foto en los top 3 negocios.
- [ ] Proyección de crecimiento estimado al ritmo actual.
- [ ] Estado: OK si promedio < 200 KB, OBS si entre 200-500 KB, FAIL si > 500 KB.

### 3.2 Sub-fase 2B — Cobertura de optimización en el cliente

#### Checklist

- [ ] Revisar el código del cliente Flutter en la ruta de subida de fotos.
- [ ] Identificar si existe compresión o resize previo al upload.
- [ ] Si existe, documentar parámetros (dimensiones target, calidad JPEG, etc.).
- [ ] Si no existe, marcar FAIL — es el ítem de mayor ROI inmediato.
- [ ] Verificar si hay límites de tamaño en el cliente (rechazo de archivos muy grandes).

#### Definition of Done — 2B

- [ ] Documentar el flujo actual de upload de fotos paso a paso.
- [ ] Estado: OK si hay compresión razonable, OBS si hay compresión pero parámetros muy permisivos, FAIL si no hay nada.

### 3.3 Sub-fase 2C — Archivos huérfanos

#### Checklist

- [ ] Listar archivos en Storage que no tienen referencia en la tabla de productos (u otras tablas que apunten a Storage).
- [ ] Estimar cuánto espacio ocupan los huérfanos.
- [ ] Si es significativo (>5% del total), planificar limpieza.

#### Definition of Done — 2C

- [ ] Conteo y tamaño de archivos huérfanos.
- [ ] Recomendación de limpieza si aplica.

---

## 4. Fase 3 — Performance de Postgres

**Duración estimada:** 2-3 días, incluyendo 48-72 horas de espera para acumular datos significativos en `pg_stat_statements`.

### 4.1 Sub-fase 3A — Setup de `pg_stat_statements`

#### Checklist

- [ ] Verificar que `pg_stat_statements` está instalado: `SELECT * FROM pg_extension WHERE extname='pg_stat_statements';`.
- [ ] Si no está, habilitarlo en `shared_preload_libraries` y reiniciar Postgres.
- [ ] Resetear estadísticas para empezar desde cero limpio: `SELECT pg_stat_statements_reset();`.
- [ ] Anotar fecha y hora del reset.
- [ ] Esperar 48-72 horas con uso normal de los 15 negocios.

#### Definition of Done — 3A

- [ ] `pg_stat_statements` activo y reseteado en fecha conocida.
- [ ] Confirmación de uso normal durante la ventana de captura (no fin de semana sin actividad).

### 4.2 Sub-fase 3B — Análisis de queries top

#### Checklist

- [ ] Top 10 queries por `total_exec_time` (las que más tiempo consumen acumulado).
- [ ] Top 10 queries por `mean_exec_time` (las que más tardan individualmente).
- [ ] Top 10 queries por `calls` (las que se llaman más veces — sospechosas de N+1).
- [ ] Para cada query del top, identificar a qué pantalla o funcionalidad corresponde.
- [ ] Hacer `EXPLAIN ANALYZE` de las queries más críticas para ver si usan índices.

#### Query base

```sql
SELECT
  substring(query, 1, 100) AS short_query,
  calls,
  total_exec_time::int AS total_ms,
  mean_exec_time::numeric(10,2) AS mean_ms,
  rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

#### Definition of Done — 3B

- [ ] Tres tablas con top 10 cada una, mapeadas a funcionalidad del producto.
- [ ] Lista de queries problemáticas identificadas con descripción del problema.

### 4.3 Sub-fase 3C — Auditoría de índices

#### Checklist

- [ ] Listar todos los índices de las tablas grandes (>10K filas).
- [ ] Verificar que cada tabla grande con `business_id` tiene índice donde `business_id` es primera columna.
- [ ] Detectar índices muertos (`idx_scan = 0` después de varios días de uso).
- [ ] Detectar índices duplicados (mismo conjunto de columnas).
- [ ] Detectar tablas grandes sin índice en columnas usadas en filtros frecuentes.

#### Queries base

```sql
-- Índices muertos
SELECT schemaname, relname AS tabla, indexrelname AS indice,
       idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS tamano
FROM pg_stat_user_indexes
WHERE idx_scan = 0 AND schemaname='public'
ORDER BY pg_relation_size(indexrelid) DESC;

-- Tablas grandes sin índice en business_id como primera columna
SELECT t.tablename
FROM pg_tables t
WHERE t.schemaname='public'
  AND NOT EXISTS (
    SELECT 1 FROM pg_indexes i
    WHERE i.tablename=t.tablename
      AND i.indexdef LIKE '%(business_id%'
  );
```

#### Definition of Done — 3C

- [ ] Lista de índices muertos con tamaño en disco.
- [ ] Lista de tablas grandes sin índice apropiado en `business_id`.
- [ ] Lista de índices duplicados.

---

## 5. Fase 4 — Realtime

**Duración estimada:** 1 día. Objetivo: inventario de uso de Realtime y detección de canales globales sin filtro fino.

### 5.1 Sub-fase 4A — Inventario de canales

#### Checklist

- [ ] Grep en codebase Flutter por: `.channel(`, `supabase.realtime`, `.on(`, `postgresChanges`, `broadcastChanges`.
- [ ] Para cada suscripción documentar: tabla escuchada, filtro aplicado, momento de subscribe, momento de unsubscribe.
- [ ] Identificar suscripciones globales sin filtro de `business_id`.
- [ ] Identificar suscripciones que no se desuscriben correctamente en `dispose()`.

#### Definition of Done — 4A

- [ ] Tabla con todas las suscripciones encontradas y sus parámetros.
- [ ] Lista de canales potencialmente problemáticos (sin filtro o sin dispose).

### 5.2 Sub-fase 4B — Validación en producción

#### Checklist

- [ ] Si Supabase Realtime expone métricas, capturar conteo de canales activos en hora pico.
- [ ] Estimar canales activos por negocio promedio.
- [ ] Validar contra objetivo: <10 canales por sesión de usuario activa.

#### Definition of Done — 4B

- [ ] Métrica de canales activos por negocio en hora pico documentada.
- [ ] Estado: OK si <10, OBS si 10-25, FAIL si >25.

---

## 6. Fase 5 — Backups y Resiliencia

**Duración estimada:** 1-2 días. Objetivo: validar que los backups no son solo configuración sino que realmente permiten restaurar.

### 6.1 Sub-fase 5A — Inventario de backups configurados

#### Checklist

- [ ] Identificar qué backups automáticos están corriendo en Coolify (Postgres, Storage, configuración).
- [ ] Verificar frecuencia y horario de cada uno.
- [ ] Verificar destino: ¿están en el mismo VPS o externalizados?
- [ ] Si están solo en el mismo VPS, marcar FAIL — caída del VPS = pérdida total.
- [ ] Verificar política de retención de backups (cuántos días, cuántas versiones).

#### Definition of Done — 5A

- [ ] Tabla con cada tipo de backup, frecuencia, destino, retención.
- [ ] Fallos claros marcados (ej: backup solo local).

### 6.2 Sub-fase 5B — Restore real probado

#### Checklist

- [ ] Levantar un Supabase secundario en ambiente staging (puede ser un `docker-compose` temporal).
- [ ] Restaurar el backup más reciente a ese ambiente.
- [ ] Medir tiempo total del restore (= RTO real, no teórico).
- [ ] Validar que los datos están íntegros: `SELECT COUNT(*)` de tablas clave, validar últimas ventas, validar fotos.
- [ ] Documentar el procedimiento paso a paso como runbook (no genérico, los pasos exactos).

#### Definition of Done — 5B

- [ ] Restore ejecutado exitosamente al menos una vez.
- [ ] RTO real documentado en minutos/horas.
- [ ] RPO real documentado (cuánta data se hubiera perdido en un escenario real, según frecuencia de backup).
- [ ] Runbook escrito y guardado en lugar accesible.

---

## 7. Fase 6 — Resumen Ejecutivo y Priorización

**Duración estimada:** 0.5 días. Cierre del PRD. Consolidación de hallazgos en un solo lugar que sirva de input directo para el siguiente PRD de implementación.

### 7.1 Checklist final

- [ ] Compilar todos los reportes de las fases 1-5 en un solo documento.
- [ ] Asignar estado de semáforo a cada dimensión: 🟢 OK, 🟡 OBS, 🔴 FAIL.
- [ ] Identificar el top 5 de hallazgos más críticos.
- [ ] Para cada hallazgo del top 5, esbozar acción correctiva (sin entrar en detalle de implementación, solo el qué).
- [ ] Estimar esfuerzo grueso (horas/días) por acción correctiva.
- [ ] Decidir cuáles van al próximo PRD de implementación y cuáles pueden esperar.

### 7.2 Formato del Resumen Ejecutivo

| Dimensión | Estado | Hallazgo principal |
|---|---|---|
| Integridad multi-tenant | _(pendiente)_ | _Resumen 1-2 frases._ |
| RLS y policies | _(pendiente)_ | _Resumen 1-2 frases._ |
| Storage y multimedia | _(pendiente)_ | _Resumen 1-2 frases._ |
| Performance Postgres | _(pendiente)_ | _Resumen 1-2 frases._ |
| Realtime | _(pendiente)_ | _Resumen 1-2 frases._ |
| Backups y restore | _(pendiente)_ | _Resumen 1-2 frases._ |

### 7.3 Definition of Done — Fase 6

- [ ] Documento consolidado de evaluación entregado y archivado junto a los PRDs anteriores.
- [ ] Tabla resumen con semáforo completa.
- [ ] Top 5 hallazgos críticos con acción correctiva propuesta.
- [ ] Decisión registrada de qué entra al siguiente PRD de implementación.

---

## 8. Cronograma Sugerido

| Día | Fase | Actividad | Entregable parcial |
|---|---|---|---|
| 1 | Fase 1 | Inventario de tablas + auditoría `business_id` | Reporte 1A + 1B |
| 2 | Fase 1 | Auditoría RLS + auditoría queries del cliente | Reporte 1C + 1D |
| 3 | Fase 2 | Storage: tamaño, distribución, optimización | Reporte Fase 2 completo |
| 3 | Fase 3A | Reset de `pg_stat_statements` | Inicio de ventana de captura |
| 4-5 | Fase 4 | Realtime: inventario y validación | Reporte Fase 4 completo |
| 4-6 | Fase 5 | Backups: inventario + restore real probado | Reporte Fase 5 + runbook |
| 6 | Fase 3B-3C | Análisis de queries y auditoría de índices | Reporte Fase 3 completo |
| 7 | Fase 6 | Consolidación + Resumen Ejecutivo | Documento final del PRD |

El cronograma asume 2-3 horas diarias de trabajo concentrado, compatible con el trabajo paralelo en PRD 5 (printing), WFM Zillow y universidad. La Fase 3 está distribuida porque requiere ventana de captura de 48-72h en producción antes de analizar; mientras esa ventana corre, se avanza con las fases 4 y 5.

### 8.1 Compromiso mínimo aceptable

Si el calendario se aprieta y solo hay tiempo para una porción de este PRD, el orden de corte por valor es:

- **Fase 1 completa (días 1-2):** es el corazón del ejercicio. Sin esto, no hay PRD.
- **Fase 5 completa (restore real probado):** es la otra mitad crítica. Backups que no se han restaurado son ficción.
- **Fase 2 (Storage):** rápida y de alto valor accionable.
- **Fase 3 (Performance):** valiosa pero puede esperar.
- **Fase 4 (Realtime):** puede esperar al PRD de implementación.
