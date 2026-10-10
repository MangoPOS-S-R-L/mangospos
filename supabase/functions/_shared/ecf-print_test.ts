import { assert, assertEquals, assertThrows } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { buildPrintModel, timbreUrl } from "./ecf-print.ts";
import { TestSetField } from "./ecf-test-set.ts";

const SIGNED = '<?xml version="1.0" encoding="utf-8"?><ECF><FechaHoraFirma>09-10-2026 00:27:46</FechaHoraFirma>' +
  "<Signature><SignedInfo></SignedInfo><SignatureValue>FlnMwsABCDEF==</SignatureValue></Signature></ECF>";

function fields(values: Record<string, string>): TestSetField[] {
  return Object.entries(values) as TestSetField[];
}

const E32_BIG = fields({
  TipoeCF: "32",
  ENCF: "E320000000006",
  RNCEmisor: "133051842",
  RazonSocialEmisor: "TROPELLA COFFEE SRL",
  NombreComercial: "Tropella Coffee",
  DireccionEmisor: "GURABO",
  Municipio: "250100",
  Provincia: "250000",
  FechaEmision: "01-04-2020",
  RNCComprador: "131880681",
  RazonSocialComprador: "DOCUMENTOS ELECTRONICOS DE 03",
  ITBIS1: "18",
  MontoGravadoTotal: "350765.00",
  MontoExento: "1625.00",
  TotalITBIS: "61395.30",
  MontoTotal: "413785.30",
  "NumeroLinea[1]": "1",
  "IndicadorFacturacion[1]": "1",
  "NombreItem[1]": "LAPICES",
  "CantidadItem[1]": "23.00",
  "UnidadMedida[1]": "43",
  "PrecioUnitarioItem[1]": "35.0000",
  "MontoItem[1]": "805.00",
  "NumeroLinea[2]": "2",
  "IndicadorFacturacion[2]": "4",
  "NombreItem[2]": "LECHE",
  "CantidadItem[2]": "25.00",
  "UnidadMedida[2]": "47",
  "MontoItem[2]": "1625.00",
});

Deno.test("RI: QR de e-CF igual al que la DGII valida (paso 2, E320000000006)", () => {
  const ri = buildPrintModel(E32_BIG, SIGNED);
  assertEquals(
    ri.qr_url,
    "https://ecf.dgii.gov.do/certecf/ConsultaTimbre?RncEmisor=133051842&RncComprador=131880681&ENCF=E320000000006" +
      "&FechaEmision=01-04-2020&MontoTotal=413785.30&FechaFirma=09-10-2026%2000%3A27%3A46&CodigoSeguridad=FlnMws",
  );
  assertEquals(ri.security_code, "FlnMws");
  assertEquals(ri.signed_at, "09-10-2026 00:27:46");
  assertEquals(ri.consumer_summary, false);
});

Deno.test("RI: encabezado, emisor en palabras y detalle", () => {
  const ri = buildPrintModel(E32_BIG, SIGNED);
  assertEquals(ri.type_name, "Factura de Consumo Electrónica");
  assertEquals(ri.due_date, null); // la factura de consumo no lleva vencimiento
  assertEquals(ri.issuer.municipality, "SANTIAGO");
  assertEquals(ri.issuer.province, "SANTIAGO");
  assertEquals(ri.items[0], {
    line: "1",
    quantity: "23.00",
    exempt: false,
    description: "LAPICES",
    detail: null,
    unit: "Unidad",
    price: "35.0000",
    itbis: "144.90",
    discount: null,
    surcharge: null,
    value: "805.00",
  });
  assertEquals(ri.items[1].exempt, true);
  assertEquals(ri.items[1].unit, "Lata");
  assertEquals(ri.items[1].itbis, null);
  assertEquals(ri.totals.total, "413785.30");
});

Deno.test("RI: ITBIS por linea cuando el precio ya lo incluye", () => {
  const f = E32_BIG.map(([c, v]): TestSetField => [c, v]);
  f.push(["IndicadorMontoGravado", "1"]);
  const ri = buildPrintModel(f, SIGNED);
  assertEquals(ri.items[0].itbis, "122.80"); // 805 - 805 / 1.18
});

Deno.test("RI: consumo menor de 250 mil usa la consulta de consumo", () => {
  const f = E32_BIG.map(([c, v]): TestSetField => [c, c === "MontoTotal" ? "40120.00" : v]);
  const ri = buildPrintModel(f, SIGNED);
  assert(ri.consumer_summary);
  assertEquals(
    ri.qr_url,
    "https://fc.dgii.gov.do/certecf/ConsultaTimbreFC?RncEmisor=133051842&ENCF=E320000000006&MontoTotal=40120.00&CodigoSeguridad=FlnMws",
  );
});

Deno.test("RI: nota de credito con e-NCF modificado y codigo en palabras, sin vencimiento", () => {
  const ri = buildPrintModel(
    fields({
      TipoeCF: "34",
      ENCF: "E340000000020",
      RNCEmisor: "133051842",
      FechaEmision: "09-10-2026",
      FechaVencimientoSecuencia: "31-12-2028",
      MontoTotal: "0.00",
      NCFModificado: "E310000000013",
      FechaNCFModificado: "09-10-2026",
      CodigoModificacion: "2",
    }),
    SIGNED,
  );
  assertEquals(ri.type_name, "Nota de Crédito Electrónica");
  assertEquals(ri.due_date, null);
  assertEquals(ri.modified_encf, "E310000000013");
  assertEquals(ri.modification, "Corrige Texto del Comprobante Fiscal modificado");
  assertEquals(ri.buyer, null);
});

Deno.test("RI: sin comprador (gastos menores) el QR no lleva RncComprador", () => {
  const url = timbreUrl({
    rncEmisor: "133051842",
    rncComprador: null,
    encf: "E430000000011",
    fechaEmision: "09-10-2026",
    montoTotal: "1000.00",
    fechaFirma: "09-10-2026 13:00:00",
    codigoSeguridad: "a+b/c=",
    consumerSummary: false,
  });
  assert(!url.includes("RncComprador"));
  assert(url.endsWith("CodigoSeguridad=a%2Bb%2Fc%3D"));
});

Deno.test("RI: sin firma no se arma", () => {
  assertThrows(() => buildPrintModel(E32_BIG, "<ECF></ECF>"));
});
