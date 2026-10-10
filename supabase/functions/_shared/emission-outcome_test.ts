import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { classifyAlanubeFailure } from "./emission-outcome.ts";

Deno.test("sin respuesta (tiempo agotado o red): incierto, nunca reenvío a ciegas", () => {
  assertEquals(classifyAlanubeFailure(0, ""), "uncertain");
});

Deno.test("5xx: Alanube pudo haberlo guardado", () => {
  assertEquals(classifyAlanubeFailure(500, "{}"), "uncertain");
  assertEquals(classifyAlanubeFailure(503, "AEP2009 DGII service unavailable"), "uncertain");
});

Deno.test("«ya existe» o 409: el primer envío pudo llegar — incierto, no rechazado", () => {
  assertEquals(classifyAlanubeFailure(409, "{}"), "uncertain");
  assertEquals(classifyAlanubeFailure(400, '{"message":"Document already exists"}'), "uncertain");
  assertEquals(classifyAlanubeFailure(422, '{"error":"e-NCF duplicado"}'), "uncertain");
});

Deno.test("rechazo antes de procesar: reenviar es seguro", () => {
  assertEquals(classifyAlanubeFailure(401, "{}"), "retry");
  assertEquals(classifyAlanubeFailure(408, "{}"), "retry");
  assertEquals(classifyAlanubeFailure(429, "{}"), "retry");
  assertEquals(classifyAlanubeFailure(400, '{"message":"AEP2009 DGII service unavailable"}'), "retry");
});

Deno.test("validación del contenido: definitivo", () => {
  assertEquals(classifyAlanubeFailure(400, '{"message":"RNC comprador inválido"}'), "dead");
  assertEquals(classifyAlanubeFailure(422, '{"errors":["fechaVencimientoSecuencia"]}'), "dead");
  assertEquals(classifyAlanubeFailure(403, "{}"), "dead");
});
