// Cliente HTTP reutilizable para Alanube.
// USO: createAlanubeClient() lee env vars y devuelve cliente listo.
// register-company, emit-document, y futuros consumers DEBEN usar este module
// para evitar divergencia de auth headers, base URLs, y error handling.

export interface AlanubeRequestOptions {
  method: "GET" | "POST" | "PATCH" | "DELETE";
  path: string;
  body?: unknown;
  idempotencyKey?: string;
  companyId?: string;
  timeoutMs?: number;
}

export interface AlanubeErrorPayload {
  status: number;
  body: unknown;
  message: string;
  isRetryable: boolean;
}

export class AlanubeError extends Error {
  status: number;
  body: unknown;
  isRetryable: boolean;
  constructor(p: AlanubeErrorPayload) {
    super(p.message);
    this.name = "AlanubeError";
    this.status = p.status;
    this.body = p.body;
    this.isRetryable = p.isRetryable;
  }
}

export class AlanubeClient {
  constructor(private baseUrl: string, private jwt: string) {}

  async request<T>(opts: AlanubeRequestOptions): Promise<T> {
    const url = `${this.baseUrl}${opts.path}`;
    const headers: Record<string, string> = {
      "Authorization": `Bearer ${this.jwt}`,
      "Content-Type": "application/json",
      "Accept": "application/json",
    };
    if (opts.idempotencyKey) headers["Idempotency-Key"] = opts.idempotencyKey;
    if (opts.companyId) headers["X-Company-Id"] = opts.companyId;

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), opts.timeoutMs ?? 30_000);

    try {
      const res = await fetch(url, {
        method: opts.method,
        headers,
        body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
        signal: controller.signal,
      });

      const text = await res.text();
      let body: unknown = null;
      if (text) {
        try { body = JSON.parse(text); } catch { body = text; }
      }

      if (!res.ok) {
        // Retryable: 401 (JWT renovable), 429 (rate limit), 5xx (servidor).
        // Dead: 400, 403, 404, 422 (payload o config rota — fix manual).
        const isRetryable = res.status === 401 || res.status === 429 || res.status >= 500;
        throw new AlanubeError({
          status: res.status,
          body,
          message: `Alanube ${res.status} on ${opts.method} ${opts.path}`,
          isRetryable,
        });
      }

      return body as T;
    } catch (e) {
      if (e instanceof AlanubeError) throw e;
      throw new AlanubeError({
        status: 0,
        body: null,
        message: e instanceof Error ? `${e.name}: ${e.message}` : String(e),
        isRetryable: true,
      });
    } finally {
      clearTimeout(timeoutId);
    }
  }
}

export function createAlanubeClient(): AlanubeClient {
  const baseUrl = Deno.env.get("ALANUBE_BASE_URL");
  const jwt = Deno.env.get("ALANUBE_JWT");
  if (!baseUrl) throw new Error("ALANUBE_BASE_URL env var not set");
  if (!jwt) throw new Error("ALANUBE_JWT env var not set");
  return new AlanubeClient(baseUrl, jwt);
}
