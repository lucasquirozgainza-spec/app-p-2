package com.condocontrol.condocontrol;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.OrientationEventListener;
import android.view.ScaleGestureDetector;
import android.view.Surface;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.FocusMeteringAction;
import androidx.camera.core.ImageCapture;
import androidx.camera.core.ImageCaptureException;
import androidx.camera.core.MeteringPoint;
import androidx.camera.core.Preview;
import androidx.camera.core.ZoomState;
import androidx.camera.core.resolutionselector.AspectRatioStrategy;
import androidx.camera.core.resolutionselector.ResolutionSelector;
import androidx.camera.core.resolutionselector.ResolutionStrategy;
import androidx.camera.extensions.ExtensionMode;
import androidx.camera.extensions.ExtensionsManager;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.camera.view.PreviewView;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.Lifecycle;
import androidx.lifecycle.LifecycleOwner;
import androidx.lifecycle.LifecycleRegistry;

import com.google.common.util.concurrent.ListenableFuture;

import java.io.File;
import java.util.ArrayList;

/**
 * Cámara PROCESADA de OSIRIS (rondas): usa el procesamiento del FABRICANTE
 * (modo automático u HDR de las extensiones de cámara de Android) cuando el
 * celular lo ofrece; si no, la cámara estándar a máxima resolución y máxima
 * calidad JPEG. Devuelve las rutas de las fotos (resultado "fotos").
 * Si algo falla al abrir, termina con RESULT_FIRST_USER y la app usa su
 * cámara de siempre.
 */
public class ExtCameraActivity extends Activity implements LifecycleOwner {
    private final LifecycleRegistry lifecycle = new LifecycleRegistry(this);

    @NonNull
    @Override
    public Lifecycle getLifecycle() {
        return lifecycle;
    }

    private PreviewView preview;
    private TextView titulo, estado;
    private Button disparo, listo, flashBtn;
    private View destello;

    private ProcessCameraProvider provider;
    private ExtensionsManager extensiones;
    private ImageCapture captura;
    private Camera camara;
    private OrientationEventListener orientacion;

    private boolean multi, frontal;
    private int minFotos;
    private File dir;
    private boolean ocupado = false;
    private boolean terminado = false;
    private int flash = ImageCapture.FLASH_MODE_OFF;
    private String modo = "Estándar";
    private final ArrayList<String> fotos = new ArrayList<>();

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        lifecycle.setCurrentState(Lifecycle.State.CREATED);

        Intent in = getIntent();
        multi = in.getBooleanExtra("multi", false);
        frontal = in.getBooleanExtra("frontal", false);
        minFotos = in.getIntExtra("minFotos", 0);
        String d = in.getStringExtra("dir");
        dir = d != null ? new File(d) : new File(getFilesDir(), "fotos");
        if (!dir.exists()) dir.mkdirs();

        construirPantalla();
        iniciarCamara();

