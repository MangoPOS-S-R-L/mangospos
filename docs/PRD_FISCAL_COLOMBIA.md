# PRD — Fiscalización por país (Fase B): Colombia primero

**Estado:** Borrador / plan. Nada implementado.
**Fecha:** 2026-06-21.
**Relacionado:**
- Capa de **moneda** (hecha): `lib/core/currency/business_currency.dart`, `lib/core/business/country_profile.dart`, `business_settings.currency_code`/`country_code`.
- Plan macro: `docs/PRD_GLOBALIZACION_POR_PAIS.md` (3 pilares: impuestos, fiscal, idioma — esto es el pilar **fiscal**).
- Investigación de respaldo: `docs/RESEARCH_COMPROBANTES_FISCALES_POR_PAIS.md`.
- Fiscal DR actual (referencia de patrón): `lib/core/fiscal/ncf_types.dart`, modelos en `lib/data/models/fiscal_models.dart`, `fiscal_documents`.

> Decisión del usuario (2026-06-21): trabajar la fiscalización **por partes, empezando por Colombia**. Este PRD define la arquitectura común y la primera entrega (Colombia / DIAN).

---

## 1. Objetivo

Permitir que un negocio configurado en Colombia emita los comprobantes que exige la **DIAN**, sin romper el flujo fiscal dominicano (NCF/e-CF) que ya está en producción. Se hace detrás de una **abstracción de "proveedor fiscal" enchufable por país**, para que agregar el siguiente país (México, Chile…) sea sumar un adaptador, no reescribir el POS.

## 2. Principio rector

El POS hoy asume **un solo sistema fiscal (RD)**. En vez de meter `if (pais == 'CO')` por todos lados:

1. Se define una **interfaz `FiscalProvider`** (contrato común: emitir, anular, consultar estado, contingencia, representación impresa).
2. El sistema fiscal de cada país es un **adaptador** que implementa esa interfaz.
3. El adaptador activo se resuelve desde el **perfil de país** del negocio (`business_settings.country_code` → `fiscalSystem`). RD usa `ncf_do` (refactor del actual, sin cambio de comportamiento); Colombia usa `dian_co`.

Esto sale directo del análisis de patrones de la investigación: Colombia es **Patrón A (clearance por documento)** — el XML se valida con la DIAN antes de ser válido.

## 3. Arquitectura común (Fase B0 — habilitadora)

```
FiscalProvider (interfaz)
  Future<FiscalResult> issue(FiscalRequest req)      // emite/valida un comprobante
  Future<FiscalResult> voidDocument(...)             // anula / nota de crédito
  Future<FiscalStatus> status(String id)             // consulta estado (async clearance)
  FiscalPrintModel buildPrintModel(FiscalResult r)   // QR, claves, leyendas para impresión
  // capacidades declaradas: requiresOnlineClearance, supportsContingency, idCustomerThreshold...

  Implementaciones:
    NcfDoProvider   (RD — envuelve el flujo NCF/e-CF actual; sin cambio funcional)
    DianCoProvider  (CO — nuevo)
    NoneProvider    (recibo simple, países sin factura regulada)
```

- **`country_profile`** gana `fiscalSystem` (`none | ncf_do | dian_co | …`). Hoy `CountryProfile` solo mapea país→moneda; se le agrega este campo.
- `business_settings` gana lo que el adaptador necesite (ver §6). El default `country_code='DO'` ⇒ `ncf_do` ⇒ comportamiento idéntico al actual.
- **B0 no cambia nada visible**: solo extrae el flujo RD detrás de `NcfDoProvider` y enchufa el selector. Es el seguro para no romper RD.

## 4. Alcance Colombia (DIAN)

Colombia tiene **dos documentos** relevantes a un POS de restaurante/retail (investigación §CO):

| Documento | Cuándo | ID comprador | Identificador |
|---|---|---|---|
| **Documento Equivalente Electrónico – Tiquete POS** | Default consumidor final, bajo valor (≤ 5 UVT, aunque puede emitirse a cualquier valor) | **No requiere** identificar comprador | **CUDE** |
| **Factura Electrónica de Venta** | Cliente pide factura / requiere costos-IVA / supera umbral | **Requiere NIT/cédula** | **CUFE** (96 car.) |

Reglas clave (2025-2026):
- **XML UBL 2.1** firmado, **validación previa por DIAN** (el documento solo está "expedido" cuando la DIAN lo valida).
- **2026: transmisión a la DIAN el mismo día de la emisión** → diseñar envío casi en tiempo real + contingencia.
- Numeración/rangos **autorizados por DIAN** antes de emitir.
- Representación impresa con **CUFE/CUDE + QR**.

## 5. Fases de entrega (Colombia)

### B0 — Abstracción `FiscalProvider` + refactor RD detrás de ella
Sin cambio de comportamiento. Tests de regresión sobre el flujo NCF/e-CF actual. **Pre-requisito de todo lo demás.**

