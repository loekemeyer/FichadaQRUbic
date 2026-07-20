# FichadaQRUbic — Documento de diseño y contexto

> **Propósito de este documento:** dejar por escrito qué se conversó y qué se
> pensó como diseño, para que una próxima sesión (que trabajará junto con el
> repo de producción de la fábrica) tenga todo el contexto y pueda unir ambos
> proyectos en uno solo. **Primero se desarrolla acá**; una vez que el
> resultado conforme, recién ahí se hace el "rejunte" a un único repo.

Fecha de la conversación: 2026-07-16
Estado: **diseño acordado, sin implementar todavía.**

---

## 1. Qué se quiere lograr (pedido del usuario)

Una app simple de **fichada (check-in) por QR** para el personal de una fábrica:

1. Hay un **QR**. Lo único que hace es llevar a **una sola página**.
2. En esa página se **confirma el correo**, que viene **precargado**.
3. La **lista de correos habilitados** sale de una fuente de datos externa
   (se definió: **Supabase**).
4. Cada persona **puede fichar una sola vez por día**.
5. La fichada tiene que hacerse **realmente desde el punto de trabajo**.

### El problema central (lo más importante)

El usuario **NO quiere pedir la ubicación (geolocalización)** del celular, por
una cuestión de **privacidad**. Pero igual necesita **evitar la fichada
trucha**: ya le pasó que **lo ficharon a distancia** del punto de trabajo.

Entonces el desafío es:

> **Garantizar presencia física en el lugar de trabajo, SIN pedirle al celular
> dónde está.**

Aclaración importante: como no se usa geolocalización, **ya no hacen falta las
coordenadas del mapa ni el radio de X metros** que se habían mencionado al
principio. Ese enfoque quedó descartado a favor del de abajo.

---

## 2. Diagnóstico

El fraude (fichar a distancia) ocurre porque un **QR estático / link fijo se
puede compartir**: si el QR está impreso en la pared, alguien le saca una foto,
la manda por WhatsApp y otro ficha desde su casa.

- La **geolocalización** del navegador resolvería esto, pero el usuario no la
  quiere (privacidad) y además es "engañable" con apps de GPS falso.
- Por lo tanto, **la prueba de presencia tiene que ser el propio mecanismo de
  fichar**, no un permiso del celular.

---

## 3. Solución acordada: QR rotativo en el lugar (estilo TOTP / token bancario)

En vez de un QR impreso y fijo, se pone una **pantalla en el punto de trabajo**
(tablet, celular viejo o monitor) que muestra un **QR que se regenera solo cada
~30 segundos**. Cada QR lleva un **token firmado y con vencimiento corto**.

### Flujo

1. La persona llega al trabajo y **escanea el QR que la pantalla muestra en ese
   momento**.
2. Se abre la página de fichar → **confirma su correo** (precargado desde la
   lista de Supabase).
3. El servidor (Edge Function) valida:
   - **firma** correcta,
   - token **no vencido**,
   - token **no usado** antes (un solo uso),
   - correo **habilitado** en la lista,
   - esa persona **no fichó hoy**.
4. Se registra la fichada. ✅

### Por qué funciona

- **No pide ubicación** → cero fricción, cero problema de privacidad.
- **No se puede truchar a distancia**: solo la pantalla que está físicamente en
  el laburo muestra un token válido *ahora*. Una foto vieja del QR **ya venció**.
- Es el mismo principio que los **tokens bancarios**: el código cambia y por eso
  hay que estar presente.

### Limitación honesta (y su mitigación)

Alguien podría sacarle **captura al QR y mandárselo a un compañero dentro de la
ventana de ~30 s**. Se mitiga con:

- ventana **corta** (30 s),
- token de **un solo uso**,
- regla de **1 fichada por día**.

Para el caso real de esta fábrica (un compañero fichando a un amigo desde su
casa), esto **alcanza y sobra**: el ataque de relay en tiempo real es de mucho
mayor esfuerzo que el "foto por WhatsApp" que ocurría.

### Refuerzo opcional (invisible, para más adelante)

Chequear del lado del servidor que la fichada venga desde la **IP pública de la
red WiFi del trabajo**. No molesta a nadie y suma una segunda barrera.

- Se saltea con datos móviles / VPN, por eso va como **complemento**, no como
  única defensa.
- Queda **preparado en el código** y se **activa** cuando el usuario pase la IP
  del trabajo.

### Alternativas evaluadas y por qué se descartaron

