import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { alanubeDocumentPath, parseDocumentLinks } from "./ecf-documents.ts";

Deno.test("ruta de consulta por tipo", () => {
  assertEquals(alanubeDocumentPath("E32", "01DOC", "01CO"), "/invoices/01DOC/idCompany/01CO");
  assertEquals(alanubeDocumentPath("E31", "01DOC", "01CO"), "/fiscal-invoices/01DOC/idCompany/01CO");
  assertEquals(alanubeDocumentPath("E34", "01DOC", "01CO"), "/credit-notes/01DOC/idCompany/01CO");
  assertEquals(alanubeDocumentPath("B02", "01DOC", "01CO"), null);
});

Deno.test("enlaces con los nombres reales de Alanube", () => {
  const l = parseDocumentLinks({
    id: "01DOC",
    legalStatus: "ACCEPTED",
    documentStampUrl: "https://fc.dgii.gov.do/ecf/ConsultaTimbreFC?RncEmisor=133328828&ENCF=E320000000003",
    pdf: "https://api-alanube.s3.amazonaws.com/x.pdf?Expires=1",
    xml: "https://api-alanube.s3.amazonaws.com/x.xml?Expires=1",
  });
  assertEquals(l.legal_status, "ACCEPTED");
  assertEquals(l.stamp_url?.startsWith("https://fc.dgii.gov.do/"), true);
  assertEquals(l.pdf_url?.endsWith("Expires=1"), true);
  assertEquals(l.xml_url?.includes(".xml"), true);
});

Deno.test("sin enlaces o con basura no inventa", () => {
  const l = parseDocumentLinks({ pdf: "", xml: 12, documentStampUrl: "no-es-url" });
  assertEquals(l, { stamp_url: null, pdf_url: null, xml_url: null, legal_status: null });
  assertEquals(parseDocumentLinks(null).pdf_url, null);
});
