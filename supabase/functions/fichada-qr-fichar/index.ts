// ============================================================================
// Edge Function: fichada-qr-fichar
// ----------------------------------------------------------------------------
// Cáscara HTTP + CORS. Soporta DOS modos de fichada:
//
//  - ROTATIVO (compat): body {token, email} -> public.fichadaqr_fichar
//      Valida firma HMAC + vencimiento del token. Una foto de un código vencido
//      no sirve (el secreto de firma nunca sale al navegador).
//
//  - ESTATICO + IP: body {email} (sin token) -> public.fichadaqr_fichar_directo
//      El QR es fijo (no vence). La prueba de presencia es la IP: acá se lee la
//      IP pública del que ficha (x-forwarded-for) y la SQL la compara contra
//      FichadaQR.config.ip_trabajo. La IP la determina el SERVIDOR, no el cliente.
//
//  - whoami: body {whoami:true} -> {ip}  (para descubrir la IP del trabajo y
//      cargarla en config.ip_trabajo).
//
// Deploy con verify_jwt = false: la autorización es el token firmado (rotativo)
// o la IP del trabajo (estático).
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function clientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for") || "";
  const first = xff.split(",")[0]?.trim();
  return first || (req.headers.get("x-real-ip") || "").trim();
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const json = (o: unknown, status = 200) =>
    new Response(JSON.stringify(o), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  if (req.method !== "POST") return json({ error: "metodo" }, 405);

  let body: { token?: string; email?: string; whoami?: boolean };
  try {
    body = await req.json();
  } catch {
    return json({ error: "body_invalido" }, 400);
  }

  const ip = clientIp(req);
  if (body?.whoami) return json({ ip });

  const token = String(body?.token ?? "");
  const email = String(body?.email ?? "");
  if (!email) return json({ error: "faltan_datos" }, 400);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  if (token) {
    // Modo rotativo (compat): firma + vencimiento.
    const { data, error } = await supabase.rpc("fichadaqr_fichar", {
      p_token: token,
      p_email: email,
    });
    if (error) return json({ error: "error_interno", detalle: error.message }, 500);
    return json(data);
  }

  // Modo estático: sin token, presencia anclada a la IP del trabajo.
  const { data, error } = await supabase.rpc("fichadaqr_fichar_directo", {
    p_email: email,
    p_ip: ip,
  });
  if (error) return json({ error: "error_interno", detalle: error.message }, 500);
  return json(data);
});
