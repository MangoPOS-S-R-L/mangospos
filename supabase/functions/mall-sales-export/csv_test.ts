// Paridad con test/mall_sales_export_service_test.dart — MISMAS fixtures.
// Si un test de acá falla y el de Dart no (o al revés), el archivo que sube el
// servidor y el que sube la app dejaron de ser el mismo.
//
// Correr:  deno test supabase/functions/mall-sales-export/csv_test.ts

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  buildCsv,
  buildFileName,
  CSV_HEADER,
  type MallExportConfig,
} from "./csv.ts";

const config: MallExportConfig = {
  clientCode: "341",
  filePrefix: "Ventas_4_8",
  exchangeRate: 1.0,
};

const date = "2018-03-27";

Deno.test("buildFileName sigue el patrón del manual (prefijo_ddMMyyyy.txt)", () => {
  assertEquals(
    buildFileName(config.filePrefix, date),
    "Ventas_4_8_27032018.txt",
  );
});

Deno.test("buildCsv emite cabecera exacta y filas por hora", () => {
  // Fila de ejemplo del manual: 270318,341,27/03/2018,10:23,18,22.000000,1,
  // 60885.60,10959.40 — donde 10 959.40 es el 18% de 60 885.60, o sea que el
  // primer monto es la BASE. Mapeo cruzado: totalNet → TOTALBRUTO.
  const csv = buildCsv({
    config,
    dateIso: date,
    rows: [{
      hour: 10,
      txCount: 18,
      totalItems: 22,
      totalGross: 71845.00, // cobrado → TOTALNETO
      totalTax: 10959.40,
      totalNet: 60885.60, // base → TOTALBRUTO
    }],
  });
  const lines = csv.trimEnd().split("\r\n");
  assertEquals(lines.length, 2);
  assertEquals(lines[0], CSV_HEADER);
  assertEquals(
    lines[1],
    "27031810,341,27/03/2018,10,18,22.000000,1,60885.60,10959.40,71845.00",
  );
});

Deno.test("TOTALNETO es la suma de TOTALBRUTO y TOTALIMPUESTOS", () => {
  const csv = buildCsv({
    config,
    dateIso: date,
    rows: [{
      hour: 20,
      txCount: 29,
      totalItems: 92,
      totalGross: 44450.00,
      totalTax: 9518.65,
      totalNet: 34931.35,
    }],
  });
  const campos = csv.trimEnd().split("\r\n")[1].split(",");
  const bruto = Number(campos[7]);
  const impuestos = Number(campos[8]);
  const neto = Number(campos[9]);

  assertEquals(bruto, 34931.35);
  assertEquals(impuestos, 9518.65);
  assertEquals(neto, 44450.00);
  assert(Math.abs(bruto + impuestos - neto) < 0.005);
});

Deno.test("buildCsv sin ventas produce solo la cabecera", () => {
  assertEquals(
    buildCsv({ config, dateIso: date, rows: [] }),
    `${CSV_HEADER}\r\n`,
  );
});

Deno.test("la hora va a 2 dígitos en ID_TRANSACCION pero entera en HORA", () => {
  // Regresión del archivo real Ventas_16082026.txt, que trae la hora 0.
  const csv = buildCsv({
    config,
    dateIso: "2026-08-16",
    rows: [{
      hour: 0,
      txCount: 1,
      totalItems: 1,
      totalGross: 200.00,
      totalTax: 43.75,
      totalNet: 156.25,
    }],
  });
  const campos = csv.trimEnd().split("\r\n")[1].split(",");
  assertEquals(campos[0], "16082600");
  assertEquals(campos[3], "0");
});

Deno.test("una tasa no entera se emite con 2 decimales", () => {
  const csv = buildCsv({
    config: { ...config, exchangeRate: 58.75 },
    dateIso: date,
    rows: [{
      hour: 9,
      txCount: 1,
      totalItems: 1,
      totalGross: 118,
      totalTax: 18,
      totalNet: 100,
    }],
  });
  assertEquals(csv.trimEnd().split("\r\n")[1].split(",")[6], "58.75");
});
