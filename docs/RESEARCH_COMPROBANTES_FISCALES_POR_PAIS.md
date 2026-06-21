# Comprobantes Fiscales / Facturación Electrónica por País (2025–2026)

**Propósito:** Planificar la globalización de un POS de restaurantes/retail que hoy solo soporta República Dominicana (NCF/DGII).
**Fecha de investigación:** 2026-06-21.
**Verificación:** Datos cruzados contra portales oficiales de las autoridades tributarias y proveedores acreditados. Las fechas de mandato cambian por extensiones administrativas — **siempre re-confirmar contra el calendario oficial vigente antes de comprometer roadmap o copy legal**. Las incertidumbres están marcadas como **(NO CONFIRMADO)**.

> Nota metodológica: parte de la información se obtuvo vía resúmenes de búsqueda (no todos los PDFs/portales oficiales fueron accesibles en sesión). Para implementación, abrir directamente los manuales técnicos y resoluciones citados.

---

## Tabla resumen general

| País | Sistema | Autoridad | ¿Obligatorio B2C? | Estándar / modelo de validación |
|------|---------|-----------|-------------------|----------------------------------|
| **DO** | e-CF (e-NCF) | DGII | Sí, en despliegue (SMB en 2026) | XML firmado, pre-validación DGII, contingencia 72h |
| **MX** | CFDI 4.0 | SAT | Sí (universal) | XML (Anexo 20), timbrado por **PAC** → UUID |
| **CO** | Factura Electrónica + Doc. Equivalente POS | DIAN | Sí (desde 2024) | XML UBL 2.1, pre-validación DIAN, CUFE/CUDE |
| **CL** | DTE / Boleta Electrónica | SII | Sí (boleta desde 2021) | XML v4.1, folios **CAF**, timbre PDF417 |
| **AR** | Factura Electrónica (CAE/CAEA) | ARCA (ex-AFIP) | Sí (universal) | Web service WSFE → CAE en tiempo real, QR |
| **PE** | CPE (SEE) | SUNAT | Sí (universal desde 2022) | XML UBL 2.1 firmado, OSE/PSE, Resumen Diario |
| **BR** | NF-e / **NFC-e** (modelo 65) | SEFAZ (estatal) + Receita Federal | Sí (de facto, por estado) | XML firmado A1, autorización SEFAZ online + contingencia |
| **ES** | **Verifactu/SIF** (B2C); SII; Crea y Crece (B2B) | AEAT | Verifactu ~2027 (en juego) | Cadena de hash SHA-256 + QR; B2B estructurado aparte |
| **US** | **Ninguno (no hay factura fiscal federal)** | IRS + Dept. of Revenue estatal | **No** (sales tax por estado) | Sin XML/firma/QR fiscal; recibo comercial |
| **CR** | Comprobantes Electrónicos v4.4 | Hacienda (TRIBU-CR) | Sí | XML firmado, clave 50 dígitos, validación Hacienda |
| **GT** | FEL (DTE) | SAT GT | Sí (~universal) | XML firmado, **Certificador** tiempo real, UUID |
| **PA** | SFEP | DGI / MEF | Sí (dual: equipo fiscal o SFEP) | XML firmado + **PAC**, CUFE |
| **UY** | CFE (e-Ticket/e-Factura) | DGI | Sí (universal) | XML firmado, **rangos CAE** + reporte diario |
| **EC** | Comprobantes Electrónicos (offline) | SRI | Sí (~universal) | XML XAdES-BES, clave de acceso 49 díg., **tiempo real desde 2026** |
| **BO** | Sistema de Facturación (SFE/SIAT) | SIN | Sí (por grupos) | XML web services, CUF + CUFD, QR |
| **PY** | SIFEN / e-Kuatia | DNIT (ex-SET) | Por fases (no universal aún) | XML firmado, clearance SIFEN, CDC 44 díg., KuDE |
| **VE** | Máquinas fiscales + facturación digital | SENIAT | Sí (máquina fiscal obligatoria) | **Sin clearance XML real**; número de control + memoria fiscal |
| **CA** | Ninguno fiscal | CRA + provincias | No | GST/HST/PST; Peppol B2G voluntario |
| **HN** | Régimen de Facturación (CAI) | SAR | Sí (con CAI; e-invoice en fases) | CAI + correlativo autorizado |
| **NI** | Pie de Imprenta Fiscal | DGI | Sí (no CTC; e-emisión opt-in) | Correlativos autorizados, sin XML CTC |
| **DE** | e-Rechnung (B2B) + KassenSichV (POS) | BMF/Finanzamt | B2B (no B2C); **TSE obligatorio en caja** | XRechnung/ZUGFeRD EN 16931; TSE/DSFinV-K |
| **FR** | Réforme e-invoicing (Factur-X/PDP) | DGFiP | B2B 2026-27; B2C vía e-reporting | Factur-X/UBL/CII, PDP/Chorus Pro |
| **IT** | Fattura Elettronica (SdI) | Agenzia Entrate | Sí (desde 2019); RT en retail | FatturaPA XML vía SdI; corrispettivi telematici |
| **PT** | Faturas + SAF-T (PT) | AT | Sí (software certificado + ATCUD+QR) | SAF-T (PT) XML, ATCUD + QR obligatorios |
| **GB** | Ninguno (MTD para IVA) | HMRC | No (mandato B2B previsto 2029) | Sin estándar fiscal; MTD digital |
| **CH** | Ninguno B2C (QR-bill pagos) | ESTV/AFC | No (solo B2G) | QR-bill; eBill/Peppol voluntario |
| **SE** | B2G Peppol + Kassaregister | Skatteverket | No B2B/B2C (caja registradora certificada en retail) | Peppol BIS 3.0 (B2G) |
| **PL** | KSeF (B2B) + kasy fiskalne (B2C) | Admin. tributaria PL | B2B 2026-27; B2C vía caja fiscal | XML FA(3) vía KSeF |

