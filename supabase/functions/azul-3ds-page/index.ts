// azul-3ds-page — página servida en el navegador del comercio para registrar
// su tarjeta con autenticación 3D Secure 2.0.
//
// GET /functions/v1/azul-3ds-page?sid=<session_id>
//   status pending        → formulario de tarjeta + driver JS de la máquina 3DS
//   status approved        → pantalla de éxito
//   status declined/error… → pantalla de fallo
//
// Pública (autorizada por el sid). El driver JS llama a azul-3ds-orchestrate y,
// para el desafío, postea el creq al ACS. La app detecta el resultado por
// Realtime sobre azul_payment_sessions. Ver PRD-Azul-3DSecure §6/§7.

import { corsPreflight, escapeHtmlAttr, htmlResponse } from "../_shared/responses.ts";
import { getAzulEnv } from "../_shared/env.ts";
import { getServiceClient } from "../_shared/supabase.ts";

Deno.serve(async (req) => {
  const pre = corsPreflight(req);
  if (pre) return pre;
  if (req.method !== "GET") return htmlResponse(shell("Método no permitido", ""), 405);

  const sid = new URL(req.url).searchParams.get("sid");
  if (!sid) return htmlResponse(resultPage("error", "Falta el identificador de sesión."), 400);

  const service = getServiceClient();
  const { data: session, error } = await service
    .from("azul_payment_sessions")
    .select("id, status, expires_at")
    .eq("id", sid)
    .maybeSingle();

  if (error) return htmlResponse(resultPage("error", "Error al cargar la sesión."), 500);
  if (!session) return htmlResponse(resultPage("error", "Sesión no encontrada."), 404);

  // Estados resueltos → pantalla de resultado.
  if (session.status === "approved") {
    return htmlResponse(resultPage("approved", "Tu tarjeta quedó registrada y verificada."));
  }
  if (["declined", "error", "timeout", "cancelled"].includes(session.status)) {
    return htmlResponse(resultPage("declined", "No pudimos verificar tu tarjeta. Intenta de nuevo."));
  }
  if (new Date(session.expires_at) <= new Date()) {
    return htmlResponse(resultPage("declined", "La sesión expiró. Inicia de nuevo desde la app."));
  }
  if (session.status === "authenticating") {
    return htmlResponse(resultPage("processing", "Estamos verificando tu tarjeta con el banco…"));
  }

  // status === 'pending' → formulario.
  const env = getAzulEnv();
  const base = env.publicCallbackBaseUrl.replace(/\/+$/, "");
  const orchUrl = `${base}/azul-3ds-orchestrate?sid=${encodeURIComponent(sid)}`;
  const pageUrl = `${base}/azul-3ds-page?sid=${encodeURIComponent(sid)}`;
  return htmlResponse(formPage(orchUrl, pageUrl));
});

// ---------------------------------------------------------------------------
// Vistas
// ---------------------------------------------------------------------------

const STYLE = `
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
       background:#f5f5f7;color:#222;display:flex;align-items:center;
       justify-content:center;min-height:100vh;margin:0;padding:20px}
  .box{background:#fff;border-radius:14px;padding:28px;max-width:420px;width:100%;
       box-shadow:0 2px 24px rgba(0,0,0,.06)}
  h1{margin:0 0 6px;font-size:19px}
  p.sub{margin:0 0 20px;font-size:13px;color:#777}
  label{display:block;font-size:12px;color:#555;margin:14px 0 6px}
  input{width:100%;box-sizing:border-box;padding:12px;border:1px solid #ddd;
        border-radius:9px;font-size:15px}
  .row{display:flex;gap:12px}.row>div{flex:1}
  button{width:100%;margin-top:22px;background:#FF7A00;color:#fff;border:0;
         padding:14px;border-radius:10px;font-size:15px;font-weight:600;cursor:pointer}
  button:disabled{opacity:.6;cursor:default}
  .status{margin-top:16px;font-size:13px;color:#555;text-align:center;min-height:18px}
  .spinner{width:30px;height:30px;border:3px solid #eee;border-top-color:#FF7A00;
           border-radius:50%;margin:0 auto 14px;animation:spin 1s linear infinite}
  @keyframes spin{to{transform:rotate(360deg)}}
  .ico{font-size:42px;text-align:center;margin-bottom:8px}
  .center{text-align:center}
  #tds-method{position:absolute;width:1px;height:1px;overflow:hidden;left:-9999px}
`;

function shell(title: string, inner: string): string {
  return `<!DOCTYPE html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtmlAttr(title)}</title><style>${STYLE}</style></head>
<body><div class="box">${inner}</div><div id="tds-method"></div></body></html>`;
}

