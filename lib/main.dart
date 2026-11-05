import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;

/// URL de onde o app tenta baixar dados mais novos ao abrir.
/// Aponta para o meta.json do próprio repositório no GitHub.
/// Se ficar vazio ou falhar, o app usa os dados embutidos.
const String kRemoteDataUrl =
    'https://raw.githubusercontent.com/Guilherme-AMS/wild-rift-helpercoach/main/assets/meta.json';

const String kRemoteGuidesUrl =
    'https://raw.githubusercontent.com/Guilherme-AMS/wild-rift-helpercoach/main/assets/guides.json';

void main() => runApp(const WildRiftApp());

const List<String> kLanes = ['Baron', 'Jungle', 'Mid', 'Duo', 'Support'];
const Map<String, String> kLaneLabels = {
  'Baron': 'Barão',
  'Jungle': 'Selva',
  'Mid': 'Meio',
  'Duo': 'Dragão',
  'Support': 'Suporte',
};
const Map<String, IconData> kLaneIcons = {
  'Baron': Icons.shield,
  'Jungle': Icons.park,
  'Mid': Icons.bolt,
  'Duo': Icons.gps_fixed,
  'Support': Icons.favorite,
};
const Map<String, Color> kTierColors = {
  'S': Color(0xFFFF5252),
  'A': Color(0xFFFFA726),
  'B': Color(0xFF66BB6A),
  'C': Color(0xFF42A5F5),
  'D': Color(0xFF9E9E9E),
};

// ---------------------------------------------------------------- dados

class ChampStat {
  ChampStat(this.name, this.lane, this.win, this.pick, this.ban);

  factory ChampStat.fromJson(Map<String, dynamic> j) => ChampStat(
        j['name'] as String,
        j['lane'] as String,
        (j['win'] as num).toDouble(),
        (j['pick'] as num).toDouble(),
        (j['ban'] as num).toDouble(),
      );

  final String name;
  final String lane;
  final double win;
  final double pick;
  final double ban;
  double score = 0;
  String tier = 'B';
}

class MetaData {
  MetaData(this.patch, this.updated, this.source, this.stats) {
    _computeTiers();
  }

  factory MetaData.fromJson(Map<String, dynamic> j) => MetaData(
        j['patch'] as String? ?? '?',
        j['updated'] as String? ?? '',
        j['source'] as String? ?? '',
        (j['stats'] as List)
            .map((e) => ChampStat.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  final String patch;
  final String updated;
  final String source;
  final List<ChampStat> stats;

  /// JSON original, repassado para a bolha flutuante.
  String raw = '';

  /// Pontuação: win rate pesa mais; pick e ban mostram força no meta.
  void _computeTiers() {
    for (final s in stats) {
      s.score = (s.win - 50) * 2 + s.pick * 0.25 + s.ban * 0.05;
    }
    for (final lane in kLanes) {
      final list = byLane(lane);
      final n = list.length;
      for (var i = 0; i < n; i++) {
        final p = n <= 1 ? 0.0 : i / (n - 1);
        list[i].tier = p < 0.10
            ? 'S'
            : p < 0.30
                ? 'A'
                : p < 0.65
                    ? 'B'
                    : p < 0.90
                        ? 'C'
                        : 'D';
      }
    }
  }

  List<ChampStat> byLane(String lane) {
    final list = stats.where((s) => s.lane == lane).toList();
    list.sort((a, b) => b.score.compareTo(a.score));
    return list;
  }

  List<String> get champions {
    final set = stats.map((s) => s.name).toSet().toList();
    set.sort();
    return set;
  }

  double pickRate(String name, String lane) {
    for (final s in stats) {
      if (s.name == name && s.lane == lane) return s.pick;
    }
    return 0;
  }

  ChampStat? statIn(String name, String lane) {
    for (final s in stats) {
      if (s.name == name && s.lane == lane) return s;
    }
    return null;
  }

  /// Converte um nome vindo de outra fonte para o nome usado nas estatísticas.
  String resolve(String name) {
    final n = normName(name);
    for (final c in champions) {
      if (normName(c) == n) return c;
    }
    return name;
  }

  List<ChampStat> statsOf(String name) {
    final list = stats.where((s) => s.name == name).toList();
    list.sort((a, b) => b.pick.compareTo(a.pick));
    return list;
  }
}

Future<MetaData> loadBundled() async {
  final raw = await rootBundle.loadString('assets/meta.json');
  return MetaData.fromJson(jsonDecode(raw) as Map<String, dynamic>)..raw = raw;
}

Future<MetaData?> loadRemote() async {
  if (kRemoteDataUrl.isEmpty) return null;
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    final req = await client.getUrl(Uri.parse(kRemoteDataUrl));
    final res = await req.close();
    if (res.statusCode != 200) return null;
    final body = await res.transform(utf8.decoder).join();
    client.close();
    return MetaData.fromJson(jsonDecode(body) as Map<String, dynamic>)..raw = body;
  } catch (_) {
    return null;
  }
}

String normName(String s) => s.toLowerCase().replaceAll(RegExp('[^a-z]'), '');

class Guide {
  Guide(this.name, this.role, this.counteredBy, this.synergy, this.items,
      this.spells, this.runes);