---

# Países de ALTA prioridad

## República Dominicana (DO)
- **Sistema:** e-CF (e-NCF), evolución del NCF; secuencia `E`+2 díg. tipo+secuencial. Ley 32-23.
- **Autoridad:** DGII.
- **Obligatorio:** Por fases. Grandes ya; Grandes/Medianos Locales 15 nov 2025; pequeños/micro en 2026 (mayo vs nov **NO CONFIRMADO**).
- **Tipos (POS):** 31 Crédito Fiscal (B2B, requiere RNC), **32 Consumo** (ticket típico), 33 Nota Débito, 34 Nota Crédito, 41/43/44/45/46/47 otros.
- **Estándar:** XML firmado, pre-validación DGII, **Código de Seguridad** (6 díg. del hash) + **QR**.
- **ID cliente:** RNC/cédula; requerido en 31; en 32 opcional, bajo RD$250,000 RNC opcional.
- **POS:** QR + Código Seguridad; contingencia 72h. Es el país ya soportado — NCF→e-CF es evolución.

## México (MX)
- **Sistema:** CFDI 4.0. **Autoridad:** SAT.
- **Obligatorio:** universal; CFDI 4.0 único válido desde 1 abr 2023.
- **Tipos:** Ingreso (venta), **Factura Global** (público no identificado, emitir 72h del cierre), Egreso (=N.Crédito), Pago (complemento). El ticket de papel **NO** es CFDI fiscal.
- **Estándar:** XML (Anexo 20) sellado con **CSD**; **PAC** timbra → **UUID**.
- **ID cliente:** **RFC** + régimen + uso CFDI + CP. Público general: RFC XAXX010101000.
- **POS:** integración PAC obligatoria; Factura Global (72h); propinas fuera de base; QR de verificación SAT.

## Colombia (CO)
- **Sistema:** **Factura Electrónica de Venta** + **Documento Equivalente Electrónico** (tiquete POS). Res. 000165/2023, mod. 000202/2025.
- **Autoridad:** **DIAN**.
- **Obligatorio:** Sí. Doc. equivalente POS (Res. 000008/2024): grandes 1 may 2024, hasta ~1 abr 2025 resto. **2026: transmisión a DIAN el mismo día de emisión.**
- **Tipos (POS):** Factura Electrónica de Venta (cliente requiere costos/IVA o supera umbral); **Documento Equivalente – Tiquete POS** (default retail/restaurante); Notas Crédito/Débito.
- **Estándar:** **XML UBL 2.1** firmado; **validación previa DIAN** (solo "expedido" tras validar); **CUFE** (96 car.) / **CUDE** (POS).
- **ID cliente:** NIT/cédula. Doc. equivalente POS **no** requiere identificar comprador; factura sí. Tiquete POS aplica ≤ 5 UVT (puede emitirse sin importar valor); comprador puede exigir factura.
- **POS:** transmisión mismo día (2026) + contingencia; flujo "solicitar factura completa"; CUFE/CUDE + QR; numeración autorizada por DIAN.

