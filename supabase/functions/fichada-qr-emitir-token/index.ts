// ============================================================================
// Edge Function: fichada-qr-emitir-token
// ----------------------------------------------------------------------------
// Cáscara HTTP + CORS. Toda la lógica (validar la clave de dispositivo, firmar
// el token con vencimiento corto) vive en la función SQL
// public.fichadaqr_emitir_token, que solo puede ejecutar el service_role.
// El secreto de firma NUNCA sale al navegador.
//
// Deploy con verify_jwt = false: la autenticación es la clave de dispositivo.
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-clave-dispositivo",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const json = (o: unknown, status = 200) =>
    new Response(JSON.stringify(o), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

  // La clave de dispositivo llega por header (preferido) o en el body.
  let clave = req.headers.get("x-clave-dispositivo") ?? "";
  if (!clave) {
    try {
      const b = await req.json();
      clave = b?.clave ?? "";
    } catch { /* body vacío */ }
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data, error } = await supabase.rpc("fichadaqr_emitir_token", { p_clave: clave });
  if (error) return json({ error: "error_interno", detalle: error.message }, 500);

  const status = (data as { error?: string })?.error === "clave_invalida" ? 401 : 200;
  return json(data, status);
});
