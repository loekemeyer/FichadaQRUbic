// ============================================================================
// Edge Function: recon-facial-nombre
// ----------------------------------------------------------------------------
// Devuelve el NOMBRE del empleado dado su LEGAJO (desde planify.employees), para
// que la pantalla de enrolar muestre "Legajo 132 → Maturano Romina" mientras se
// escribe. La lógica vive en public.recon_facial_nombre (solo service_role).
//
// Deploy con verify_jwt = false: la autorización es la clave de dispositivo.
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
  if (req.method !== "POST") return json({ error: "metodo" }, 405);

  let body: { legajo?: unknown; clave?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "body_invalido" }, 400);
  }

  const clave = req.headers.get("x-clave-dispositivo") ?? String(body?.clave ?? "");
  const legajo = String(body?.legajo ?? "").trim();
  if (!legajo) return json({ error: "faltan_datos" }, 400);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data, error } = await supabase.rpc("recon_facial_nombre", {
    p_clave: clave,
    p_legajo: legajo,
  });
  if (error) {
    console.error("recon_facial_nombre rpc error:", error.message);
    return json({ error: "error_interno" }, 500);
  }

  const status = (data as { error?: string })?.error === "clave_invalida" ? 401 : 200;
  return json(data, status);
});