- **QR estático impreso + geolocalización:** rechazado por privacidad.
- **NFC estático:** la URL es fija → se puede clonar/compartir igual que un QR
  impreso, salvo que se combine con token rotativo (más complejidad, poco
  beneficio).
- **Beacons Bluetooth:** requieren app instalada; demasiada complejidad.
- **QR rotativo (elegido):** mejor equilibrio entre **seguridad, privacidad y
  simplicidad**, y **no requiere instalar ninguna app**.

---

## 4. Decisiones ya tomadas

| Tema | Decisión |
|------|----------|
| Mecanismo anti-fraude | **QR rotativo** en pantalla fija on-site (sin geolocalización) |
| Dispositivo on-site | **Sí, el usuario tiene** un dispositivo para dejar fijo mostrando el QR |
| Fuente de correos / datos | **Supabase** |
| Organización Supabase | `Gestion Productiva` (`azosplccoimzkdtbvzfi`) |
| Proyecto Supabase | **`Control Partes Talleristas`** (`hrxfctzncixxqmpfhskv`), en un **schema aislado `FichadaQR`** para no tocar la fichada de producción que ya vive en `public` |
| Coordenadas / radio en metros | **Descartado** (ya no se usa geolocalización) |

### Proyectos Supabase existentes en la org (al 2026-07-16)

- `Control Partes Talleristas` — `hrxfctzncixxqmpfhskv` (sa-east-1)
- `loekemeyer's web` — `kwkclwhmoygunqmlegrg` (sa-east-1)
- `Costos` — `fxyhvacysnqzzsdvmplx` (us-west-2)

> Falta decidir si se usa un **proyecto Supabase nuevo** (ej. "FichadaQR") o uno
> de estos existentes.

---

## 5. Arquitectura técnica propuesta

### Dos páginas web estáticas

**A) `pantalla.html` — corre en el dispositivo fijo del trabajo**
- Muestra un **QR que se regenera cada 30 s**.
- Cada ~25 s le pide a Supabase un **token nuevo, firmado y con vencimiento
  corto**, y arma el QR con la URL `.../fichar?t=<token>`.
- Protegida por una **clave de dispositivo** (una URL secreta que solo el
  usuario abre en esa pantalla), para que **solo ese dispositivo** pueda emitir
  tokens válidos.

**B) `fichar.html` — la que se abre al escanear el QR**
- Confirma el **correo** (precargado desde la lista de `empleados`).
- Manda `token + correo` a la Edge Function `fichar`, que valida y registra.

### Base de datos (Supabase / Postgres)

- **`empleados`** — `correo`, `nombre`, `activo`
- **`fichadas`** — `correo`, `fecha`, `timestamp`
  - restricción **`UNIQUE (correo, fecha)`** → **1 fichada por día**
- **`tokens_usados`** — `jti`, `usado_en` → garantiza el **uso único** del token

### Edge Functions (Deno) — el secreto de firma vive SOLO acá, nunca en el navegador

- **`emitir-token`** → genera el token firmado (HMAC). Requiere la **clave de
  dispositivo** para responder (solo la pantalla on-site puede pedir tokens).
- **`fichar`** → valida (firma + vencimiento + uso único + correo habilitado +
  no fichó hoy) y **registra** la fichada. Acá se puede activar el chequeo de
  **IP del trabajo** más adelante.

### Diseño del token

- Token corto y firmado (estilo JWT/HMAC-SHA256): payload `{ exp, jti }`.
- `exp` = vencimiento corto (~30–60 s).
- `jti` = identificador único → se guarda en `tokens_usados` al canjearlo para
  impedir la reutilización.
- El **secreto de firma** vive únicamente como variable de entorno de la Edge
  Function.

### Anclaje a la ubicación física (lo que hace que "presencia" sea real)

Dos anclas por software, combinables:

1. **Clave de dispositivo**: solo la pantalla on-site conoce la URL/clave que
   permite **emitir** tokens.
2. **IP de la red del trabajo** (opcional): solo se aceptan fichadas desde la IP
   pública conocida de la fábrica.

El QR rotativo defiende contra el **compartir el link**; estas anclas atan al
**emisor** al lugar físico.

### Hosting sugerido para las dos páginas

Páginas estáticas → opciones simples y económicas: **GitHub Pages** (el repo ya
está en GitHub, gratis), Vercel o Netlify. **Sin definir todavía.**

---

## 6. Decisiones que quedaron pendientes

1. ~~**Supabase:** ¿proyecto nuevo o reusar uno existente?~~ **RESUELTO:** se
   reusa `Control Partes Talleristas` con un schema aislado `FichadaQR`.
