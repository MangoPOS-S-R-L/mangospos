// Set de pruebas de la DGII para la certificacion como emisor electronico.
//
// La DGII entrega, en su portal de certificacion ("Pruebas de datos e-CF"), un
// Excel con los comprobantes exactos que hay que mandar: una hoja ECF (un e-CF
// por fila) y una hoja RFCE (los resumenes de las facturas de consumo menores
// de RD$250 mil). Cada columna es un elemento del XML (`FormaPago[1]`,
// `NombreItem[3]`, `TipoCodigo[2][1]`...) y "#e" quiere decir vacio. Los XML
// tienen que llevar esos mismos datos: aqui no se calcula ni se corrige nada.
//
// En el paso siguiente ("Pruebas de datos aprobacion comercial") la DGII da
// otro Excel: el contribuyente hace de COMPRADOR y aprueba (o rechaza) e-CF que
// la DGII le "emitio". Cada fila es un ACECF.
//
// Este modulo es puro (sin red ni BD): lee el archivo (.xlsx, o .csv de una
// hoja), reconoce cual de los dos sets es, valida los casos y arma el XML de
// cada uno en el orden de los XSD v1.0 de la DGII. La firma y el envio viven en
// dgii-signer.ts y dgii-certification.ts.

// ── Estructura de los XSD ────────────────────────────────────────────────────
//
// Contenedor y elementos de cada e-CF, en el orden de los XSD "e-CF 31..47
// v.1.0" (union de todos los tipos; ningun tipo usa a la vez dos elementos cuyo
// orden relativo cambie entre XSD). `*` = se repite: cada uno consume un indice
// de la columna del Excel, de afuera hacia adentro. FechaHoraFirma no viene en
// el Excel: la pone la firma.
const ECF_LAYOUT: ReadonlyArray<readonly [string, string]> = [
  ["Encabezado", "Version"],
  ["Encabezado/IdDoc", "TipoeCF eNCF IndicadorNotaCredito FechaVencimientoSecuencia IndicadorEnvioDiferido"],
  ["Encabezado/IdDoc", "IndicadorMontoGravado IndicadorServicioTodoIncluido TipoIngresos TipoPago"],
  ["Encabezado/IdDoc", "FechaLimitePago TerminoPago"],
  ["Encabezado/IdDoc/TablaFormasPago/FormaDePago*", "FormaPago MontoPago"],
  ["Encabezado/IdDoc", "TipoCuentaPago NumeroCuentaPago BancoPago FechaDesde FechaHasta TotalPaginas"],
  ["Encabezado/Emisor", "RNCEmisor RazonSocialEmisor NombreComercial Sucursal DireccionEmisor Municipio"],
  ["Encabezado/Emisor", "Provincia"],
  ["Encabezado/Emisor/TablaTelefonoEmisor", "TelefonoEmisor*"],
  ["Encabezado/Emisor", "CorreoEmisor WebSite ActividadEconomica CodigoVendedor NumeroFacturaInterna"],
  ["Encabezado/Emisor", "NumeroPedidoInterno ZonaVenta RutaVenta InformacionAdicionalEmisor FechaEmision"],
  ["Encabezado/Comprador", "RNCComprador IdentificadorExtranjero RazonSocialComprador ContactoComprador"],
  ["Encabezado/Comprador", "CorreoComprador DireccionComprador MunicipioComprador ProvinciaComprador"],
  ["Encabezado/Comprador", "PaisComprador FechaEntrega ContactoEntrega DireccionEntrega TelefonoAdicional"],
  ["Encabezado/Comprador", "FechaOrdenCompra NumeroOrdenCompra CodigoInternoComprador ResponsablePago"],
  ["Encabezado/Comprador", "InformacionAdicionalComprador"],
  ["Encabezado/InformacionesAdicionales", "FechaEmbarque NumeroEmbarque NumeroContenedor NumeroReferencia"],
  ["Encabezado/InformacionesAdicionales", "NombrePuertoEmbarque CondicionesEntrega TotalFob Seguro Flete"],
  ["Encabezado/InformacionesAdicionales", "OtrosGastos TotalCif RegimenAduanero NombrePuertoSalida"],
  ["Encabezado/InformacionesAdicionales", "NombrePuertoDesembarque PesoBruto PesoNeto UnidadPesoBruto"],
  ["Encabezado/InformacionesAdicionales", "UnidadPesoNeto CantidadBulto UnidadBulto VolumenBulto"],
  ["Encabezado/InformacionesAdicionales", "UnidadVolumen"],
  ["Encabezado/Transporte", "ViaTransporte PaisOrigen DireccionDestino PaisDestino"],
  ["Encabezado/Transporte", "RNCIdentificacionCompaniaTransportista NombreCompaniaTransportista NumeroViaje"],
  ["Encabezado/Transporte", "Conductor DocumentoTransporte Ficha Placa RutaTransporte ZonaTransporte"],
  ["Encabezado/Transporte", "NumeroAlbaran"],
  ["Encabezado/Totales", "MontoGravadoTotal MontoGravadoI1 MontoGravadoI2 MontoGravadoI3 MontoExento ITBIS1"],
  ["Encabezado/Totales", "ITBIS2 ITBIS3 TotalITBIS TotalITBIS1 TotalITBIS2 TotalITBIS3"],
  ["Encabezado/Totales", "MontoImpuestoAdicional"],
  ["Encabezado/Totales/ImpuestosAdicionales/ImpuestoAdicional*", "TipoImpuesto TasaImpuestoAdicional"],
  ["Encabezado/Totales/ImpuestosAdicionales/ImpuestoAdicional*", "MontoImpuestoSelectivoConsumoEspecifico"],
  ["Encabezado/Totales/ImpuestosAdicionales/ImpuestoAdicional*", "MontoImpuestoSelectivoConsumoAdvalorem"],
  ["Encabezado/Totales/ImpuestosAdicionales/ImpuestoAdicional*", "OtrosImpuestosAdicionales"],
  ["Encabezado/Totales", "MontoTotal MontoNoFacturable MontoPeriodo SaldoAnterior MontoAvancePago"],
  ["Encabezado/Totales", "ValorPagar TotalITBISRetenido TotalISRRetencion TotalITBISPercepcion"],
  ["Encabezado/Totales", "TotalISRPercepcion"],
  ["Encabezado/OtraMoneda", "TipoMoneda TipoCambio MontoGravadoTotalOtraMoneda MontoGravado1OtraMoneda"],
  ["Encabezado/OtraMoneda", "MontoGravado2OtraMoneda MontoGravado3OtraMoneda MontoExentoOtraMoneda"],
  ["Encabezado/OtraMoneda", "TotalITBISOtraMoneda TotalITBIS1OtraMoneda TotalITBIS2OtraMoneda"],
  ["Encabezado/OtraMoneda", "TotalITBIS3OtraMoneda MontoImpuestoAdicionalOtraMoneda"],
  ["Encabezado/OtraMoneda/ImpuestosAdicionalesOtraMoneda/ImpuestoAdicionalOtraMoneda*", "TipoImpuestoOtraMoneda"],
  ["Encabezado/OtraMoneda/ImpuestosAdicionalesOtraMoneda/ImpuestoAdicionalOtraMoneda*", "TasaImpuestoAdicionalOtraMoneda"],
  [
    "Encabezado/OtraMoneda/ImpuestosAdicionalesOtraMoneda/ImpuestoAdicionalOtraMoneda*",
    "MontoImpuestoSelectivoConsumoEspecificoOtraMoneda",
  ],
  [
    "Encabezado/OtraMoneda/ImpuestosAdicionalesOtraMoneda/ImpuestoAdicionalOtraMoneda*",
    "MontoImpuestoSelectivoConsumoAdvaloremOtraMoneda",
  ],
  ["Encabezado/OtraMoneda/ImpuestosAdicionalesOtraMoneda/ImpuestoAdicionalOtraMoneda*", "OtrosImpuestosAdicionalesOtraMoneda"],
  ["Encabezado/OtraMoneda", "MontoTotalOtraMoneda"],
  ["DetallesItems/Item*", "NumeroLinea"],
  ["DetallesItems/Item*/TablaCodigosItem/CodigosItem*", "TipoCodigo CodigoItem"],
  ["DetallesItems/Item*", "IndicadorFacturacion"],
  ["DetallesItems/Item*/Retencion", "IndicadorAgenteRetencionoPercepcion MontoITBISRetenido"],
  ["DetallesItems/Item*/Retencion", "MontoISRRetenido"],
  ["DetallesItems/Item*", "NombreItem IndicadorBienoServicio DescripcionItem CantidadItem UnidadMedida"],
  ["DetallesItems/Item*", "CantidadReferencia UnidadReferencia"],
  ["DetallesItems/Item*/TablaSubcantidad/SubcantidadItem*", "Subcantidad CodigoSubcantidad"],
  ["DetallesItems/Item*", "GradosAlcohol PrecioUnitarioReferencia FechaElaboracion FechaVencimientoItem"],
  ["DetallesItems/Item*/Mineria", "PesoNetoKilogramo PesoNetoMineria TipoAfiliacion Liquidacion"],
  ["DetallesItems/Item*", "PrecioUnitarioItem DescuentoMonto"],
  ["DetallesItems/Item*/TablaSubDescuento/SubDescuento*", "TipoSubDescuento SubDescuentoPorcentaje"],
  ["DetallesItems/Item*/TablaSubDescuento/SubDescuento*", "MontoSubDescuento"],
  ["DetallesItems/Item*", "RecargoMonto"],
  ["DetallesItems/Item*/TablaSubRecargo/SubRecargo*", "TipoSubRecargo SubRecargoPorcentaje MontoSubRecargo"],
  ["DetallesItems/Item*/TablaImpuestoAdicional/ImpuestoAdicional*", "TipoImpuesto"],
  ["DetallesItems/Item*/OtraMonedaDetalle", "PrecioOtraMoneda DescuentoOtraMoneda RecargoOtraMoneda"],
  ["DetallesItems/Item*/OtraMonedaDetalle", "MontoItemOtraMoneda"],
  ["DetallesItems/Item*", "MontoItem"],
  ["Subtotales/Subtotal*", "NumeroSubTotal DescripcionSubtotal Orden SubTotalMontoGravadoTotal"],
  ["Subtotales/Subtotal*", "SubTotalMontoGravadoI1 SubTotalMontoGravadoI2 SubTotalMontoGravadoI3"],
  ["Subtotales/Subtotal*", "SubTotaITBIS SubTotaITBIS1 SubTotaITBIS2 SubTotaITBIS3"],
  ["Subtotales/Subtotal*", "SubTotalImpuestoAdicional SubTotalExento MontoSubTotal Lineas"],
  ["DescuentosORecargos/DescuentoORecargo*", "NumeroLinea TipoAjuste IndicadorNorma1007"],
  ["DescuentosORecargos/DescuentoORecargo*", "DescripcionDescuentooRecargo TipoValor ValorDescuentooRecargo"],
  ["DescuentosORecargos/DescuentoORecargo*", "MontoDescuentooRecargo MontoDescuentooRecargoOtraMoneda"],
  ["DescuentosORecargos/DescuentoORecargo*", "IndicadorFacturacionDescuentooRecargo"],
  ["Paginacion/Pagina*", "PaginaNo NoLineaDesde NoLineaHasta SubtotalMontoGravadoPagina"],
  ["Paginacion/Pagina*", "SubtotalMontoGravado1Pagina SubtotalMontoGravado2Pagina"],
  ["Paginacion/Pagina*", "SubtotalMontoGravado3Pagina SubtotalExentoPagina SubtotalItbisPagina"],
  ["Paginacion/Pagina*", "SubtotalItbis1Pagina SubtotalItbis2Pagina SubtotalItbis3Pagina"],
  ["Paginacion/Pagina*", "SubtotalImpuestoAdicionalPagina"],
  ["Paginacion/Pagina*/SubtotalImpuestoAdicional", "SubtotalImpuestoSelectivoConsumoEspecificoPagina"],
  ["Paginacion/Pagina*/SubtotalImpuestoAdicional", "SubtotalOtrosImpuesto"],
  ["Paginacion/Pagina*", "MontoSubtotalPagina SubtotalMontoNoFacturablePagina"],
  ["InformacionReferencia", "NCFModificado RNCOtroContribuyente FechaNCFModificado CodigoModificacion"],
  ["InformacionReferencia", "RazonModificacion"],
];

