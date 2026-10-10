// Paso 4 de la certificacion: "Pruebas de simulacion e-CF". La DGII ya no da
// los datos: el contribuyente manda e-CF de su operacion, con la misma
// composicion que el set de pruebas de datos (4 E31, 2 E32 >= 250 mil, 1 E33,
// 2 E34, 2 de cada uno de 41/43/44/45/46/47 y 4 E32 menores de 250 mil, que van
// como resumen).
//
// Se arman con los casos del set de datos que la DGII ya acepto (montos,
// impuestos e items que cuadran) y se cambia lo que tiene que ser del
// contribuyente y de hoy:
//   - e-NCF nuevos: la DGII da del 1 al 10,000,000 por tipo y no deja repetir
//     ni entre intentos, asi que se sigue despues del mayor ya usado.
//   - el emisor: razon social, nombre comercial, direccion, municipio y
//     provincia (codigos DGII), telefono y correo del alta e-CF. Los datos de
//     relleno del set (codigo de vendedor, web, zona de venta...) se quitan:
//     son opcionales.
//   - FechaEmision = hoy; las demas fechas se corren lo mismo para que no
//     cambie el orden entre ellas. FechaVencimientoSecuencia queda igual.
//   - las notas de credito/debito apuntan al e-NCF nuevo de lo que modifican.
// Los compradores (RNC de prueba de la DGII) se quedan: el ambiente de
// certificacion los conoce.

import { locationCodes } from "./dgii-catalogs.ts";
import {
  buildEcfXml,
  CONSUMPTION_SUMMARY_LIMIT,
  isAdjustmentNote,
  summaryFieldsFrom,
  TestSetCase,
  TestSetField,
} from "./ecf-test-set.ts";

export interface SimulationIssuer {
  rnc: string;
  legalName: string;
  tradeName: string | null;
  address: string;
  province: string | null;
  municipality: string | null;
  phone: string | null;
  email: string | null;
}

export interface SimulationTemplate {
  position: number;
  ecf_type: string;
  encf: string;
  fields: TestSetField[];
}

/** Columnas de relleno del set de la DGII que no van en una operacion real. */
const DROPPED_COLUMNS = new Set([
  "casoprueba",
  "sucursal",
  "website",
  "actividadeconomica",
  "codigovendedor",
  "numerofacturainterna",
  "numeropedidointerno",
  "zonaventa",
  "rutaventa",
  "informacionadicionalemisor",
  "telefonoemisor[2]",
  "telefonoemisor[3]",
]);

/** Fechas dd-MM-yyyy que se corren junto con FechaEmision. */
const SHIFTED_DATE_COLUMNS = /^(fechaemision|fechalimitepago|fechadesde|fechahasta|fechaentrega|fechaordencompra|fechaembarque|fechaelaboracion\[\d+\]|fechavencimientoitem\[\d+\])$/;

const DATE_RE = /^(\d{2})-(\d{2})-(\d{4})$/;

function parseDate(v: string): number | null {
  const m = DATE_RE.exec(v.trim());
  if (!m) return null;
  const t = Date.UTC(Number(m[3]), Number(m[2]) - 1, Number(m[1]));
  return Number.isFinite(t) ? t : null;
}

