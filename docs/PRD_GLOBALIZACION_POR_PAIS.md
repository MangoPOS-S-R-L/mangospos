# PRD — Globalización por país (impuestos, fiscal e idioma)

**Estado:** Borrador / plan. Nada de esto está implementado todavía.
**Fecha:** 2026-06-19
**Relacionado:** capa de **moneda** ya implementada (ver más abajo), `PRD_UNIFIED_TAX_MODEL` / memoria `project_unified_tax_model`, `ncf_types.dart`, `tax_engine.dart`.

---

## 1. Objetivo y por qué

Hoy MangoPOS está construido para **República Dominicana**. La capa de **moneda** ya
se globalizó (el negocio puede operar en cualquiera de ~34 monedas de América y
Europa, elegible en el registro y en Ajustes → Monedas). **Pero elegir la moneda
NO hace que la app "funcione para ese país".** Para que un comercio mexicano,
español, chileno, etc. pueda operar legalmente faltan tres pilares que siguen
amarrados a RD:

1. **Impuestos** — tasas, nombres y reglas (IVA, sales tax) en vez de ITBIS 18%.
2. **Documentos fiscales** — el comprobante legal (CFDI/SAT en México, factura
   electrónica en la UE…) en vez de NCF/DGII.
3. **Idioma** — toda la interfaz está en español.

Este PRD planifica esos tres pilares. Se diseña por **fases independientes** para
poder entregar valor incremental sin tocar todo a la vez (CLAUDE.md: cambios
acotados; impresión y fiscal son zonas sensibles).

## 2. Lo que YA existe (no rehacer)

- **Moneda** (hecho): `lib/core/currency/business_currency.dart` (catálogo ~34),
  `business_settings.currency_code`, selector en registro y en Ajustes → Monedas.
- **Impuestos configurables por negocio** (parcial): existe tabla `taxes`,
  `tax_repository.dart`, modelo `tax.dart`, motor `tax_engine.dart`. Las **tasas
  ya no están hardcodeadas** — cada negocio define sus impuestos. Lo DR-específico
  son los **defaults** (ITBIS 18%, "Ley"/propina de ley) y algunas reglas
  (inclusivo/exclusivo, redondeo) — ver memoria `project_unified_tax_model`.
- **Fiscal DR** (hardcoded): `lib/core/fiscal/ncf_types.dart` mapea códigos
  NCF de la DGII (B01/E31/…) con texto en español. No hay abstracción de país.
- **Idioma**: sin i18n. `intl` se usa solo para números/fechas. Sin `.arb`,
  sin `flutter_localizations`, sin `supportedLocales`. Cientos de strings en
  español hardcodeados.

## 3. Arquitectura propuesta: "Perfil de país"

Introducir un concepto único de **perfil de país/región** que agrupe los defaults,
para que elegir país en el registro configure todo de una vez (y la moneda se
sugiera desde ahí):

```
country_profile (catálogo en cliente + opcional tabla de override en BD)
  ├─ countryCode        (ISO 3166: DO, MX, ES, CL, US, …)
  ├─ defaultCurrency    (ISO 4217 → reusa BusinessCurrency)
  ├─ defaultLocale      (es_DO, es_MX, es_ES, en_US, …) → idioma + formato
  ├─ taxPreset          (lista de impuestos default: IVA 16%, ITBIS 18%, …)
  │                       reglas: inclusivo/exclusivo, redondeo, nombre visible
  └─ fiscalSystem       (enum/adapter: none | ncf_do | cfdi_mx | facturae_es | …)
```

- **`business_settings`** gana una columna `country_code` (default `DO`). La
  moneda ya existe (`currency_code`). El resto se deriva del perfil pero es
  **override-able** por negocio (un comercio puede tener config no estándar).
- El perfil **siembra defaults** al registrarse; no es una jaula. Reusa el patrón
  best-effort que ya usa el registro para el preset retail y la moneda.

## 4. Fases

### Fase A — Impuestos por país (presets + reglas)
**Riesgo: medio-alto (toca `tax_engine`, fiscal).**
- Catálogo de `taxPreset` por país (IVA MX 16%, IVA ES 21%/10%/4%, sales tax US
  por estado, ITBIS DO 18%, etc.).
- Al registrarse / elegir país: sembrar la tabla `taxes` del negocio con el preset.
- Desacoplar defaults DR del motor: quitar supuestos `default_tax_rate=18`,
  nombre "ITBIS", "Ley"/service_fee fijos. Hacer nombre y reglas data-driven.
