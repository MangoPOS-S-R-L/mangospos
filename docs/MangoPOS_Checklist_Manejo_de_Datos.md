# Checklist — Manejo de Datos de MangoPOS

> **Contexto:** MangoPOS sobre Supabase self-hosted en Coolify, 15 negocios piloto, VPS con holgura (CPU 20%, RAM 27%, disco 40/200GB). DRI único: Cristian. Horizonte: próximos 3 meses.
>
> **Criterio de orden:** ROI (impacto / esfuerzo), no cronología. Ítems al tope son donde poco trabajo previene o resuelve más dolor. Cada bloque tiene su prioridad asignada: 🔴 hacer ya, 🟡 hacer este mes, 🟢 hacer este trimestre, ⚪ planificado / decisión pendiente.

---

## Bloque 0 — Higiene crítica de integridad (🔴 hacer ya)

> **Por qué primero:** un solo agujero aquí compromete los 15 negocios y arreglarlo después es exponencialmente más caro que verificarlo ahora. Es trabajo de auditoría, no de implementación pesada.

### 0.1 Auditoría de `business_id` en todas las tablas

- [ ] Listar todas las tablas de dominio de negocio en Supabase (excluir `auth.*`, `storage.*`, `realtime.*`, `_prisma_migrations`, etc.).
- [ ] Para cada tabla, verificar que tiene columna `business_id`.
- [ ] Verificar que `business_id` está como `NOT NULL` (un NULL aquí es un agujero de seguridad).
- [ ] Verificar que `business_id` tiene FK al catálogo de negocios con `ON DELETE` definido explícitamente (restrict, no cascade).
- [ ] Documentar excepciones legítimas (catálogos globales, lookup tables) en un solo lugar.

**Query útil para auditar:**
```sql
SELECT table_name,
       EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name=t.table_name
                 AND column_name='business_id') AS tiene_business_id
FROM information_schema.tables t
WHERE table_schema='public' AND table_type='BASE TABLE'
ORDER BY 1;
```

### 0.2 Auditoría de RLS

- [ ] Listar tablas con RLS habilitada vs deshabilitada (`pg_class.relrowsecurity`).
- [ ] Para cada tabla con `business_id`, confirmar que RLS está habilitada.
- [ ] Listar todas las policies activas y verificar que filtran por `business_id` correctamente.
- [ ] Detectar policies con `USING (true)` o equivalente — son agujeros.
- [ ] Probar con cuenta de test de un negocio que NO puede ver datos de otro (test manual con SQL client).

**Query útil para auditar:**
```sql
SELECT schemaname, tablename, rowsecurity, forcerowsecurity
FROM pg_tables
WHERE schemaname='public'
ORDER BY rowsecurity, tablename;
```

### 0.3 Auditoría de queries del cliente Flutter

- [ ] Script grep / search en el codebase Flutter buscando `supabase.from(...)` o `client.from(...)`.
- [ ] Para cada hit, verificar que tiene filtro explícito por `business_id` (no depender solo de RLS).
- [ ] Marcar como deuda técnica los que solo dependen de RLS y crear ticket para arreglar.
- [ ] Documentar la regla en el README del proyecto: "Todo query a Supabase debe incluir `business_id` explícito".

### 0.4 Backups con restore probado (no solo configurado)

- [ ] Verificar que Coolify está haciendo backup automático de Postgres.
- [ ] Verificar destino del backup (NO debe estar solo en el mismo VPS — si se cae el VPS, se va todo).
- [ ] **Hacer un restore real** a un Supabase secundario o local. Sin esto, los backups son ficción.
- [ ] Documentar el procedimiento de restore como runbook (pasos concretos, no genéricos).
- [ ] Verificar que el backup incluye Storage (las fotos), no solo Postgres.
- [ ] Definir RTO (cuánto tarda restaurar) y RPO (cuánta data pierdo) y dejar registrados.

---

## Bloque 1 — Optimización de fotos en upload (🔴 hacer ya)

> **Por qué tan arriba:** es trabajo de una tarde con impacto 40-50x en consumo de storage. Detiene la sangría hacia adelante. Sin esto, todo lo demás de Storage es trabajo de Sísifo.

### 1.1 Auditoría del estado actual del Storage

- [ ] SSH al VPS de Coolify.
- [ ] Identificar el volumen del Storage de Supabase:
  ```bash
  docker volume ls | grep supabase
  docker inspect $(docker ps -q --filter "name=storage") | grep -A 5 Mounts
  ```
