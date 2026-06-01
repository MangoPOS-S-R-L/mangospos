# Diseño — F4: NCF / Comprobantes fiscales offline

> **Tipo:** Diseño técnico para aprobación (antes de implementar). Roadmap offline, fase F4.
> **Fecha:** 2026-06-01
> **Estado:** PROPUESTA — requiere decisiones del dueño Y validación del contador/DGII (§4).

---

## 0. Advertencia (léelo)

Esto toca **numeración fiscal ante DGII**. Un error no es un bug: es un problema legal/tributario para el cliente. Por eso:
- El diseño técnico lo pongo yo.
- Las **políticas fiscales** (tamaño de rangos, huecos de numeración, contingencia e-CF, agotamiento) **las debe firmar el contador del cliente.** No se enciende la emisión offline real sin ese visto bueno.

---

## 1. Cómo funciona hoy (resumen)

- `ncf_sequences`: una secuencia por **(business_id, ncf_type, serie)** — UNIQUE en esos 3. Campos: `range_start/range_end/current_number`, `prefix`, `expiration_date`, `is_active`.
- `generate_ncf(business, type)`: server-side, `FOR UPDATE`, `current_number+1`, formato `prefix || LPAD(n,8)`.
- Emisión: trigger `trg_issue_fiscal` al **INSERT de payment** → `issue_fiscal_document` → `generate_ncf` + inserta en `fiscal_documents` (UNIQUE `business_id+ncf_number`).
- **e-CF**: infraestructura Alanube (tablas `business_alanube_settings`, `fiscal_document_status_events`, webhook inbox; campos `ecf_status` pending/sent/accepted/rejected, `idempotency_key`, `retry_count`). La **firma y transmisión a DGII son server/Alanube**, NO en el dispositivo.
- **Offline hoy**: el pago se encola **sin NCF**; al sincronizar, el trigger asigna el NCF retroactivamente. El cliente NO recibe comprobante con número en el momento.

---

## 2. Idea central (reusa `serie`, cambio de esquema mínimo)

**Rangos por dispositivo = una `serie` por dispositivo**, con sub-rango disjunto del rango autorizado del negocio.

```
Rango autorizado del negocio para B02:  [1 .. 100000]
  ├─ serie "C1" (caja 1):  [1     .. 40000]
  ├─ serie "C2" (caja 2):  [40001 .. 70000]
  └─ serie "POS" (online): [70001 .. 100000]   ← la secuencia "central" actual
```

- Cada dispositivo emite offline desde **su** serie, llevando el `current_number` **localmente** (no puede hacer UPDATE al server sin red).
- Como los sub-rangos son **disjuntos**, los NCF nunca colisionan entre dispositivos — y el UNIQUE `business_id+ncf_number` en `fiscal_documents` es la red de seguridad server-side.
- Al reconectar, se concilian los números consumidos (se sube `current_number` de esa serie y se insertan los `fiscal_documents` con su NCF ya asignado).

**Ventaja:** el esquema ya soporta múltiples series. El cambio en `ncf_sequences` es mínimo o nulo (a lo sumo una columna opcional `device_id` para trazar qué serie es de qué equipo; la mecánica usa `serie`).

---

## 3. Flujo offline propuesto

### 3.1 Asignación del número (papel y e-CF igual)
1. El dispositivo conoce **su serie** y su sub-rango (entregado al aprovisionar — relacionado con F0, o configurado en Ajustes fiscales).
2. Al cobrar offline: se asigna `next = current_local + 1` de su serie; se valida `<= range_end`.
3. Se persiste localmente el `fiscal_document` (con su NCF, `status='active'`, marca `offline_issued=true`) y se **encola** para sync.
4. El comprobante **se imprime con su NCF real** en el momento.

### 3.2 Diferencia papel vs e-CF
- **Papel (B0x):** offline está completo — el NCF impreso es válido; al sync solo se registra el `fiscal_document` y se sube el contador. ✅
- **e-CF (E3x):** el **número** se asigna offline igual, pero **firma + transmisión a DGII van por Alanube (server)**. Offline se emite en **modo contingencia** (el e-CF se imprime con su e-NCF; la transmisión queda **encolada** y Alanube la envía al reconectar, dentro de la ventana DGII). El código de seguridad/QR definitivo se completa al transmitir. *(Requiere que el negocio esté habilitado para contingencia — decisión fiscal.)*

### 3.3 Reconciliación al reconectar (uplink, reusa lo de F3b)
- Cada `fiscal_document` offline se sube con su NCF ya fijado (NO se re-genera). El UNIQUE `business_id+ncf_number` previene duplicados.
- Se actualiza `ncf_sequences.current_number` de la serie del dispositivo al máximo consumido.
- e-CF: los documentos pasan a la cola Alanube (`ecf_status=pending` → worker los transmite).
- Idempotente por `idempotency_key` (ya existe en fiscal_documents).

---

## 4. Decisiones que REQUIEREN al contador/DGII (no las decido yo)

1. **Huecos de numeración:** los sub-rangos por dispositivo y los números reservados-no-usados generan **huecos** en la secuencia. DGII espera secuencialidad; los huecos deben ser justificables. ¿El contador lo acepta y cómo se reportan?
2. **Agotamiento del rango offline:** si un equipo agota su sub-rango sin red, ¿qué hacemos? (a) **bloquear** la emisión fiscal offline (cobra sin comprobante hasta reconectar), o (b) recibo **provisional sin NCF** (como hoy) y NCF al sync. → decisión §5.B.
3. **Contingencia e-CF:** ¿el negocio está autorizado a emitir e-CF en contingencia y transmitir diferido? ¿Alanube lo soporta en su plan? Sin esto, el e-CF offline NO es legal — habría que diferir el e-CF al sync (solo papel offline).
4. **Tamaño y reparto de sub-rangos** por dispositivo, y cómo se reabastecen online sin colisión.

