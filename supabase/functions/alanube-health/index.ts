// Health check para validar reachability + runtime contra Alanube sandbox.
// Devuelve diagnóstico estructurado para el gate D-1 del PRD.

const ALANUBE_BASE_URL = Deno.env.get("ALANUBE_BASE_URL") ?? "https://sandbox.alanube.co/dom/v1";
const ALANUBE_JWT = Deno.env.get("ALANUBE_JWT") ?? "";

Deno.serve(async () => {
  const startedAt = Date.now();

  const result: Record<string, unknown> = {
    timestamp: new Date().toISOString(),
    alanube_url: ALANUBE_BASE_URL,
    has_jwt: ALANUBE_JWT.length > 0,
    runtime: {
      deno_version: Deno.version.deno,
      v8_version: Deno.version.v8,
      typescript_version: Deno.version.typescript,
    },
    reachable: false,
    alanube_status: null as number | null,
    latency_ms: 0,
    error: null as string | null,
    body_sample: null as string | null,
  };

  try {
    const probeUrl = `${ALANUBE_BASE_URL}/companies`;
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (ALANUBE_JWT) headers["Authorization"] = `Bearer ${ALANUBE_JWT}`;

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 10_000);

    const response = await fetch(probeUrl, {
      method: "GET",
      headers,
      signal: controller.signal,
    });
    clearTimeout(timeoutId);

    result.reachable = true;
    result.alanube_status = response.status;
    result.latency_ms = Date.now() - startedAt;

    const text = await response.text();
    result.body_sample = text.slice(0, 250);
  } catch (e) {
    result.error = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
    result.latency_ms = Date.now() - startedAt;
  }

  return new Response(JSON.stringify(result, null, 2), {
    headers: { "Content-Type": "application/json" },
    status: 200,
  });
});