## Chile (CL)
- **Sistema:** DTE; consumidor **Boleta Electrónica**, B2B Factura Electrónica. **Autoridad:** SII.
- **Obligatorio:** factura desde 2018, boleta desde ene 2021. Res. 12/2025 (1 may 2025): copia impresa si hay impresora; digital desde 1 mar 2026 si no. **DTE v4.1** (fecha XSD **NO CONFIRMADA**).
- **Tipos (códigos):** Boleta afecta (39)/exenta (41); Factura (33/34); N.Crédito (61); N.Débito (56); Guía (52).
- **Estándar:** XML v4.1 firmado; **folios CAF** por tipo; timbre **PDF417**; boletas reporte diario.
- **ID cliente:** RUT; boleta normalmente sin RUT; sobre 135 UF B2C datos obligatorios.
- **POS:** gestión de folios/CAF; PDF417; reglas de entrega 2025-2026; apuntar a v4.1.

## Argentina (AR)
- **Sistema:** Factura Electrónica autorizada por **CAE** (14 díg.) o CAEA. **Autoridad:** **ARCA** (ex-AFIP).
- **Obligatorio:** universal. Desde 1 jun 2026 CAE estándar único; abr 2026 `CondicionIVAReceptorId` obligatorio incluso consumidor final (**NO CONFIRMADO**, confirmar RG).
- **Tipos:** Factura A/B/C/M/E, Tique/Tique-Factura, N.Crédito/Débito.
- **Estándar:** web services SOAP **WSFEv1** → **CAE tiempo real**; CAEA diferido; PDF con CAE+vencimiento+**QR**; Controlador Fiscal (hardware) legacy.
- **ID cliente:** CUIT/CUIL/CDI/DNI. Consumidor final solo sobre umbral (RG 5700/2025: AR$10.000.000).
- **POS:** QR; CAE tiempo real → contingencia CAEA; nuevo campo condición-IVA receptor.

## Perú (PE)
- **Sistema:** **CPE** (SEE). **Autoridad:** SUNAT.
- **Obligatorio:** universal desde 2022. Excepción NRUS.
- **Tipos:** Factura (B2B, RUC); **Boleta de Venta** (consumidor); N.Crédito/Débito; **Ticket POS** (bajo valor); **Resumen Diario** (lote).
- **Estándar:** **XML UBL 2.1** firmado; SEE / OSE / PSE; boletas tiempo real o Resumen Diario.
- **ID cliente:** RUC (factura) / DNI. Boleta requiere ID si total > S/ 700 o si lo pide.
- **POS:** QR; Ticket POS para bajo valor; OSE/PSE; Resumen Diario (offline/alto volumen).

## Brasil (BR)
- **Sistema:** NF-e (55) y **NFC-e** (modelo 65, consumidor/POS). **Autoridad:** SEFAZ estatal + Receita Federal.
- **Obligatorio:** NFC-e estándar de facto en retail, **por estado** (SP obliga desde ene 2026, requiere e-CNPJ A1). Reforma: NT 2025.002 agrega IBS/CBS (ene 2026 jurídico; prod ago 2026 / ene 2027).
- **Tipos:** **NFC-e (modelo 65)** = consumidor (impresión DANFE NFC-e); NF-e (55) B2B; NFS-e servicios.
- **Estándar:** XML firmado **e-CNPJ A1**, autorización **SEFAZ online**; **chave 44 díg.**; **CSC** para hash del QR; **contingencia offline**.
- **ID cliente:** CNPJ/CPF; en NFC-e CPF opcional ("CPF na nota").
- **POS:** NFC-e + DANFE + QR; certificado A1; CSC por estado; chave 44 díg.; modo contingencia offline; campos IBS/CBS 2026.