/** "RFCE 32 v.1.0.xsd". CodigoSeguridadeCF sale de la firma del E32. */
const RFCE_LAYOUT: ReadonlyArray<readonly [string, string]> = [
  ["Encabezado", "Version"],
  ["Encabezado/IdDoc", "TipoeCF eNCF TipoIngresos TipoPago"],
  ["Encabezado/IdDoc/TablaFormasPago/FormaDePago*", "FormaPago MontoPago"],
  ["Encabezado/Emisor", "RNCEmisor RazonSocialEmisor FechaEmision"],
  ["Encabezado/Comprador", "RNCComprador IdentificadorExtranjero RazonSocialComprador"],
  ["Encabezado/Totales", "MontoGravadoTotal MontoGravadoI1 MontoGravadoI2 MontoGravadoI3 MontoExento"],
  ["Encabezado/Totales", "TotalITBIS TotalITBIS1 TotalITBIS2 TotalITBIS3 MontoImpuestoAdicional"],
  ["Encabezado/Totales/ImpuestosAdicionales/ImpuestoAdicional*", "TipoImpuesto"],
  ["Encabezado/Totales/ImpuestosAdicionales/ImpuestoAdicional*", "MontoImpuestoSelectivoConsumoEspecifico"],
  ["Encabezado/Totales/ImpuestosAdicionales/ImpuestoAdicional*", "MontoImpuestoSelectivoConsumoAdvalorem"],
  ["Encabezado/Totales/ImpuestosAdicionales/ImpuestoAdicional*", "OtrosImpuestosAdicionales"],
  ["Encabezado/Totales", "MontoTotal MontoNoFacturable MontoPeriodo"],
  ["Encabezado", "CodigoSeguridadeCF"],
];