- [ ] Tamaño total del Storage: `du -sh /path/al/storage/`.
- [ ] Top 20 carpetas/buckets más pesados: `du -sh /path/al/storage/* | sort -h | tail -20`.
- [ ] Identificar los 2-3 negocios que concentran la mayoría del espacio.
- [ ] Registrar baseline: GB totales, GB por negocio top, número aproximado de fotos.

### 1.2 Implementar optimización en el cliente Flutter (upload)

- [ ] Agregar `flutter_image_compress` (o equivalente) a `pubspec.yaml`.
- [ ] Definir target: 800x800px max, JPEG calidad 80 (≈80-150 KB por foto).
- [ ] Wrapper en el repositorio de productos: toda foto pasa por compresión antes de subir.
- [ ] UI feedback: mostrar "comprimiendo..." si la foto original es grande.
- [ ] Definir límites duros: rechazar archivos >10 MB pre-compresión.
- [ ] Tests manuales: subir foto de 4 MB → verificar que llega a Storage con ~100 KB.
- [ ] Deploy a producción y monitorear consumo de Storage durante 7 días para confirmar baja del ritmo de crecimiento.

### 1.3 Política de fotos por negocio (preventiva)

- [ ] Definir límite de fotos por producto (recomendado: 1-3).
- [ ] Definir tamaño máximo aceptado pre-optimización (recomendado: 5 MB).
- [ ] Implementar en cliente Flutter el rechazo claro con mensaje al dueño del negocio.
- [ ] Documentar la política en el manual de uso de MangoPOS.

---

## Bloque 2 — Auditoría e índices de performance (🟡 hacer este mes)

> **Por qué aquí:** ataca el 70% del dolor de performance (capa de datos). Es trabajo de medición primero y luego ajustes quirúrgicos, no rewrite.

### 2.1 Activar y revisar `pg_stat_statements`

- [ ] Verificar que `pg_stat_statements` está habilitado en la Postgres de Supabase.
- [ ] Resetear estadísticas para empezar desde cero: `SELECT pg_stat_statements_reset();`.
- [ ] Esperar 48-72h de uso real en producción.
- [ ] Sacar top 10 por `total_exec_time` y por `mean_exec_time`.
- [ ] Sacar top 10 por `calls` (queries que se llaman demasiadas veces → posible N+1).
- [ ] Para cada uno: ¿se justifica esa frecuencia o esa duración?

### 2.2 Índices sobre `business_id`

- [ ] Listar tablas grandes (>10K filas).
- [ ] Para cada una, verificar que tiene índice con `business_id` como primera columna.
- [ ] Para tablas con queries frecuentes filtrados por `business_id` + otra columna (ej: `business_id + created_at` en ventas), crear índice compuesto.
- [ ] Después de crear índices, correr `VACUUM ANALYZE` sobre las tablas afectadas.
- [ ] Verificar mejora con `EXPLAIN ANALYZE` antes y después en queries representativos.

### 2.3 Detectar índices muertos o duplicados

- [ ] Query a `pg_stat_user_indexes` para ver índices nunca usados (`idx_scan = 0`).
- [ ] Evaluar drop de índices muertos (cuidado: pueden ser necesarios para queries puntuales como reportes).
- [ ] Buscar índices duplicados (mismo conjunto de columnas) y eliminar redundancias.

### 2.4 Refactor de queries N+1 en el cliente Flutter

- [ ] Identificar pantallas que listan entidades con relaciones (ej: ventas con items, mesas con cuentas).
- [ ] Refactorizar a un solo query con joins de PostgREST: `select('*, items(*), customer(*)')`.
- [ ] Medir reducción de queries por pantalla con `pg_stat_statements` antes/después.
- [ ] Documentar el patrón en el README como regla.

### 2.5 Paginación obligatoria

- [ ] Listar todas las pantallas que listan datos (productos, ventas, clientes, etc.).
- [ ] Para cada una: ¿usa `range()` o `infinite_scroll_pagination`?
- [ ] Si carga "todo" al abrir, refactorizar a paginación (50-100 items por página).
- [ ] Caso especial: productos en grilla de venta — si el negocio típico tiene <500 productos, está bien cargar todo (pero entonces cachear local). Si tiene >500, paginar o usar búsqueda.

---

## Bloque 3 — Realtime con filtros y control de canales (🟡 hacer este mes)

> **Por qué aquí:** Realtime mal usado es uno de los cuellos de botella más silenciosos. Aún con CPU baja en el servidor, demasiados canales degradan latencia de eventos para todos.

### 3.1 Inventario de suscripciones Realtime

- [ ] Buscar en el codebase Flutter todas las llamadas a `.channel(...)` o `.on(...)`.
- [ ] Para cada una documentar: ¿qué tabla escucha?, ¿con qué filtro?, ¿en qué momento se suscribe y cuándo se desuscribe?
- [ ] Identificar canales globales sin filtro de `business_id` (son los más caros).

