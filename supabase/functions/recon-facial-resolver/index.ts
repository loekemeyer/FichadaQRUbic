// ============================================================================
// Edge Function: recon-facial-resolver
// ----------------------------------------------------------------------------
// Cáscara HTTP + CORS del preview "¿Sos vos, Juan?". NO ficha: solo resuelve
// quién es la cara (match server-side) para que el kiosco pida confirmación
// antes de fichar y así bajar falsos positivos. La lógica vive en
// public.recon_facial_resolver, que solo puede ejecutar el service_role.
//
// La galería de vectores nunca sale del server: el kiosco manda su embedding y
// recibe solo {correo, distancia}.
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

  let body: { embedding?: unknown; umbral?: unknown; clave?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "body_invalido" }, 400);
  }

  const clave = req.headers.get("x-clave-dispositivo") ?? String(body?.clave ?? "");

  const embedding = body?.embedding;
  if (embedding == null) return json({ error: "faltan_datos" }, 400);
  if (!Array.isArray(embedding) || embedding.length !== 128 ||
      !embedding.every((n) => typeof n === "number" && Number.isFinite(n))) {
    return json({ error: "dim_invalida" }, 400);
  }
  const umbral =
    typeof body?.umbral === "number" && Number.isFinite(body.umbral) && body.umbral > 0
      ? body.umbral
      : null;

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data, error } = await supabase.rpc("recon_facial_resolver", {
    p_clave: clave,
    p_embedding: embedding,
    p_umbral: umbral,
  });
  if (error) {
    console.error("recon_facial_resolver rpc error:", error.message);
    return json({ error: "error_interno" }, 500);
  }

  const status = (data as { error?: string })?.error === "clave_invalida" ? 401 : 200;
  return json(data, status);
});