/** "ACECF v.1.0.xsd". */
const ACECF_LAYOUT: ReadonlyArray<readonly [string, string]> = [
  ["DetalleAprobacionComercial", "Version RNCEmisor eNCF FechaEmision MontoTotal RNCComprador Estado"],
  ["DetalleAprobacionComercial", "DetalleMotivoRechazo FechaHoraAprobacionComercial"],
];

/** Nombres del Excel que no son el del XSD. La comparacion ignora mayusculas
 *  (ENCF = eNCF, MontosubRecargo = MontoSubRecargo). */
const DGII_COLUMN_ALIASES: Record<string, string> = {
  // El Excel distingue la linea del descuento/recargo global de la del item.
  numerolineador: "DescuentosORecargos/DescuentoORecargo*/NumeroLinea",
};

/** Columnas del Excel que no van en el XML. */
const IGNORED_COLUMNS = new Set(["casoprueba"]);

interface Segment {
  name: string;
  repeats: boolean;
  /** Ruta sin indices hasta este segmento: para ordenar hermanos. */
  key: string;
}

interface ElementSpec {
  containers: Segment[];
  leaf: Segment;
  /** Cuantos indices pide la columna del Excel. */
  indexes: number;
}

interface Layout {
  root: string;
  byColumn: Map<string, ElementSpec>;
  /** Orden de cada contenedor/elemento dentro de su padre (posicion en el XSD). */
  order: Map<string, number>;
}