  factory Guide.fromJson(String name, Map<String, dynamic> j) {
    List<String> ls(dynamic v) =>
        v is List ? v.map((e) => e.toString()).toList() : <String>[];
    final items = <String, List<String>>{};
    final it = j['items'];
    if (it is Map) {
      it.forEach((k, v) => items[k.toString()] = ls(v));
    }
    return Guide(name, j['role']?.toString() ?? '', ls(j['counteredBy']),
        ls(j['synergy']), items, ls(j['spells']), ls(j['runes']));
  }

  final String name;
  final String role;
  final List<String> counteredBy;
  final List<String> synergy;
  final Map<String, List<String>> items;
  final List<String> spells;
  final List<String> runes;
}

class GuideData {
  GuideData(this.patch, this.updated, this.byNorm, this.raw);

  factory GuideData.parse(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    final map = <String, Guide>{};
    final g = j['guides'];
    if (g is Map) {
      g.forEach((k, v) {
        map[normName(k.toString())] =
            Guide.fromJson(k.toString(), v as Map<String, dynamic>);
      });
    }
    return GuideData(j['patch']?.toString() ?? '', j['updated']?.toString() ?? '',
        map, raw);
  }

  factory GuideData.empty() => GuideData('', '', {}, '');

  final String patch;
  final String updated;
  final Map<String, Guide> byNorm;
  final String raw;

  Guide? of(String name) => byNorm[normName(name)];
}

Future<GuideData> loadGuidesBundled() async {
  try {
    return GuideData.parse(await rootBundle.loadString('assets/guides.json'));
  } catch (_) {
    return GuideData.empty();
  }
}

Future<GuideData?> loadGuidesRemote() async {
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    final req = await client.getUrl(Uri.parse(kRemoteGuidesUrl));
    final res = await req.close();
    if (res.statusCode != 200) return null;
    final body = await res.transform(utf8.decoder).join();
    client.close();
    final g = GuideData.parse(body);
    return g.byNorm.isEmpty ? null : g;
  } catch (_) {
    return null;
  }
}

/// Distribui os campeões inimigos pelas rotas, maximizando a taxa de escolha
/// de cada um na rota. Devolve rota -> campeão.
Map<String, String> assignLanes(MetaData data, List<String> champs) {
  final cs = champs.take(5).toList();
  var best = -1.0;
  var bestMap = <String, String>{};
  final cur = <String, String>{};
  void rec(int i, double sum) {
    if (i == cs.length) {
      if (sum > best) {
        best = sum;
        bestMap = Map<String, String>.of(cur);
      }
      return;
    }
    for (final l in kLanes) {
      if (cur.containsKey(l)) continue;
      cur[l] = cs[i];
      rec(i + 1, sum + data.pickRate(cs[i], l) + 0.001);
      cur.remove(l);
    }
  }

  rec(0, 0);
  return bestMap;
}