### CO-1 — Documento Equivalente POS (tiquete) con la DIAN
El caso **más común** de restaurante/retail. Sin identificar comprador. Genera XML UBL 2.1 del tiquete, firma, transmite a DIAN, recibe **CUDE**, imprime con QR. Incluye **contingencia** (emitir y transmitir mismo día). Es el MVP que pone a Colombia operativo.

### CO-2 — Factura Electrónica de Venta (nominada)
Flujo "el cliente pide factura": captura **NIT/cédula** + datos, genera **CUFE**, valida con DIAN. Reusa el motor de CO-1.

### CO-3 — Notas Crédito/Débito electrónicas
Anulaciones y ajustes (devoluciones, correcciones), atadas al documento original.

### CO-4 — Endurecimiento
Resúmenes/numeración, manejo de rechazos DIAN, reportes, monitoreo de transmisión "mismo día".

## 6. Modelo de datos (incremental, no romper RD)

- `country_profile.fiscalSystem` (cliente).
- `business_settings`: credenciales/configuración del proveedor DIAN (NIT del emisor, resolución de numeración/rango autorizado, ambiente prueba/producción, datos del proveedor/PAC si se usa intermediario). Por-negocio, fuera del repo de código (secretos).
- `fiscal_documents` (ya existe para RD): generalizar para guardar el identificador del país (`CUFE`/`CUDE` en CO, `e-NCF` en DO), el XML/representación, el estado de clearance (pendiente/aceptado/rechazado/contingencia) y timestamps. **Aditivo**: columnas nuevas nullables; RD sigue llenando sus campos.
- Cola de transmisión/contingencia (reusar patrón inbox async ya usado para Alanube/Azul, ver memorias del proyecto).

## 7. Integración DIAN vía Alanube (DECIDIDO)

**Proveedor: Alanube** — ya integrado en MangoPOS para el e-CF dominicano
(`supabase/migrations/20260506_0001_alanube_ecf_extension.sql`, PRDs en
`lib/PRD Facturacion Electronica/`, patrón inbox async). Alanube es
**multi-país** (DO, CO, MX, PE, …), así que Colombia **NO se construye desde
cero**: se extiende la integración existente.

Esto reescribe la estrategia: el `DianCoProvider` es en realidad un **adaptador
sobre Alanube** que reusa el mismo cliente/cola async ya probado para DO. Alanube
se encarga del XML UBL 2.1, la firma, la validación con la DIAN y la numeración;
MangoPOS le manda los datos del comprobante y recibe CUFE/CUDE + QR.

Implicación: la interfaz `FiscalProvider` (§3) puede tener una implementación
base **`AlanubeProvider`** parametrizada por país, en vez de un proveedor
distinto por país. RD y CO comparten el cliente Alanube; cambia la config y el
mapeo de tipos de documento.

Pendientes técnicos (menores con Alanube):
- Activar el país Colombia en la cuenta Alanube del negocio + credenciales.
- Mapear tipos de documento CO (Tiquete POS / Factura de Venta / Notas) al API de Alanube.
- Ambiente de **pruebas/habilitación** de Alanube para CO antes de producción.

## 8. Representación impresa

El render de impresión ya es currency-aware (la moneda sale por `BusinessCurrency`). Falta que sea **fiscal-aware por país**: el `FiscalPrintModel` del adaptador inyecta QR + CUFE/CUDE + leyendas legales colombianas. El layout base (print_ticket_service) se mantiene; cambian los bloques fiscales.

## 9. Riesgos

- **Cumplimiento legal**: cada error fiscal tiene consecuencias para el comerciante. Validar en ambiente de habilitación DIAN; revisión por contador colombiano antes de producción.
- **Zona sensible (CLAUDE.md)**: fiscal + impresión. No big-bang; B0 debe dejar RD intacto y con tests.
- **BD diverge del repo** (memoria `project_db_diverges_from_repo_migrations`): verificar funciones vivas antes de tocar lo fiscal; aplicar migraciones por el canal habitual.
- **Transmisión "mismo día" (2026)**: exige conectividad confiable + contingencia robusta.

## 10. Decisiones abiertas (para ti)

1. ~~¿Proveedor o directo?~~ **RESUELTO: Alanube** (ya integrado para DO, multi-país).
2. ¿Arrancamos por **B0** (abstracción `FiscalProvider` + envolver el flujo Alanube/DO actual) o un **spike de CO-1** directo contra Alanube-Colombia (pruebas)?
3. ¿Hay un negocio/cliente colombiano de piloto? (define urgencia y datos reales).
4. ¿Alanube ya tiene Colombia habilitado en tu cuenta, o hay que activarlo/contratarlo?

## 11. Criterios de aceptación (CO-1, MVP)
- Un negocio con `country_code='CO'` emite un **Tiquete POS** que la DIAN **valida** (ambiente habilitación), recibe **CUDE**, e imprime con **QR**.
- Contingencia: si no hay red, el tiquete se emite y se transmite el mismo día al reconectar.
- Un negocio con `country_code='DO'` **no cambia en nada** (regresión verde).
