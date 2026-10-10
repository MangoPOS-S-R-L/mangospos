// Cliente de los servicios de CERTIFICACION de la DGII (ambiente CerteCF), para
// mandar el set de pruebas firmado con el certificado del contribuyente. La
// emision real NO pasa por aqui: la hace Alanube.
//
//   Autenticacion: GET semilla → firmarla → POST ValidarSemilla → token (~1 h)
//   e-CF:          POST Recepcion → trackId; GET ConsultaResultado?trackid=
//   E32 < 250 mil: POST RecepcionFC (fc.dgii.gov.do) con el resumen (RFCE);
//                  responde el estado en el acto.
//   ACECF:         POST AprobacionComercial; tambien responde en el acto.
//
// Los envios van como multipart con el campo `xml` y el nombre RNC+eNCF.xml.
// La DGII rechaza un multipart sin Content-Length ("Multipart cannot be empty"),
// por eso el cuerpo se arma completo en memoria.

import { DgiiMessage, parseDgiiMessages, statusFromDgii, TestCaseStatus } from "./ecf-test-set.ts";

export const DGII_CERT_ECF_URL = "https://ecf.dgii.gov.do/CerteCF";
export const DGII_CERT_FC_URL = "https://fc.dgii.gov.do/CerteCF";

// Corto: cada lote del panel tiene que caber en los 60 s del gateway.
const TIMEOUT_MS = 20_000;

export class DgiiError extends Error {
  constructor(
    message: string,
    public status: number,
    public body: unknown,
  ) {
    super(message);
  }

  /** Mensajes de la DGII que vengan en el cuerpo del error. */
  get messages(): DgiiMessage[] {
    const b = this.body as { mensajes?: unknown; mensaje?: unknown } | null;
    return parseDgiiMessages(b?.mensajes ?? b?.mensaje);
  }
}

export interface DgiiToken {
  token: string;
  expiresAt: Date;
}

export interface DgiiResult {
  status: TestCaseStatus;
  trackId: string | null;
  messages: DgiiMessage[];
}

type Fetch = typeof fetch;

/** Cuerpo multipart con un solo archivo en el campo `xml`. */
export function xmlMultipart(filename: string, xml: string): { body: Uint8Array; contentType: string } {
  const boundary = `----mangopos${crypto.randomUUID().replace(/-/g, "")}`;
  const enc = new TextEncoder();
  const head = enc.encode(
    `--${boundary}\r\nContent-Disposition: form-data; name="xml"; filename="${filename.replace(/"/g, "")}"\r\n` +
      `Content-Type: text/xml\r\n\r\n`,
  );
  const content = enc.encode(xml);
  const tail = enc.encode(`\r\n--${boundary}--\r\n`);
  const body = new Uint8Array(head.length + content.length + tail.length);
  body.set(head);
  body.set(content, head.length);
  body.set(tail, head.length + content.length);
  return { body, contentType: `multipart/form-data; boundary=${boundary}` };
}

export class DgiiCertificationClient {
  constructor(
    private ecfUrl = DGII_CERT_ECF_URL,
    private fcUrl = DGII_CERT_FC_URL,
    private fetchFn: Fetch = fetch,
    private timeoutMs = TIMEOUT_MS,
  ) {}