// ---------------------------------------------------------------- app

class WildRiftApp extends StatelessWidget {
  const WildRiftApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rift Helper',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF00BFA5),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  MetaData? _data;
  GuideData _guides = GuideData.empty();
  int _tab = 0;
  bool _updating = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final bundled = await loadBundled();
    final guides = await loadGuidesBundled();
    if (!mounted) return;
    setState(() {
      _data = bundled;
      _guides = guides;
    });
    await _refresh(silent: true);
  }

  static const _overlay = MethodChannel('rift/overlay');

  Future<void> _openBubble() async {
    final data = _data;
    if (data == null) return;
    try {
      final canDraw = await _overlay.invokeMethod<bool>('canDraw') ?? false;
      if (!canDraw) {
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Bolha sobre o jogo'),
            content: const Text(
                'Para mostrar a bolha por cima do Wild Rift, ative "Sobrepor a outros apps" para o Rift Helper na tela que vai abrir. Depois volte e toque na bolha de novo.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Agora não')),
              FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Abrir ajustes')),
            ],
          ),
        );
        if (ok == true) await _overlay.invokeMethod('requestPermission');
        return;
      }
      await _overlay
          .invokeMethod('start', {'json': data.raw, 'guides': _guides.raw});
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Bolha ativada'),
          content: const Text(
              '1. Abra o Wild Rift.\n'
              '2. Na seleção de campeões, toque na bolha RH e em "Ler draft".\n'
              '3. Autorize a gravação escolhendo a tela inteira.\n\n'
              'A gravação desliga sozinha quando os 10 campeões aparecem, depois de 4 minutos, ou em "Parar". '
              'Arraste a bolha para mudar de lugar; segure para fechar.'),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(c), child: const Text('Entendi')),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Não foi possível abrir a bolha: $e')));
    }
  }

  Future<void> _refresh({bool silent = false}) async {
    setState(() => _updating = true);
    final remote = await loadRemote();
    final remoteGuides = await loadGuidesRemote();
    if (!mounted) return;
    setState(() {
      _updating = false;
      if (remote != null) _data = remote;
      if (remoteGuides != null) _guides = remoteGuides;
    });
    if (!silent) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(remote != null
            ? 'Dados atualizados (patch ${remote.patch})'
            : 'Sem atualização disponível, usando dados salvos'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rift Helper'),
        actions: [
          if (data != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text('Patch ${data.patch}',
                    style: Theme.of(context).textTheme.labelLarge),
              ),
            ),
          IconButton(
            tooltip: 'Bolha sobre o jogo',
            onPressed: data == null ? null : _openBubble,
            icon: const Icon(Icons.bubble_chart),
          ),
          IconButton(
            tooltip: 'Atualizar dados',
            onPressed: _updating ? null : () => _refresh(),
            icon: _updating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: data == null
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(
              index: _tab,
              children: [
                TierListPage(data: data, guides: _guides),
                DraftPage(data: data, guides: _guides),
                AboutPage(data: data, guides: _guides),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.leaderboard_outlined),
              selectedIcon: Icon(Icons.leaderboard),
              label: 'Tier List'),
          NavigationDestination(
              icon: Icon(Icons.how_to_vote_outlined),
              selectedIcon: Icon(Icons.how_to_vote),
              label: 'Draft'),
          NavigationDestination(
              icon: Icon(Icons.info_outline),
              selectedIcon: Icon(Icons.info),
              label: 'Sobre'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- widgets comuns

class ChampAvatar extends StatelessWidget {
  const ChampAvatar({super.key, required this.name, this.tier, this.size = 40});

  final String name;
  final String? tier;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = kTierColors[tier] ?? Theme.of(context).colorScheme.primary;
    final letters = name
        .split(RegExp(r"[\s'.&]+"))
        .where((p) => p.isNotEmpty)
        .take(2)
        .map((p) => p[0].toUpperCase())
        .join();
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: color.withOpacity(0.18),
      foregroundColor: color,
      child: Text(letters,
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: size * 0.36)),
    );
  }
}

class TierBadge extends StatelessWidget {
  const TierBadge(this.tier, {super.key});

  final String tier;

  @override
  Widget build(BuildContext context) {
    final color = kTierColors[tier] ?? Colors.grey;
    return Container(
      width: 30,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(tier,
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Colors.black, fontWeight: FontWeight.w900)),
    );
  }
}

