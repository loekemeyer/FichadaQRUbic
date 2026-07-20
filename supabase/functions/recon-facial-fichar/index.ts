// ============================================================================
// Edge Function: recon-facial-fichar
// ----------------------------------------------------------------------------
// Cáscara HTTP + CORS del kiosco de fichada por CARA. Toda la lógica (clave de
// dispositivo, liveness, match server-side por embedding, correo habilitado,
// 1 fichada por día y registro) vive en la función SQL public.recon_facial_fichar,
// que solo puede ejecutar el service_role.
//
// El kiosco calcula el embedding (128-D, face-api.js) EN EL NAVEGADOR y manda
// solo el vector: nunca sube la foto, y la galería de rostros no sale del server.
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

  let body: { embedding?: unknown; liveness_ok?: unknown; umbral?: unknown; clave?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "body_invalido" }, 400);
  }

  // Clave de dispositivo por header (preferido) o en el body.
  const clave = req.headers.get("x-clave-dispositivo") ?? String(body?.clave ?? "");

  const embedding = body?.embedding;
  if (!Array.isArray(embedding) || embedding.length !== 128 ||
      !embedding.every((n) => typeof n === "number" && Number.isFinite(n))) {
    return json({ error: "embedding_invalido" }, 400);
  }
  const livenessOk = body?.liveness_ok === true;
  const umbral = typeof body?.umbral === "number" ? body.umbral : null;

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data, error } = await supabase.rpc("recon_facial_fichar", {
    p_clave: clave,
    p_embedding: embedding,
    p_liveness_ok: livenessOk,
    p_umbral: umbral,
  });
  if (error) return json({ error: "error_interno", detalle: error.message }, 500);

  const status = (data as { error?: string })?.error === "clave_invalida" ? 401 : 200;
  return json(data, status);
});
