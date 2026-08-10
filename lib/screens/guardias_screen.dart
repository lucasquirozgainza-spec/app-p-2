import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/auth_service.dart';
import '../services/cloud.dart';
import '../theme.dart';
import '../widgets/toast.dart';
import 'reporte_personal_screen.dart';
import 'advertencias_screen.dart';

/// Un turno emparejado (ingreso -> salida) con su duración.
class _Turno {
  final DateTime inicio;
  final double horas;
  _Turno(this.inicio, this.horas);
  // Tipo de turno según su duración: 24 o 36 (el más largo es 36).
  int get tipo => horas < 30 ? 24 : 36;
  double get extra => horas > tipo ? horas - tipo : 0; // pasó de su turno
  double get falta => horas < tipo ? tipo - horas : 0; // hizo menos (llegó antes)
}

/// Resumen de un guardia (horas del mes) calculado desde la nube.
class _ResG {
  final String guardia;
  final Set<String> dias = {};
  final List<_Turno> turnos = [];
  DateTime? abierto;
  _ResG(this.guardia);
  double get horas => turnos.fold(0.0, (a, t) => a + t.horas);
  double get extra => turnos.fold(0.0, (a, t) => a + t.extra);
  int get n24 => turnos.where((t) => t.tipo == 24).length;
  int get n36 => turnos.where((t) => t.tipo == 36).length;
}

class GuardiasScreen extends StatefulWidget {
  const GuardiasScreen({super.key});
  @override
  State<GuardiasScreen> createState() => _GuardiasScreenState();
}

