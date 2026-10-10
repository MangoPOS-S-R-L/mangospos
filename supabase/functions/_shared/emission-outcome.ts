// T07 (20261010_0009): qué hacer con un envío a Alanube que no salió bien.
//
//   retry     — Alanube lo rechazó ANTES de procesarlo (credenciales, límite
//               de pedidos, DGII caída con respuesta clara): reenviar es seguro.
//   uncertain — pudo haberlo recibido (tiempo agotado, red, 5xx, «ya existe»):
//               NO se reenvía solo; se concilia (webhook) o lo decide una
//               persona. Reenviar a ciegas duplicaría el e-NCF ante la DGII.
//   dead      — rechazo definitivo del contenido (4xx de validación).

export type EmissionOutcome = "retry" | "uncertain" | "dead";

const DGII_TRANSIENT = ["AEP2009", "DGII service", "network path", "timed out"];
const DUPLICATE = /duplic|already exist|ya existe|exists/i;

export function isDgiiTransient(body: string): boolean {
  return DGII_TRANSIENT.some((marker) => body.includes(marker));
}

/** [status] 0 = sin respuesta HTTP (tiempo agotado o red). */
export function classifyAlanubeFailure(status: number, body: string): EmissionOutcome {
  if (status === 0) return "uncertain";
  if (status >= 500) return "uncertain";
  if (status === 409 || DUPLICATE.test(body)) return "uncertain";
  if (status === 401 || status === 408 || status === 429) return "retry";
  if (isDgiiTransient(body)) return "retry";
  return "dead";
}
