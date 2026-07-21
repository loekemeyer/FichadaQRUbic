# Fichada facial — Guía de puesta en marcha

Sistema de fichada por **reconocimiento facial** para una tablet fija: el empleado
se para frente a la cámara, parpadea y queda registrada su entrada del día.

- La cámara procesa todo **en la tablet**: nunca se sube una foto, solo un vector
  de números. La comparación se hace en el servidor y la base de caras nunca sale
  de ahí.
- Necesitás **una cuenta gratis de Supabase** (es la base de datos donde se guardan
  los vectores y las fichadas). Es el único servicio externo, y el plan gratis
  alcanza de sobra.

Son **4 pasos**. Toma ~15 minutos.

---

## Paso 1 — Crear el proyecto en Supabase (gratis)

1. Entrá a **https://supabase.com** → *Start your project* → creá una cuenta
   (con Google o email).
2. *New project*. Ponele un nombre (ej. `fichada`), elegí una contraseña de base
   (guardala) y la región más cercana. *Create new project* y esperá ~2 min.

## Paso 2 — Crear la base (pegar 1 archivo)

1. En el proyecto, menú izquierdo → **SQL Editor** → *New query*.
2. Abrí el archivo **`supabase-setup.sql`** de esta carpeta, copiá **todo** y
   pegalo.
3. Apretá **Run** (abajo a la derecha).
4. Al terminar, abajo vas a ver una tabla con **`tu_clave_de_dispositivo`**.
   **Copiá ese valor y guardalo** — es la llave que abre el kiosco y el enrolar.

   (Si lo perdés, lo volvés a ver corriendo en el SQL Editor:
   `select clave_dispositivo from reconocimiento_facial.config;`)

## Paso 3 — Conectar las pantallas a tu proyecto

1. En Supabase, menú izquierdo → **Project Settings** → **Data API**. Copiá:
   - **Project URL** (ej. `https://abcd1234.supabase.co`)
   - **anon / public** key (una cadena larga que empieza con `eyJ…`)
2. Abrí **`config.js`** de esta carpeta con cualquier editor de texto y pegá esos
   dos valores:
   ```js
   const SUPABASE_URL  = "https://abcd1234.supabase.co";
   const SUPABASE_ANON = "eyJ...tu-anon-key...";
   ```
   Guardá. **Es el único archivo que editás.** (La anon key es pública por diseño:
   va en el navegador. Lo que protege el sistema es la clave de dispositivo.)

## Paso 4 — Publicar las páginas (con HTTPS)

La cámara **solo funciona por `https`** (no sirve abrir el archivo con doble clic).
Subí esta carpeta a un hosting gratis. La opción más fácil, sin instalar nada:

**Cloudflare Pages o Netlify (arrastrar y soltar):**
1. Entrá a **https://app.netlify.com/drop** (o Cloudflare Pages).
2. Arrastrá **toda la carpeta `entrega-facial`** a la página.
3. Te da una URL `https://algo.netlify.app`. Listo.

> Alternativa: GitHub Pages, o cualquier hosting estático. También sirve el mismo
> equipo en `http://localhost` para probar, pero para la tablet necesitás https.

---

## Usarlo

### Enrolar (registrar caras) — una vez por empleado
Abrí en una compu o en la tablet:
```
https://TU-SITIO/enrolar.html#clave=TU_CLAVE_DE_DISPOSITIVO
```
- Escribí un **legajo/ID** (cualquier identificador: un número, un apodo) y el
  **nombre**. Si el ID es nuevo, se crea solo.
- Tomá **3 a 5 capturas** de la cara desde ángulos un poco distintos.
- "Terminar / enrolar otro" para el siguiente.

> Tip: podés enrolar desde una **foto de carnet** con el botón "Cambiar cámara"
> (usa la cámara trasera para apuntar a la foto).

### Kiosco (la tablet fija)
Abrí en la tablet, en pantalla completa:
```
https://TU-SITIO/kiosco.html#clave=TU_CLAVE_DE_DISPOSITIVO
```
El empleado se para frente a la cámara, **parpadea**, confirma "Sí, fichar" y queda
registrado. **Una fichada por día** por persona.

> Para que quede fija: en la tablet, abrí esa URL, "Agregar a pantalla de inicio"
> y activá el modo kiosco/pantalla completa. Conviene desactivar el bloqueo de
> pantalla o poner el brillo/tiempo de apagado alto.

---

## Ver las fichadas
En Supabase → **Table Editor** → schema `reconocimiento_facial` → tabla
**`fichadas`**. O en el SQL Editor:
```sql
select fecha, nombre, legajo, creado_en
from reconocimiento_facial.fichadas
order by creado_en desc;
```

## Cosas útiles (opcional)

- **Borrar la cara de alguien** (o si quedó mal enrolado): en el SQL Editor
  `select public.recon_facial_baja('132');` (usá su legajo/ID).
- **Ajustar qué tan estricto reconoce:** `umbral_distancia` en la tabla
  `reconocimiento_facial.config` (menor = más estricto; por defecto 0.55).
- **Cambiar la zona horaria** de las fichadas: está como
  `America/Argentina/Buenos_Aires` dentro de `supabase-setup.sql`.
- **Rotar la clave de dispositivo** (si se filtró):
  ```sql
  update reconocimiento_facial.config
     set clave_dispositivo = substr(replace(gen_random_uuid()::text,'-',''),1,20)
   where id = 1;
  ```
  (después abrí el kiosco/enrolar con la clave nueva en la URL.)

## Si algo no anda
- **"Falta configurar Supabase"** → no editaste `config.js` (Paso 3).
- **"Clave de dispositivo inválida"** → la clave del `#clave=` no coincide con la
  de `config`. Copiala de nuevo del Paso 2.
- **No prende la cámara** → la página tiene que abrirse por **https** y hay que
  darle permiso de cámara; cerrá otras apps que la estén usando.
- **"No te reconocí"** → esa persona no está enrolada, o hace falta enrolarla con
  más capturas / mejor luz.