### 3.2 Filtros finos por `business_id`

- [ ] Refactorizar suscripciones globales a filtradas: `filter: 'business_id=eq.X'`.
- [ ] Validar que el filtro funciona (cambios de otros negocios no llegan al cliente).

### 3.3 Ciclo de vida de los canales

- [ ] Verificar que cada `subscribe()` tiene su `unsubscribe()` correspondiente en `dispose()` del widget/provider.
- [ ] Auditar que no se suscriben canales duplicados al cambiar de pantalla y volver.
- [ ] Métrica objetivo: un negocio activo no debería tener más de 5-10 canales abiertos simultáneos.

### 3.4 Validar comportamiento en producción

- [ ] Levantar herramienta para ver canales activos por usuario (Supabase logs o tooling propio).
- [ ] Confirmar que el conteo está dentro del objetivo.

---

## Bloque 4 — Cloudflare delante de Storage (🟡 hacer este mes)

> **Por qué aquí:** trabajo de configuración, no de código. Reduce drásticamente la carga sobre el VPS al servir fotos y mejora la experiencia del cliente Flutter. Casi gratis si ya tienes Cloudflare en el stack.

### 4.1 Configurar cache de Storage en Cloudflare

- [ ] Identificar el subdominio que sirve las URLs públicas de Supabase Storage.
- [ ] Crear regla de cache en Cloudflare: cachear agresivamente assets de Storage (TTL alto, ej: 30 días).
- [ ] Configurar correctamente los headers `Cache-Control` desde Supabase Storage (immutable para fotos con hash en el nombre).
- [ ] Validar con `curl -I` que las respuestas tienen `cf-cache-status: HIT` después del primer fetch.

### 4.2 Estrategia de URLs de fotos

- [ ] Decidir si las URLs incluyen un hash o versión en el path (permite cache eternal sin problemas de invalidación).
- [ ] Si una foto se reemplaza, generar nueva URL (no sobrescribir el mismo archivo).
- [ ] Documentar la estrategia.

### 4.3 Métricas de hit rate

- [ ] Después de 7-14 días en producción, revisar el cache hit rate en Cloudflare Analytics.
- [ ] Objetivo: >90% hit rate para Storage.
- [ ] Si está más bajo, revisar headers y reglas.

---

## Bloque 5 — Capa de cache local con drift/SQLite (🟢 hacer este trimestre)

> **Por qué aquí:** alto ROI a largo plazo (la app se siente instantánea, funciona offline, reduce carga sobre Supabase), pero requiere 2-3 semanas de trabajo bien hecho. Vale la pena, pero solo después de que la sangría de Storage esté contenida y los queries básicos estén optimizados.

### 5.1 Decisión de scope: qué dominios cachear

- [ ] Listar dominios candidatos: productos, categorías, clientes, mesas, configuración del negocio, modificadores, impuestos.
- [ ] Priorizar por: frecuencia de lectura vs frecuencia de cambio. Lo que se lee mucho y cambia poco es el mejor candidato (productos, categorías, configuración).
- [ ] **NO cachear** lo que requiere consistencia fuerte multi-dispositivo en tiempo real (mesas abiertas, ventas en curso, sesión de caja activa).
- [ ] Documentar la decisión y rationale.

### 5.2 Diseño técnico

- [ ] Elegir entre `drift` (recomendado por tipado fuerte y queries en Dart) y `sqflite` (más bare metal).
- [ ] Diseñar el patrón stale-while-revalidate: UI lee del cache inmediato, en background sincroniza con Supabase, notifica al UI si hay cambios.
- [ ] Diseñar la estrategia de invalidación: ¿pull cada N minutos? ¿push por Realtime? ¿híbrido?
- [ ] Decidir comportamiento offline: ¿solo lectura cacheada? ¿escrituras encoladas? ¿límite de tiempo offline?

### 5.3 Implementación incremental

- [ ] Empezar por un dominio: productos (el de mayor ROI inmediato).
- [ ] Implementar repositorio que usa cache primero, Supabase después.
- [ ] Medir tiempo de carga de la grilla de productos antes/después.
- [ ] Iterar a los siguientes dominios priorizados.

### 5.4 Migration safety

- [ ] Plan de migración del schema de SQLite local (cuando agregas columnas, etc.).
- [ ] Comportamiento si el cliente Flutter tiene una versión de schema y el servidor otra (forzar update, refresh full, etc.).
- [ ] Testing en dispositivos reales antes de release.

---

## Bloque 6 — Retención y limpieza de datos (🟢 hacer este trimestre)

