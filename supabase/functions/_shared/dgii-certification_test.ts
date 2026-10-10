import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { DgiiCertificationClient, DgiiError, xmlMultipart } from "./dgii-certification.ts";

interface Call {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: string | null;
}

function fakeDgii(responses: Array<{ status?: number; body: unknown }>) {
  const calls: Call[] = [];
  const fetchFn = (input: string | URL | Request, init?: RequestInit) => {
    const r = responses.shift()!;
    calls.push({
      url: String(input),
      method: init?.method ?? "GET",
      headers: (init?.headers ?? {}) as Record<string, string>,
      body: init?.body ? new TextDecoder().decode(init.body as Uint8Array) : null,
    });
    const text = typeof r.body === "string" ? r.body : JSON.stringify(r.body);
    return Promise.resolve(new Response(text, { status: r.status ?? 200 }));
  };
  return { calls, client: new DgiiCertificationClient("https://ecf.test/CerteCF", "https://fc.test/CerteCF", fetchFn) };
}

Deno.test("multipart: campo xml con nombre de archivo y largo conocido", () => {
  const { body, contentType } = xmlMultipart("101000001E310000000001.xml", "<ECF>ñ</ECF>");
  const text = new TextDecoder().decode(body);
  const boundary = contentType.split("boundary=")[1];
  assert(text.startsWith(`--${boundary}\r\nContent-Disposition: form-data; name="xml"; filename="101000001E310000000001.xml"`));
  assert(text.endsWith(`\r\n--${boundary}--\r\n`));
  assert(text.includes("\r\n\r\n<ECF>ñ</ECF>\r\n"));
});

Deno.test("autenticacion: semilla y token", async () => {
  const { calls, client } = fakeDgii([
    { body: '<?xml version="1.0"?><SemillaModel><valor>abc</valor><fecha>2026</fecha></SemillaModel>' },
    { body: { token: "tok", expira: "2026-10-08T17:00:00Z", expedido: "2026-10-08T16:00:00Z" } },
  ]);
  assert((await client.getSeed()).includes("<valor>abc</valor>"));
  const t = await client.validateSeed("<SemillaModel/>");
  assertEquals(t.token, "tok");
  assertEquals(t.expiresAt.toISOString(), "2026-10-08T17:00:00.000Z");
  assertEquals(calls[0].url, "https://ecf.test/CerteCF/Autenticacion/api/Autenticacion/Semilla");
  assertEquals(calls[1].url, "https://ecf.test/CerteCF/Autenticacion/api/Autenticacion/ValidarSemilla");
  assert(calls[1].headers["Content-Type"].startsWith("multipart/form-data; boundary="));
});

Deno.test("e-CF: trackId y consulta", async () => {
  const { calls, client } = fakeDgii([
    { body: { trackId: "T-1", error: null, mensajes: [] } },
    { body: { trackId: "T-1", codigo: 2, estado: "Rechazado", mensajes: [{ valor: "Monto invalido", codigo: 7 }] } },
  ]);
  const sent = await client.sendEcf("tok", "a.xml", "<ECF/>");
  assertEquals(sent, { status: "sent", trackId: "T-1", messages: [] });
  assertEquals(calls[0].headers.Authorization, "Bearer tok");
  const r = await client.trackStatus("tok", "T-1");
  assertEquals(r.status, "rejected");
  assertEquals(r.messages, [{ code: "7", message: "Monto invalido" }]);
  assertEquals(calls[1].url, "https://ecf.test/CerteCF/ConsultaResultado/api/Consultas/Estado?trackid=T-1");
});

Deno.test("resumen: va a fc.dgii y un 400 con estado es un rechazo, no un error", async () => {
  const { calls, client } = fakeDgii([
    { status: 400, body: { codigo: 2, estado: "Rechazado", encf: "E320000000002", mensajes: [{ valor: "Codigo de seguridad", codigo: 1 }] } },
  ]);
  const r = await client.sendSummary("tok", "a.xml", "<RFCE/>");
  assertEquals(r.status, "rejected");
  assertEquals(calls[0].url, "https://fc.test/CerteCF/RecepcionFC/api/recepcion/ecf");
});

Deno.test("errores: 401 con mensaje de la DGII", async () => {
  const { client } = fakeDgii([{ status: 401, body: { mensajes: [{ valor: "Token vencido", codigo: 1 }] } }]);
  const e = await assertRejects(() => client.sendEcf("tok", "a.xml", "<ECF/>"), DgiiError);
  assertEquals(e.status, 401);
  assert(e.message.includes("Token vencido"));
});

Deno.test("tiempo limite: tambien corta una respuesta que se cuelga a mitad del cuerpo", async () => {
  // Como fetch real: los encabezados llegan, el cuerpo nunca termina y abortar
  // la señal corta la lectura.
  const fetchFn = (_input: string | URL | Request, init?: RequestInit) => {
    const stream = new ReadableStream<Uint8Array>({
      start(c) {
        c.enqueue(new TextEncoder().encode('{"trackId":'));
        init?.signal?.addEventListener("abort", () => c.error(new DOMException("aborted", "AbortError")));
      },
    });
    return Promise.resolve(new Response(stream, { status: 200 }));
  };
  const client = new DgiiCertificationClient("https://ecf.test/CerteCF", "https://fc.test/CerteCF", fetchFn, 50);
  const e = await assertRejects(() => client.trackStatus("tok", "t1"), DgiiError);
  assertEquals(e.status, 0);
  assert(e.message.includes("no respondio a tiempo"));
});

Deno.test("aprobacion comercial: va a AprobacionComercial y responde en el acto", async () => {
  const { calls, client } = fakeDgii([
    { body: { codigo: "01", estado: "Aprobación Comercial Aprobada.", mensaje: [] } },
    { status: 400, body: { codigo: "02", estado: "Error", mensaje: ["El e-NCF no existe"] } },
  ]);
  const ok = await client.sendCommercialApproval("tok", "101000001E310000000001.xml", "<ACECF/>");
  assertEquals(ok, { status: "accepted", trackId: null, messages: [{ code: null, message: "Aprobación Comercial Aprobada." }] });
  assertEquals(calls[0].url, "https://ecf.test/CerteCF/AprobacionComercial/api/AprobacionComercial");
  assertEquals(calls[0].headers.Authorization, "Bearer tok");
  const e = await assertRejects(() => client.sendCommercialApproval("tok", "a.xml", "<ACECF/>"), DgiiError);
  assertEquals(e.messages, [{ code: null, message: "El e-NCF no existe" }]);
  assert(e.message.includes("El e-NCF no existe"));
});