String pct(double v) => '${v.toStringAsFixed(1)}%';

// ---------------------------------------------------------------- tier list

enum SortBy { tier, win, pick, ban }

class TierListPage extends StatefulWidget {
  const TierListPage({super.key, required this.data, required this.guides});

  final MetaData data;
  final GuideData guides;

  @override
  State<TierListPage> createState() => _TierListPageState();
}

class _TierListPageState extends State<TierListPage> {
  String _lane = 'Mid';
  SortBy _sort = SortBy.tier;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    var list = widget.data.byLane(_lane);
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list.where((s) => s.name.toLowerCase().contains(q)).toList();
    }
    switch (_sort) {
      case SortBy.tier:
        break;
      case SortBy.win:
        list.sort((a, b) => b.win.compareTo(a.win));
        break;
      case SortBy.pick:
        list.sort((a, b) => b.pick.compareTo(a.pick));
        break;
      case SortBy.ban:
        list.sort((a, b) => b.ban.compareTo(a.ban));
        break;
    }

    return Column(
      children: [
        SizedBox(
          height: 56,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              for (final lane in kLanes)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    avatar: Icon(kLaneIcons[lane], size: 18),
                    label: Text(kLaneLabels[lane]!),
                    selected: _lane == lane,
                    onSelected: (_) => setState(() => _lane = lane),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Buscar campeão',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<SortBy>(
                value: _sort,
                onChanged: (v) => setState(() => _sort = v ?? SortBy.tier),
                items: const [
                  DropdownMenuItem(value: SortBy.tier, child: Text('Tier')),
                  DropdownMenuItem(value: SortBy.win, child: Text('Vitória')),
                  DropdownMenuItem(value: SortBy.pick, child: Text('Escolha')),
                  DropdownMenuItem(value: SortBy.ban, child: Text('Ban')),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? const Center(child: Text('Nenhum campeão encontrado'))
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final s = list[i];
                    return ListTile(
                      leading: ChampAvatar(name: s.name, tier: s.tier),
                      title: Text(s.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                          'Vitória ${pct(s.win)} · Escolha ${pct(s.pick)} · Ban ${pct(s.ban)}'),
                      trailing: TierBadge(s.tier),
                      onTap: () =>
                          showChampSheet(context, widget.data, widget.guides, s.name),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

void showChampSheet(
    BuildContext context, MetaData data, GuideData guides, String name) {
  final rows = data.statsOf(name);
  final guide = guides.of(name);
  final t = Theme.of(context).textTheme;

  Widget chips(List<String> items) => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [for (final i in items) Chip(label: Text(i), visualDensity: VisualDensity.compact)],
      );

  Widget champRow(List<String> names) => Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          for (final n in names)
            Column(mainAxisSize: MainAxisSize.min, children: [
              ChampAvatar(
                  name: n,
                  tier: data.statsOf(data.resolve(n)).isEmpty
                      ? null
                      : data.statsOf(data.resolve(n)).first.tier,
                  size: 40),
              const SizedBox(height: 4),
              Text(n, style: const TextStyle(fontSize: 12)),
            ]),
        ],
      );

  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Row(children: [
            ChampAvatar(
                name: name, tier: rows.isEmpty ? null : rows.first.tier, size: 52),
            const SizedBox(width: 14),
            Expanded(child: Text(name, style: t.headlineSmall)),
          ]),
          const SizedBox(height: 16),
          Text('Desempenho por rota', style: t.titleSmall),
          for (final s in rows)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(kLaneIcons[s.lane]),
              title: Text(kLaneLabels[s.lane] ?? s.lane),
              subtitle: Text(
                  'Vitória ${pct(s.win)} · Escolha ${pct(s.pick)} · Ban ${pct(s.ban)}'),
              trailing: TierBadge(s.tier),
            ),
          if (guide != null) ...[
            if (guide.counteredBy.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Counters (quem ganha de $name)', style: t.titleSmall),
              const SizedBox(height: 8),
              champRow(guide.counteredBy),
            ],
            if ((guide.items['core'] ?? []).isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Itens principais', style: t.titleSmall),
              const SizedBox(height: 6),
              chips(guide.items['core']!),
            ],
            if ((guide.items['final'] ?? []).isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Build completa', style: t.titleSmall),
              const SizedBox(height: 6),
              chips(guide.items['final']!),
            ],
            if (guide.runes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Runas', style: t.titleSmall),
              const SizedBox(height: 6),
              chips(guide.runes),
            ],
            if (guide.spells.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Feitiços', style: t.titleSmall),
              const SizedBox(height: 6),
              chips(guide.spells),
            ],
            if (guide.synergy.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Combina bem com', style: t.titleSmall),
              const SizedBox(height: 8),
              champRow(guide.synergy),
            ],
            const SizedBox(height: 12),
            Text('Builds e counters: WildRiftFire', style: t.bodySmall),
          ],
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------- draft

class DraftPage extends StatefulWidget {
  const DraftPage({super.key, required this.data, required this.guides});

  final MetaData data;
  final GuideData guides;

  @override
  State<DraftPage> createState() => _DraftPageState();
}

class _DraftPageState extends State<DraftPage> {
  final List<String?> _ally = List<String?>.filled(5, null);
  final List<String?> _enemy = List<String?>.filled(5, null);
  final List<String?> _bans = List<String?>.filled(10, null);
  String _myLane = 'Mid';
  String? _opponent;

  Set<String> get _used => {
        ..._ally.whereType<String>(),
        ..._enemy.whereType<String>(),
        ..._bans.whereType<String>(),
      };

  Future<void> _pick(List<String?> target, int index) async {
    final current = target[index];
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ChampPicker(
        data: widget.data,
        disabled: _used..remove(current),
        allowClear: current != null,
      ),
    );
    if (result == null) return;
    setState(() => target[index] = result.isEmpty ? null : result);
  }

  void _reset() {
    setState(() {
      for (var i = 0; i < 5; i++) {
        _ally[i] = null;
        _enemy[i] = null;
      }
      for (var i = 0; i < 10; i++) {
        _bans[i] = null;
      }
    });
  }

  Widget _slot(List<String?> list, int i, Color color, {double size = 44}) {
    final name = list[i];
    String? tier;
    if (name != null) {
      final s = widget.data.statsOf(name);
      if (s.isNotEmpty) tier = s.first.tier;
    }
    return InkWell(
      borderRadius: BorderRadius.circular(size),
      onTap: () => _pick(list, i),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 2),
        ),
        child: name == null
            ? Icon(Icons.add, color: color, size: size * 0.45)
            : ChampAvatar(name: name, tier: tier, size: size - 4),
      ),
    );
  }

  Widget _counterCard(BuildContext context, Set<String> used) {
    final t = Theme.of(context).textTheme;
    final enemies = _enemy.whereType<String>().toList();
    if (enemies.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
              'Marque os campeões inimigos para ver o counter do seu oponente de rota.',
              style: t.bodyMedium),
        ),
      );
    }
    final inferred = assignLanes(widget.data, enemies)[_myLane];
    final opponent =
        (_opponent != null && enemies.contains(_opponent)) ? _opponent : inferred;
    final guide = opponent == null ? null : widget.guides.of(opponent);
    final counters = guide?.counteredBy ?? const <String>[];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Counter do seu oponente de rota', style: t.titleSmall),
            const SizedBox(height: 4),
            Row(children: [
              const Text('Oponente: '),
              DropdownButton<String>(
                value: opponent,
                hint: const Text('escolher'),
                items: [
                  for (final e in enemies)
                    DropdownMenuItem(
                        value: e,
                        child: Text(e == inferred ? '$e (provável)' : e)),
                ],
                onChanged: (v) => setState(() => _opponent = v),
              ),
            ]),
            if (opponent == null)
              const Text('Nenhum inimigo parece jogar nessa rota ainda.')
            else if (counters.isEmpty)
              Text('Sem dados de counter para $opponent.')
            else
              for (final c in counters)
                Builder(builder: (context) {
                  final name = widget.data.resolve(c);
                  final inLane = widget.data.statIn(name, _myLane);
                  final main = widget.data.statsOf(name);
                  final taken = used.contains(name);
                  final sub = inLane != null
                      ? 'Na sua rota: ${inLane.tier} · Vitória ${pct(inLane.win)}'
                      : main.isNotEmpty
                          ? 'Joga mais de ${kLaneLabels[main.first.lane]}'
                          : 'Sem estatísticas no patch';
                  return Opacity(
                    opacity: taken ? 0.4 : 1,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: ChampAvatar(
                          name: name,
                          tier: inLane?.tier ?? (main.isEmpty ? null : main.first.tier),
                          size: 34),
                      title: Text(name),
                      subtitle: Text(taken ? 'Indisponível · $sub' : sub),
                      trailing: IconButton(
                        icon: const Icon(Icons.info_outline),
                        onPressed: () => showChampSheet(
                            context, widget.data, widget.guides, name),
                      ),
                      onTap: taken
                          ? null
                          : () {
                              final free = _ally.indexWhere((e) => e == null);
                              if (free >= 0) setState(() => _ally[free] = name);
                            },
                    ),
                  );
                }),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final used = _used;
    final scheme = Theme.of(context).colorScheme;
    const allyColor = Color(0xFF29B6F6);
    const enemyColor = Color(0xFFEF5350);

    final picks = widget.data
        .byLane(_myLane)
        .where((s) => !used.contains(s.name))
        .take(8)
        .toList();

    final banSuggestions = <ChampStat>[];
    final seen = <String>{};
    final allByThreat = [...widget.data.stats]
      ..sort((a, b) => (b.ban * 0.6 + b.score).compareTo(a.ban * 0.6 + a.score));
    for (final s in allByThreat) {
      if (used.contains(s.name) || seen.contains(s.name)) continue;
      seen.add(s.name);
      banSuggestions.add(s);
      if (banSuggestions.length == 5) break;
    }

    final threats = _enemy.whereType<String>().map((n) {
      final s = widget.data.statsOf(n);
      return s.isEmpty ? null : s.first;
    }).whereType<ChampStat>().toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text('Bans', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            TextButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.restart_alt),
              label: const Text('Limpar'),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < 10; i++)
              _slot(_bans, i, i < 5 ? allyColor : enemyColor, size: 36),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Seu time',
                      style: TextStyle(
                          color: allyColor, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  for (var i = 0; i < 5; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        _slot(_ally, i, allyColor),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(_ally[i] ?? '—',
                                overflow: TextOverflow.ellipsis)),
                      ]),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('Inimigos',
                      style: TextStyle(
                          color: enemyColor, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  for (var i = 0; i < 5; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        Expanded(
                            child: Text(_enemy[i] ?? '—',
                                textAlign: TextAlign.end,
                                overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 8),
                        _slot(_enemy, i, enemyColor),
                      ]),
                    ),
                ],
              ),
            ),
          ],
        ),
        const Divider(height: 32),
        Text('Sua rota', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            for (final l in kLanes)
              ButtonSegment(value: l, icon: Icon(kLaneIcons[l]), tooltip: kLaneLabels[l]),
          ],
          selected: {_myLane},
          onSelectionChanged: (v) => setState(() => _myLane = v.first),
        ),
        const SizedBox(height: 16),
        _counterCard(context, used),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Melhores escolhas disponíveis · ${kLaneLabels[_myLane]}',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                for (final s in picks)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: ChampAvatar(name: s.name, tier: s.tier, size: 34),
                    title: Text(s.name),
                    subtitle: Text('Vitória ${pct(s.win)} · Escolha ${pct(s.pick)}'),
                    trailing: TierBadge(s.tier),
                    onTap: () {
                      final free = _ally.indexWhere((e) => e == null);
                      if (free >= 0) setState(() => _ally[free] = s.name);
                    },
                  ),
                if (picks.isEmpty) const Text('Nenhuma opção livre nessa rota.'),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Bans sugeridos',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in banSuggestions)
                      ActionChip(
                        avatar: ChampAvatar(name: s.name, tier: s.tier, size: 24),
                        label: Text('${s.name} · ${pct(s.ban)}'),
                        onPressed: () {
                          final free = _bans.indexWhere((e) => e == null);
                          if (free >= 0) setState(() => _bans[free] = s.name);
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (threats.isNotEmpty)
          Card(
            color: scheme.errorContainer.withOpacity(0.35),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Ameaças do time inimigo',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  for (final s in threats)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: ChampAvatar(name: s.name, tier: s.tier, size: 34),
                      title: Text(s.name),
                      subtitle: Text(
                          '${kLaneLabels[s.lane]} · Vitória ${pct(s.win)}'),
                      trailing: TierBadge(s.tier),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          'Toque em um círculo para escolher o campeão. Toque numa sugestão para colocá-la no seu time ou nos bans.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class ChampPicker extends StatefulWidget {
  const ChampPicker({
    super.key,
    required this.data,
    required this.disabled,
    required this.allowClear,
  });

  final MetaData data;
  final Set<String> disabled;
  final bool allowClear;

  @override
  State<ChampPicker> createState() => _ChampPickerState();
}

class _ChampPickerState extends State<ChampPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final names =
        widget.data.champions.where((n) => n.toLowerCase().contains(q)).toList();
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Buscar campeão',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                if (widget.allowClear) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => Navigator.pop(context, ''),
                    child: const Text('Remover'),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 90,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.8,
              ),
              itemCount: names.length,
              itemBuilder: (context, i) {
                final n = names[i];
                final disabled = widget.disabled.contains(n);
                final stats = widget.data.statsOf(n);
                return Opacity(
                  opacity: disabled ? 0.3 : 1,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: disabled ? null : () => Navigator.pop(context, n),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ChampAvatar(
                            name: n,
                            tier: stats.isEmpty ? null : stats.first.tier,
                            size: 48),
                        const SizedBox(height: 6),
                        Text(n,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- sobre

class AboutPage extends StatelessWidget {
  const AboutPage({super.key, required this.data, required this.guides});

  final MetaData data;
  final GuideData guides;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Rift Helper', style: t.headlineSmall),
        const SizedBox(height: 8),
        Text('Patch ${data.patch} · atualizado em ${data.updated}'),
        Text('Fonte: ${data.source}'),
        Text('Counters e builds: WildRiftFire · ${guides.byNorm.length} campeões'
            '${guides.updated.isEmpty ? '' : ' · ${guides.updated}'}'),
        Text('${data.champions.length} campeões · ${data.stats.length} combinações campeão/rota'),
        const SizedBox(height: 20),
        Text('Como o tier é calculado', style: t.titleMedium),
        const SizedBox(height: 6),
        const Text(
            'Cada campeão recebe uma nota por rota, com a taxa de vitória pesando mais e as taxas de escolha e ban como sinal de força no meta. O tier é a posição dessa nota dentro da rota: S são os 10% melhores, depois A, B, C e D.'),
        const SizedBox(height: 20),
        Text('Limitações', style: t.titleMedium),
        const SizedBox(height: 6),
        const Text(
            'A Riot não oferece API pública do Wild Rift, então o app não busca perfis de jogadores. Na bolha, o draft é lido pela tela só quando você toca em "Ler draft", reconhecendo os nomes dos campeões nas colunas dos times; os bans não são lidos. Os counters vêm das listas "Countered By" do WildRiftFire, atualizadas toda semana.'),
        const SizedBox(height: 20),
        Text(
            'Projeto de fã, sem vínculo com a Riot Games. League of Legends: Wild Rift é marca da Riot Games, Inc.',
            style: t.bodySmall),
      ],
    );
  }
}
