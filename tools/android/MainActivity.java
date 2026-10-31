package com.condocontrol.condocontrol;

import android.app.NotificationManager;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.view.WindowManager;
import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.util.ArrayList;

/**
 * Actividad principal de OSIRIS. Además abre la "cámara procesada"
 * (ExtCameraActivity): la cámara con el procesamiento del fabricante
 * (HDR / automático) para las rondas.
 */
public class MainActivity extends FlutterActivity {
    private static final String CANAL = "osiris/camara_pro";
    private static final int REQ = 7301;
    private MethodChannel.Result pendiente;
    private static final String CANAL_ALARMA = "osiris/alarma";

    /** Alarma de control de presencia: la pantalla se muestra sobre el bloqueo y se enciende. */
    private void sobreBloqueo(boolean si) {
        try {
            if (Build.VERSION.SDK_INT >= 27) {
                setShowWhenLocked(si);
                setTurnScreenOn(si);
            } else {
                int f = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON;
                if (si) getWindow().addFlags(f); else getWindow().clearFlags(f);
            }
            if (si) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        } catch (Exception ignored) {}
    }

    /** Abierta desde la notificación de la alarma (pantalla completa): ya sobre el bloqueo. */
    private void revisarIntent(Intent i) {
        if (i == null) return;
        try {
            String p = i.getStringExtra("payload");
            if (p != null && p.startsWith("presencia")) sobreBloqueo(true);
        } catch (Exception ignored) {}
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        revisarIntent(getIntent());
        super.onCreate(savedInstanceState);
    }

    @Override
    protected void onNewIntent(@NonNull Intent intent) {
        revisarIntent(intent);
        super.onNewIntent(intent);
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine engine) {
        super.configureFlutterEngine(engine);
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), CANAL_ALARMA).setMethodCallHandler((call, result) -> {
            try {
                switch (call.method) {
                    case "sobreBloqueo": {
                        Boolean si = call.argument("si");
                        sobreBloqueo(si != null && si);
                        result.success(true);
                        break;
                    }
                    case "puedePantallaCompleta": {
                        boolean ok = true;
                        if (Build.VERSION.SDK_INT >= 34) {
                            NotificationManager nm = getSystemService(NotificationManager.class);
                            ok = nm != null && nm.canUseFullScreenIntent();
                        }
                        result.success(ok);
                        break;
                    }
                    case "pedirPantallaCompleta": {
                        if (Build.VERSION.SDK_INT >= 34) {
                            Intent i = new Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT);
                            i.setData(Uri.parse("package:" + getPackageName()));
                            startActivity(i);
                        }
                        result.success(true);
                        break;
                    }
                    default:
                        result.notImplemented();
                }
            } catch (Exception e) {
                result.error("alarma", String.valueOf(e), null);
            }
        });
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), CANAL).setMethodCallHandler((call, result) -> {
            if (!"tomar".equals(call.method)) {
                result.notImplemented();
                return;
            }
            if (pendiente != null) {
                result.error("ocupada", "La cámara ya está abierta", null);
                return;
            }
            try {
                Intent i = new Intent(this, ExtCameraActivity.class);
                Boolean multi = call.argument("multi");
                Boolean frontal = call.argument("frontal");
                Integer min = call.argument("minFotos");
                String dir = call.argument("dir");
                i.putExtra("multi", multi != null && multi);
                i.putExtra("frontal", frontal != null && frontal);
                i.putExtra("minFotos", min == null ? 0 : min);
                i.putExtra("dir", dir);
                pendiente = result;
                startActivityForResult(i, REQ);
            } catch (Exception e) {
                pendiente = null;
                result.error("sin_camara", String.valueOf(e), null);
            }
        });
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQ || pendiente == null) return;
        MethodChannel.Result r = pendiente;
        pendiente = null;
        if (resultCode == RESULT_OK && data != null) {
            ArrayList<String> fotos = data.getStringArrayListExtra("fotos");
            r.success(fotos);
        } else if (resultCode == RESULT_FIRST_USER) {
            r.error("sin_camara", data != null ? data.getStringExtra("error") : "", null);
        } else {
            r.success(null);
        }
    }
}
