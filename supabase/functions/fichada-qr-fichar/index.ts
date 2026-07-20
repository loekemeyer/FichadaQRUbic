// ============================================================================
// Edge Function: fichada-qr-fichar
// ----------------------------------------------------------------------------
// Cáscara HTTP + CORS. Toda la lógica (firma + vencimiento del token, correo
// habilitado, 1 fichada por día y registro) vive en la función SQL
// public.fichadaqr_fichar, que solo puede ejecutar el service_role.
//
// Es lo que hace que una FOTO de un código VENCIDO no sirva: el vencimiento se
// chequea del lado del servidor y el secreto de firma nunca sale al navegador.
//
// Deploy con verify_jwt = false: la autorización es el propio token firmado.
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const json = (o: unknown, status = 200) =>
    new Response(JSON.stringify(o), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  if (req.method !== "POST") return json({ error: "metodo" }, 405);

  let body: { token?: string; email?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "body_invalido" }, 400);
  }
  const token = String(body?.token ?? "");
  const email = String(body?.email ?? "");
  if (!token || !email) return json({ error: "faltan_datos" }, 400);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data, error } = await supabase.rpc("fichadaqr_fichar", {
    p_token: token,
    p_email: email,
  });
  if (error) return json({ error: "error_interno", detalle: error.message }, 500);

  return json(data);
});