class _GuardiasScreenState extends State<GuardiasScreen> {
  List<Map<String, dynamic>> _activosLocal = [];
  List<Map<String, dynamic>> _presencia = []; // en linea desde la nube (todos los celulares)
  List<Map<String, dynamic>> _personal = [];
  Map<String, Map<String, _ResG>> _horas = {}; // edificio -> guardia -> resumen (nube)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final activos = await db.query('ingreso_turno',
        where: 'edificio=? AND activo=1', whereArgs: [ed], orderBy: 'id DESC');
    final personal = await db.query('usuarios',
        where: "rol IN ('guardia','supervisor','conserje','limpieza','franquero') AND activo=1 "
            "AND (edificio=? OR edificio IS NULL OR edificio='')",
        whereArgs: [ed],
        orderBy: 'nombre');
    // Presencia + horas del mes de TODOS los celulares (Supabase).
    Cloud.heartbeat();
    final res = await Future.wait([Cloud.presencia(), Cloud.eventosTurnoMes()]);
    final pres = res[0];
    final horas = _calcularHoras(res[1]);
    if (!mounted) return;
    setState(() {
      _activosLocal = activos;
      _personal = personal;
      _presencia = pres;
      _horas = horas;
    });
  }

  /// Empareja ingreso->salida por guardia y edificio para sacar horas/turnos.
  Map<String, Map<String, _ResG>> _calcularHoras(List<Map<String, dynamic>> eventos) {
    eventos.sort((a, b) => (a['created_at'] ?? '').toString().compareTo((b['created_at'] ?? '').toString()));
    final data = <String, Map<String, _ResG>>{};
    for (final e in eventos) {
      final ed = (e['edificio'] ?? 'Sin edificio').toString();
      final g = (e['guardia'] ?? 'Sin nombre').toString();
      final tipo = (e['tipo'] ?? '').toString();
      DateTime? t;
      try { t = DateTime.parse(e['created_at'].toString()).toLocal(); } catch (_) {}
      final r = data.putIfAbsent(ed, () => {}).putIfAbsent(g, () => _ResG(g));
      if (tipo == 'Ingreso de turno') {
        if (t != null) { r.dias.add(DateFormat('yyyy-MM-dd').format(t)); r.abierto = t; }
      } else if (tipo == 'Salida de turno') {
        if (t != null && r.abierto != null) {
          final h = t.difference(r.abierto!).inMinutes / 60.0;
          if (h > 0 && h < 48) r.turnos.add(_Turno(r.abierto!, h));
          r.abierto = null;
        }
      }
    }
    return data;
  }

  /// Panel de detalle de un guardia: turnos de 24h/36h, extras y cada turno.
  void _detalleGuardia(_ResG r) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(r.guardia),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              _chip('Días', '${r.dias.length}', AppColors.azulMarino),
              _chip('Turnos 24h', '${r.n24}', AppColors.verde),
              _chip('Turnos 36h', '${r.n36}', const Color(0xFF6A1B9A)),
              _chip('Horas extra', r.extra.toStringAsFixed(1), const Color(0xFFEF6C00)),
              _chip('Horas total', r.horas.toStringAsFixed(1), Colors.teal),
            ]),
            const Divider(height: 20),
            const Text('Turnos del mes', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            if (r.turnos.isEmpty) const Text('Sin turnos cerrados este mes.'),
            for (final t in r.turnos)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text('${DateFormat('dd/MM HH:mm').format(t.inicio)} · ${t.horas.toStringAsFixed(1)} h '
                    '(turno ${t.tipo}h'
                    '${t.extra > 0 ? ', +${t.extra.toStringAsFixed(1)} h extra' : ''}'
                    '${t.falta > 0 ? ', ${t.falta.toStringAsFixed(1)} h menos (llegó antes)' : ''})',
                    style: const TextStyle(fontSize: 13)),
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))],
      ),
    );
  }

  Widget _chip(String label, String value, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color)),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ]),
      );

  bool _enLinea(Map<String, dynamic> p) {
    try {
      final ls = DateTime.parse(p['last_seen'].toString()).toUtc();
      return DateTime.now().toUtc().difference(ls).inMinutes < 5;
    } catch (_) {
      return false;
    }
  }

  /// Guardias en linea de este edificio segun la nube (todos los celulares).
  List<Map<String, dynamic>> get _enTurnoNube {
    final ed = AppState.instance.edificioId;
    return _presencia
        .where((p) => _enLinea(p) && p['en_turno'] == true && (p['edificio']?.toString() ?? '') == ed)
        .toList();
  }

  Future<void> _eliminarPersonal(Map<String, dynamic> p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.person_remove, color: AppColors.rojo, size: 36),
        title: const Text('Eliminar personal'),
        content: Text('¿Eliminar a "${p['nombre'] ?? ''}" del personal registrado?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.rojo),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final db = await DB.instance.database;
    await db.delete('usuarios', where: 'id=?', whereArgs: [p['id']]);
    if (!mounted) return;
    TopToast.show(context, 'Personal eliminado');
    _load();
  }

  Future<void> _nuevoGuardia() async {
    final n = TextEditingController();
    final c = TextEditingController(text: 'Guardia de Seguridad');
    String rol = 'guardia';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Registrar guardia'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: n, decoration: const InputDecoration(labelText: 'Nombre completo')),
              const SizedBox(height: 8),
              TextField(controller: c, decoration: const InputDecoration(labelText: 'Cargo')),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: rol,
                decoration: const InputDecoration(labelText: 'Rol'),
                items: const [
                  DropdownMenuItem(value: 'guardia', child: Text('Guardia')),
                  DropdownMenuItem(value: 'franquero', child: Text('Franquero (temporal)')),
                  DropdownMenuItem(value: 'supervisor', child: Text('Supervisor')),
                  DropdownMenuItem(value: 'conserje', child: Text('Conserje')),
                  DropdownMenuItem(value: 'limpieza', child: Text('Limpieza')),
                ],
                onChanged: (v) => setD(() => rol = v ?? 'guardia'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Registrar')),
          ],
        ),
      ),
    );
    if (ok == true && n.text.trim().isNotEmpty) {
      await AuthService.crearGuardia(nombre: n.text.trim(), cargo: c.text, rol: rol);
      if (!mounted) return;
      TopToast.show(context, 'Guardia registrado');
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final admin = AppState.instance.isAdmin;
    // "En linea" preferimos la nube (todos los celulares); si no hay, lo local.
    final enTurnoNube = _enTurnoNube;
    final usarNube = enTurnoNube.isNotEmpty || Cloud.enabled;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Guardias'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar',
            onPressed: _load,
          ),
          if (admin)
            IconButton(
              icon: const Icon(Icons.warning_amber),
              tooltip: 'Advertencias',
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const AdvertenciasScreen())),
            ),
          if (admin)
            IconButton(
              icon: const Icon(Icons.assessment),
              tooltip: 'Reporte de personal (PDF)',
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const ReportePersonalScreen())),
            ),
        ],
      ),
      floatingActionButton: admin
          ? FloatingActionButton.extended(
              backgroundColor: AppColors.azulMarino,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.person_add),
              label: const Text('Registrar guardia'),
              onPressed: _nuevoGuardia,
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Row(children: [
              const Icon(Icons.wifi_tethering, color: AppColors.verde),
              const SizedBox(width: 8),
              Text('En línea ahora (${usarNube ? enTurnoNube.length : _activosLocal.length})',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ]),
            const Text('En todos los celulares con la app (se actualiza al refrescar).',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            if (usarNube)
              ...(enTurnoNube.isEmpty
                  ? [const Card(child: ListTile(title: Text('Ningún guardia en línea ahora')))]
                  : [
                      for (final p in enTurnoNube)
                        Card(
                          child: ListTile(
                            leading: const CircleAvatar(
                                backgroundColor: Color(0x1A2E7D32),
                                child: Icon(Icons.shield, color: AppColors.verde)),
                            title: Text(p['guardia']?.toString() ?? '—',
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text('${p['edificio'] ?? ''} · En turno'),
                            trailing: const Icon(Icons.circle, color: AppColors.verde, size: 12),
                          ),
                        ),
                    ])
            else if (_activosLocal.isEmpty)
              const Card(child: ListTile(title: Text('Ningún guardia con turno activo')))
            else
              for (final t in _activosLocal)
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                        backgroundColor: Color(0x1A2E7D32),
                        child: Icon(Icons.shield, color: AppColors.verde)),
                    title: Text(t['guardia_nombre']?.toString() ?? '—',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        'Ingreso: ${DateFormat('dd/MM HH:mm').format(DateTime.parse(t['created_at'] as String))}'
                        '${t['bateria'] != null ? ' · Bateria ${t['bateria']}%' : ''}'),
                    trailing: const Icon(Icons.circle, color: AppColors.verde, size: 12),
                  ),
                ),

            // El personal registrado (con usuarios) SOLO lo ve el administrador.
            if (admin) ...[
              const SizedBox(height: 20),
              Row(children: [
                const Icon(Icons.groups, color: AppColors.azulMarino),
                const SizedBox(width: 8),
                Text('Personal registrado (${_personal.length})',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 8),
              for (final p in _personal)
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                        backgroundColor: Color(0x1A0A335D),
                        child: Icon(Icons.person, color: AppColors.azulMarino)),
                    title: Text(p['nombre']?.toString() ?? '—',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${p['cargo'] ?? ''} · Usuario: ${p['usuario']} · ${p['rol']}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: AppColors.rojo),
                      tooltip: 'Eliminar',
                      onPressed: () => _eliminarPersonal(p),
                    ),
                  ),
                ),
              // Horas del mes (todos los edificios) desde la nube — tocable.
              const SizedBox(height: 20),
              Row(children: [
                const Icon(Icons.query_stats, color: Color(0xFF00838F)),
                const SizedBox(width: 8),
                const Text('Horas del mes (todos los edificios)',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ]),
              const Text('Toca un guardia para ver sus turnos de 24h/36h y horas extra.',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 8),
              if (_horas.isEmpty)
                const Card(child: ListTile(title: Text('Sin turnos este mes en la nube')))
              else
                for (final ed in (_horas.keys.toList()..sort())) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                    child: Text(ed, style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.azulMarino)),
                  ),
                  for (final r in (_horas[ed]!.values.toList()..sort((a, b) => b.horas.compareTo(a.horas))))
                    Card(
                      child: ListTile(
                        onTap: () => _detalleGuardia(r),
                        leading: CircleAvatar(
                          backgroundColor: AppColors.verde.withOpacity(.12),
                          child: Text('${r.dias.length}', style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.verde)),
                        ),
                        title: Text(r.guardia, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text('${r.n24} de 24h · ${r.n36} de 36h · ${r.horas.toStringAsFixed(1)} h'
                            '${r.extra > 0 ? ' · +${r.extra.toStringAsFixed(1)} extra' : ''}'),
                        trailing: const Icon(Icons.chevron_right),
                      ),
                    ),
                ],
            ] else ...[
              const SizedBox(height: 24),
              const Card(
                child: ListTile(
                  leading: Icon(Icons.lock, color: Colors.blueGrey),
                  title: Text('Personal y registro'),
                  subtitle: Text('Solo el administrador puede ver el personal y registrar guardias.'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
