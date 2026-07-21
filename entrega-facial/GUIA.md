# Fichada facial — Guía de puesta en marcha

Sistema de fichada por **reconocimiento facial** para una tablet fija: el empleado
se para frente a la cámara, parpadea y queda registrada su entrada del día.

- La cámara procesa todo **en la tablet**: nunca se sube una foto, solo un vector
  de números. La comparación se hace en el servidor y la base de caras nunca sale
  de ahí.
- Necesitás **una cuenta gratis de Supabase** (es la base de datos donde se guardan
  los empleados, los vectores y las fichadas). Es el único servicio externo, y el
  plan gratis alcanza de sobra.

Son **5 pasos**. Toma ~15 minutos.

---

## ¿Qué es "planify"?

Es simplemente tu **lista de empleados** dentro de la base: una tabla con el
**legajo/ID** y el **nombre** de cada persona. El sistema facial la usa para saber
a quién corresponde cada cara. No es una app aparte ni hay que instalar nada: la
creás con un SQL (Paso 2). Podés cargar la lista de una, o dejar que cada empleado
se agregue solo cuando lo enrolás.

---

## Paso 1 — Crear el proyecto en Supabase (gratis)

1. Entrá a **https://supabase.com** → *Start your project* → creá una cuenta.
2. *New project*. Nombre (ej. `fichada`), una contraseña de base (guardala) y la
   región más cercana. *Create new project* y esperá ~2 min.

## Paso 2 — Crear tu planify y el motor facial (pegar 2 archivos)

En el proyecto, menú izquierdo → **SQL Editor**. Corré **en orden**:

1. *New query* → abrí **`1-crear-planify.sql`**, copiá todo, pegá y **Run**.
   (Crea tu lista de empleados. Adentro hay un ejemplo con 2 personas que podés
   editar por las tuyas, o dejar y cargarlas después.)
2. *New query* → abrí **`2-fichada-facial.sql`**, copiá todo, pegá y **Run**.
   (Crea el motor de reconocimiento.) Al terminar, abajo aparece
   **`tu_clave_de_dispositivo`**: **copiala y guardala** — es la llave que abre el
   kiosco y el enrolar.

   (Si la perdés: SQL Editor → `select clave_dispositivo from reconocimiento_facial.config;`)

> Importante: primero el 1 y después el 2 (el 2 necesita que ya exista tu planify).

## Paso 3 — Conectar las pantallas a tu proyecto

1. En Supabase → **Project Settings** → **Data API**. Copiá:
   - **Project URL** (ej. `https://abcd1234.supabase.co`)
   - **anon / public** key (cadena larga que empieza con `eyJ…`)
2. Abrí **`config.js`** con cualquier editor de texto y pegá esos dos valores:
   ```js
   const SUPABASE_URL  = "https://abcd1234.supabase.co";
   const SUPABASE_ANON = "eyJ...tu-anon-key...";
   ```
   Guardá. **Es el único archivo que editás.** (La anon key es pública por diseño:
   va en el navegador. Lo que protege el sistema es la clave de dispositivo.)

## Paso 4 — Publicar las páginas (con HTTPS)

La cámara **solo funciona por `https`** (no sirve abrir el archivo con doble clic).
Subí esta carpeta a un hosting gratis, sin instalar nada:

1. Entrá a **https://app.netlify.com/drop** (o Cloudflare Pages).
2. Arrastrá **toda la carpeta `entrega-facial`** a la página.
3. Te da una URL `https://algo.netlify.app`. Listo.

> Alternativa: GitHub Pages o cualquier hosting estático.

## Paso 5 — Enrolar y usar

### Enrolar (registrar caras) — una vez por empleado
Abrí en una compu o en la tablet:
```
https://TU-SITIO/enrolar.html#clave=TU_CLAVE_DE_DISPOSITIVO
```
- Escribí el **legajo/ID** y el **nombre**. Si el ID es nuevo, se agrega solo a tu
  planify. Si ya lo cargaste en el Paso 2, el nombre aparece solo.
- Tomá **3 a 5 capturas** desde ángulos un poco distintos.
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

> Para dejarla fija: en la tablet, abrí esa URL, "Agregar a pantalla de inicio" y
> activá modo kiosco/pantalla completa. Conviene subir el tiempo de apagado.

---

## Manejar la lista de empleados (tu planify)

En Supabase → **Table Editor** → schema `planify` → tabla `employees`. Podés
agregar/editar/desactivar gente ahí. O por SQL:
```sql
-- agregar / actualizar
insert into planify.employees (legajo, nombre) values ('7','Ana López')
on conflict (lower(btrim(legajo))) do update set nombre = excluded.nombre;

-- desactivar (no puede fichar, sin borrar su historial)
update planify.employees set activo = false where legajo = '7';
```

## Ver las fichadas
Supabase → **Table Editor** → schema `reconocimiento_facial` → tabla `fichadas`.
O en el SQL Editor:
```sql
select fecha, nombre, legajo, creado_en
from reconocimiento_facial.fichadas
order by creado_en desc;
```

## Cosas útiles (opcional)
- **Borrar la cara de alguien** (o si quedó mal enrolado):
  `select public.recon_facial_baja('7');` (usá su legajo/ID).
- **Qué tan estricto reconoce:** `umbral_distancia` en
  `reconocimiento_facial.config` (menor = más estricto; por defecto 0.55).
- **Zona horaria** de las fichadas: está como `America/Argentina/Buenos_Aires`
  dentro de `2-fichada-facial.sql`.
- **Rotar la clave de dispositivo** (si se filtró):
  ```sql
  update reconocimiento_facial.config
     set clave_dispositivo = substr(replace(gen_random_uuid()::text,'-',''),1,20)
   where id = 1;
  ```

## Si algo no anda
- **"Falta configurar Supabase"** → no editaste `config.js` (Paso 3).
- **"Clave de dispositivo inválida"** → la clave del `#clave=` no coincide con la
  de `config`. Copiala de nuevo del Paso 2.
- **No prende la cámara** → la página tiene que abrirse por **https** y hay que
  darle permiso; cerrá otras apps que la estén usando.
- **"No te reconocí"** → esa persona no está enrolada, o hace falta enrolarla con
  más capturas / mejor luz.
- **Al correr el archivo 2 dice que no existe `planify.employees`** → corriste el 2
  antes que el 1. Corré primero `1-crear-planify.sql`.