## España (ES)
> Tres regímenes distintos: **Verifactu/SIF** (relevante POS), **SII** (grandes), **Crea y Crece** (B2B).
- **Autoridad:** AEAT.
- **Obligatorio (Verifactu):** software cumple desde 29 jul 2025; **uso** obligatorio 1 ene 2027 (sociedades) / 1 jul 2027 (autónomos) (**NO CONFIRMADO** — pospuesto repetidamente). Quienes están en SII, exentos.
- **Tipos:** Factura completa (NIF); **Factura simplificada** (ticket consumidor); rectificativa.
- **Estándar:** SIF genera "registro de facturación" encadenado con **hash SHA-256** + **QR**. Modos: Verifactu (envío AEAT tiempo real) o local inmutable. Crea y Crece (B2B) = Facturae/UBL estructurado.
- **ID cliente:** NIF/CIF; no requerido en simplificada/ticket.
- **POS:** cadena hash + QR por ticket; elegir Verifactu online vs local. Riesgo: fechas pospuestas.

---

# Países de MEDIA prioridad

## Estados Unidos (US) — el contraste clave
**NO existe factura electrónica fiscal federal.** Sin clearance ni validación del recibo. Consumo gravado por **sales tax estatal**. El recibo es comercial, no fiscal. Opuesto a Latinoamérica.
- **Autoridad:** IRS (income, no valida recibos) + Dept. of Revenue por estado (sales/use tax). 45 estados + DC con sales tax; 5 sin (AK, DE, MT, NH, OR).
- **Obligatorio:** No hay e-invoice fiscal. Obligación = registrarse, recaudar, declarar, remitir.
- **POS:** sin impresora/QR fiscal. Complejidad = **cálculo de tasas** por jurisdicción + nexus económico post-Wayfair ($100k o 200 tx, tendencia a quitar el de 200). Motores: Avalara/TaxJar/Vertex/Sovos. Taxabilidad comida preparada vs abarrotes varía (**NO hardcodear**).

## Costa Rica (CR)
- **Sistema:** Comprobantes Electrónicos v4.4. **Autoridad:** Hacienda (TRIBU-CR desde 6 oct 2025).
- **Obligatorio:** sí; v4.4 desde 1 sep 2025. Decreto 44739-H.
- **Tipos:** Factura, **Tiquete Electrónico** (consumidor), N.Crédito/Débito, Factura de Compra, REP (nuevo 4.4).
- **Estándar:** XML firmado (.p12), **clave 50 díg.**, validación Hacienda. **QR introducido en 4.4 pero SUSPENDIDO desde sept 2025** (monitorear). Contingencia ~48h.
- **ID cliente:** tiquete sin ID; factura con cédula.

## Guatemala (GT)
- **Sistema:** **FEL** (emite **DTE**). **Autoridad:** SAT GT.
- **Obligatorio:** ~universal desde 1 jul 2023.
- **Tipos:** FACT, FCAM, FPEQ, FESP, NCRE, NDEB, NABN.
- **Estándar:** XML firma avanzada + **UUID** + Número de Autorización; **Certificador** tiempo real.
- **ID cliente:** **NIT** (CF "Consumidor Final" muy restringido: ≤ Q2,500, Decreto 31-2024 endurece). El POS debe capturar/validar NIT.

## Panamá (PA)
- **Sistema:** **SFEP**. **Autoridad:** DGI/MEF.
- **Obligatorio:** dual (equipo fiscal o SFEP). Desde 1 ene 2026 quienes superen 100 docs/mes o B/.36,000 anuales deben **PAC**.
- **Tipos:** Factura, F. Operación Interna, N.Crédito/Débito, F. Exportación, F. Zona Franca.
- **Estándar:** XML (Ficha v1.10), firma calificada + **PAC**, **CUFE** (~50 car.).
- **ID cliente:** B2B RUC; consumidor final no requiere RUC completo. POS: CUFE + QR; PAC para volumen.

## Uruguay (UY)
- **Sistema:** **CFE**. **Autoridad:** DGI. **Obligatorio:** universal (final 31 dic 2024; nuevos desde 1 ene 2025).
- **Tipos:** **e-Ticket** (B2C, 101/102), **e-Factura** (B2B con RUT, 111/112), N.Crédito/Débito, e-Remito, e-Resguardo.
- **Estándar:** XML firmado; **modelo CAE** (rangos pre-autorizados, no clearance por documento); **reporte diario**.
- **ID cliente:** e-Factura RUT; e-Ticket sin ID salvo umbral (5.000 vs 10.000 UI **NO CONFIRMADO**).
- **POS:** gestionar rangos CAE, reporte diario batch, QR, contingencia.