2. **Hosting** de `pantalla.html` y `fichar.html`: GitHub Pages / Vercel /
   Netlify / Supabase.
3. **IP del trabajo** para activar la capa opcional (columna `config.ip_trabajo`
   ya preparada; falta el chequeo en la Edge Function y pasar la IP real).
4. **Correos habilitados:** la fuente es **`planify.employees`** (columna
   `Email`/`gmail`, autodetectada; filtra por `activo`). La tabla ya existe pero
   **aún sin la columna de email**; mientras tanto la fichada usa como respaldo
   la lista propia `FichadaQR.empleados` y cambia sola a `planify.employees` en
   cuanto tenga la columna (ver `supabase/README.md`).

---

## 6.b Estado actual — prototipo construido (Fase 1 en curso)

Ya está el **prototipo visual/UX** en el repo, listo para publicar en GitHub
Pages. **Todavía sin backend conectado** (usa datos de ejemplo).

Archivos:

- **`index.html`** — entrada con dos accesos (Pantalla / Fichar).
- **`pantalla.html`** — pantalla del dispositivo fijo. Genera un **QR real y
  escaneable** que **rota cada 30 s** (usa la librería `qrcodejs` por CDN, que
  corre en el navegador). El QR apunta a `fichar.html?t=<token>`.
- **`fichar.html`** — pantalla que se abre al escanear. Confirma el correo
  (lista de ejemplo), con estados: fichada OK, ya fichó hoy, código vencido,
  correo no habilitado. Tiene una constante `USING_BACKEND` y el `fetch` a la
  Edge Function `fichar` ya escrito, listo para activar.

Además hay un **prototipo interactivo publicado** (solo UX, datos de ejemplo,
QR representativo no escaneable) para ver desde el celular sin desplegar nada.

Para dejarlo online real en el repo: activar **GitHub Pages** (Settings → Pages
→ Source: `main` / carpeta raíz). Queda en `https://<usuario>.github.io/FichadaQRUbic/`.

## 6.c Estado actual — **backend conectado** (Fase 1 casi cerrada)

El backend ya está creado, desplegado y **probado** en Supabase (proyecto
`Control Partes Talleristas`, schema `FichadaQR`). Detalle completo en
[`supabase/README.md`](supabase/README.md). Resumen:

- **Tablas** (`FichadaQR`): `empleados`, `fichadas` (`UNIQUE(correo,fecha)` = 1/día),
  `tokens_usados`, `config` (secreto de firma + clave de dispositivo + TTL).
- **Lógica** en funciones SQL `public.fichadaqr_emitir_token` y
  `public.fichadaqr_fichar` (firma HMAC-SHA256 con `pgcrypto`, validación de
  vencimiento, correo habilitado y 1/día). Solo `service_role` las ejecuta.
- **Edge Functions** (cáscara HTTP + CORS): `fichada-qr-emitir-token` y
  `fichada-qr-fichar`.
- **`pantalla.html`** ya pide el token firmado a `fichada-qr-emitir-token`
  (clave de dispositivo por URL: `pantalla.html#clave=...`).
- **`fichar.html`** ya tiene `USING_BACKEND = true` y pega contra
  `fichada-qr-fichar`.

**Prueba hecha (vía SQL, la lógica real):** código válido → OK; mismo correo de
nuevo → `ya_ficho`; correo no habilitado → `no_habilitado`; token adulterado →
`token_invalido`; **código vencido → `token_vencido`** (una foto vieja ya no
sirve). ✅

Pendiente de Fase 1:
- **Probar el flujo completo en el navegador** (escanear → fichar). El test HTTP
  de las Edge Functions no se pudo correr desde el entorno de desarrollo porque
  su red bloquea la salida a Supabase; hay un script `curl` listo en
  `supabase/README.md` para correr desde una máquina con internet.
- **Cargar la lista real de correos** en `FichadaQR.empleados`.
- (Opcional) que `fichar.html` traiga la lista de correos desde la base en vez
  de tenerla hardcodeada.
- (Opcional) activar el chequeo de **IP del trabajo**.

## 7. Plan de trabajo

- [ ] **Fase 1 (este repo, `FichadaQRUbic`):** construir el MVP funcional
  (tablas + Edge Functions + `pantalla.html` + `fichar.html`) y validarlo.
- [ ] **Fase 2 (próxima sesión):** una vez que el resultado conforme, **unir**
  este proyecto con el **repo de producción de la fábrica** en un solo repo.

> Este documento es el **traspaso de contexto** para esa próxima sesión.