> **Por qué aquí:** no urge hoy con 15 negocios pero la deuda crece silenciosa. Definir las políticas ahora cuesta poco; implementarlas más tarde con tablas de millones de filas duele.

### 6.1 Definir política de retención por tipo de dato

- [ ] **Telemetría / logs** (heartbeats del PRD 6, healthchecks): retención corta (30-90 días).
- [ ] **Eventos efímeros** (sesiones, OTPs, tokens expirados): purga inmediata o muy corta (días).
- [ ] **Transaccionales** (ventas, items, pagos): retención fiscal según ley DR (mínimo 10 años para fiscales).
- [ ] **Maestros** (productos, clientes): no se purgan, se marcan como inactivos (soft delete).
- [ ] **Backups antiguos**: retención de 30-90 días para diarios, 1 año para mensuales.

### 6.2 Implementación de purga

- [ ] Crear funciones SQL o jobs (pg_cron) que purgan datos según política.
- [ ] Para tablas grandes con purga frecuente, considerar particionamiento por fecha.
- [ ] Documentar y monitorear que las purgas se ejecutan (no fallar silenciosamente).

### 6.3 Archivado de datos viejos

- [ ] Para datos transaccionales que ya no se consultan activamente pero hay que conservar (>2 años), evaluar archivado a tabla separada o a bucket.
- [ ] Esto es planificación para más adelante (>50 negocios), pero dejar la decisión documentada.

---

## Bloque 7 — Decisiones estratégicas pendientes (⚪ decidir pronto, ejecutar después)

> **Por qué aquí:** son decisiones que no urgen pero que conviene tomar con la cabeza fría antes de que el contexto cambie. Documentar la decisión cuenta como ítem hecho, aunque la implementación venga después.

### 7.1 Estrategia de Storage a 6-12 meses

- [ ] Evaluar opciones documentadas: disco local (hasta ~50 negocios con optimización), Cloudflare R2 (sin egress fees), Backblaze B2, Supabase Cloud Storage.
- [ ] **Decisión tentativa registrada en conversaciones previas:** Cloudflare R2 si el stack crece o el VPS empieza a apretarse.
- [ ] Trigger de migración: definir umbral concreto (ej: "cuando Storage supere 60 GB" o "cuando lleguemos a 40 negocios").
- [ ] Documentar el plan de migración cuando llegue el trigger (script, downtime esperado, ventana).

### 7.2 Separación física de tenants (sharding)

- [ ] Vinculado al PRD de Blast Radius. No migrar hoy a multi-instancia.
- [ ] Triggers de revisión documentados: >50-70 negocios, o un cliente >25% del volumen, o cliente con compliance contractual de aislamiento.

### 7.3 Estrategia de observabilidad de queries en producción

- [ ] Vinculado al PRD 6 (Sistema de Monitoreo). GlitchTip captura errores; queries lentos los detectamos con `pg_stat_statements` + revisión semanal.
- [ ] Decidir: ¿revisión manual mensual o automatizar reporte que llega por email?

---

## Resumen ejecutivo de orden de ejecución

| Bloque | Prioridad | Estimado | Cuándo |
|--------|-----------|----------|--------|
| 0 — Higiene crítica de integridad | 🔴 Hacer ya | 3-5 días | Esta semana |
| 1 — Optimización de fotos en upload | 🔴 Hacer ya | 2-3 días | Esta semana |
| 2 — Auditoría e índices de performance | 🟡 Este mes | 1 semana | Semanas 2-3 |
| 3 — Realtime con filtros | 🟡 Este mes | 3-5 días | Semanas 2-3 |
| 4 — Cloudflare delante de Storage | 🟡 Este mes | 1-2 días | Semana 4 |
| 5 — Cache local con drift | 🟢 Este trimestre | 2-3 semanas | Mes 2-3 |
| 6 — Retención y limpieza | 🟢 Este trimestre | 1 semana | Mes 2-3 |
| 7 — Decisiones estratégicas | ⚪ Decidir y documentar | 1-2 días | Cuando aplique |

**Total real de trabajo concentrado:** ~6-8 semanas distribuidas en 3 meses, compatible con el trabajo paralelo en PRD 5 (printing), WFM Zillow y universidad.

**Puntos de corte aceptables si el calendario se aprieta:**
- Después de Bloque 0 y Bloque 1: ya cubriste integridad crítica y detuviste sangría de fotos. ~30% del valor.
- Después de Bloque 2 y Bloque 3: performance accionable resuelto. ~70% del valor.
- Después de Bloque 4: distribución de fotos optimizada. ~80% del valor.
- Bloques 5, 6, 7: el otro 20% que es valioso pero no crítico para los próximos 3 meses.
