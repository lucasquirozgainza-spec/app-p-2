#!/usr/bin/env python3
"""Inyecta permisos (camara / GPS) y el nombre de la app en el
AndroidManifest.xml que genera `flutter create`, y ajusta minSdk.
Se ejecuta en CI despues de scaffoldear la carpeta android/."""
import re, pathlib, sys, shutil, os

manifest = pathlib.Path("android/app/src/main/AndroidManifest.xml")
txt = manifest.read_text(encoding="utf-8")

permisos = """    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.CAMERA"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29" tools:replace="android:maxSdkVersion"/>
    <uses-permission android:name="android.permission.ACCESS_MEDIA_LOCATION"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
    <uses-permission android:name="android.permission.USE_EXACT_ALARM"/>
    <uses-permission android:name="android.permission.VIBRATE"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-feature android:name="android.hardware.camera" android:required="false"/>
"""

if "android.permission.CAMERA" not in txt:
    txt = txt.replace("<application", permisos + "\n    <application", 1)

# Asegurar el namespace tools en <manifest> (necesario para tools:replace)
if "xmlns:tools=" not in txt:
    txt = re.sub(r"(<manifest\b)", r'\1 xmlns:tools="http://schemas.android.com/tools"', txt, count=1)

# Visibilidad de paquetes (Android 11+) para abrir WhatsApp, tel, https rapido
if "<queries>" not in txt:
    queries = (
        "    <queries>\n"
        '        <package android:name="com.whatsapp"/>\n'
        '        <package android:name="com.whatsapp.w4b"/>\n'
        '        <intent><action android:name="android.intent.action.VIEW"/>'
        '<data android:scheme="https"/></intent>\n'
        '        <intent><action android:name="android.intent.action.DIAL"/></intent>\n'
        "    </queries>\n"
    )
    txt = txt.replace("<application", queries + "\n    <application", 1)

# Nombre visible de la app (bajo el icono)
txt = re.sub(r'android:label="[^"]*"', 'android:label="OSIRIS"', txt, count=1)

# Más memoria para la app (cámara en alta resolución, PDF, imágenes): evita
# cierres por falta de memoria.
if "largeHeap" not in txt:
    txt = txt.replace("<application", '<application android:largeHeap="true"', 1)

# Icono redondo
if "roundIcon" not in txt:
    txt = txt.replace('android:icon="@mipmap/ic_launcher"',
                      'android:icon="@mipmap/ic_launcher" android:roundIcon="@mipmap/ic_launcher_round"', 1)

manifest.write_text(txt, encoding="utf-8")
print("Manifest parcheado OK (nombre: OSIRIS)")

# --- Icono OSIRIS (copia iconos pre-generados a res/mipmap-*) ---
res = pathlib.Path("android/app/src/main/res")
src_icons = pathlib.Path("tools/launcher_icons")
if src_icons.exists():
    for dens in ["mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"]:
        srcd = src_icons / f"mipmap-{dens}"
        dstd = res / f"mipmap-{dens}"
        if srcd.exists():
            dstd.mkdir(parents=True, exist_ok=True)
            for name in ["ic_launcher.png", "ic_launcher_round.png", "ic_launcher_foreground.png"]:
                if (srcd / name).exists():
                    shutil.copyfile(srcd / name, dstd / name)
    # Icono adaptable (Android 8+)
    anydpi = res / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    adaptive = ('<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@color/ic_launcher_background"/>\n'
                '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
                '</adaptive-icon>\n')
    (anydpi / "ic_launcher.xml").write_text(adaptive, encoding="utf-8")
    (anydpi / "ic_launcher_round.xml").write_text(adaptive, encoding="utf-8")
    valdir = res / "values"
    valdir.mkdir(parents=True, exist_ok=True)
    (valdir / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        '    <color name="ic_launcher_background">#C62828</color>\n</resources>\n',
        encoding="utf-8")
    print("Icono OSIRIS aplicado")
else:
    print("Aviso: no se encontraron iconos en tools/launcher_icons")