- Resolver el bug latente del modelo unificado (`project_unified_tax_model`)
  antes o durante, para no arrastrarlo a más países.
- **No requiere idioma ni fiscal.** Entregable: un negocio MX cobra IVA 16%
  correctamente, reportes y recibos muestran "IVA" en vez de "ITBIS".

### Fase B — Documentos fiscales por país (lo más grande)
**Riesgo: alto (legal + impresión + offline + integraciones externas).**
- Convertir lo fiscal en **adaptadores enchufables** (`fiscalSystem`):
  - `none` — sin comprobante fiscal regulado (recibo simple). Habilita países
    sin requisito de facturación electrónica de inmediato.
  - `ncf_do` — el actual (NCF/DGII). Refactor de `ncf_types.dart` detrás de la
    interfaz, sin cambiar comportamiento.
  - `cfdi_mx`, `facturae_es`, … — nuevos, cada uno su integración (PAC/SAT,
    SII, etc.). Patrón inbox async ya usado para Alanube/Azul.
- Tocar: numeración, impresión de comprobantes, conciliación, sync offline de
  folios (paralelo al trabajo F4 NCF offline ya hecho).
- **Empezar por `none`** desbloquea muchos países sin construir cada integración.
  Las integraciones fiscales reales se priorizan por demanda real de mercado.

### Fase C — Idioma / i18n
**Riesgo: medio (volumen alto, mecánico).**
- Agregar `flutter_localizations` + estructura `.arb` (es, en, pt… según mercado).
- `supportedLocales` + selección por negocio/usuario (deriva del perfil de país).
- Migrar los strings hardcodeados por módulo (incremental, empezar por flujos
  core: venta, cobro, login).
- Fechas: hoy `main.dart` inicializa solo `es_DO`; pasar a inicializar el locale
  del negocio.

## 5. Puntos de acoplamiento DR a desacoplar (mapa de código)

| Área | Archivo(s) | Acoplamiento |
|---|---|---|
| Impuestos | `lib/core/tax/tax_engine.dart`, `data/models/tax.dart` | redondeo a 2 dec fijo, nombre/“Ley” |
| Default tasa | `business_settings.default_tax_rate=18` (schema) | ITBIS hardcoded |
| Fiscal | `lib/core/fiscal/ncf_types.dart` | códigos NCF/DGII en español, sin abstracción |
| Cierre de caja | `cashier/state/cash_close_formatters.dart` (+6) | denominaciones físicas DOP |
| Recibos | `print_service.dart`, `services/printing/print_ticket_service.dart`, `sales/view/invoice_modal.dart` | formato/símbolo DR |
| Idioma | toda la UI | strings español hardcodeados |
| Fechas | `main.dart` (`initializeDateFormatting('es_DO')`) | locale fijo |

## 6. Riesgos y restricciones

- **Fiscal e impresión son zonas críticas** (CLAUDE.md). Cambios ahí necesitan
  pruebas en hardware y validación legal por país. No hacer big-bang.
- **La BD viva diverge de las migraciones del repo** (memoria
  `project_db_diverges_from_repo_migrations`): verificar `pg_get_functiondef`
  antes de tocar funciones fiscales; aplicar migraciones por el canal habitual.
- **Cumplimiento legal**: cada `fiscalSystem` real implica integración con la
  autoridad tributaria del país — no es solo formato, es certificación.
- Preservar **100% el comportamiento DO** en cada fase (default `country_code=DO`).

## 7. Out of scope / decisiones abiertas

- Multi-moneda con conversión en una venta (ya cubierto display-only por PRD 6).
- ¿Qué países priorizar para impuestos (Fase A) y para fiscal real (Fase B)?
  → definir por demanda de mercado.
- ¿`country_code` también condiciona métodos de pago / pasarelas por país?
  (fuera de este PRD; relacionado con Azul).
- ¿Idioma por **negocio** o por **usuario**? (propuesta: default por negocio,
  override por usuario).

## 8. Recomendación de orden

1. **Fase A (impuestos)** — mayor valor inmediato, desbloquea cobro correcto.
2. **Fase B con `fiscalSystem='none'`** — desbloquea países sin factura regulada.
3. **Fase C (idioma)** en paralelo, incremental por módulo.
4. Integraciones fiscales reales (CFDI, etc.) **por demanda**, una a una.