---

## 5. Decisiones de producto (tuyas)

- **A. Alcance inicial:** ¿papel (B0x) offline primero y e-CF diferido? ¿o ambos con contingencia desde ya?
- **B. Política de agotamiento offline:** bloquear vs recibo provisional sin NCF.
- **C. Asignación de series/sub-rangos:** ¿automática al aprovisionar (F0) o configurable a mano en Ajustes fiscales por ahora?

---

## 6. Qué construiría (cuando se aprueben §4 y §5)

1. **Migración (sin aplicar):** opcional `ncf_sequences.device_id` para trazar serie↔equipo; `fiscal_documents.offline_issued boolean`. Posible RPC `fn_assign_ncf_serie_range(business, type, device, size)` que carva un sub-rango disjunto online.
2. **Dart:** `NcfOfflineAllocator` — conoce la serie+rango del dispositivo, asigna el próximo número localmente con tracking persistente (drift/SP), valida agotamiento.
3. **Emisión offline:** al cobrar sin red, crear el `fiscal_document` local con NCF, imprimirlo, encolarlo.
4. **Uplink:** subir los `fiscal_documents` offline con su NCF (sin regenerar) + actualizar `current_number` + meter e-CF a la cola Alanube. Reusa el motor de F3b.
5. **Reportes/auditoría:** marcar comprobantes emitidos offline; visor de huecos para el contador.

---

## 7. Riesgos

| Riesgo | Mitigación |
|---|---|
| Colisión de NCF entre equipos | Sub-rangos disjuntos por serie + UNIQUE `business+ncf_number` server-side |
| Huecos de numeración | Visor/reporte de huecos; política firmada por contador (§4.1) |
| e-CF offline sin contingencia legal | Si no hay contingencia → e-CF se DIFIERE al sync (solo papel offline) |
| Agotamiento de rango | Alerta al 80%; política de agotamiento (§5.B) |
| Reabastecer rangos sin colisión | Solo online, carvado central de sub-rangos |

---

## 8. Estado de implementación + el bloqueo real del carvado

**Construido (gateado, `kOfflineNcfEnabled=false`):**
- F4-1: `NcfOfflineAllocator` (asigna NCF local del rango del dispositivo, agota→null) + migración 20260601_0004 (device_id, offline_issued). 8 tests.
- F4-2 (lado lectura): `NcfRangeService.resolveDeviceRange` — lee la fila de `ncf_sequences` del dispositivo y arma el `NcfRange` que consume el allocator.

**Bloqueo del carvado (lado escritura) — PREGUNTA FISCAL precisa para el contador:**
En el modelo actual, `ncf_sequences.prefix = serie + tipo` y la `serie` debe estar **autorizada por DGII**. Entonces "rangos por dispositivo" puede significar dos cosas FISCALMENTE distintas, y solo el contador sabe cuál aplica a este negocio:
- **(a) Series separadas por terminal**: DGII autoriza una serie distinta por caja (cada una con su propio rango). El NCF impreso difiere por serie. Cero solapamiento por diseño.
- **(b) Partición del rango de UNA serie**: una sola serie autorizada, y repartimos su rango numérico en bloques disjuntos por dispositivo. Mismo prefijo, números disjuntos.

El **carvado y la emisión offline NO se codifican hasta que el contador defina (a) o (b)** — implementarlo a ciegas baca el modelo fiscal equivocado. Con la respuesta, el carvado son ~1-2 días (RPC que reparte + alerta de agotamiento) sobre la infra ya lista.

---

## 9. MODELO PREFERIDO: Hub Local como asignador (sin huecos)

Si los equipos están en la **misma LAN** (caso normal), el **Hub Local (F3)**
debe ser el **único asignador de NCF** mientras no hay internet — igual que
Supabase online. Todas las cajas piden el próximo número al Hub vía un endpoint
dedicado (`POST /hub/ncf/next`, atómico sobre el `current_number` de la serie).

Ventaja decisiva: **numeración secuencial sin huecos** aunque facturen varias
cajas a la vez. Elimina el problema fiscal de los sub-rangos por dispositivo
(bloques reservados-no-usados = huecos a justificar).

```
Online              → Supabase asigna (como hoy)
Offline + Hub LAN   → el Hub asigna secuencial, SIN huecos   ← preferido
Offline sin Hub     → recibo provisional sin NCF (caja aislada) ← fallback raro
```

Los sub-rangos por dispositivo (allocator F4-1) quedan solo como **fallback**
para una caja aislada del Hub. El carvado por dispositivo (§2) deja de ser el
camino principal cuando hay Hub.

Implicación de build: el carvado masivo pierde prioridad; lo que se necesita es
el endpoint de asignación en el Hub + reconciliación del `current_number` al
reconectar (reusa el uplink de F3b). Depende de activar F3 (Hub) y de la
confirmación fiscal (§4 / consulta al contador en `F4_NCF_OFFLINE_CONSULTA_CONTADOR.md`).

---

*Diseño basado en el código real al 2026-06-01. F4-1/F4-2 (infra gateada) construidos; el modelo preferido (Hub asignador, §9) + emisión esperan activar F3 y la firma fiscal (§4/§8).*