# --- Firma FIJA de release ---------------------------------------------------
# Sin esto, cada compilacion en GitHub firma con una clave distinta y Android
# rechaza instalar/actualizar ("aplicacion no instalada"). Copiamos un keystore
# fijo (tools/osiris.jks) a android/app y lo usamos para firmar el release.
KEYSTORE_SRC = pathlib.Path("tools/osiris.jks")
if KEYSTORE_SRC.exists():
    shutil.copyfile(KEYSTORE_SRC, "android/app/osiris.jks")
    print("Keystore de release copiado a android/app/osiris.jks")
else:
    print("AVISO: no se encontro tools/osiris.jks; el release usara la clave debug (cambia cada build)")

# --- minSdk + core library desugaring (requerido por flutter_local_notifications) ---
for g in ["android/app/build.gradle", "android/app/build.gradle.kts"]:
    p = pathlib.Path(g)
    if not p.exists():
        continue
    kts = g.endswith(".kts")
    b = p.read_text(encoding="utf-8")

    # minSdk 23
    b = re.sub(r"minSdk(Version)?\s*=?\s*[\w\.\(\)]+",
               "minSdk = 23" if kts else "minSdkVersion 23", b)

    # Activar desugaring dentro de compileOptions
    if "coreLibraryDesugaring" not in b:
        enable = "isCoreLibraryDesugaringEnabled = true" if kts else "coreLibraryDesugaringEnabled true"
        b = re.sub(r"compileOptions\s*\{", "compileOptions {\n        " + enable, b, count=1)
        # Bloque de dependencias con la librería de desugaring
        if kts:
            dep = '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")\n}\n'
        else:
            dep = "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.4'\n}\n"
        b = b + dep

    # Desactivar R8/minificacion en release (evita errores de clases faltantes de ML Kit).
    b = re.sub(r"minifyEnabled\s+true", "minifyEnabled false", b)
    b = re.sub(r"(isMinifyEnabled|isShrinkResources)\s*=\s*true", r"\1 = false", b)
    b = re.sub(r"shrinkResources\s+true", "shrinkResources false", b)
    if "minifyEnabled" not in b and "isMinifyEnabled" not in b:
        if kts:
            b = re.sub(r"(release\s*\{)", r"\1\n            isMinifyEnabled = false\n            isShrinkResources = false", b, count=1)
        else:
            b = re.sub(r"(release\s*\{)", r"\1\n            minifyEnabled false\n            shrinkResources false", b, count=1)

    # --- Firma FIJA de release (SE HACE AL FINAL) --------------------------
    # Debe ir despues del bloque de minify: asi el "release {" que inyecta el
    # bloque signingConfigs NO es confundido con el buildTypes.release (era la
    # causa del error "Could not find method minifyEnabled() on SigningConfig").
    if KEYSTORE_SRC.exists() and "osiris_signing" not in b:
        if kts:
            sign_block = (
                '\n    signingConfigs {\n'
                '        create("release") {\n'
                '            storeFile = file("osiris.jks")  // osiris_signing\n'
                '            storePassword = "osiris2025"\n'
                '            keyAlias = "osiris"\n'
                '            keyPassword = "osiris2025"\n'
                '        }\n'
                '    }\n'
            )
        else:
            sign_block = (
                '\n    signingConfigs {\n'
                '        release {\n'
                "            storeFile file('osiris.jks')  // osiris_signing\n"
                "            storePassword 'osiris2025'\n"
                "            keyAlias 'osiris'\n"
                "            keyPassword 'osiris2025'\n"
                '        }\n'
                '    }\n'
            )
        b = re.sub(r"android\s*\{", "android {" + sign_block, b, count=1)
        if kts:
            b = b.replace('signingConfigs.getByName("debug")', 'signingConfigs.getByName("release")')
            b = b.replace('signingConfigs.debug', 'signingConfigs.getByName("release")')
        else:
            b = b.replace("signingConfigs.debug", "signingConfigs.release")

    p.write_text(b, encoding="utf-8")
    print(f"build.gradle ajustado (minSdk + desugaring + R8 off + firma) en {g}")