function buildLayout(root: string, rows: ReadonlyArray<readonly [string, string]>): Layout {
  const order = new Map<string, number>();
  const byPath = new Map<string, ElementSpec>();
  let pos = 0;
  for (const [container, names] of rows) {
    const containers: Segment[] = [];
    let key = "";
    for (const raw of container.split("/").filter((s) => s.length > 0)) {
      const name = raw.replace("*", "");
      key = key ? `${key}/${name}` : name;
      containers.push({ name, repeats: raw.endsWith("*"), key });
    }
    for (const rawLeaf of names.split(" ")) {
      const name = rawLeaf.replace("*", "");
      const leafKey = key ? `${key}/${name}` : name;
      const leaf: Segment = { name, repeats: rawLeaf.endsWith("*"), key: leafKey };
      const indexes = containers.filter((c) => c.repeats).length + (leaf.repeats ? 1 : 0);
      // Un contenedor se ordena por su primer elemento.
      for (const c of containers) if (!order.has(c.key)) order.set(c.key, pos);
      order.set(leafKey, pos++);
      byPath.set(`${container}/${rawLeaf.replace("*", "")}`.replace(/^\//, ""), { containers, leaf, indexes });
    }
  }

  const byColumn = new Map<string, ElementSpec>();
  const add = (column: string, spec: ElementSpec) => {
    const k = `${column.toLowerCase()}#${spec.indexes}`;
    if (byColumn.has(k)) throw new Error(`Columna ambigua en el layout ${root}: ${k}`);
    byColumn.set(k, spec);
  };
  for (const [path, spec] of byPath) {
    if (Object.values(DGII_COLUMN_ALIASES).includes(path)) continue;
    add(spec.leaf.name, spec);
  }
  for (const [alias, path] of Object.entries(DGII_COLUMN_ALIASES)) {
    const spec = byPath.get(path);
    if (spec) add(alias, spec);
  }
  return { root, byColumn, order };
}

const ECF = buildLayout("ECF", ECF_LAYOUT);
const RFCE = buildLayout("RFCE", RFCE_LAYOUT);
const ACECF = buildLayout("ACECF", ACECF_LAYOUT);

// ── Armado del XML ───────────────────────────────────────────────────────────

/** Par columna/valor tal cual vino en el archivo (solo los que tienen valor). */
export type TestSetField = [string, string];

interface XmlNode {
  name: string;
  key: string;
  index: number;
  children: XmlNode[];
  text?: string;
}

export class TestSetLayoutError extends Error {
  constructor(public columns: string[]) {
    super(`Columnas que no corresponden a ningun elemento del XSD: ${columns.join(", ")}.`);
  }
}

const COLUMN_RE = /^([^[\]]+)((?:\[\d+\])*)$/;

/** Celda vacia para la DGII: en blanco o "#e". */
export function isEmptyCell(v: string | null | undefined): boolean {
  if (v === null || v === undefined) return true;
  const t = v.trim();
  return t.length === 0 || t.toLowerCase() === "#e";
}

function buildTree(layout: Layout, fields: TestSetField[]): XmlNode {
  const root: XmlNode = { name: layout.root, key: "", index: 0, children: [] };
  const unknown: string[] = [];
  for (const [column, value] of fields) {
    const m = COLUMN_RE.exec(column.trim());
    if (!m) {
      unknown.push(column);
      continue;
    }
    const base = m[1].trim().toLowerCase();
    if (IGNORED_COLUMNS.has(base)) continue;
    const indexes = [...m[2].matchAll(/\[(\d+)\]/g)].map((x) => Number(x[1]));
    const spec = layout.byColumn.get(`${base}#${indexes.length}`);
    if (!spec) {
      unknown.push(column);
      continue;
    }
    let node = root;
    let i = 0;
    for (const seg of [...spec.containers, spec.leaf]) {
      const index = seg.repeats ? indexes[i++] : 0;
      const isLeaf = seg === spec.leaf;
      let child = isLeaf ? undefined : node.children.find((c) => c.key === seg.key && c.index === index);
      if (!child) {
        child = { name: seg.name, key: seg.key, index, children: [] };
        node.children.push(child);
      }
      node = child;
    }
    node.text = value;
  }
  if (unknown.length > 0) throw new TestSetLayoutError(unknown);
  return root;
}

/** Texto con el escape de la forma canonica (C14N): `"` y `'` van tal cual. */
function escapeText(v: string): string {
  return v.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\r/g, "&#xD;");
}

function serialize(layout: Layout, node: XmlNode, out: string[]): void {
  out.push(`<${node.name}>`);
  if (node.text !== undefined) {
    out.push(escapeText(node.text));
  } else {
    const kids = [...node.children].sort((a, b) =>
      (layout.order.get(a.key)! - layout.order.get(b.key)!) || (a.index - b.index)
    );
    for (const k of kids) serialize(layout, k, out);
  }
  out.push(`</${node.name}>`);
}

/**
 * XML del e-CF, sin declaracion y ya en forma canonica (lo que se firma). Los
 * datos van tal cual el Excel; [signedAt] es FechaHoraFirma.
 */
export function buildEcfXml(fields: TestSetField[], signedAt: string): string {
  const root = buildTree(ECF, fields);
  const out: string[] = [];
  serialize(ECF, root, out);
  out.splice(out.length - 1, 0, `<FechaHoraFirma>${escapeText(signedAt)}</FechaHoraFirma>`);
  return out.join("");
}

/** XML del resumen (RFCE) de una factura de consumo menor de RD$250 mil. */
export function buildRfceXml(fields: TestSetField[], securityCode: string): string {
  const withCode = fields.filter(([c]) => c.trim().toLowerCase() !== "codigoseguridadecf");
  withCode.push(["CodigoSeguridadeCF", securityCode]);
  const root = buildTree(RFCE, withCode);
  const out: string[] = [];
  serialize(RFCE, root, out);
  return out.join("");
}

/**
 * Monto con exactamente dos decimales (Decimal18D2 del XSD). La hoja de
 * aprobaciones trae numeros de Excel (7080, 228460.5), no texto como la del e-CF.
 */
export function twoDecimals(v: string): string {
  const t = v.trim();
  if (/^\d+\.\d{2}$/.test(t)) return t;
  if (/^\d+$/.test(t)) return `${t}.00`;
  if (/^\d+\.\d$/.test(t)) return `${t}0`;
  const n = Number(t);
  return Number.isFinite(n) && n >= 0 ? n.toFixed(2) : t;
}

/** XML de la aprobacion comercial, en forma canonica (lo que se firma). */
export function buildAcecfXml(fields: TestSetField[]): string {
  const normalized = fields.map(([c, v]): TestSetField =>
    c.trim().toLowerCase() === "montototal" ? [c, twoDecimals(v)] : [c, v]
  );
  const root = buildTree(ACECF, normalized);
  const out: string[] = [];
  serialize(ACECF, root, out);
  return out.join("");
}

/** Columnas que lleva el RFCE. Las demas del E32 no van en el resumen. */
function isRfceColumn(column: string): boolean {
  const m = COLUMN_RE.exec(column.trim());
  if (!m) return false;
  const base = m[1].trim().toLowerCase();
  if (IGNORED_COLUMNS.has(base)) return true;
  const indexes = (m[2].match(/\[/g) ?? []).length;
  return RFCE.byColumn.has(`${base}#${indexes}`) && base !== "codigoseguridadecf";
}

/** Resumen armado con las mismas columnas del E32 (cuando no vino la hoja RFCE). */
export function summaryFieldsFrom(ecfFields: TestSetField[]): TestSetField[] {
  return ecfFields.filter(([c]) => isRfceColumn(c));
}

// ── Lectura del archivo ──────────────────────────────────────────────────────

export interface TestSetSheets {
  ecf: string[][];
  rfce: string[][] | null;
}

/** `ecf` = pruebas de datos e-CF (+ RFCE); `acecf` = aprobacion comercial; `sim` = simulacion e-CF. */
export type TestSetKind = "ecf" | "acecf" | "sim";

export type TestSetFile =
  | { kind: "ecf"; sheets: TestSetSheets }
  | { kind: "acecf"; rows: string[][] };

/** Fecha y hora de firma como la pide la DGII (dd-MM-yyyy HH:mm:ss, hora de RD). */
export function dgiiTimestamp(now: Date = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "America/Santo_Domingo",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(now);
  const p = Object.fromEntries(parts.map((x) => [x.type, x.value]));
  return `${p.day}-${p.month}-${p.year} ${p.hour}:${p.minute}:${p.second}`;
}

/** CSV de Excel: coma o punto y coma, comillas dobles, BOM opcional. */
export function parseCsv(text: string): string[][] {
  const src = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  const firstLine = src.slice(0, src.search(/\r?\n|$/));
  const delimiter = (firstLine.match(/;/g)?.length ?? 0) > (firstLine.match(/,/g)?.length ?? 0) ? ";" : ",";

  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < src.length; i++) {
    const ch = src[i];
    if (quoted) {
      if (ch === '"') {
        if (src[i + 1] === '"') {
          cell += '"';
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell += ch;
      }
    } else if (ch === '"') {
      quoted = true;
    } else if (ch === delimiter) {
      row.push(cell);
      cell = "";
    } else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && src[i + 1] === "\n") i++;
      row.push(cell);
      rows.push(row);
      row = [];
      cell = "";
    } else {
      cell += ch;
    }
  }
  if (cell.length > 0 || row.length > 0) {
    row.push(cell);
    rows.push(row);
  }
  return rows.filter((r) => r.some((c) => c.length > 0));
}