  private async call(
    what: string,
    url: string,
    init: { method: "GET" | "POST"; token?: string; xml?: { filename: string; content: string } },
  ): Promise<unknown> {
    const headers: Record<string, string> = { Accept: "application/json" };
    if (init.token) headers.Authorization = `Bearer ${init.token}`;
    let body: Uint8Array | undefined;
    if (init.xml) {
      const mp = xmlMultipart(init.xml.filename, init.xml.content);
      body = mp.body;
      headers["Content-Type"] = mp.contentType;
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    let res: Response;
    let text: string;
    try {
      res = await this.fetchFn(url, { method: init.method, headers, body, signal: controller.signal });
      // Leer el cuerpo también cuenta: la DGII puede mandar los encabezados y
      // colgarse a mitad de la respuesta.
      text = await res.text();
    } catch (e) {
      const reason = e instanceof DOMException && e.name === "AbortError" ? "no respondio a tiempo" : String(e);
      throw new DgiiError(`La DGII ${reason} al ${what}.`, 0, null);
    } finally {
      clearTimeout(timer);
    }
    let parsed: unknown = text;
    try {
      parsed = text ? JSON.parse(text) : null;
    } catch {
      // La semilla viene como XML; algunos errores, como texto.
    }
    if (!res.ok) {
      const b = parsed as { mensajes?: unknown; mensaje?: unknown } | null;
      const msgs = parseDgiiMessages(b?.mensajes ?? b?.mensaje);
      const detail = msgs.length > 0
        ? msgs.map((m) => m.message).join("; ")
        : typeof parsed === "string"
        ? parsed.slice(0, 300)
        : (parsed as { error?: unknown; message?: unknown } | null)?.error ??
          (parsed as { message?: unknown } | null)?.message ?? "";
      throw new DgiiError(
        `La DGII respondio ${res.status} al ${what}${detail ? `: ${detail}` : "."}`,
        res.status,
        parsed,
      );
    }
    return parsed;
  }

  async getSeed(): Promise<string> {
    const seed = await this.call("pedir la semilla", `${this.ecfUrl}/Autenticacion/api/Autenticacion/Semilla`, {
      method: "GET",
    });
    if (typeof seed !== "string" || !seed.includes("<valor>")) {
      throw new DgiiError("La DGII no devolvio la semilla de autenticacion.", 200, seed);
    }
    return seed;
  }

  async validateSeed(signedSeed: string): Promise<DgiiToken> {
    const res = await this.call(
      "validar la semilla firmada",
      `${this.ecfUrl}/Autenticacion/api/Autenticacion/ValidarSemilla`,
      { method: "POST", xml: { filename: "semilla.xml", content: signedSeed } },
    ) as { token?: unknown; expira?: unknown } | null;
    if (typeof res?.token !== "string" || res.token.length === 0) {
      throw new DgiiError("La DGII no devolvio el token (¿el certificado es del representante?).", 200, res);
    }
    const expires = typeof res.expira === "string" ? new Date(res.expira) : null;
    return {
      token: res.token,
      // Sin fecha legible se asume menos de la hora que suele durar.
      expiresAt: expires && !Number.isNaN(expires.getTime()) ? expires : new Date(Date.now() + 50 * 60_000),
    };
  }

  /** e-CF completo a Recepcion. Queda "sent" hasta consultar el trackId. */
  async sendEcf(token: string, filename: string, signedXml: string): Promise<DgiiResult> {
    const res = await this.call("enviar el e-CF", `${this.ecfUrl}/Recepcion/api/FacturasElectronicas`, {
      method: "POST",
      token,
      xml: { filename, content: signedXml },
    }) as { trackId?: unknown; error?: unknown; mensajes?: unknown } | null;
    const trackId = typeof res?.trackId === "string" && res.trackId.length > 0 ? res.trackId : null;
    const messages = parseDgiiMessages(res?.mensajes);
    if (!trackId) {
      const why = messages.map((m) => m.message).join("; ") || (typeof res?.error === "string" ? res.error : "");
      throw new DgiiError(`La DGII no devolvio trackId${why ? `: ${why}` : "."}`, 200, res);
    }
    return { status: "sent", trackId, messages };
  }

  /** Resumen (RFCE) de una factura de consumo menor de 250 mil: estado en el acto. */
  async sendSummary(token: string, filename: string, signedXml: string): Promise<DgiiResult> {
    let res: { estado?: unknown; codigo?: unknown; mensajes?: unknown } | null;
    try {
      res = await this.call("enviar el resumen de consumo", `${this.fcUrl}/RecepcionFC/api/recepcion/ecf`, {
        method: "POST",
        token,
        xml: { filename, content: signedXml },
      }) as typeof res;
    } catch (e) {
      // Un rechazo puede venir como 400 con el estado en el cuerpo: es un resultado.
      const body = e instanceof DgiiError ? e.body as typeof res : null;
      if (!body || typeof body !== "object" || body.estado === undefined) throw e;
      res = body;
    }
    return { status: statusFromDgii(res?.estado, res?.codigo), trackId: null, messages: parseDgiiMessages(res?.mensajes) };
  }

  /**
   * Aprobacion comercial (ACECF) firmada por el comprador. Responde en el acto
   * `{ codigo: "01" | "02", estado, mensaje[] }`; un 200 es que la recibio. El
   * `estado` repite si la aprobacion era de aceptar o de rechazar el e-CF.
   */
  async sendCommercialApproval(token: string, filename: string, signedXml: string): Promise<DgiiResult> {
    const res = await this.call(
      "enviar la aprobacion comercial",
      `${this.ecfUrl}/AprobacionComercial/api/AprobacionComercial`,
      { method: "POST", token, xml: { filename, content: signedXml } },
    ) as { estado?: unknown; mensaje?: unknown; mensajes?: unknown } | null;
    const messages = parseDgiiMessages(res?.mensajes ?? res?.mensaje);
    if (typeof res?.estado === "string" && res.estado.trim().length > 0) {
      messages.unshift({ code: null, message: res.estado.trim() });
    }
    return { status: "accepted", trackId: null, messages };
  }

  async trackStatus(token: string, trackId: string): Promise<DgiiResult> {
    const res = await this.call(
      "consultar el trackId",
      `${this.ecfUrl}/ConsultaResultado/api/Consultas/Estado?trackid=${encodeURIComponent(trackId)}`,
      { method: "GET", token },
    ) as { estado?: unknown; codigo?: unknown; mensajes?: unknown } | null;
    return { status: statusFromDgii(res?.estado, res?.codigo), trackId, messages: parseDgiiMessages(res?.mensajes) };
  }
}
