// Generación del .txt de ventas por hora para la plaza comercial.
//
// PARIDAD CON DART: este módulo es el gemelo de `MallSalesExportService.buildCsv`
// (lib/core/services/mall_sales_export_service.dart). Cualquier cambio de formato
// tiene que hacerse en LOS DOS o los archivos divergen según quién los suba.
// `csv_test.ts` fija los bytes exactos para que la divergencia se note.
//
// CONVENCIÓN DE MONTOS (confirmada por la plaza el 2026-08-13):
//   TOTALBRUTO      = base SIN impuesto
//   TOTALIMPUESTOS  = impuesto
//   TOTALNETO       = TOTALBRUTO + TOTALIMPUESTOS = lo que pagó el cliente
//
// Es al revés de la nomenclatura interna (`total_gross` = cobrado,
// `total_net` = base), así que el mapeo va CRUZADO:
//   TOTALBRUTO ← totalNet   ·   TOTALNETO ← totalGross

export interface MallExportConfig {
  clientCode: string;
  filePrefix: string;
  exchangeRate: number;
}

/** Fila del agregado que devuelve `fn_mall_sales_by_hour`. */
export interface MallHourlyRow {
  hour: number;
  txCount: number;
  totalItems: number;
  /** Monto cobrado al cliente (nomenclatura interna). */
  totalGross: number;
  totalTax: number;
  /** Base sin impuesto (nomenclatura interna). */
  totalNet: number;
}

/** Cabecera exacta del archivo de ejemplo del manual de la plaza (§6.6). */
export const CSV_HEADER =
  "ID_TRANSACCION,NUMSERIE,FECHA,HORA,TOTALTRANSVENTA,TOTALART,TASA," +
  "TOTALBRUTO,TOTALIMPUESTOS,TOTALNETO";

/** Parte una fecha ISO `YYYY-MM-DD` sin pasar por Date (evita corrimientos de TZ). */
function splitIsoDate(dateIso: string): { yyyy: string; mm: string; dd: string } {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateIso);
  if (!m) throw new Error(`Fecha inválida (se esperaba YYYY-MM-DD): ${dateIso}`);
  return { yyyy: m[1], mm: m[2], dd: m[3] };
}

/**
 * Nombre del archivo: `<prefijo>_<ddMMyyyy>.txt`.
 * Con prefijo "Ventas_4_8" produce `Ventas_4_8_27032018.txt` como el manual.
 */
export function buildFileName(filePrefix: string, dateIso: string): string {
  const { yyyy, mm, dd } = splitIsoDate(dateIso);
  const prefix = filePrefix.trim() === "" ? "Ventas" : filePrefix.trim();
  return `${prefix}_${dd}${mm}${yyyy}.txt`;
}

/**
 * Contenido del .txt: cabecera + una fila por hora con venta, separadas por
 * CRLF y con CRLF final. Formatos calcados del ejemplo del manual:
 *   - ID_TRANSACCION: ddMMyy + hora a 2 dígitos → único por fila/día.
 *   - HORA: entero 0-23 (la tabla del manual la define INT).
 *   - TOTALART con 6 decimales, montos con 2.
 *
 * `toFixed` de JS y `toStringAsFixed` de Dart comparten la semántica de
 * ECMA-262, así que el redondeo coincide entre app y servidor.
 */
export function buildCsv(params: {
  config: MallExportConfig;
  dateIso: string;
  rows: MallHourlyRow[];
}): string {
  const { config, dateIso, rows } = params;
  const { yyyy, mm, dd } = splitIsoDate(dateIso);
  const yy = yyyy.slice(2);
  const fecha = `${dd}/${mm}/${yyyy}`;
  const rate = config.exchangeRate;
  const tasa = rate === Math.round(rate) ? rate.toFixed(0) : rate.toFixed(2);

  let out = CSV_HEADER;
  for (const row of rows) {
    const hh = String(row.hour).padStart(2, "0");
    out += "\r\n" +
      [
        `${dd}${mm}${yy}${hh}`,
        config.clientCode.trim(),
        fecha,
        String(row.hour),
        String(row.txCount),
        row.totalItems.toFixed(6),
        tasa,
        row.totalNet.toFixed(2), // TOTALBRUTO = base sin impuesto
        row.totalTax.toFixed(2), // TOTALIMPUESTOS
        row.totalGross.toFixed(2), // TOTALNETO = base + impuesto
      ].join(",");
  }
  out += "\r\n";
  return out;
}
