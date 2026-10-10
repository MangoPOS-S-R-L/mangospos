import { assert, assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  buildAcecfXml,
  buildEcfXml,
  buildRfceXml,
  dgiiTimestamp,
  isEmptyCell,
  parseCsv,
  parseApprovalSet,
  parseDgiiMessages,
  parseTestSet,
  readTestSetFile,
  sendOrder,
  statusFromDgii,
  summaryFieldsFrom,
  TestSetField,
  TestSetLayoutError,
  twoDecimals,
} from "./ecf-test-set.ts";

// Encabezado y filas con la forma del Excel de la DGII (columnas recortadas).
const HEAD = [
  "CasoPrueba", "Version", "TipoeCF", "ENCF", "FechaVencimientoSecuencia", "IndicadorNotaCredito",
  "TipoIngresos", "TipoPago", "FormaPago[1]", "MontoPago[1]", "FormaPago[2]", "MontoPago[2]",
  "RNCEmisor", "RazonSocialEmisor", "TelefonoEmisor[1]", "TelefonoEmisor[2]", "FechaEmision",
  "RNCComprador", "RazonSocialComprador", "MontoGravadoTotal", "MontoGravadoI1", "ITBIS1", "TotalITBIS",
  "TotalITBIS1", "MontoTotal", "TipoImpuesto[1]", "TasaImpuestoAdicional[1]", "NumeroLinea[1]",
  "TipoCodigo[1][1]", "CodigoItem[1][1]", "IndicadorFacturacion[1]", "NombreItem[1]",
  "IndicadorBienoServicio[1]", "CantidadItem[1]", "PrecioUnitarioItem[1]", "TipoImpuesto[1][1]",
  "MontoItem[1]", "NumeroLinea[2]", "IndicadorFacturacion[2]", "NombreItem[2]",
  "IndicadorBienoServicio[2]", "CantidadItem[2]", "PrecioUnitarioItem[2]", "MontoItem[2]",
  "NumeroLineaDoR[1]", "TipoAjuste[1]", "MontosubRecargo[1][1]", "NCFModificado", "FechaNCFModificado",
  "CodigoModificacion",
];

function row(values: Record<string, string>): string[] {
  return HEAD.map((h) => values[h] ?? "#e");
}

const E31 = row({
  CasoPrueba: "101000001E310000000001", Version: "1.0", TipoeCF: "31", ENCF: "E310000000001",
  FechaVencimientoSecuencia: "31-12-2028", TipoIngresos: "01", TipoPago: "1", "FormaPago[1]": "1",
  "MontoPago[1]": "1180.00", RNCEmisor: "101000001", RazonSocialEmisor: "EMISOR & HIJOS",
  "TelefonoEmisor[1]": "809-555-0001", FechaEmision: "01-04-2020", RNCComprador: "131880681",
  RazonSocialComprador: "COMPRADOR", MontoGravadoTotal: "1000.00", MontoGravadoI1: "1000.00", ITBIS1: "18",
  TotalITBIS: "180.00", TotalITBIS1: "180.00", MontoTotal: "1180.00", "NumeroLinea[1]": "1",
  "TipoCodigo[1][1]": "INTERNA", "CodigoItem[1][1]": "A1", "IndicadorFacturacion[1]": "1",
  "NombreItem[1]": 'TV 57" <LED>', "IndicadorBienoServicio[1]": "1", "CantidadItem[1]": "1.00",
  "PrecioUnitarioItem[1]": "1000.0000", "MontoItem[1]": "1000.00",
});

const E32_SMALL = row({
  CasoPrueba: "101000001E320000000002", Version: "1.0", TipoeCF: "32", ENCF: "E320000000002",
  TipoIngresos: "01", TipoPago: "1", RNCEmisor: "101000001", RazonSocialEmisor: "EMISOR & HIJOS",
  FechaEmision: "01-04-2020", MontoGravadoTotal: "100.00", MontoGravadoI1: "100.00", ITBIS1: "18",
  TotalITBIS: "18.00", TotalITBIS1: "18.00", MontoTotal: "118.00", "TipoImpuesto[1]": "006",
  "TasaImpuestoAdicional[1]": "10", "NumeroLinea[1]": "1", "IndicadorFacturacion[1]": "1",
  "NombreItem[1]": "PAN", "IndicadorBienoServicio[1]": "1", "CantidadItem[1]": "1.00",
  "PrecioUnitarioItem[1]": "100.0000", "MontoItem[1]": "100.00",
});