function decodeXmlEntities(v: string): string {
  return v.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos);/gi, (_, e: string) => {
    const k = e.toLowerCase();
    if (k === "amp") return "&";
    if (k === "lt") return "<";
    if (k === "gt") return ">";
    if (k === "quot") return '"';
    if (k === "apos") return "'";
    const code = k.startsWith("#x") ? parseInt(k.slice(2), 16) : parseInt(k.slice(1), 10);
    return String.fromCodePoint(code);
  });
}

/** Texto de los `<t>` de un `<si>` o `<is>` (sin la guia fonetica `<rPh>`). */
function richText(xml: string): string {
  const clean = xml.replace(/<rPh\b[\s\S]*?<\/rPh>/g, "");
  let out = "";
  for (const m of clean.matchAll(/<t\b[^>]*\/>|<t\b[^>]*>([\s\S]*?)<\/t>/g)) out += m[1] ?? "";
  return decodeXmlEntities(out);
}

function columnIndex(ref: string): number {
  const letters = /^[A-Z]+/.exec(ref)?.[0] ?? "";
  let n = 0;
  for (const ch of letters) n = n * 26 + (ch.charCodeAt(0) - 64);
  return n - 1;
}

/** Lee un .zip en memoria (solo lo necesario para un .xlsx: stored y deflate). */
async function unzip(bytes: Uint8Array): Promise<Map<string, Uint8Array>> {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let eocd = -1;
  for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 65_557); i--) {
    if (view.getUint32(i, true) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error("El archivo no es un .xlsx valido (no es un zip).");
  const count = view.getUint16(eocd + 10, true);
  let p = view.getUint32(eocd + 16, true);
  const files = new Map<string, Uint8Array>();
  for (let n = 0; n < count; n++) {
    if (view.getUint32(p, true) !== 0x02014b50) throw new Error("El .xlsx esta danado (directorio del zip).");
    const method = view.getUint16(p + 10, true);
    const size = view.getUint32(p + 20, true);
    const nameLen = view.getUint16(p + 28, true);
    const extraLen = view.getUint16(p + 30, true);
    const commentLen = view.getUint16(p + 32, true);
    const local = view.getUint32(p + 42, true);
    const name = new TextDecoder().decode(bytes.subarray(p + 46, p + 46 + nameLen));
    p += 46 + nameLen + extraLen + commentLen;
    if (!/^(xl\/(workbook\.xml|sharedStrings\.xml|worksheets\/[^/]+\.xml|_rels\/workbook\.xml\.rels))$/.test(name)) {
      continue;
    }
    if (size === 0xffffffff) throw new Error("El .xlsx es demasiado grande.");
    const start = local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
    const data = bytes.subarray(start, start + size);
    if (method === 0) {
      files.set(name, data);
    } else if (method === 8) {
      const stream = new Blob([new Uint8Array(data)]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
      files.set(name, new Uint8Array(await new Response(stream).arrayBuffer()));
    } else {
      throw new Error(`El .xlsx usa una compresion no soportada (${method}).`);
    }
  }
  return files;
}

/** Hojas de un .xlsx por nombre, como filas de texto. */
export async function readXlsx(bytes: Uint8Array): Promise<Map<string, string[][]>> {
  const files = await unzip(bytes);
  const text = (name: string) => {
    const f = files.get(name);
    return f ? new TextDecoder().decode(f) : null;
  };
  const workbook = text("xl/workbook.xml");
  const rels = text("xl/_rels/workbook.xml.rels");
  if (!workbook || !rels) throw new Error("El .xlsx no tiene libro de trabajo.");

  const targets = new Map<string, string>();
  for (const m of rels.matchAll(/<Relationship\b[^>]*>/g)) {
    const id = /\bId="([^"]+)"/.exec(m[0])?.[1];
    const target = /\bTarget="([^"]+)"/.exec(m[0])?.[1];
    if (id && target) {
      targets.set(id, target.startsWith("/") ? target.slice(1) : `xl/${target.replace(/^\.\//, "")}`);
    }
  }

  const shared: string[] = [];
  const sst = text("xl/sharedStrings.xml");
  if (sst) for (const m of sst.matchAll(/<si\b[^>]*\/>|<si\b[^>]*>([\s\S]*?)<\/si>/g)) shared.push(richText(m[1] ?? ""));

  const sheets = new Map<string, string[][]>();
  for (const m of workbook.matchAll(/<sheet\b[^>]*>/g)) {
    const name = decodeXmlEntities(/\bname="([^"]*)"/.exec(m[0])?.[1] ?? "");
    const rid = /\br:id="([^"]+)"/.exec(m[0])?.[1] ?? /\bid="([^"]+)"/.exec(m[0])?.[1];
    const xml = rid ? text(targets.get(rid) ?? "") : null;
    if (!xml) continue;
    const rows: string[][] = [];
    for (const r of xml.matchAll(/<row\b[^>]*?(?:\/>|>([\s\S]*?)<\/row>)/g)) {
      const row: string[] = [];
      for (const c of (r[1] ?? "").matchAll(/<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
        const attrs = c[1];
        const ref = /\br="([A-Z]+)\d+"/.exec(attrs)?.[1];
        const idx = ref ? columnIndex(ref) : row.length;
        const type = /\bt="([^"]+)"/.exec(attrs)?.[1] ?? "n";
        const inner = c[2] ?? "";
        const v = /<v>([\s\S]*?)<\/v>/.exec(inner)?.[1];
        let value = "";
        if (type === "s") value = v !== undefined ? shared[Number(v)] ?? "" : "";
        else if (type === "inlineStr") value = richText(inner);
        else value = v !== undefined ? decodeXmlEntities(v) : "";
        while (row.length < idx) row.push("");
        row[idx] = value;
      }
      rows.push(row);
    }
    sheets.set(name, rows.filter((r) => r.some((c) => c.length > 0)));
  }
  return sheets;
}