## Ecuador (EC)
- **Sistema:** Comprobantes Electrónicos (Off-line). **Autoridad:** SRI. **Obligatorio:** ~universal (excepción RIMPE Negocio Popular).
- **2026:** Res. NAC-DGERCGC25-00000017 → **transmisión en tiempo real** (elimina gracia 72h).
- **Tipos:** Factura, Nota de Venta, Comprobante de Retención, N.Crédito/Débito, Guía, Liquidación de Compra.
- **Estándar:** XML XAdES-BES; **clave de acceso 49 díg.**; RIDE = impreso.
- **ID cliente:** RUC(13)/cédula(10) o "Consumidor Final" 9999999999999. POS: clave 49 díg. + QR; transmisión inmediata 2026.

## Bolivia (BO)
- **Sistema:** Sistema de Facturación (SFE/SIAT). **Autoridad:** SIN. **Obligatorio:** por grupos (desde 1 oct 2025 grupos 9-12 en línea).
- **Tipos:** Factura, F. con crédito fiscal, N.Crédito-Débito, F. Exportación, sectoriales.
- **Estándar:** XML web services; **CUF** (por factura) + **CUFD** (diario, 24h por sucursal); QR; modalidades en línea/computarizada/portal.
- **ID cliente:** NIT/CI; ≤ Bs 1.000 "S/N". POS: CUF por factura, refrescar CUFD 24h, QR, contingencia.

## Paraguay (PY)
- **Sistema:** **SIFEN** (clearance); **e-Kuatia** / **e-Kuatia'i**. **Autoridad:** DNIT (ex-SET).
- **Obligatorio:** **por fases, NO universal** (grupos 14→dic 2025 … 18→dic 2026; pequeños 2026-2027).
- **Tipos:** Factura Electrónica (también innominada consumidor final), Autofactura, N.Crédito/Débito, N.Remisión.
- **Estándar:** XML firmado → API SIFEN aprueba; **CDC 44 díg.** en QR del **KuDE**; ~72h en algunos casos.
- **ID cliente:** RUC/CI; innominada salvo umbral. PYG **sin decimales**. POS: CDC, KuDE, clearance asíncrono.

## Venezuela (VE) — máquinas fiscales (no clearance)
**No hay e-invoicing real con XML/firma/clearance a 2026.** Validez por **número de control** + **máquinas fiscales** (memoria fiscal) para B2C; nuevo track de "facturación digital" (software homologado PA 0121 + imprenta digital PA 0102).
- **Autoridad:** SENIAT. **Obligatorio:** máquina fiscal obligatoria restaurantes/retail.
- **POS (gran restricción):** un POS de software puro **NO** puede emitir el recibo fiscal B2C solo; necesita impresora fiscal certificada o software homologado. **IGTF 3%** (pagos en divisa) como línea separada. Reporte X/Z.

---

# Países de BAJA prioridad
- **CA:** sin e-invoice fiscal. GST/HST/PST. Peppol B2G voluntario. Abierto como US.
- **HN:** **CAI** (Clave de Autorización de Impresión) vía SAR; e-invoice en fases (**NO CONFIRMADO**). POS gestiona CAI/rango/vencimiento.
- **NI:** opt-in (no CTC general confirmado). Base: "Pie de Imprenta Fiscal". Fuentes escasas.
- **DE:** e-Rechnung B2B (XRechnung/ZUGFeRD). **B2C no**. POS crítico: **KassenSichV** → **TSE** firma cada transacción + DSFinV-K.
- **FR:** reforma B2B 2026-27 (Factur-X/PDP/Chorus Pro); **B2C vía e-reporting**.
- **IT:** **SdI** (FatturaPA) B2B/B2C desde 2019; retail usa **Registratore Telematico (RT)**; desde 1 ene 2026 RT enlazado al POS de pago.
- **PT:** software **certificado por AT**, **SAF-T (PT)**, **ATCUD + QR** obligatorios; QES en PDF desde 1 ene 2027.
- **GB:** sin e-invoice fiscal; MTD; mandato B2B previsto 1 abr 2029.
- **CH:** sin obligatorio B2C; **QR-bill** pagos; eBill/Peppol voluntario.
- **SE:** B2G Peppol obligatorio; B2B/B2C no; retail **Kassaregister** certificado.
- **PL:** **KSeF** B2B (feb-abr 2026; micro 2027); B2C **kasy fiskalne**.

---

# Implicaciones para arquitectura de POS

El POS necesita una **abstracción por país** (proveedor/validación), catálogo de tipos de documento, reglas de ID del cliente (requerido vs opcional + umbral) y representaciones de impresión (QR/PDF417/códigos/claves). Agrupaciones:

