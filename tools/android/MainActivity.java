package com.condocontrol.condocontrol;

import android.content.Intent;
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

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine engine) {
        super.configureFlutterEngine(engine);
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
