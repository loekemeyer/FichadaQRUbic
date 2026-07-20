// ============================================================================
// Edge Function: recon-facial-enrolar
// ----------------------------------------------------------------------------
// Cáscara HTTP + CORS de la pantalla de ADMIN para enrolar rostros. Toda la
// lógica (clave de dispositivo, correo habilitado, guardar el vector) vive en
// public.recon_facial_enrolar, que solo puede ejecutar el service_role.
//
// Se enrolan varios embeddings por empleado (3-5 capturas de distintos ángulos)
// llamando a este endpoint una vez por captura. Se guarda SOLO el vector, nunca
// la foto (dato biométrico sensible, Ley 25.326).
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

  let body: { correo?: unknown; embedding?: unknown; etiqueta?: unknown; clave?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "body_invalido" }, 400);
  }

  const clave = req.headers.get("x-clave-dispositivo") ?? String(body?.clave ?? "");
  const correo = String(body?.correo ?? "");
  const embedding = body?.embedding;
  const etiqueta = body?.etiqueta == null ? null : String(body.etiqueta);

  if (!correo) return json({ error: "faltan_datos" }, 400);
  if (!Array.isArray(embedding) || embedding.length !== 128 ||
      !embedding.every((n) => typeof n === "number" && Number.isFinite(n))) {
    return json({ error: "embedding_invalido" }, 400);
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data, error } = await supabase.rpc("recon_facial_enrolar", {
    p_clave: clave,
    p_correo: correo,
    p_embedding: embedding,
    p_etiqueta: etiqueta,
  });
  if (error) return json({ error: "error_interno", detalle: error.message }, 500);

  const status = (data as { error?: string })?.error === "clave_invalida" ? 401 : 200;
  return json(data, status);
});