const E34 = row({
  CasoPrueba: "101000001E340000000003", Version: "1.0", TipoeCF: "34", ENCF: "E340000000003",
  IndicadorNotaCredito: "0", TipoIngresos: "01", TipoPago: "1", RNCEmisor: "101000001",
  RazonSocialEmisor: "EMISOR & HIJOS", FechaEmision: "02-04-2020", RNCComprador: "131880681",
  RazonSocialComprador: "COMPRADOR", MontoTotal: "1180.00", "NumeroLinea[1]": "1",
  "IndicadorFacturacion[1]": "1", "NombreItem[1]": "DEVOLUCION", "IndicadorBienoServicio[1]": "1",
  "CantidadItem[1]": "1.00", "PrecioUnitarioItem[1]": "1000.0000", "MontoItem[1]": "1000.00",
  NCFModificado: "E310000000001", FechaNCFModificado: "01-04-2020", CodigoModificacion: "2",
});

function fieldsOf(r: string[]): TestSetField[] {
  return HEAD.map((h, i) => [h, r[i]] as TestSetField).filter(([, v]) => !isEmptyCell(v));
}

function csv(rows: string[][], sep = ","): string {
  return rows.map((r) => r.map((v) => (/[",;\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v)).join(sep)).join("\r\n");
}

// ── XML ──────────────────────────────────────────────────────────────────────

Deno.test("xml: anida segun el XSD y salta las celdas #e", () => {
  const xml = buildEcfXml(fieldsOf(E31), "08-10-2026 12:00:00");
  assert(xml.startsWith("<ECF><Encabezado><Version>1.0</Version><IdDoc><TipoeCF>31</TipoeCF><eNCF>E310000000001</eNCF>"));
  assert(xml.includes("<TablaFormasPago><FormaDePago><FormaPago>1</FormaPago><MontoPago>1180.00</MontoPago></FormaDePago></TablaFormasPago>"));
  assert(xml.includes("<TablaTelefonoEmisor><TelefonoEmisor>809-555-0001</TelefonoEmisor></TablaTelefonoEmisor>"));
  assert(xml.includes("<TablaCodigosItem><CodigosItem><TipoCodigo>INTERNA</TipoCodigo><CodigoItem>A1</CodigoItem></CodigosItem></TablaCodigosItem>"));
  assert(xml.endsWith("<FechaHoraFirma>08-10-2026 12:00:00</FechaHoraFirma></ECF>"));
  assert(!xml.includes("#e"));
});

Deno.test("xml: escapa como C14N (comillas tal cual)", () => {
  const xml = buildEcfXml(fieldsOf(E31), "08-10-2026 12:00:00");
  assert(xml.includes("<RazonSocialEmisor>EMISOR &amp; HIJOS</RazonSocialEmisor>"));
  assert(xml.includes('<NombreItem>TV 57" &lt;LED&gt;</NombreItem>'));
});

Deno.test("xml: el orden sale del XSD, no del orden de las columnas", () => {
  const f = fieldsOf(E31);
  const shuffled = [...f].reverse();
  assertEquals(buildEcfXml(shuffled, "x"), buildEcfXml(f, "x"));
});

Deno.test("xml: TipoImpuesto de totales y de item no se confunden", () => {
  const f: TestSetField[] = [
    ["Version", "1.0"], ["TipoeCF", "32"], ["ENCF", "E320000000009"],
    ["TipoImpuesto[1]", "006"], ["NumeroLinea[1]", "1"], ["TipoImpuesto[1][1]", "006"],
  ];
  const xml = buildEcfXml(f, "x");
  assert(xml.includes("<Totales><ImpuestosAdicionales><ImpuestoAdicional><TipoImpuesto>006</TipoImpuesto>"));
  assert(xml.includes("<TablaImpuestoAdicional><ImpuestoAdicional><TipoImpuesto>006</TipoImpuesto></ImpuestoAdicional></TablaImpuestoAdicional>"));
});

Deno.test("xml: alias del Excel (NumeroLineaDoR, MontosubRecargo, ENCF)", () => {
  const f: TestSetField[] = [
    ["Version", "1.0"], ["NumeroLinea[1]", "1"], ["MontosubRecargo[1][1]", "5.00"],
    ["NumeroLineaDoR[1]", "1"], ["TipoAjuste[1]", "D"],
  ];
  const xml = buildEcfXml(f, "x");
  assert(xml.includes("<TablaSubRecargo><SubRecargo><MontoSubRecargo>5.00</MontoSubRecargo></SubRecargo></TablaSubRecargo>"));
  assert(xml.includes("<DescuentosORecargos><DescuentoORecargo><NumeroLinea>1</NumeroLinea><TipoAjuste>D</TipoAjuste>"));
});

Deno.test("xml: columna desconocida con valor no se ignora callada", () => {
  const e = assertThrows(() => buildEcfXml([["Version", "1.0"], ["CampoInventado", "x"]], "x"), TestSetLayoutError);
  assertEquals(e.columns, ["CampoInventado"]);
});

Deno.test("rfce: se deriva del E32 con las columnas del resumen y el codigo de seguridad", () => {
  const summary = summaryFieldsFrom(fieldsOf(E32_SMALL));
  const xml = buildRfceXml(summary, "Ab1+/C");
  assert(xml.startsWith("<RFCE><Encabezado><Version>1.0</Version><IdDoc><TipoeCF>32</TipoeCF><eNCF>E320000000002</eNCF>"));
  assert(xml.endsWith("<MontoTotal>118.00</MontoTotal></Totales><CodigoSeguridadeCF>Ab1+/C</CodigoSeguridadeCF></Encabezado></RFCE>"));
  // El resumen no lleva items ni la tasa del impuesto adicional.
  assert(!xml.includes("NombreItem"));
  assert(!xml.includes("TasaImpuestoAdicional"));
  assert(xml.includes("<ImpuestoAdicional><TipoImpuesto>006</TipoImpuesto></ImpuestoAdicional>"));
});

// ── Archivo y casos ──────────────────────────────────────────────────────────

Deno.test("csv: comas, comillas y BOM de Excel", () => {
  const rows = parseCsv('﻿a,b,c\r\n"x, y","di ""hola""",\r\n');
  assertEquals(rows, [["a", "b", "c"], ["x, y", 'di "hola"', ""]]);
});

Deno.test("csv: punto y coma (Excel en espanol)", () => {
  assertEquals(parseCsv("a;b\n1,5;2\n"), [["a", "b"], ["1,5", "2"]]);
});

Deno.test("set: casos, via de envio y nota que modifica", async () => {
  const file = await readTestSetFile("set.csv", new TextEncoder().encode(csv([HEAD, E31, E32_SMALL, E34])));
  assert(file.kind === "ecf");
  const r = parseTestSet(file.sheets);
  assert(r.ok, JSON.stringify(!r.ok && r.errors));
  assertEquals(r.value.map((c) => [c.encf, c.via]), [
    ["E310000000001", "ecf"],
    ["E320000000002", "rfce"],
    ["E340000000003", "ecf"],
  ]);
  assertEquals(r.value[0].case_id, "101000001E310000000001");
  assertEquals(r.value[2].modifies, "E310000000001");
  assertEquals(r.value[1].total, 118);
  assert(r.value[1].summary_fields !== null);
});

Deno.test("set: E32 de 250 mil o mas va completo a Recepcion", () => {
  const big = [...E32_SMALL];
  big[HEAD.indexOf("MontoTotal")] = "250000.00";
  const r = parseTestSet({ ecf: [HEAD, big], rfce: null });
  assert(r.ok);
  assertEquals(r.value[0].via, "ecf");
  assertEquals(r.value[0].summary_fields, null);
});

Deno.test("set: la hoja RFCE manda sobre el resumen derivado", () => {
  const rh = ["CasoPrueba", "Version", "TipoeCF", "ENCF", "RNCEmisor", "MontoTotal", "CodigoSeguridadeCF"];
  const r = parseTestSet({
    ecf: [HEAD, E32_SMALL],
    rfce: [rh, ["101000001E320000000002", "1.0", "32", "E320000000002", "101000001", "118.00", "#e"]],
  });
  assert(r.ok);
  assertEquals(r.value[0].summary_fields?.map(([c]) => c), rh.slice(0, 6));
});

Deno.test("set: errores claros (tipo que no cuadra, repetido, columnas faltantes)", () => {
  const wrongType = [...E31];
  wrongType[HEAD.indexOf("TipoeCF")] = "32";
  const r = parseTestSet({ ecf: [HEAD, wrongType, E32_SMALL, E32_SMALL], rfce: null });
  assert(!r.ok);
  assertEquals(r.errors.length, 2);
  assert(!parseTestSet({ ecf: [["a", "b"], ["1", "2"]], rfce: null }).ok);
  assert(!parseTestSet({ ecf: [HEAD], rfce: null }).ok);
});

Deno.test("set: un CSV de la hoja RFCE se rechaza", async () => {
  const rfce = csv([["CasoPrueba", "ENCF", "CodigoSeguridadeCF"], ["x", "E320000000002", "#e"]]);
  await assertRejects(() => readTestSetFile("rfce.csv", new TextEncoder().encode(rfce)), Error, "hoja RFCE");
});

Deno.test("set: extension que no es xlsx ni csv", async () => {
  await assertRejects(() => readTestSetFile("set.pdf", new Uint8Array([1])), Error, ".xlsx");
});

// .xlsx minimo armado aqui: zip con workbook, rels, sharedStrings y dos hojas.
async function zip(files: Record<string, string>, deflate: boolean): Promise<Uint8Array> {
  const enc = new TextEncoder();
  const locals: Uint8Array[] = [];
  const centrals: Uint8Array[] = [];
  let offset = 0;
  for (const [name, text] of Object.entries(files)) {
    const raw = enc.encode(text);
    const data = deflate
      ? new Uint8Array(await new Response(new Blob([raw]).stream().pipeThrough(new CompressionStream("deflate-raw"))).arrayBuffer())
      : raw;
    const n = enc.encode(name);
    const local = new Uint8Array(30 + n.length + data.length);
    const lv = new DataView(local.buffer);
    lv.setUint32(0, 0x04034b50, true);
    lv.setUint16(8, deflate ? 8 : 0, true);
    lv.setUint32(18, data.length, true);
    lv.setUint32(22, raw.length, true);
    lv.setUint16(26, n.length, true);
    local.set(n, 30);
    local.set(data, 30 + n.length);
    const central = new Uint8Array(46 + n.length);
    const cv = new DataView(central.buffer);
    cv.setUint32(0, 0x02014b50, true);
    cv.setUint16(10, deflate ? 8 : 0, true);
    cv.setUint32(20, data.length, true);
    cv.setUint32(24, raw.length, true);
    cv.setUint16(28, n.length, true);
    cv.setUint32(42, offset, true);
    central.set(n, 46);
    locals.push(local);
    centrals.push(central);
    offset += local.length;
  }
  const cdSize = centrals.reduce((a, c) => a + c.length, 0);
  const end = new Uint8Array(22);
  const ev = new DataView(end.buffer);
  ev.setUint32(0, 0x06054b50, true);
  ev.setUint16(8, centrals.length, true);
  ev.setUint16(10, centrals.length, true);
  ev.setUint32(12, cdSize, true);
  ev.setUint32(16, offset, true);
  const out = new Uint8Array(offset + cdSize + 22);
  let p = 0;
  for (const part of [...locals, ...centrals, end]) {
    out.set(part, p);
    p += part.length;
  }
  return out;
}

function sheetXml(rows: string[][], shared: string[]): string {
  const col = (i: number) => String.fromCharCode(65 + i);
  const body = rows.map((r, ri) =>
    `<row r="${ri + 1}">` + r.map((v, ci) => {
      const ref = `${col(ci)}${ri + 1}`;
      if (v === "") return `<c r="${ref}" s="1"/>`;
      let idx = shared.indexOf(v);
      if (idx < 0) idx = shared.push(v) - 1;
      return `<c r="${ref}" t="s"><v>${idx}</v></c>`;
    }).join("") + "</row>"
  ).join("");
  return `<worksheet><sheetData>${body}</sheetData></worksheet>`;
}

const esc = (v: string) => v.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

for (const deflate of [false, true]) {
  Deno.test(`xlsx: lee las hojas ECF y RFCE (${deflate ? "deflate" : "sin comprimir"})`, async () => {
    const shared: string[] = [];
    const ecfRows = [["CasoPrueba", "Version", "TipoeCF", "ENCF", "RNCEmisor", "MontoTotal", "NombreItem[1]"],
      ["101000001E320000000002", "1.0", "32", "E320000000002", "101000001", "118.00", 'A & "B"']];
    const rfceRows = [["CasoPrueba", "Version", "TipoeCF", "ENCF", "MontoTotal", "CodigoSeguridadeCF"],
      ["101000001E320000000002", "1.0", "32", "E320000000002", "118.00", ""]];
    const s1 = sheetXml(ecfRows, shared);
    const s2 = sheetXml(rfceRows, shared);
    const bytes = await zip({
      "[Content_Types].xml": "<Types/>",
      "xl/workbook.xml": '<workbook xmlns:r="x"><sheets><sheet name="ECF" sheetId="1" r:id="rId1"/>' +
        '<sheet name="RFCE" sheetId="2" r:id="rId2"/></sheets></workbook>',
      "xl/_rels/workbook.xml.rels": '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/>' +
        '<Relationship Id="rId2" Target="/xl/worksheets/sheet2.xml"/></Relationships>',
      "xl/sharedStrings.xml": `<sst>${shared.map((v) => `<si><t xml:space="preserve">${esc(v)}</t></si>`).join("")}</sst>`,
      "xl/worksheets/sheet1.xml": s1,
      "xl/worksheets/sheet2.xml": s2,
    }, deflate);
    const file = await readTestSetFile("133051842-08102026.xlsx", bytes);
    assert(file.kind === "ecf");
    assertEquals(file.sheets.ecf, ecfRows);
    assertEquals(file.sheets.rfce?.[1].slice(0, 5), rfceRows[1].slice(0, 5));
  });
}

// ── Aprobaciones comerciales ─────────────────────────────────────────────────

const ACECF_HEAD = [
  "Version", "RNCEmisor", "eNCF", "FechaEmision", "MontoTotal", "RNCComprador", "Estado",
  "DetalleMotivoRechazo", "FechaHoraAprobacionComercial",
];
const ACECF_ROW = ["1.0", "131880681", "E310000000006", "01-04-2020", "228460.5", "101000001", "1", "", "09-10-2026 12:11:51"];

Deno.test("monto con dos decimales como pide el XSD del ACECF", () => {
  assertEquals(twoDecimals("7080"), "7080.00");
  assertEquals(twoDecimals("228460.5"), "228460.50");
  assertEquals(twoDecimals("0"), "0.00");
  assertEquals(twoDecimals("45253.25"), "45253.25");
  assertEquals(twoDecimals("1.005"), "1.00");
});

Deno.test("acecf: XML en el orden del XSD, sin el motivo vacio", () => {
  const fields = ACECF_HEAD.map((h, i) => [h, ACECF_ROW[i]] as TestSetField).filter(([, v]) => !isEmptyCell(v));
  assertEquals(
    buildAcecfXml(fields),
    "<ACECF><DetalleAprobacionComercial><Version>1.0</Version><RNCEmisor>131880681</RNCEmisor>" +
      "<eNCF>E310000000006</eNCF><FechaEmision>01-04-2020</FechaEmision><MontoTotal>228460.50</MontoTotal>" +
      "<RNCComprador>101000001</RNCComprador><Estado>1</Estado>" +
      "<FechaHoraAprobacionComercial>09-10-2026 12:11:51</FechaHoraAprobacionComercial>" +
      "</DetalleAprobacionComercial></ACECF>",
  );
});

Deno.test("acecf: casos firmados por el comprador, nombre RNC comprador + e-NCF", () => {
  const r = parseApprovalSet([ACECF_HEAD, ACECF_ROW, ["1.0", "131880681", "E340000000018", "02-12-2018", "0", "101000001", "1", "", "09-10-2026 12:11:51"]]);
  assert(r.ok, JSON.stringify(!r.ok && r.errors));
  assertEquals(r.value.map((c) => [c.case_id, c.ecf_type, c.via, c.signer_rnc, c.total]), [
    ["101000001E310000000006", "31", "acecf", "101000001", 228460.5],
    ["101000001E340000000018", "34", "acecf", "101000001", 0],
  ]);
});

Deno.test("acecf: el mismo e-NCF de dos emisores son dos aprobaciones, con su emisor", () => {
  const other = [...ACECF_ROW];
  other[1] = "1-01-55555-5";
  const r = parseApprovalSet([ACECF_HEAD, ACECF_ROW, other]);
  assert(r.ok, JSON.stringify(!r.ok && r.errors));
  assertEquals(r.value.map((c) => [c.encf, c.issuer_rnc]), [
    ["E310000000006", "131880681"],
    ["E310000000006", "101555555"],
  ]);
});

Deno.test("acecf: errores claros", () => {
  const badState = [...ACECF_ROW];
  badState[6] = "3";
  const r = parseApprovalSet([ACECF_HEAD, badState, ACECF_ROW, ACECF_ROW]);
  assert(!r.ok);
  assertEquals(r.errors.length, 2); // estado invalido y repetido
  assert(!parseApprovalSet([["eNCF", "Estado"], ["E310000000001", "1"]]).ok);
});

Deno.test("archivo: se reconoce el de aprobaciones comerciales (.csv y .xlsx con numeros)", async () => {
  const fromCsv = await readTestSetFile("aprobaciones.csv", new TextEncoder().encode(csv([ACECF_HEAD, ACECF_ROW])));
  assertEquals(fromCsv.kind, "acecf");

  const shared = ["Version", "RNCEmisor", "eNCF", "MontoTotal", "RNCComprador", "Estado", "FechaHoraAprobacionComercial"];
  const sheet = '<worksheet><sheetData><row r="1">' +
    shared.map((_, i) => `<c r="${String.fromCharCode(65 + i)}1" t="s"><v>${i}</v></c>`).join("") +
    '</row><row r="2"><c r="D2" s="1"><v>228460.5</v></c><c r="F2"><v>1</v></c></row></sheetData></worksheet>';
  const bytes = await zip({
    "xl/workbook.xml": '<workbook><sheets><sheet name="ACEECF_Generadas" sheetId="1" r:id="rId1"/></sheets></workbook>',
    "xl/_rels/workbook.xml.rels": '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>',
    "xl/sharedStrings.xml": `<sst>${shared.map((v) => `<si><t>${v}</t></si>`).join("")}</sst>`,
    "xl/worksheets/sheet1.xml": sheet,
  }, true);
  const fromXlsx = await readTestSetFile("133051842-09102026121152.xlsx", bytes);
  assert(fromXlsx.kind === "acecf");
  assertEquals(fromXlsx.rows[1][3], "228460.5");
  assertEquals(fromXlsx.rows[1][5], "1");
});

Deno.test("mensajes de la aprobacion comercial vienen como texto", () => {
  assertEquals(parseDgiiMessages(["Firma invalida"]), [{ code: null, message: "Firma invalida" }]);
});

// ── Estados ──────────────────────────────────────────────────────────────────

Deno.test("orden de envio: notas al final, lo demas en el orden del archivo", () => {
  const order = sendOrder([
    { ecf_type: "34", position: 1 },
    { ecf_type: "31", position: 2 },
    { ecf_type: "33", position: 3 },
    { ecf_type: "32", position: 4 },
  ]);
  assertEquals(order.map((c) => c.position), [2, 4, 1, 3]);
});

Deno.test("estados de la DGII", () => {
  assertEquals(statusFromDgii("Aceptado", 1), "accepted");
  assertEquals(statusFromDgii("Aceptado Condicional", 4), "conditional");
  assertEquals(statusFromDgii("Rechazado", 2), "rejected");
  assertEquals(statusFromDgii("En Proceso", 3), "sent");
  assertEquals(statusFromDgii(undefined, 0), "sent");
  assertEquals(parseDgiiMessages([{ valor: "Monto invalido", codigo: 2 }, null]), [{ code: "2", message: "Monto invalido" }]);
});

Deno.test("fecha de firma en hora de RD (UTC-4)", () => {
  assertEquals(dgiiTimestamp(new Date("2026-01-02T03:04:05Z")), "01-01-2026 23:04:05");
});