const MAX_TEST_SET_FILE_BYTES = 5 * 1024 * 1024;

function header(rows: string[][]): string[] {
  return (rows[0] ?? []).map((h) => h.trim().toLowerCase());
}

function isRfceSheet(rows: string[][]): boolean {
  return header(rows).includes("codigoseguridadecf");
}

function isApprovalSheet(rows: string[][]): boolean {
  return header(rows).includes("fechahoraaprobacioncomercial");
}

/**
 * Reconoce el set: el de e-CF (.xlsx con las hojas ECF y RFCE, o .csv de la
 * hoja ECF) o el de aprobaciones comerciales (una hoja con
 * FechaHoraAprobacionComercial).
 */
export async function readTestSetFile(filename: string, bytes: Uint8Array): Promise<TestSetFile> {
  if (bytes.length === 0) throw new Error("El archivo esta vacio.");
  if (bytes.length > MAX_TEST_SET_FILE_BYTES) throw new Error("El archivo es demasiado grande para ser el set de la DGII.");
  const ext = filename.trim().toLowerCase().split(".").pop();
  if (ext === "csv") {
    const rows = parseCsv(new TextDecoder().decode(bytes));
    if (isApprovalSheet(rows)) return { kind: "acecf", rows };
    if (isRfceSheet(rows)) {
      throw new Error("Ese CSV es la hoja RFCE. Sube la hoja ECF (o el .xlsx completo de la DGII).");
    }
    return { kind: "ecf", sheets: { ecf: rows, rfce: null } };
  }
  if (ext !== "xlsx") throw new Error("El archivo tiene que ser el .xlsx de la DGII o un .csv de una de sus hojas.");

  const sheets = await readXlsx(bytes);
  const approvals = [...sheets.values()].find(isApprovalSheet);
  if (approvals) return { kind: "acecf", rows: approvals };
  const byName = (name: string) => [...sheets].find(([n]) => n.trim().toUpperCase() === name)?.[1] ?? null;
  const ecf = byName("ECF") ?? [...sheets.values()].find((r) => header(r).includes("encf") && !isRfceSheet(r)) ?? null;
  const rfce = byName("RFCE") ?? [...sheets.values()].find(isRfceSheet) ?? null;
  if (!ecf) throw new Error("El .xlsx no tiene la hoja ECF ni la de aprobaciones comerciales de la DGII.");
  return { kind: "ecf", sheets: { ecf, rfce } };
}

