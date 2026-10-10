import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.208.0/assert/mod.ts";
import forge from "https://esm.sh/node-forge@1.3.1?no-dts";
import { canonicalSeed, loadSigner, securityCode, SignerError, signXml, XML_DECLARATION } from "./dgii-signer.ts";

// Certificado de prueba generado en el momento (no hay llaves en el repo).
function testP12(password: string, opts: { algorithm?: "3des" | "aes256" } = {}): Uint8Array {
  const keys = forge.pki.rsa.generateKeyPair(1024);
  const cert = forge.pki.createCertificate();
  cert.publicKey = keys.publicKey;
  cert.serialNumber = "01";
  cert.validity.notBefore = new Date(Date.now() - 86_400_000);
  cert.validity.notAfter = new Date(Date.now() + 86_400_000);
  cert.setSubject([{ name: "commonName", value: "PRUEBA MANGOPOS" }]);
  cert.setIssuer([{ name: "commonName", value: "PRUEBA MANGOPOS" }]);
  cert.sign(keys.privateKey, forge.md.sha256.create());
  const asn1 = forge.pkcs12.toPkcs12Asn1(keys.privateKey, [cert], password, { algorithm: opts.algorithm ?? "3des" });
  return Uint8Array.from(forge.asn1.toDer(asn1).getBytes(), (c: string) => c.charCodeAt(0));
}

function b64(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes));
}

async function verify(signed: string): Promise<boolean> {
  const body = signed.slice(XML_DECLARATION.length);
  const sig = /<Signature xmlns="http:\/\/www\.w3\.org\/2000\/09\/xmldsig#">.*<\/Signature>/.exec(body)![0];
  const doc = body.replace(sig, "");
  const digest = /<DigestValue>([^<]+)<\/DigestValue>/.exec(sig)![1];
  const expected = b64(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(doc))));
  if (digest !== expected) return false;

  const rootNs = [.../^<[^\s>]+([^>]*)>/.exec(doc)![1].matchAll(/\s(xmlns:[\w.-]+="[^"]*")/g)].map((m) => ` ${m[1]}`)
    .sort().join("");
  const signedInfo = /<SignedInfo>.*<\/SignedInfo>/.exec(sig)![0]
    .replace("<SignedInfo>", `<SignedInfo xmlns="http://www.w3.org/2000/09/xmldsig#"${rootNs}>`);
  const certB64 = /<X509Certificate>([^<]+)<\/X509Certificate>/.exec(sig)![1];
  const cert = forge.pki.certificateFromAsn1(forge.asn1.fromDer(atob(certB64)));
  const spki = forge.asn1.toDer(forge.pki.publicKeyToAsn1(cert.publicKey)).getBytes();
  const key = await crypto.subtle.importKey(
    "spki",
    Uint8Array.from(spki, (c: string) => c.charCodeAt(0)),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const value = Uint8Array.from(atob(/<SignatureValue>([^<]+)<\/SignatureValue>/.exec(sig)![1]), (c) => c.charCodeAt(0));
  return crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, value, new TextEncoder().encode(signedInfo));
}

Deno.test("firma: enveloped al final de la raiz y verificable", async () => {
  const signer = await loadSigner(testP12("clave con espacio "), "clave con espacio ");
  assertEquals(signer.subject, "CN=PRUEBA MANGOPOS");
  const signed = await signXml("<ECF><Encabezado><Version>1.0</Version></Encabezado><FechaHoraFirma>x</FechaHoraFirma></ECF>", signer);
  assert(signed.startsWith(`${XML_DECLARATION}<ECF><Encabezado>`));
  assert(signed.endsWith("</Signature></ECF>"));
  assert(signed.includes('<Reference URI="">'));
  assert(await verify(signed));
  assertEquals(securityCode(signed), /<SignatureValue>(.{6})/.exec(signed)![1]);
});

Deno.test("firma: semilla con xmlns, canonica y verificable", async () => {
  const signer = await loadSigner(testP12("x", { algorithm: "aes256" }), "x");
  const seed = '<?xml version="1.0" encoding="utf-8"?>\n  <SemillaModel xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ' +
    'xmlns:xsd="http://www.w3.org/2001/XMLSchema">\n    <valor>t9vz+/A=</valor>\n    <fecha>2025-01-25T13:33:57.395-04:00</fecha>\n  </SemillaModel>';
  const canonical = canonicalSeed(seed);
  assert(canonical.startsWith('<SemillaModel xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi='));
  assert(await verify(await signXml(canonical, signer)));
});

Deno.test("firma: contrasena equivocada se explica", async () => {
  await assertRejects(() => loadSigner(testP12("buena"), "mala"), SignerError, "contrasena");
});

Deno.test("firma: un archivo que no es .p12", async () => {
  await assertRejects(() => loadSigner(new Uint8Array([0x30, 0x03, 0x02, 0x01, 0x01]), "x"), SignerError);
});