function formPage(orchUrl: string, pageUrl: string): string {
  // El driver JS vive aquí. NUNCA envía PAN/CVC a otro lado que no sea el
  // orchestrate (que a su vez va a Azul); no se persiste en el navegador.
  const driver = `
  var ORCH=${JSON.stringify(orchUrl)}, PAGE=${JSON.stringify(pageUrl)};
  function $(id){return document.getElementById(id);}
  function setStatus(t){$("status").textContent=t||"";}
  function collectBrowserInfo(){
    var s=window.screen||{}, dpr=window.devicePixelRatio||1;
    return {
      language:navigator.language||"es-DO",
      colorDepth:String(s.colorDepth||24),
      screenWidth:String(Math.round((s.width||0)*dpr)),
      screenHeight:String(Math.round((s.height||0)*dpr)),
      timeZone:String(new Date().getTimezoneOffset()),
      userAgent:navigator.userAgent||"",
      javaScriptEnabled:"true"
    };
  }
  function toYYYYMM(v){
    var m=(v||"").replace(/\\s+/g,"").match(/^(\\d{2})\\/?(\\d{2}|\\d{4})$/);
    if(!m)return ""; var mm=m[1], yy=m[2]; if(yy.length===2)yy="20"+yy; return yy+mm;
  }
  function callOrch(payload){
    return fetch(ORCH,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})
      .then(function(r){return r.json();})
      .catch(function(e){return {next:"error",message:String(e)};});
  }
  function injectMethodForm(html){
    var host=$("tds-method"); var ifr=document.createElement("iframe");
    ifr.style.display="none"; host.appendChild(ifr);
    var doc=ifr.contentWindow.document; doc.open(); doc.write(html); doc.close();
  }
  function submitChallenge(redirectPostUrl,creq,termUrl){
    var f=document.createElement("form"); f.method="POST"; f.action=redirectPostUrl;
    function add(n,v){var i=document.createElement("input");i.type="hidden";i.name=n;i.value=v;f.appendChild(i);}
    add("creq",creq); add("TermUrl",termUrl);
    document.body.appendChild(f); f.submit();
  }
  function handleNext(r){
    if(!r){setStatus("Error inesperado.");return;}
    if(r.error){setStatus(r.error.message||"No pudimos continuar.");$("btn").disabled=false;return;}
    if(r.next==="approved"){location.href=PAGE+"&result=approved";return;}
    if(r.next==="declined"){location.href=PAGE+"&result=declined";return;}
    if(r.next==="method"){
      setStatus("Verificando con tu banco…");
      injectMethodForm(r.methodForm);
      setTimeout(function(){callOrch({action:"method-complete"}).then(handleNext);},10000);
      return;
    }
    if(r.next==="challenge"){
      setStatus("Redirigiendo a tu banco para autenticarte…");
      submitChallenge(r.redirectPostUrl,r.creq,r.termUrl);
      return;
    }
    setStatus(r.message||"No pudimos continuar.");$("btn").disabled=false;
  }
  document.addEventListener("DOMContentLoaded",function(){
    $("cardForm").addEventListener("submit",function(e){
      e.preventDefault();
      var exp=toYYYYMM($("exp").value);
      if(!exp){setStatus("Fecha de expiración inválida (MM/AA).");return;}
      $("btn").disabled=true; setStatus("Procesando…");
      callOrch({
        action:"start",
        card:{number:$("num").value.replace(/\\s+/g,""),expiration:exp,cvc:$("cvc").value.trim()},
        cardholder:{name:$("name").value.trim(),email:$("email").value.trim()},
        browserInfo:collectBrowserInfo()
      }).then(handleNext);
    });
  });`;

  const inner = `
    <h1>Registrar tarjeta</h1>
    <p class="sub">Verificamos tu tarjeta con una autorización de RD$1.00 que se libera automáticamente. Protegido con 3D Secure.</p>
    <form id="cardForm" autocomplete="off">
      <label for="name">Nombre del tarjetahabiente</label>
      <input id="name" name="name" required maxlength="96" autocomplete="cc-name">
      <label for="email">Correo electrónico</label>
      <input id="email" name="email" type="email" required maxlength="254" autocomplete="email">
      <label for="num">Número de tarjeta</label>
      <input id="num" name="num" inputmode="numeric" required maxlength="23" autocomplete="cc-number" placeholder="0000 0000 0000 0000">
      <div class="row">
        <div>
          <label for="exp">Expiración (MM/AA)</label>
          <input id="exp" name="exp" inputmode="numeric" required placeholder="12/28" maxlength="7" autocomplete="cc-exp">
        </div>
        <div>
          <label for="cvc">CVC</label>
          <input id="cvc" name="cvc" inputmode="numeric" required maxlength="4" autocomplete="cc-csc" placeholder="123">
        </div>
      </div>
      <button id="btn" type="submit">Registrar tarjeta</button>
      <div id="status" class="status"></div>
    </form>
    <script>${driver}</script>`;
  return shell("Registrar tarjeta", inner);
}

function resultPage(kind: "approved" | "declined" | "processing" | "error", message: string): string {
  const ico = kind === "approved" ? "✅" : kind === "processing" ? "" : "⚠️";
  const title = kind === "approved"
    ? "¡Tarjeta registrada!"
    : kind === "processing"
    ? "Verificando…"
    : "No pudimos continuar";
  const spinner = kind === "processing" ? `<div class="spinner"></div>` : `<div class="ico">${ico}</div>`;
  const hint = kind === "approved"
    ? `<p class="sub center">Ya puedes volver a la app de MangoPOS.</p>`
    : kind === "processing"
    ? ""
    : `<p class="sub center">Vuelve a la app e inténtalo de nuevo.</p>`;
  const inner = `${spinner}<h1 class="center">${escapeHtmlAttr(title)}</h1>
    <p class="sub center">${escapeHtmlAttr(message)}</p>${hint}`;
  return shell(title, inner);
}