// ── Casos ────────────────────────────────────────────────────────────────────

export const TEST_SET_ECF_TYPES = ["31", "32", "33", "34", "41", "43", "44", "45", "46", "47"];

/** Facturas de consumo desde este monto van completas a Recepcion; las menores, como resumen. */
export const CONSUMPTION_SUMMARY_LIMIT = 250_000;

const MAX_TEST_SET_CASES = 200;

export interface TestSetCase {
  position: number;
  case_id: string;
  ecf_type: string;
  encf: string;
  /** RNC del contribuyente que firma: el emisor en el e-CF, el comprador en el ACECF. */
  signer_rnc: string;
  total: number | null;
  /**
   * `ecf` → Recepcion. `rfce` → E32 menor de 250 mil: se firma y se manda su
   * resumen. `acecf` → aprobacion comercial.
   */
  via: "ecf" | "rfce" | "acecf";
  /** Nota de credito/debito: el e-CF que modifica. */
  modifies: string | null;
  fields: TestSetField[];
  summary_fields: TestSetField[] | null;
  /**
   * ACECF: RNC (solo digitos) del emisor del e-CF aprobado. El mismo e-NCF
   * puede venir de emisores distintos, asi que la aprobacion es emisor + e-NCF.
   */
  issuer_rnc?: string | null;
}

type Validation<T> = { ok: true; value: T } | { ok: false; errors: string[] };

function rowFields(head: string[], row: string[]): TestSetField[] {
  const out: TestSetField[] = [];
  head.forEach((column, i) => {
    const v = row[i];
    if (column.trim().length > 0 && !isEmptyCell(v)) out.push([column.trim(), v as string]);
  });
  return out;
}

function value(fields: TestSetField[], column: string): string | null {
  const c = column.toLowerCase();
  return fields.find(([k]) => k.toLowerCase() === c)?.[1].trim() ?? null;
}

export function parseTestSet(sheets: TestSetSheets): Validation<TestSetCase[]> {
  const errors: string[] = [];
  const head = sheets.ecf[0] ?? [];
  const lower = head.map((h) => h.trim().toLowerCase());
  if (!lower.includes("encf") || !lower.includes("tipoecf")) {
    return { ok: false, errors: ["El archivo no parece el set de pruebas de la DGII (faltan las columnas TipoeCF y ENCF)."] };
  }

  const summaries = new Map<string, TestSetField[]>();
  if (sheets.rfce && sheets.rfce.length > 1) {
    const rh = sheets.rfce[0];
    for (const row of sheets.rfce.slice(1)) {
      const f = rowFields(rh, row);
      const encf = value(f, "ENCF")?.toUpperCase();
      if (encf) summaries.set(encf, f);
    }
  }

  const cases: TestSetCase[] = [];
  const seen = new Set<string>();
  const rncs = new Set<string>();
  const rows = sheets.ecf.slice(1);
  if (rows.length > MAX_TEST_SET_CASES) {
    return { ok: false, errors: [`El archivo trae ${rows.length} filas; el set de la DGII no pasa de ${MAX_TEST_SET_CASES}.`] };
  }
  rows.forEach((row, i) => {
    const fields = rowFields(head, row);
    if (fields.length === 0) return;
    const line = i + 2;
    const encf = (value(fields, "ENCF") ?? "").toUpperCase();
    const type = value(fields, "TipoeCF") ?? "";
    const rnc = (value(fields, "RNCEmisor") ?? "").replace(/\D/g, "");
    if (!/^E\d{12}$/.test(encf)) {
      errors.push(`Fila ${line}: el e-NCF "${encf}" no es valido.`);
      return;
    }
    if (!TEST_SET_ECF_TYPES.includes(type) || encf.slice(1, 3) !== type) {
      errors.push(`Fila ${line} (${encf}): el tipo "${type}" no corresponde al e-NCF.`);
      return;
    }
    if (seen.has(encf)) {
      errors.push(`Fila ${line}: el e-NCF ${encf} esta repetido.`);
      return;
    }
    seen.add(encf);
    if (rnc) rncs.add(rnc);

    try {
      buildEcfXml(fields, "01-01-2000 00:00:00");
    } catch (e) {
      errors.push(`Fila ${line} (${encf}): ${e instanceof Error ? e.message : String(e)}`);
      return;
    }

    const totalRaw = value(fields, "MontoTotal");
    const total = totalRaw !== null && Number.isFinite(Number(totalRaw)) ? Number(totalRaw) : null;
    const via = type === "32" && total !== null && total < CONSUMPTION_SUMMARY_LIMIT ? "rfce" : "ecf";
    let summary: TestSetField[] | null = null;
    if (via === "rfce") {
      summary = summaries.get(encf) ?? summaryFieldsFrom(fields);
      try {
        buildRfceXml(summary, "000000");
      } catch (e) {
        errors.push(`Resumen de ${encf}: ${e instanceof Error ? e.message : String(e)}`);
        return;
      }
    }

    cases.push({
      position: cases.length + 1,
      case_id: value(fields, "CasoPrueba") ?? `${rnc}${encf}`,
      ecf_type: type,
      encf,
      signer_rnc: rnc,
      total,
      via,
      modifies: value(fields, "NCFModificado")?.toUpperCase() ?? null,
      fields,
      summary_fields: summary,
    });
  });

  if (rncs.size > 1) errors.push(`El archivo mezcla varios RNC emisores (${[...rncs].join(", ")}).`);
  if (errors.length === 0 && cases.length === 0) errors.push("El archivo no trae ningun comprobante.");
  if (errors.length > 0) return { ok: false, errors: errors.slice(0, 15) };
  return { ok: true, value: cases };
}

