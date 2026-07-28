#!/usr/bin/env python3
"""Inyecta permisos (camara / GPS) y el nombre de la app en el
AndroidManifest.xml que genera `flutter create`, y ajusta minSdk.
Se ejecuta en CI despues de scaffoldear la carpeta android/."""
import re, pathlib, sys

manifest = pathlib.Path("android/app/src/main/AndroidManifest.xml")
txt = manifest.read_text(encoding="utf-8")

permisos = """    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.CAMERA"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-feature android:name="android.hardware.camera" android:required="false"/>
"""

if "android.permission.CAMERA" not in txt:
    txt = txt.replace("<application", permisos + "\n    <application", 1)

# Nombre visible de la app
txt = re.sub(r'android:label="[^"]*"', 'android:label="CondoControl Pro"', txt, count=1)

manifest.write_text(txt, encoding="utf-8")
print("Manifest parcheado OK")

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

    p.write_text(b, encoding="utf-8")
    print(f"build.gradle ajustado (minSdk + desugaring) en {g}")
