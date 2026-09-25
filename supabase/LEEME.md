# OSIRIS v12 · Pasos en Supabase (en este orden)

1. **Diagnóstico (solo lectura).** Abre SQL Editor, ejecuta `00_diagnostico.sql` y guarda los resultados. No modifica nada.
2. **Activar sesiones anónimas.** Ve a Authentication → Sign In / Providers y activa "Allow anonymous sign-ins". Cada celular inicia sesión solo, sin contraseña, y se vincula con un código.
3. **Estructura.** Ejecuta `01_estructura.sql`.
   - Crea edificios, unidades (torres o dispositivos), guardias, advertencias y códigos.
   - A `eventos` y `presencia` solo les agrega columnas.
   - No borra datos. Las versiones anteriores de la app siguen funcionando.
4. **Código del administrador.** Ejecuta aparte el bloque del punto 13 al final de `01_estructura.sql` (quítale los `--`) y anota el código que devuelve.
5. **Instala la app v12 en el celular del administrador.** En Configuración → Este celular → Vincular con código, ingresa el código del paso 4.
6. **Por cada edificio**, desde el celular del administrador:
   - En Configuración, activa el edificio. Queda publicado en la nube con la unidad "Principal".
   - En "Torres y celulares", agrega "Torre 2" si el edificio tiene dos dispositivos, o renombra "Principal" a "Torre 1".
   - Toca "Código" en cada torre y vincula con ese código el celular de esa torre.
   - En Guardias, registra el guardia diurno y el nocturno de cada torre. Empiezan en cero.
7. **Cierre de seguridad (al final).** Cuando TODOS los celulares tengan la v12 y estén vinculados, ejecuta `02_rls_eventos.sql`. Desde ese momento, cada celular solo puede leer y escribir su edificio, y solo el administrador puede borrar.

Nada de esto borra información. Los registros anteriores quedan como archivo histórico: sin guardia asignado, visibles para el administrador en Guardias → ⋮ → Archivo (sistema anterior).
