// Firma XMLDSig de documentos para la DGII con el certificado .p12 del
// contribuyente: firma enveloped sobre todo el documento (Reference URI=""),
// C14N 1.0, RSA-SHA256 y el certificado en KeyInfo. Es la misma configuracion
// que usa la DGII en sus ejemplos (y la libreria dgii-ecf).
//
// Solo firma XML que este modulo ya recibe en forma canonica: sin declaracion,
// sin espacios entre elementos, sin atributos fuera de los xmlns y con el texto
// escapado como C14N (ecf-test-set.ts los arma asi). Asi el digest es el de los
// mismos bytes que se envian, sin implementar C14N completo.
//
// El certificado y la contrasena solo viven en memoria durante la peticion.

import forge from "https://esm.sh/node-forge@1.3.1?no-dts";

const DSIG_NS = "http://www.w3.org/2000/09/xmldsig#";
const C14N = "http://www.w3.org/TR/2001/REC-xml-c14n-20010315";
const RSA_SHA256 = "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256";
const SHA256 = "http://www.w3.org/2001/04/xmlenc#sha256";
const ENVELOPED = "http://www.w3.org/2000/09/xmldsig#enveloped-signature";

export const XML_DECLARATION = '<?xml version="1.0" encoding="utf-8"?>';

export class SignerError extends Error {}

export interface DgiiSigner {
  key: CryptoKey;
  /** DER del certificado en base64 (va en X509Certificate). */
  certificate: string;
  subject: string;
  notAfter: Date;
}

function toBase64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

function binaryToBytes(bin: string): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Lee el .p12: llave privada y el certificado que le corresponde. */
export async function loadSigner(p12: Uint8Array, password: string): Promise<DgiiSigner> {
  // deno-lint-ignore no-explicit-any
  let pfx: any;
  try {
    const asn1 = forge.asn1.fromDer(forge.util.binary.raw.encode(p12));
    pfx = forge.pkcs12.pkcs12FromAsn1(asn1, false, password);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (/mac|password|invalid/i.test(msg)) {
      throw new SignerError("La contrasena del certificado no es correcta.");
    }
    throw new SignerError(`No se pudo leer el certificado .p12 (${msg}).`);
  }

  // deno-lint-ignore no-explicit-any
  const bags = (type: string): any[] => pfx.getBags({ bagType: type })[type] ?? [];
  const keyBag = [...bags(forge.pki.oids.pkcs8ShroudedKeyBag), ...bags(forge.pki.oids.keyBag)]
    .find((b) => b.key);
  if (!keyBag) throw new SignerError("El .p12 no trae la llave privada.");
  const privateKey = keyBag.key;
  if (!privateKey.n) throw new SignerError("La llave del certificado no es RSA.");

  // Puede venir la cadena completa: se usa el certificado de esta llave.
  const certs = bags(forge.pki.oids.certBag).map((b) => b.cert).filter(Boolean);
  const cert = certs.find((c) => c.publicKey?.n?.equals?.(privateKey.n)) ?? certs[0];
  if (!cert) throw new SignerError("El .p12 no trae el certificado.");

  const pkcs8 = forge.asn1.toDer(forge.pki.wrapRsaPrivateKey(forge.pki.privateKeyToAsn1(privateKey))).getBytes();
  const key = await crypto.subtle.importKey(
    "pkcs8",
    binaryToBytes(pkcs8),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const der = forge.asn1.toDer(forge.pki.certificateToAsn1(cert)).getBytes();
  return {
    key,
    certificate: btoa(der),
    // deno-lint-ignore no-explicit-any
    subject: cert.subject.attributes.map((a: any) => `${a.shortName ?? a.name}=${a.value}`).join(", "),
    notAfter: cert.validity.notAfter,
  };
}

async function sha256Base64(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return toBase64(new Uint8Array(digest));
}

/**
 * Declaraciones xmlns con prefijo de la raiz, ordenadas como C14N. C14N
 * inclusivo las hereda a SignedInfo (la semilla trae xmlns:xsd y xmlns:xsi).
 */
function rootPrefixedNamespaces(canonicalXml: string): string {
  const start = /^<[^\s>]+([^>]*)>/.exec(canonicalXml)?.[1] ?? "";
  return [...start.matchAll(/\s(xmlns:[\w.-]+)="([^"]*)"/g)]
    .map((m) => [m[1], m[2]] as const)
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
    .map(([k, v]) => ` ${k}="${v}"`)
    .join("");
}

function signedInfo(digest: string, inheritedNamespaces: string | null): string {
  const ns = inheritedNamespaces === null ? "" : ` xmlns="${DSIG_NS}"${inheritedNamespaces}`;
  return `<SignedInfo${ns}>` +
    `<CanonicalizationMethod Algorithm="${C14N}"></CanonicalizationMethod>` +
    `<SignatureMethod Algorithm="${RSA_SHA256}"></SignatureMethod>` +
    `<Reference URI=""><Transforms><Transform Algorithm="${ENVELOPED}"></Transform></Transforms>` +
    `<DigestMethod Algorithm="${SHA256}"></DigestMethod><DigestValue>${digest}</DigestValue></Reference>` +
    `</SignedInfo>`;
}

/**
 * Firma [canonicalXml] (un solo elemento raiz, ya en forma canonica) y
 * devuelve el documento con declaracion y la `<Signature>` al final de la raiz.
 */
export async function signXml(canonicalXml: string, signer: DgiiSigner): Promise<string> {
  const close = /<\/([A-Za-z_][\w.-]*)>$/.exec(canonicalXml);
  if (!canonicalXml.startsWith("<") || !close) throw new SignerError("XML a firmar mal formado.");

  const digest = await sha256Base64(canonicalXml);
  // Canonizado aparte, SignedInfo lleva los xmlns que hereda (Signature y raiz).
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      signer.key,
      new TextEncoder().encode(signedInfo(digest, rootPrefixedNamespaces(canonicalXml))),
    ),
  );
  const block = `<Signature xmlns="${DSIG_NS}">${signedInfo(digest, null)}` +
    `<SignatureValue>${toBase64(signature)}</SignatureValue>` +
    `<KeyInfo><X509Data><X509Certificate>${signer.certificate}</X509Certificate></X509Data></KeyInfo>` +
    `</Signature>`;
  const at = canonicalXml.length - close[0].length;
  return XML_DECLARATION + canonicalXml.slice(0, at) + block + close[0];
}

/**
 * Codigo de seguridad del e-CF: los primeros seis caracteres del
 * SignatureValue. Va en el resumen (RFCE) y en la representacion impresa.
 */
export function securityCode(signedXml: string): string {
  const v = /<SignatureValue>([^<]+)<\/SignatureValue>/.exec(signedXml)?.[1]?.trim();
  if (!v || v.length < 6) throw new SignerError("El documento firmado no tiene SignatureValue.");
  return v.slice(0, 6);
}

/**
 * La semilla de autenticacion de la DGII, rearmada en forma canonica (C14N
 * ordena las declaraciones xmlns y quita los espacios entre elementos).
 */
export function canonicalSeed(seedXml: string): string {
  const valor = /<valor>([^<]*)<\/valor>/.exec(seedXml)?.[1];
  const fecha = /<fecha>([^<]*)<\/fecha>/.exec(seedXml)?.[1];
  if (!valor || !fecha) throw new SignerError("La DGII no devolvio una semilla valida.");
  return `<SemillaModel xmlns:xsd="http://www.w3.org/2001/XMLSchema" ` +
    `xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><valor>${valor.trim()}</valor>` +
    `<fecha>${fecha.trim()}</fecha></SemillaModel>`;
}