function formatDate(t: number): string {
  const d = new Date(t);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${p(d.getUTCDate())}-${p(d.getUTCMonth() + 1)}-${d.getUTCFullYear()}`;
}

/** Telefono como lo pide el XSD (999-999-9999), o null si no se puede. */
export function dgiiPhone(raw: string | null | undefined): string | null {
  let digits = (raw ?? "").replace(/\D/g, "");
  if (digits.length === 11 && digits.startsWith("1")) digits = digits.slice(1);
  if (digits.length !== 10) return null;
  return `${digits.slice(0, 3)}-${digits.slice(3, 6)}-${digits.slice(6)}`;
}

export function encfFor(type: string, n: number): string {
  return `E${type}${String(n).padStart(10, "0")}`;
}

/** Numero de un e-NCF (E310000000012 → 12). */
export function encfNumber(encf: string): number {
  return Number(encf.slice(3));
}

const MAX_SEQUENCE = 10_000_000;

type Validation<T> = { ok: true; value: T } | { ok: false; errors: string[] };

export interface SimulationResult {
  cases: TestSetCase[];
  /** Ultimo numero usado por tipo, para no repetirlo en otro intento. */
  lastNumbers: Record<string, number>;
}

/**
 * Arma el set de simulacion. [nextNumbers] es el primer numero libre por tipo;
 * [today] va en dd-MM-yyyy.
 */
export function buildSimulationCases(
  templates: SimulationTemplate[],
  issuer: SimulationIssuer,
  today: string,
  nextNumbers: Record<string, number>,
): Validation<SimulationResult> {
  const errors: string[] = [];
  const todayT = parseDate(today);
  if (todayT === null) return { ok: false, errors: [`Fecha de hoy invalida: ${today}`] };
  if (!issuer.legalName.trim() || !issuer.address.trim()) {
    return { ok: false, errors: ["Faltan la razon social o la direccion fiscal del contribuyente."] };
  }
  if (templates.length === 0) {
    return { ok: false, errors: ["No hay casos del set de datos de la DGII para usar de modelo."] };
  }

  // e-NCF nuevos, en el orden del set.
  const ordered = [...templates].sort((a, b) => a.position - b.position);
  const counters: Record<string, number> = { ...nextNumbers };
  const lastNumbers: Record<string, number> = {};
  const newEncf = new Map<string, string>();
  for (const t of ordered) {
    const n = Math.max(1, counters[t.ecf_type] ?? 1);
    if (n > MAX_SEQUENCE) {
      errors.push(`Se agoto la secuencia de prueba del tipo ${t.ecf_type} (maximo ${MAX_SEQUENCE}).`);
      continue;
    }
    newEncf.set(t.encf, encfFor(t.ecf_type, n));
    lastNumbers[t.ecf_type] = n;
    counters[t.ecf_type] = n + 1;
  }
  if (errors.length > 0) return { ok: false, errors };

  const codes = locationCodes(issuer.province, issuer.municipality);
  const phone = dgiiPhone(issuer.phone);
  const email = issuer.email?.trim() && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(issuer.email.trim())
    ? issuer.email.trim().slice(0, 80)
    : null;
  const issuerValues: Record<string, string | null> = {
    razonsocialemisor: issuer.legalName.trim().slice(0, 150),
    nombrecomercial: (issuer.tradeName?.trim() || issuer.legalName.trim()).slice(0, 150),
    direccionemisor: issuer.address.trim().slice(0, 100),
    municipio: codes.municipality,
    provincia: codes.province,
    "telefonoemisor[1]": phone,
    correoemisor: email,
  };

  const cases: TestSetCase[] = [];
  for (const t of ordered) {
    const encf = newEncf.get(t.encf)!;
    const emission = parseDate(t.fields.find(([c]) => c.toLowerCase() === "fechaemision")?.[1] ?? "");
    const shift = emission === null ? 0 : todayT - emission;
    const reference = t.fields.find(([c]) => c.toLowerCase() === "ncfmodificado")?.[1]?.trim().toUpperCase() ?? null;
    const newReference = reference ? newEncf.get(reference) ?? reference : null;

    const fields: TestSetField[] = [];
    const seen = new Set<string>();
    for (const [column, value] of t.fields) {
      const key = column.trim().toLowerCase();
      seen.add(key);
      if (DROPPED_COLUMNS.has(key)) continue;
      if (key === "encf") {
        fields.push([column, encf]);
      } else if (key === "rncemisor") {
        fields.push([column, issuer.rnc]);
      } else if (key in issuerValues) {
        const v = issuerValues[key];
        if (v) fields.push([column, v]);
      } else if (key === "ncfmodificado") {
        fields.push([column, newReference ?? value]);
      } else if (key === "fechancfmodificado") {
        // Lo modificado se emite hoy tambien (si es del set).
        fields.push([column, reference && newEncf.has(reference) ? today : value]);
      } else if (key === "indicadornotacredito") {
        // 0 = dentro de los 30 dias del comprobante modificado (hoy mismo).
        fields.push([column, reference && newEncf.has(reference) ? "0" : value]);
      } else if (SHIFTED_DATE_COLUMNS.test(key)) {
        const d = parseDate(value);
        fields.push([column, d === null ? value : formatDate(d + shift)]);
      } else {
        fields.push([column, value]);
      }
    }
    // Datos del emisor que el modelo no traia (el XSD los pone despues de los
    // que si trae; buildEcfXml ordena por el XSD).
    for (const [key, column] of [
      ["nombrecomercial", "NombreComercial"],
      ["municipio", "Municipio"],
      ["provincia", "Provincia"],
      ["telefonoemisor[1]", "TelefonoEmisor[1]"],
      ["correoemisor", "CorreoEmisor"],
    ] as const) {
      const v = issuerValues[key];
      if (!seen.has(key) && v) fields.push([column, v]);
    }

    try {
      buildEcfXml(fields, "01-01-2000 00:00:00");
    } catch (e) {
      errors.push(`${encf} (modelo ${t.encf}): ${e instanceof Error ? e.message : String(e)}`);
      continue;
    }

    const totalRaw = fields.find(([c]) => c.toLowerCase() === "montototal")?.[1];
    const total = totalRaw !== undefined && Number.isFinite(Number(totalRaw)) ? Number(totalRaw) : null;
    const via = t.ecf_type === "32" && total !== null && total < CONSUMPTION_SUMMARY_LIMIT ? "rfce" : "ecf";
    cases.push({
      position: cases.length + 1,
      case_id: `${issuer.rnc}${encf}`,
      ecf_type: t.ecf_type,
      encf,
      signer_rnc: issuer.rnc,
      total,
      via,
      modifies: isAdjustmentNote(t.ecf_type) ? newReference : null,
      fields,
      summary_fields: via === "rfce" ? summaryFieldsFrom(fields) : null,
    });
  }

  if (errors.length > 0) return { ok: false, errors: errors.slice(0, 15) };
  return { ok: true, value: { cases, lastNumbers } };
}