### Patrón A — Clearance por documento (validación en línea con la autoridad)
DO, CO, CR, BO, GT, PA, PY, EC (tiempo real 2026), AR (WSFE→CAE), BR (SEFAZ + contingencia offline). Requiere conectividad + contingencia.

### Patrón B — Proveedor autorizado obligatorio (PAC/OSE)
MX (PAC→UUID), PE (OSE/PSE), PA (PAC sobre umbral), PY (PAC o directo).

### Patrón C — Pre-autorización de rangos + reporte diferido (tolerante offline)
UY (CAE + reporte diario), CL (folios CAF + reporte boletas), AR-CAEA, BR-CSC (hash QR en contingencia).

### Patrón D — Software anti-manipulación (hash + QR), sin clearance
ES (Verifactu/SIF, SHA-256 + QR, online o local).

### Patrón E — Hardware/software fiscal certificado obligatorio
VE (máquina fiscal), DE (TSE/KassenSichV), IT (RT enlazado al POS), SE (Kassaregister), PL (kasy fiskalne B2C), PT (software certificado AT + ATCUD/QR). Un POS de software puro puede no bastar.

### Patrón F — Sin factura electrónica fiscal (basta recibo comercial)
US, CA, GB, CH. El reto es el **cálculo de impuestos** por jurisdicción + declaración periódica (integrar Avalara/TaxJar/Vertex).

### IDs fiscales del cliente a soportar
RNC (DO), RFC (MX), NIT/cédula (CO,GT,HN), RUT (CL,UY), CUIT/DNI (AR), RUC/DNI (PE,EC,PY), CNPJ/CPF (BR), NIF/CIF (ES,EU), CI (BO), RIF (VE), GST/EIN (US/CA).
**Patrón común:** ID del comprador **opcional bajo un umbral** (ticket consumidor) y **obligatorio para factura con crédito fiscal/B2B**. El POS debe modelar "ticket simple sin ID" vs "factura nominada con ID" por país.

### IDs de documento a generar/almacenar
e-NCF + Código Seguridad (DO), UUID (MX), CUFE/CUDE (CO), folio+PDF417 (CL), CAE 14 (AR), clave 49 + RIDE (EC), chave 44 + CSC (BR), CUF+CUFD (BO), CDC 44 + KuDE (PY), clave 50 (CR), N. Autorización/UUID (GT), CUFE (PA), número de control (VE), hash SHA-256 (ES).

### Recomendaciones de diseño transversales
1. **Capa "fiscal provider" pluggable por país** (emitir/anular/consultar/contingencia) con adaptadores: clearance directo, PAC/OSE, rangos+batch, hash local, hardware fiscal.
2. **Contingencia/offline first-class** (DO/PY 72h, CR 48h, BR offline+CSC, AR CAEA, UY/CL batch). El POS de restaurante no puede bloquearse sin red.
3. **Catálogo de tipos de documento por país** mapeado a concepto interno (venta consumidor / factura nominada / N.Crédito / N.Débito / pago).
4. **Render de representación configurable** (QR, PDF417, códigos, leyendas, ATCUD, IGTF).
5. **Captura de tax ID del cliente con umbral por país.**
6. **US/CA/GB/CH: motor de cálculo de impuestos por jurisdicción** (no clearance).
7. **VE/DE/IT/SE/PL/PT: dependencia de hardware/software certificado** — evaluar certificación local o integración con dispositivos de terceros.

---

## Incertidumbres principales (re-verificar antes de comprometer)
- DO: plazo final SMB 2026 (mayo vs nov). ES: fechas Verifactu/Crea y Crece (~2027) pospuestas. AR: "CAE-only jun 2026" y campo condición-IVA abr 2026 (confirmar RG). BR: mandatos por estado + fechas IBS/CBS. CR: suspensión QR v4.4. GT: estatus de Consumidor Final. UY/EC: umbrales de ID. PY: cobertura retail fin 2026. VE: fechas phase-in + software homologado. HN/NI: calendario CTC poco verificable. FR/PT/GB/PL: fechas volátiles.

> **Fiabilidad:** parte de los datos se obtuvo vía resúmenes de búsqueda; varios portales/PDFs oficiales no fueron accesibles en sesión. Para implementación legal/técnica, abrir los manuales técnicos y resoluciones oficiales de cada autoridad y confirmar fechas vigentes.