        orientacion = new OrientationEventListener(this) {
            @Override
            public void onOrientationChanged(int grados) {
                if (grados == ORIENTATION_UNKNOWN || captura == null) return;
                int rot;
                if (grados >= 45 && grados < 135) rot = Surface.ROTATION_270;
                else if (grados >= 135 && grados < 225) rot = Surface.ROTATION_180;
                else if (grados >= 225 && grados < 315) rot = Surface.ROTATION_90;
                else rot = Surface.ROTATION_0;
                // La foto sale derecha aunque se tome en horizontal.
                captura.setTargetRotation(rot);
            }
        };
    }

    private Button boton(String texto, int fondo) {
        Button b = new Button(this);
        b.setText(texto);
        b.setAllCaps(false);
        b.setTextColor(Color.WHITE);
        b.setTextSize(15);
        GradientDrawable g = new GradientDrawable();
        g.setColor(fondo);
        g.setCornerRadius(dp(22));
        b.setBackground(g);
        b.setPadding(dp(16), 0, dp(16), 0);
        return b;
    }

    private void construirPantalla() {
        FrameLayout raiz = new FrameLayout(this);
        raiz.setBackgroundColor(Color.BLACK);

        preview = new PreviewView(this);
        preview.setScaleType(PreviewView.ScaleType.FIT_CENTER); // se ve TODO lo que sale en la foto
        raiz.addView(preview, new FrameLayout.LayoutParams(-1, -1));

        destello = new View(this);
        destello.setBackgroundColor(Color.WHITE);
        destello.setAlpha(0f);
        raiz.addView(destello, new FrameLayout.LayoutParams(-1, -1));

        // Barra superior: contador, modo y linterna.
        LinearLayout arriba = new LinearLayout(this);
        arriba.setOrientation(LinearLayout.HORIZONTAL);
        arriba.setGravity(Gravity.CENTER_VERTICAL);
        arriba.setPadding(dp(14), dp(14), dp(14), dp(8));
        arriba.setBackgroundColor(0x66000000);
        LinearLayout textos = new LinearLayout(this);
        textos.setOrientation(LinearLayout.VERTICAL);
        titulo = new TextView(this);
        titulo.setTextColor(Color.WHITE);
        titulo.setTextSize(17);
        estado = new TextView(this);
        estado.setTextColor(0xFFB2FF59);
        estado.setTextSize(12);
        textos.addView(titulo);
        textos.addView(estado);
        arriba.addView(textos, new LinearLayout.LayoutParams(0, -2, 1f));
        flashBtn = boton("Luz: no", 0x55FFFFFF);
        flashBtn.setOnClickListener(v -> cambiarFlash());
        arriba.addView(flashBtn, new LinearLayout.LayoutParams(-2, dp(40)));
        raiz.addView(arriba, new FrameLayout.LayoutParams(-1, -2, Gravity.TOP));

        // Barra inferior: cancelar, disparador y listo.
        LinearLayout abajo = new LinearLayout(this);
        abajo.setOrientation(LinearLayout.HORIZONTAL);
        abajo.setGravity(Gravity.CENTER_VERTICAL);
        abajo.setPadding(dp(16), dp(14), dp(16), dp(28));
        abajo.setBackgroundColor(0x66000000);
        Button cancelar = boton("Cancelar", 0x55FFFFFF);
        cancelar.setOnClickListener(v -> terminar());
        abajo.addView(cancelar, new LinearLayout.LayoutParams(0, dp(44), 1f));

        disparo = new Button(this);
        GradientDrawable circulo = new GradientDrawable();
        circulo.setShape(GradientDrawable.OVAL);
        circulo.setColor(Color.WHITE);
        circulo.setStroke(dp(5), 0xFF9E9E9E);
        disparo.setBackground(circulo);
        disparo.setOnClickListener(v -> tomar());
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(dp(76), dp(76));
        lp.leftMargin = dp(18);
        lp.rightMargin = dp(18);
        abajo.addView(disparo, lp);

        listo = boton("Listo", 0xFF2E7D32);
        listo.setOnClickListener(v -> terminar());
        abajo.addView(listo, new LinearLayout.LayoutParams(0, dp(44), 1f));
        raiz.addView(abajo, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));

        // Tocar = enfocar; pellizcar = zoom.
        final ScaleGestureDetector zoom = new ScaleGestureDetector(this,
                new ScaleGestureDetector.SimpleOnScaleGestureListener() {
                    @Override
                    public boolean onScale(ScaleGestureDetector det) {
                        if (camara == null) return false;
                        ZoomState z = camara.getCameraInfo().getZoomState().getValue();
                        if (z == null) return false;
                        float nuevo = Math.max(z.getMinZoomRatio(),
                                Math.min(z.getMaxZoomRatio(), z.getZoomRatio() * det.getScaleFactor()));
                        camara.getCameraControl().setZoomRatio(nuevo);
                        return true;
                    }
                });
        preview.setOnTouchListener((v, ev) -> {
            zoom.onTouchEvent(ev);
            if (ev.getAction() == MotionEvent.ACTION_UP && ev.getPointerCount() == 1 && camara != null
                    && !zoom.isInProgress()) {
                try {
                    MeteringPoint p = preview.getMeteringPointFactory().createPoint(ev.getX(), ev.getY());
                    camara.getCameraControl().startFocusAndMetering(new FocusMeteringAction.Builder(p).build());
                } catch (Exception ignored) {
                }
                v.performClick();
            }
            return true;
        });

        setContentView(raiz);
        actualizar();
    }

    private void actualizar() {
        String t = fotos.size() + (minFotos > 0 ? " / " + minFotos : "") + (fotos.size() == 1 ? " foto" : " fotos");
        titulo.setText(t);
        estado.setText(ocupado ? "Procesando…" : "Calidad: " + modo);
        disparo.setEnabled(!ocupado);
        disparo.setAlpha(ocupado ? 0.5f : 1f);
        listo.setVisibility(fotos.isEmpty() ? View.INVISIBLE : View.VISIBLE);
    }

    private void iniciarCamara() {
        final ListenableFuture<ProcessCameraProvider> f = ProcessCameraProvider.getInstance(this);
        f.addListener(() -> {
            try {
                provider = f.get();
            } catch (Exception e) {
                fallar("No se pudo abrir la cámara: " + e);
                return;
            }
            // Procesamiento del fabricante (si el celular lo ofrece).
            try {
                final ListenableFuture<ExtensionsManager> ef = ExtensionsManager.getInstanceAsync(this, provider);
                ef.addListener(() -> {
                    try {
                        extensiones = ef.get();
                    } catch (Exception e) {
                        extensiones = null;
                    }
                    vincular();
                }, ContextCompat.getMainExecutor(this));
            } catch (Exception e) {
                extensiones = null;
                vincular();
            }
        }, ContextCompat.getMainExecutor(this));
    }

    private ImageCapture nuevaCaptura(boolean conExtension) {
        ImageCapture.Builder b = new ImageCapture.Builder()
                .setFlashMode(flash)
                .setJpegQuality(100);
        if (!conExtension) {
            // Sin extensión: máxima resolución del sensor y máxima calidad.
            b.setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY);
            b.setResolutionSelector(new ResolutionSelector.Builder()
                    .setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY)
                    .setResolutionStrategy(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY)
                    .build());
        }
        return b.build();
    }

    private void vincular() {
        if (provider == null || isFinishing()) return;
        CameraSelector base = frontal ? CameraSelector.DEFAULT_FRONT_CAMERA : CameraSelector.DEFAULT_BACK_CAMERA;
        try {
            if (!provider.hasCamera(base)) base = CameraSelector.DEFAULT_BACK_CAMERA;
        } catch (Exception ignored) {
        }
        CameraSelector sel = base;
        String m = null;
        if (extensiones != null) {
            try {
                if (extensiones.isExtensionAvailable(base, ExtensionMode.AUTO)) {
                    sel = extensiones.getExtensionEnabledCameraSelector(base, ExtensionMode.AUTO);
                    m = "Automática del fabricante";
                } else if (extensiones.isExtensionAvailable(base, ExtensionMode.HDR)) {
                    sel = extensiones.getExtensionEnabledCameraSelector(base, ExtensionMode.HDR);
                    m = "HDR del fabricante";
                }
            } catch (Exception ignored) {
                sel = base;
                m = null;
            }
        }
        Preview p = new Preview.Builder().build();
        p.setSurfaceProvider(preview.getSurfaceProvider());
        try {
            provider.unbindAll();
            captura = nuevaCaptura(m != null);
            camara = provider.bindToLifecycle(this, sel, p, captura);
            modo = m != null ? m : "Máxima (estándar)";
        } catch (Exception e) {
            // La extensión no se pudo usar con este celular: cámara estándar.
            try {
                provider.unbindAll();
                captura = nuevaCaptura(false);
                camara = provider.bindToLifecycle(this, base, p, captura);
                modo = "Máxima (estándar)";
            } catch (Exception e2) {
                fallar("No se pudo abrir la cámara: " + e2);
                return;
            }
        }
        actualizar();
    }

    private void cambiarFlash() {
        flash = flash == ImageCapture.FLASH_MODE_OFF ? ImageCapture.FLASH_MODE_ON
                : (flash == ImageCapture.FLASH_MODE_ON ? ImageCapture.FLASH_MODE_AUTO : ImageCapture.FLASH_MODE_OFF);
        flashBtn.setText(flash == ImageCapture.FLASH_MODE_OFF ? "Luz: no" : (flash == ImageCapture.FLASH_MODE_ON ? "Luz: sí" : "Luz: auto"));
        if (captura != null) {
            try {
                captura.setFlashMode(flash);
            } catch (Exception ignored) {
            }
        }
    }

    private void tomar() {
        if (ocupado || captura == null || terminado) return;
        ocupado = true;
        actualizar();
        destello.setAlpha(0.7f);
        destello.animate().alpha(0f).setDuration(160).start();
        final File out = new File(dir, "IMG_" + System.currentTimeMillis() + "_" + fotos.size() + ".jpg");
        ImageCapture.OutputFileOptions opts = new ImageCapture.OutputFileOptions.Builder(out).build();
        captura.takePicture(opts, ContextCompat.getMainExecutor(this), new ImageCapture.OnImageSavedCallback() {
            @Override
            public void onImageSaved(@NonNull ImageCapture.OutputFileResults r) {
                ocupado = false;
                fotos.add(out.getAbsolutePath());
                actualizar();
                if (!multi || (minFotos > 0 && fotos.size() >= minFotos)) terminar();
            }

            @Override
            public void onError(@NonNull ImageCaptureException e) {
                ocupado = false;
                actualizar();
                Toast.makeText(ExtCameraActivity.this, "No se pudo tomar la foto. Intenta de nuevo.",
                        Toast.LENGTH_SHORT).show();
            }
        });
    }

    /** Devuelve las fotos tomadas (o nada si no se tomó ninguna). */
    private void terminar() {
        if (terminado) return;
        terminado = true;
        if (fotos.isEmpty()) {
            setResult(RESULT_CANCELED);
        } else {
            Intent data = new Intent();
            data.putStringArrayListExtra("fotos", fotos);
            setResult(RESULT_OK, data);
        }
        finish();
    }

    private void fallar(String motivo) {
        if (terminado) return;
        terminado = true;
        Intent data = new Intent();
        data.putExtra("error", motivo);
        if (!fotos.isEmpty()) data.putStringArrayListExtra("fotos", fotos);
        setResult(fotos.isEmpty() ? RESULT_FIRST_USER : RESULT_OK, data);
        finish();
    }

    @Override
    public void onBackPressed() {
        terminar(); // con fotos tomadas, "atrás" = Listo (no se pierden)
    }

    @Override
    protected void onStart() {
        super.onStart();
        lifecycle.setCurrentState(Lifecycle.State.STARTED);
    }

    @Override
    protected void onResume() {
        super.onResume();
        lifecycle.setCurrentState(Lifecycle.State.RESUMED);
        if (orientacion != null && orientacion.canDetectOrientation()) orientacion.enable();
    }

    @Override
    protected void onPause() {
        if (orientacion != null) orientacion.disable();
        lifecycle.setCurrentState(Lifecycle.State.STARTED);
        super.onPause();
    }

    @Override
    protected void onStop() {
        lifecycle.setCurrentState(Lifecycle.State.CREATED);
        super.onStop();
    }

    @Override
    protected void onDestroy() {
        lifecycle.setCurrentState(Lifecycle.State.DESTROYED);
        try {
            if (provider != null) provider.unbindAll();
        } catch (Exception ignored) {
        }
        super.onDestroy();
    }
}
