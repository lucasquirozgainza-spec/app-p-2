import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/app_state.dart';
import '../services/cloud.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'login_screen.dart';
import 'inicio_turno_screen.dart';
import 'visitas_screen.dart';
import 'ronda_screen.dart';
import 'propietarios_screen.dart';
import 'vehiculos_screen.dart';
import 'contactos_screen.dart';
import 'config_screen.dart';
import 'busqueda_screen.dart';
import 'salida_turno_screen.dart';
import 'panel_screen.dart';
import 'encomiendas_screen.dart';
import 'incidentes_screen.dart';
import 'mantenimiento_screen.dart';
import 'hospedajes_screen.dart';
import 'guardias_screen.dart';
import 'normativas_screen.dart';
import 'reportes_screen.dart';
import 'online_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  Timer? _hb;

  @override
  void initState() {
    super.initState();
    // Mantiene la presencia "en linea" actualizada mientras la app este abierta.
    _hb = Timer.periodic(const Duration(seconds: 60), (_) => Cloud.heartbeat());
  }

  @override
  void dispose() {
    _hb?.cancel();
    super.dispose();
  }

  Future<void> _openOnline() async {
    final s = AppState.instance;
    if (s.isAdmin) return _open(const OnlineScreen());
    final ok = await Navigator.push<bool>(
        context, MaterialPageRoute(builder: (_) => const AdminLoginScreen()));
    if (ok == true && mounted) _open(const OnlineScreen());
  }

  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    if (mounted) setState(() {});
  }

  Future<void> _openConfig() async {
    final s = AppState.instance;
    if (s.isAdmin) return _open(const ConfigScreen());
    final ok = await Navigator.push<bool>(
        context, MaterialPageRoute(builder: (_) => const AdminLoginScreen()));
    if (ok == true && mounted) _open(const ConfigScreen());
  }

  Future<void> _entrarAdmin() async {
    final ok = await Navigator.push<bool>(
        context, MaterialPageRoute(builder: (_) => const AdminLoginScreen()));
    if (ok == true && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final ahora = DateTime.now();
    final saludo = ahora.hour < 12
        ? 'Buenos dias'
        : ahora.hour < 19
            ? 'Buenas tardes'
            : 'Buenas noches';

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('OSIRIS', style: TextStyle(fontSize: 17)),
            Text(s.edificioNombre, style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Busqueda global',
            onPressed: () => _open(const BusquedaScreen()),
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _greeting(saludo, s, ahora),
              const SizedBox(height: 16),
              _turnoButton(s),
              const SizedBox(height: 18),
              const _SectionTitle('Acciones rapidas'),
              const SizedBox(height: 8),
              _acciones(s),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(child: OutlinedButton.icon(
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                  icon: const Icon(Icons.menu),
                  label: const Text('Ver todos los modulos'),
                )),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _greeting(String saludo, AppState s, DateTime ahora) {
    final nombre = s.userNombre?.split(' ').first;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [AppColors.azulMarino, Color(0xFF1E6FB8)],
            begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(nombre != null ? '$saludo, $nombre' : 'Bienvenido',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(s.turnoActivoId != null ? '${s.userCargo ?? 'Guardia'}  ·  ${s.edificioNombre}' : s.edificioNombre,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.access_time, color: Colors.white70, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(DateFormat('EEEE dd/MM/yyyy · HH:mm', 'es').format(ahora),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ),
          ]),
          const SizedBox(height: 10),
          if (s.turnoActivoId != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: AppColors.verde, borderRadius: BorderRadius.circular(20)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_circle, color: Colors.white, size: 14),
                SizedBox(width: 5),
                Text('Turno activo', style: TextStyle(color: Colors.white, fontSize: 12)),
              ]),
            )
          else
            InkWell(
              onTap: () => _open(const InicioTurnoScreen()),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.play_arrow, color: AppColors.azulMarino, size: 18),
                  SizedBox(width: 5),
                  Text('Iniciar turno', style: TextStyle(color: AppColors.azulMarino, fontWeight: FontWeight.bold)),
                ]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _turnoButton(AppState s) {
    final activo = s.turnoActivoId != null;
    return SizedBox(
      width: double.infinity,
      height: 62,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
            backgroundColor: activo ? const Color(0xFF455A64) : AppColors.verde),
        onPressed: () => _open(activo ? const SalidaTurnoScreen() : const InicioTurnoScreen()),
        icon: Icon(activo ? Icons.logout : Icons.play_arrow, size: 26),
        label: Text(activo ? 'FINALIZAR TURNO' : 'INICIAR TURNO',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _acciones(AppState s) {
    final acts = <Widget>[];
    if (s.modulo('visitas')) {
      acts.add(ActionButton(icon: Icons.badge, label: 'Registrar\nVisita', color: AppColors.azulMarino, onTap: () => _open(const VisitaFormScreen())));
    }
    if (s.modulo('incidentes')) {
      acts.add(ActionButton(icon: Icons.warning_amber, label: 'Reportar\nIncidente', color: AppColors.rojo, onTap: () => _open(const IncidenteForm())));
    }
    if (s.modulo('hospedajes')) {
      acts.add(ActionButton(icon: Icons.hotel, label: 'Registrar\nHospedaje', color: const Color(0xFF00838F), onTap: () => _open(const HospedajeForm())));
    }
    if (s.modulo('encomiendas')) {
      acts.add(ActionButton(icon: Icons.inventory_2, label: 'Encomienda', color: const Color(0xFFEF6C00), onTap: () => _open(const EncomiendaForm())));
    }
    if (s.modulo('rondas')) {
      acts.add(ActionButton(icon: Icons.directions_walk, label: 'Nueva\nRonda', color: const Color(0xFF6A1B9A), onTap: () => _open(const RondaScreen())));
    }
    if (s.modulo('reportes')) {
      acts.add(ActionButton(icon: Icons.bar_chart, label: 'Reportes', color: const Color(0xFF283593), onTap: () => _open(const ReportesScreen())));
    }
    return GridView.extent(
      maxCrossAxisExtent: 220, shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.7, mainAxisSpacing: 10, crossAxisSpacing: 10,
      children: acts,
    );
  }

  Widget _modules(AppState s) {
    final all = <_Mod>[
      _Mod('panel', Icons.dashboard, 'Panel', const Color(0xFF1565C0), () => const PanelScreen(), always: true),
      _Mod('propietarios', Icons.people, 'Propietarios', const Color(0xFF1565C0), () => const PropietariosScreen()),
      _Mod('vehiculos', Icons.directions_car, 'Vehiculos', const Color(0xFF283593), () => const VehiculosScreen()),
      _Mod('hospedajes', Icons.hotel, 'Hospedajes', const Color(0xFF00838F), () => const HospedajesScreen()),
      _Mod('encomiendas', Icons.inventory_2, 'Encomiendas', const Color(0xFFEF6C00), () => const EncomiendasScreen()),
      _Mod('incidentes', Icons.warning_amber, 'Incidentes', AppColors.rojo, () => const IncidentesScreen()),
      _Mod('mantenimiento', Icons.build, 'Mantenimiento', const Color(0xFF5D4037), () => const MantenimientoScreen()),
      _Mod('rondas', Icons.directions_walk, 'Rondas', const Color(0xFF6A1B9A), () => const RondaScreen()),
      _Mod('guardias', Icons.shield, 'Guardias', AppColors.verde, () => const GuardiasScreen(), always: true),
      _Mod('contactos', Icons.contact_phone, 'Contactos', const Color(0xFF00695C), () => const ContactosScreen()),
      _Mod('normativas', Icons.picture_as_pdf, 'Normativas', const Color(0xFF37474F), () => const NormativasScreen()),
      _Mod('reportes', Icons.bar_chart, 'Reportes', const Color(0xFF283593), () => const ReportesScreen()),
    ];
    final visibles = all.where((m) => m.always || s.modulo(m.key)).toList();
    return GridView.extent(
      maxCrossAxisExtent: 130, shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 0.92, mainAxisSpacing: 6, crossAxisSpacing: 6,
      children: [
        for (final m in visibles)
          ModuleCard(icon: m.icon, label: m.label, color: m.color, onTap: () => _open(m.build())),
        // Funciones de administrador: solo visibles cuando el admin entra.
        if (s.isAdmin) ...[
          ModuleCard(icon: Icons.cloud, label: 'En linea', color: const Color(0xFF0277BD), onTap: _openOnline),
          ModuleCard(icon: Icons.settings, label: 'Configuracion', color: const Color(0xFF546E7A), onTap: _openConfig),
        ] else
          ModuleCard(icon: Icons.admin_panel_settings, label: 'Entrar como admin', color: const Color(0xFF546E7A), onTap: _entrarAdmin),
      ],
    );
  }

  Drawer _buildDrawer() {
    final s = AppState.instance;
    Widget item(IconData i, String t, Widget screen, {bool show = true}) {
      if (!show) return const SizedBox.shrink();
      return ListTile(
        leading: Icon(i, color: AppColors.azulMarino),
        title: Text(t),
        onTap: () {
          Navigator.pop(context);
          _open(screen);
        },
      );
    }

    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: AppColors.azulMarino),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const CircleAvatar(radius: 26, backgroundColor: Colors.white, child: Icon(Icons.apartment, color: AppColors.azulMarino, size: 30)),
                const SizedBox(height: 10),
                Text(s.turnoActivoId != null ? (s.userNombre ?? '') : 'OSIRIS',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                Text(s.edificioNombre,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
          item(Icons.home, 'Inicio', const HomeScreen()),
          if (s.turnoActivoId == null)
            item(Icons.play_arrow, 'Iniciar turno', const InicioTurnoScreen())
          else
            item(Icons.logout, 'Finalizar turno', const SalidaTurnoScreen()),
          item(Icons.dashboard, 'Panel / Resumen', const PanelScreen()),
          item(Icons.shield, 'Guardias', const GuardiasScreen()),
          const Divider(),
          item(Icons.badge, 'Visitas', const VisitasScreen(), show: s.modulo('visitas')),
          item(Icons.directions_walk, 'Rondas', const RondaScreen(), show: s.modulo('rondas')),
          item(Icons.hotel, 'Hospedajes', const HospedajesScreen(), show: s.modulo('hospedajes')),
          item(Icons.inventory_2, 'Encomiendas', const EncomiendasScreen(), show: s.modulo('encomiendas')),
          item(Icons.warning_amber, 'Incidentes', const IncidentesScreen(), show: s.modulo('incidentes')),
          item(Icons.build, 'Mantenimiento', const MantenimientoScreen(), show: s.modulo('mantenimiento')),
          item(Icons.people, 'Propietarios', const PropietariosScreen(), show: s.modulo('propietarios')),
          item(Icons.directions_car, 'Vehiculos', const VehiculosScreen(), show: s.modulo('vehiculos')),
          item(Icons.contact_phone, 'Contactos', const ContactosScreen(), show: s.modulo('contactos')),
          item(Icons.picture_as_pdf, 'Normativas', const NormativasScreen(), show: s.modulo('normativas')),
          item(Icons.bar_chart, 'Reportes', const ReportesScreen(), show: s.modulo('reportes')),
          const Divider(),
          if (!s.isAdmin)
            ListTile(
              leading: const Icon(Icons.admin_panel_settings, color: Color(0xFF546E7A)),
              title: const Text('Entrar como admin'),
              onTap: () {
                Navigator.pop(context);
                _entrarAdmin();
              },
            ),
          ListTile(
            leading: const Icon(Icons.cloud, color: Color(0xFF0277BD)),
            title: const Text('En linea (admin)'),
            onTap: () {
              Navigator.pop(context);
              _openOnline();
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings, color: AppColors.azulMarino),
            title: const Text('Configuracion (admin)'),
            onTap: () {
              Navigator.pop(context);
              _openConfig();
            },
          ),
          if (s.isAdmin)
            ListTile(
              leading: const Icon(Icons.lock, color: AppColors.rojo),
              title: const Text('Salir de admin'),
              onTap: () {
                s.isAdmin = false;
                Navigator.pop(context);
                setState(() {});
              },
            ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.azulMarino));
}

class _Mod {
  final String key;
  final IconData icon;
  final String label;
  final Color color;
  final Widget Function() build;
  final bool always;
  _Mod(this.key, this.icon, this.label, this.color, this.build, {this.always = false});
}
