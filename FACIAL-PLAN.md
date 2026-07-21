# FichadaQR — Plan para el kiosco de reconocimiento facial

> Documento de traspaso para armar, en **otra sesión**, un sistema de fichada por
> **reconocimiento facial** en un dispositivo fijo con cámara en la entrada.
> Complementa (no reemplaza) el QR estático + IP que ya existe.
> Fecha: 2026-07-20 · Estado: **diseño, sin implementar**.

---

## 0. TL;DR (leé esto primero)

- **Se puede** con librerías gratuitas que corren en el navegador (`face-api.js` /
  MediaPipe). Un **MVP** son unos días.
- Lo caro NO es reconocer una cara — es hacerlo **confiable**: **liveness**
  (que una foto no fiche por otro) y **precisión** (no rechazar a gente real).
- La cara es **dato biométrico sensible** (Ley 25.326, Argentina): hace falta
  **consentimiento** y guardarla segura. Más compromiso legal que un mail.
- **Recomendación:** el reconocimiento facial suma "manos libres / sin celular",
  pero la *prueba de presencia* ya la da el QR+IP. Encararlo solo si el requisito
  real es el kiosco sin teléfono. Y hacer **liveness sí o sí** desde el MVP+1.

---

## 1. Qué se quiere

Un dispositivo fijo en la entrada (tablet / PC / celular viejo con cámara) donde
el operario **se para frente a la cámara y ficha su ingreso**, sin celular ni QR.

Reusar todo lo que ya hay:
- Tabla `FichadaQR.fichadas` (`UNIQUE(correo, fecha)` = 1/día) — **misma**.
- `FichadaQR.esta_habilitado(email)` (whitelist `planify.employees`) — **misma**.
- Zona horaria AR, y la lógica de "¿ya fichó hoy?" (`fichadaqr_ficho_hoy`).

Lo único nuevo: **resolver "quién es" por la cara** en vez de por el correo/legajo.

---

## 2. Arquitectura recomendada (in-browser, sin nube de terceros)

Todo corre en el **dispositivo del kiosco** (navegador); el backend solo guarda
vectores y registra la fichada. Nada de mandar caras a un tercero (privacidad +
costo + latencia).

```
[Kiosco: cámara] --detecta cara--> [face-api.js: embedding 128/512-D]
      |                                   |
      | compara (coseno) contra los embeddings enrolados (cacheados del server)
      v
  match >= umbral  --->  POST /fichar-facial {empleado_id, liveness_ok}
                              |
                        Edge Function valida (liveness + 1/día + habilitado)
                              |
                        INSERT en FichadaQR.fichadas
```

### Librerías
- **`face-api.js`** (TensorFlow.js): detección + landmarks + **descriptor de 128
  dimensiones**. Modelos chicos (~6 MB), corren en el navegador. Simple y probado.
- Alternativa más moderna/precisa: **MediaPipe Face** + un modelo de embeddings
  (p. ej. MobileFaceNet vía TF.js). Más laburo, mejor precisión.
- **Matching:** distancia **coseno** (o euclídea) entre el embedding de la cámara
  y los enrolados. Umbral típico face-api: distancia euclídea < ~0.5–0.6.

### Por qué in-browser
- No sube fotos a ningún lado (solo *vectores*, que no son reversibles a la cara).
- Funciona con el mismo hosting estático (GitHub Pages) que el resto.
- Sin costos por API.

---

## 3. Modelo de datos (nuevo schema o dentro de FichadaQR)

```sql
-- Enrolamiento: N embeddings por empleado (varias fotos = más robusto).
create table "FichadaQR".rostros (
  id           bigint generated always as identity primary key,
  correo       text not null,               -- linkea con la whitelist/fichadas
  embedding    real[] not null,             -- vector 128-D (o usar pgvector)
  creado_en    timestamptz not null default now()
);
-- Opción PRO: extensión pgvector -> columna vector(128) + índice ivfflat,
-- y hacer el match en el server (más seguro, no expone embeddings al cliente).
```

Dos estrategias de matching (elegir una):
- **(A) Match en el cliente:** el kiosco baja todos los embeddings (solo del
  personal activo) y compara localmente. Simple, rápido, offline-friendly.
  Contra: expone los vectores al dispositivo (mitigar: kiosco de confianza + key).
- **(B) Match en el server (pgvector):** el kiosco manda SU embedding, una RPC
  `SECURITY DEFINER` busca el más cercano (`<=>` de pgvector) y devuelve el
  empleado. No expone la base de vectores. **Recomendado** si hay pgvector.

---

## 4. Flujos

