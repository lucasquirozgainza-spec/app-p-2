# CondoControl Pro

Aplicación Android (Flutter) para gestión de condominios — **LIMCO II** y **Millennial** con la misma APK.
Funciona **sin internet** (base de datos local SQLite) y viene **precargada con tus datos reales** de los Excel (propietarios, residentes, vehículos y contactos).

---

## 1. Cómo obtener el APK (sin instalar nada en tu compu)

El proyecto ya trae un **compilador automático en la nube gratis**. Tú solo subes el proyecto a GitHub una vez y GitHub te genera el `.apk`.

### Opción A — GitHub Actions (recomendado)

1. Crea una cuenta gratis en https://github.com
2. Crea un repositorio nuevo (botón **New**), por ejemplo `condocontrol`. Puede ser **Private**.
3. Sube **todo el contenido de esta carpeta** al repositorio:
   - Lo más fácil: en la página del repo vacío, clic en **uploading an existing file** y arrastra todos los archivos y carpetas (incluida la carpeta oculta `.github`).
   - O con Git: `git init`, `git add .`, `git commit -m "primera version"`, y `git push`.
4. Ve a la pestaña **Actions** del repositorio. Verás el flujo **"Compilar APK CondoControl Pro"** ejecutándose (o dale a **Run workflow**).
5. Espera ~5–8 minutos. Cuando termine (✓ verde), entra a la ejecución y baja hasta **Artifacts**.
6. Descarga **CondoControlPro-apk**. Es un `.zip` que contiene `app-release.apk`.
7. Ese `app-release.apk` es el que mandas por **WhatsApp** e instalas en el celular.

### Opción B — Codemagic (interfaz más simple)

1. Entra a https://codemagic.io y regístrate con tu cuenta de GitHub.
2. Conecta el repositorio `condocontrol`.
3. Codemagic detecta el archivo `codemagic.yaml`. Dale **Start new build**.
4. Al terminar, descarga el `app-release.apk` desde los artifacts.

---

## 2. Instalar el APK en el celular

1. Envía el `app-release.apk` por WhatsApp (o cópialo por cable/Bluetooth).
2. Ábrelo en el celular. Android pedirá permitir **"instalar apps de esta fuente"** → actívalo.
3. Instala y abre **CondoControl Pro**.
4. La primera vez concede permisos de **cámara** y **ubicación** (son necesarios para fotos y GPS).

> Al ser una app fuera de Play Store, Android muestra un aviso de seguridad normal; es esperado.

---

## 3. Usuarios de acceso (demo)

| Usuario   | Contraseña   | Rol           |
|-----------|--------------|---------------|
| `admin`   | `admin123`   | Administrador |
| `guardia` | `guardia123` | Guardia       |

El **administrador** puede crear más usuarios y cambiar contraseñas desde **Configuración → Usuarios**.
**Cambia estas contraseñas** apenas empieces a usarla en serio.

---

## 4. Qué incluye esta primera versión (MVP)

- **Login con roles** (admin, supervisor, guardia, conserje, limpieza), contraseñas cifradas (SHA-256 + salt).
- **Inicio de turno** con foto obligatoria, y GPS / batería / dispositivo / fecha / hora capturados automáticamente (el guardia no los puede editar).
- **Dashboard** con indicadores: visitas hoy, visitas dentro, rondas hoy, hospedajes, encomiendas, incidentes, vehículos, guardias activos.
- **Visitas**: registro con foto del CI y del visitante (obligatorias), y registro de salida.
- **Rondas**: checklist de puntos con estado **verde (sin novedad) / rojo (con novedad)**; si es rojo exige descripción y foto.
- **Propietarios / Residentes**: búsqueda, ficha por departamento, llamar con un toque; el admin puede editar.
- **Vehículos**: búsqueda por placa.
- **Contactos**: llamar directo.
- **Búsqueda global** (la lupa de arriba): persona, CI, depto, placa, propietario, residente, visitante.
- **Configuración (solo admin)**: elegir edificio activo y **activar/desactivar módulos por edificio** — la misma APK sirve para LIMCO II, Millennial o cualquier otro condominio sin tocar el código.
- **Auditoría**: se registra quién creó/editó cada registro y cuándo.
- **Fin de turno** con foto obligatoria.

## 5. Novedades de esta versión (v2)

- **Diseño responsivo** corregido (sin textos desbordados) y **más colorido**.
- **Detector de fotos borrosas**: si una foto sale movida/borrosa, la app pide repetirla (umbral ajustable en `lib/services/blur_util.dart`).
- **Pantalla principal** reorganizada: arriba las **acciones rápidas** (Visita, Ronda, Encomienda, Incidente, Finalizar turno) y abajo los **módulos**. Los indicadores se movieron a su propio módulo **Panel / Resumen**.
- **Módulos ahora funcionales** (crear y listar registros): **Vehículos, Encomiendas** (con entrega + foto del residente), **Incidentes, Mantenimiento, Hospedajes**.
- **Guardias**: muestra quién está en turno (se registra automáticamente al iniciar turno) y permite registrar nuevo personal.
- **Agregar edificio** desde Configuración (además de LIMCO II y Millennial).
- En Visitas, la **tarjeta asignada ahora es foto** en vez de texto.

### Pendiente para próxima versión

**Normativas (visor PDF)** y **Reportes (exportar Excel/PDF)** siguen como "próximamente". La **sincronización con Firebase** está preparada en la estructura (cada registro tiene un campo `sync_status`).

---

## 6. Datos precargados

- Propietarios: **132** (60 LIMCO II + 72 Millennial)
- Residentes: **26**
- Vehículos: **11**
- Contactos: **24**

Se cargan solos la primera vez que se abre la app. Si quieres actualizarlos, se reemplaza `assets/seed/seed.json` y se vuelve a compilar.

## 7. Estructura del proyecto

```
lib/
  main.dart              Arranque + splash
  theme.dart             Colores y estilo Material 3
  db/database_helper.dart  Esquema SQLite + carga inicial de datos
  services/              Auth, auditoría, GPS/batería/dispositivo, fotos, estado global
  screens/               Pantallas (login, turno, dashboard, visitas, rondas, etc.)
  widgets/               Componentes reutilizables (tarjetas, campos de foto, campos bloqueados)
assets/seed/seed.json    Tus datos reales
.github/workflows/       Compilador automático (GitHub Actions)
codemagic.yaml           Compilador alternativo (Codemagic)
tools/patch_android.py   Inyecta permisos de cámara/GPS al compilar
```
