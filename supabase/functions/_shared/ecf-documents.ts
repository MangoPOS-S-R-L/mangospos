// Enlaces de un e-CF ya emitido (consulta DGII, PDF, XML firmado): logica
// PURA, sin red, para que lo que se le muestra al usuario sea verificable.
//
// Lo consume `ecf-document-links`. El PDF y el XML de Alanube son enlaces de
// S3 FIRMADOS QUE VENCEN (llevan `Expires`): no sirve guardarlos, se piden en
// el momento de abrirlos. La URL de consulta DGII no vence.

import { alanubeEndpointForNcfType } from "./ecf-payload.ts";

export interface EcfDocumentLinks {
  /** Consulta del comprobante en la DGII (lo mismo que codifica el QR). */
  stamp_url: string | null;
  /** Representacion impresa que genera Alanube. Vence. */
  pdf_url: string | null;
  /** XML firmado. Vence. */
  xml_url: string | null;
  /** Estado ante la DGII segun Alanube (ACCEPTED, REJECTED, IN_PROCESS...). */
  legal_status: string | null;
}

/** Ruta de consulta en Alanube, o null si el tipo no se emite por Alanube. */
export function alanubeDocumentPath(
  ncfType: string,
  alanubeDocumentId: string,
  alanubeCompanyId: string,
): string | null {
  const base = alanubeEndpointForNcfType(ncfType);
  if (!base) return null;
  return `${base}/${encodeURIComponent(alanubeDocumentId)}/idCompany/${
    encodeURIComponent(alanubeCompanyId)
  }`;
}

function url(v: unknown): string | null {
  return typeof v === "string" && /^https?:\/\//i.test(v.trim()) ? v.trim() : null;
}

/** Respuesta de `GET /{tipo}/{id}/idCompany/{idCompany}`. */
export function parseDocumentLinks(body: unknown): EcfDocumentLinks {
  const b = (body ?? {}) as Record<string, unknown>;
  // Algunas respuestas de Alanube envuelven el documento; se aceptan ambas.
  const doc = (b.document && typeof b.document === "object" ? b.document : b) as Record<string, unknown>;
  return {
    stamp_url: url(doc.documentStampUrl) ?? url(doc.publicUrl),
    pdf_url: url(doc.pdf) ?? url(doc.pdfUrl),
    xml_url: url(doc.xml) ?? url(doc.xmlUrl),
    legal_status: typeof doc.legalStatus === "string" ? doc.legalStatus : null,
  };
}