### 4.a Enrolamiento (una vez por empleado)
1. Pantalla de admin: elegís el empleado (de `planify.employees` / `Empleados`).
2. Cámara toma **3–5 capturas** (distintos ángulos/luz). Por cada una: detectar 1
   sola cara, calcular embedding, guardar en `FichadaQR.rostros` (correo + vector).
3. Requisito: exactamente 1 cara, tamaño mínimo, buena luz (validar antes de guardar).

### 4.b Fichada en el kiosco
1. Loop: detectar cara en vivo → si hay 1 cara estable → calcular embedding.
2. **Liveness** (ver §5) → si no pasa, pedir "movete/parpadeá", no fichar.
3. Match contra enrolados → si `distancia < umbral` → candidato = ese empleado.
4. Mostrar "¿Sos vos, Juan?" (confirmación opcional para bajar falsos positivos).
5. POST a la Edge Function `fichada-facial-fichar {correo, liveness_ok}` →
   valida habilitado + 1/día → INSERT en `FichadaQR.fichadas` → "✓ Fichado 08:15".

---

## 5. Liveness / anti-spoofing (la parte difícil — NO saltearla)

Sin esto, alguien pone la **foto/video de un compañero** frente a la cámara y
ficha por él → el mismo fraude que querías evitar, peor.

Niveles (de menos a más robusto):
- **Challenge-response (fácil, MVP):** pedir una acción al azar — "parpadeá",
  "girá la cabeza a la derecha", "sonreí". Se detecta con los landmarks de
  face-api (EAR para parpadeo, yaw para giro). Frena la foto impresa estática.
- **Textura / moiré (medio):** detectar patrones de pantalla/impresión.
- **Profundidad (fuerte):** cámara con IR/estéreo (hardware dedicado). Caro.

Para esta fábrica, el **challenge-response** probablemente alcanza (ataque real =
"me fichan de casa", no un montaje sofisticado en la puerta). Combinar con:
- **IP del trabajo** (el kiosco está en la red del laburo — reusar `config.ip_trabajo`).
- **Clave de dispositivo** en el kiosco (solo ese equipo puede fichar).

---

## 6. Seguridad y legal (leer antes de arrancar)

- **Biométrico = dato sensible** (Ley 25.326). Necesitás:
  - **Consentimiento informado** del empleado para enrolar su cara.
  - Guardar **solo el vector** (no la foto). El vector no reconstruye la cara.
  - Acceso restringido a `FichadaQR.rostros` (RLS, nunca anon).
  - Política de baja: al desvincular a alguien, borrar su embedding.
- **RLS:** la tabla de rostros jamás expuesta a la anon key. El match server-side
  (pgvector) con `SECURITY DEFINER` es lo más limpio.
- **Umbrales:** falso positivo = fichás a otro (grave). Preferir umbral estricto +
  confirmación "¿Sos vos?" para no fichar a la persona equivocada.

---

## 7. Fases sugeridas

- [ ] **Fase 0 — decisión:** ¿va facial de verdad, o alcanza QR+IP? Definir si el
      requisito es "kiosco sin celular". Conseguir consentimientos.
- [ ] **Fase 1 — MVP:** enrolar (face-api.js) + kiosco que reconoce y fiche, match
      en cliente, **liveness por parpadeo/giro**, anclado a IP del trabajo.
      Reusar `fichadas` + `esta_habilitado`.
- [ ] **Fase 2 — robustez:** pgvector + match server-side, más liveness, métricas
      de falsos positivos/negativos, umbral afinado con datos reales.
- [ ] **Fase 3 — operación:** panel de re-enrolar, baja de empleados, auditoría.

---

## 8. Checklist técnico para arrancar la próxima sesión

1. Confirmar hosting del kiosco (GitHub Pages sirve; el kiosco necesita HTTPS para
   la cámara — Pages es HTTPS ✓).
2. Bajar los modelos de `face-api.js` al repo (tinyFaceDetector + faceLandmark68 +
   faceRecognition). ~6 MB, self-hosted (no CDN para que ande offline).
3. Crear `FichadaQR.rostros` (+ evaluar `create extension vector`).
4. Página `enrolar.html` (admin, con lista de empleados) y `kiosco.html` (fichada).
5. Edge Function `fichada-facial-fichar` (valida liveness_ok + 1/día + habilitado).
6. Umbral inicial: euclídea < 0.55 (face-api) — ajustar con pruebas reales.
7. Liveness MVP: EAR (parpadeo) + yaw (giro de cabeza) desde landmarks.

> Reusar TODO lo de FichadaQR (schema, whitelist, 1/día). Lo facial solo cambia
> **cómo se identifica a la persona**; el registro de la fichada es el mismo.