/** Hoja de aprobaciones comerciales: una ACECF por fila. */
export function parseApprovalSet(rows: string[][]): Validation<TestSetCase[]> {
  const head = rows[0] ?? [];
  const lower = head.map((h) => h.trim().toLowerCase());
  const required = ["encf", "rncemisor", "rnccomprador", "estado", "montototal", "fechahoraaprobacioncomercial"];
  const missing = required.filter((c) => !lower.includes(c));
  if (missing.length > 0) {
    return { ok: false, errors: [`El archivo no parece el de aprobaciones comerciales de la DGII (faltan ${missing.join(", ")}).`] };
  }
  const body = rows.slice(1);
  if (body.length > MAX_TEST_SET_CASES) {
    return { ok: false, errors: [`El archivo trae ${body.length} filas; el set de la DGII no pasa de ${MAX_TEST_SET_CASES}.`] };
  }

  const errors: string[] = [];
  const cases: TestSetCase[] = [];
  const seen = new Set<string>();
  const buyers = new Set<string>();
  body.forEach((row, i) => {
    const fields = rowFields(head, row);
    if (fields.length === 0) return;
    const line = i + 2;
    const encf = (value(fields, "eNCF") ?? "").toUpperCase();
    const issuer = (value(fields, "RNCEmisor") ?? "").replace(/\D/g, "");
    const buyer = (value(fields, "RNCComprador") ?? "").replace(/\D/g, "");
    const estado = value(fields, "Estado");
    const total = Number(value(fields, "MontoTotal"));
    if (!/^E\d{12}$/.test(encf) || !TEST_SET_ECF_TYPES.includes(encf.slice(1, 3))) {
      errors.push(`Fila ${line}: el e-NCF "${encf}" no es valido.`);
      return;
    }
    if (estado !== "1" && estado !== "2") {
      errors.push(`Fila ${line} (${encf}): el estado "${estado ?? ""}" no es 1 (aceptado) ni 2 (rechazado).`);
      return;
    }
    if (!Number.isFinite(total)) {
      errors.push(`Fila ${line} (${encf}): el monto total no es un numero.`);
      return;
    }
    const key = `${issuer}${encf}`;
    if (seen.has(key)) {
      errors.push(`Fila ${line}: la aprobacion de ${encf} esta repetida.`);
      return;
    }
    seen.add(key);
    if (buyer) buyers.add(buyer);
    try {
      buildAcecfXml(fields);
    } catch (e) {
      errors.push(`Fila ${line} (${encf}): ${e instanceof Error ? e.message : String(e)}`);
      return;
    }
    cases.push({
      position: cases.length + 1,
      case_id: `${buyer}${encf}`,
      ecf_type: encf.slice(1, 3),
      encf,
      signer_rnc: buyer,
      total,
      via: "acecf",
      modifies: null,
      fields,
      summary_fields: null,
      issuer_rnc: issuer,
    });
  });

  if (buyers.size > 1) errors.push(`El archivo mezcla varios RNC compradores (${[...buyers].join(", ")}).`);
  if (errors.length === 0 && cases.length === 0) errors.push("El archivo no trae ninguna aprobacion comercial.");
  if (errors.length > 0) return { ok: false, errors: errors.slice(0, 15) };
  return { ok: true, value: cases };
}

/** Notas de credito/debito: modifican otro e-CF, que tiene que estar aceptado antes. */
export function isAdjustmentNote(ecfType: string): boolean {
  return ecfType === "33" || ecfType === "34";
}

/** Orden de envio: primero los comprobantes, despues las notas que los modifican. */
export function sendOrder<T extends { ecf_type: string; position: number }>(cases: T[]): T[] {
  return [...cases].sort((a, b) =>
    (Number(isAdjustmentNote(a.ecf_type)) - Number(isAdjustmentNote(b.ecf_type))) || (a.position - b.position)
  );
}

export type TestCaseStatus = "pending" | "sent" | "accepted" | "conditional" | "rejected" | "error";

/** Estado de la DGII (consulta de TrackId o respuesta del resumen) → estado del caso. */
export function statusFromDgii(estado: unknown, codigo: unknown): TestCaseStatus {
  const e = typeof estado === "string" ? estado.trim().toLowerCase() : "";
  if (e === "aceptado" || codigo === 1) return "accepted";
  if (e === "aceptado condicional" || codigo === 4) return "conditional";
  if (e === "rechazado" || codigo === 2) return "rejected";
  return "sent"; // En Proceso / No encontrado: hay que volver a consultar.
}

export function isFinalStatus(s: TestCaseStatus): boolean {
  return s === "accepted" || s === "conditional" || s === "rejected";
}

export interface DgiiMessage {
  code: string | null;
  message: string;
}

/** `mensajes: [{ valor, codigo }]` de la DGII, o `mensaje: [texto]` (aprobacion comercial). */
export function parseDgiiMessages(raw: unknown): DgiiMessage[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((m): m is Record<string, unknown> | string => typeof m === "string" || (typeof m === "object" && m !== null))
    .map((m) =>
      typeof m === "string" ? { code: null, message: m } : {
        code: m.codigo === undefined || m.codigo === null ? null : String(m.codigo),
        message: typeof m.valor === "string" ? m.valor : JSON.stringify(m),
      }
    )
    .filter((m) => m.message.length > 0);
}
