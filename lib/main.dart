import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'config/app_config.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

final backendUrl = AppConfig.backendUrl;
final apiKey = AppConfig.apiKey;


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MobileAds.instance.initialize();
  runApp(const MyApp());
}

class Article {
  String id;
  String nom;
  double prix;
  Set<String> assignedPersonIds;
  Article({required this.id, required this.nom, required this.prix, Set<String>? assigned})
      : assignedPersonIds = assigned ?? {};
}

class Person {
  String id;
  String name;
  Person({required this.id, required this.name});
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QuiPaieQuoi',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const TicketScannerPage(),
    );
  }
}

class TicketScannerPage extends StatefulWidget {
  const TicketScannerPage({super.key});
  @override
  State<TicketScannerPage> createState() => _TicketScannerPageState();
}

class _TicketScannerPageState extends State<TicketScannerPage> with TickerProviderStateMixin {
  File? _ticketImage;
  Uint8List? _displayedImage;
  bool _isLoading = false;
  List<Article> _articles = [];
  final List<Person> _persons = [];
  final _uuid = const Uuid();
  double _scanProgress = 0;
  AnimationController? _progressCtrl;
  BannerAd? _bannerAd;
  bool _isAdLoaded = false;

// TODO: replace this test ad unit with your own ad unit.
  final adUnitId = kReleaseMode ? 'ca-app-pub-7170327342166140/4448964559' : (Platform.isAndroid
    ? 'ca-app-pub-3940256099942544/9214589741'
    : 'ca-app-pub-3940256099942544/2435281174');

  @override
  void initState() {
    super.initState();
    _persons.add(Person(id: _uuid.v4(), name: "Moi"));
    loadAd();
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }

  /// Loads a banner ad.
  void loadAd() async {
    _bannerAd = BannerAd(
      adUnitId: adUnitId,
      request: const AdRequest(),
      size: AdSize.banner,
      listener: BannerAdListener(
        // Called when an ad is successfully received.
        onAdLoaded: (ad) {
          debugPrint('$ad loaded.');
          setState(() {
            _isAdLoaded = true;
          });
        },
        // Called when an ad request failed.
        onAdFailedToLoad: (ad, err) {
          debugPrint('BannerAd failed to load: $err');
          // Dispose the ad here to free resources.
          ad.dispose();
        },
      ),
    )..load();
  }

  // 1. Prendre et compresser une photo
  Future<void> _pickAndCompressImage() async {
    final picker = ImagePicker();
    final XFile? picked = await picker.pickImage(source: ImageSource.camera, imageQuality: 95);
    if (picked == null) return;
    final compressed = await FlutterImageCompress.compressWithFile(
      picked.path,
      minWidth: 600,
      minHeight: 600,
      quality: 85, // pour garder lisible mais réduire
      format: CompressFormat.jpeg,
      keepExif: false,
    );
    if (compressed == null) return;
    // si trop gros, on baisse encore la qualité
    int quality = 85;
    Uint8List result = compressed;
    while (result.lengthInBytes > 80 * 1024 && quality > 20) {
      quality -= 10;
      final temp = await FlutterImageCompress.compressWithFile(
        picked.path,
        minWidth: 600,
        minHeight: 600,
        quality: quality,
        format: CompressFormat.jpeg,
        keepExif: false,
      );
      if (temp != null) result = temp;
    }
    setState(() {
      _ticketImage = File(picked.path);
      _displayedImage = result;
    });
    await _sendToBackend(result);
  }

  // 2. Envoie au backend (avec effet de scan)
  Future<void> _sendToBackend(Uint8List imageBytes) async {
    setState(() {
      _isLoading = true;
      _scanProgress = 0;
      _articles = [];
    });

    // Vérifier la connexion Internet
    var connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.single == ConnectivityResult.none) {
      setState(() {
        _isLoading = false;
        _scanProgress = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Aucune connexion internet. Cette fonctionnalité requiert une connexion."),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Lance une animation contrôlée qui augmente _scanProgress de façon non-linéaire
    _progressCtrl?.dispose();
    _progressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 50), // Durée arbitraire, on va stopper à la réponse
    )..addListener(() {
        // Utilise une fonction pour ralentir la progression à la fin (easeOutCubic)
        final t = _progressCtrl!.value;
        final double prog = 0.96 * (1 - (1 - t) * (1 - t) * (1 - t)); // Jamais > 96%
        setState(() {
          _scanProgress = prog;
        });
      })
      ..forward();

    final base64img = base64Encode(imageBytes);

    // Petite attente pour l'effet
    await Future.delayed(const Duration(milliseconds: 600));

    bool error = false;
    String errorMessage = "Erruer lors de l'analyse du ticket.Veuillez réessayer.";

    try {
      final response = await http.post(
        Uri.parse(backendUrl),
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
        },
        body: jsonEncode({'base64_image': base64img}),
      ).timeout(const Duration(seconds: 25), onTimeout: () {
        throw Exception("Le serveur met trop de temps à répondre.");
      });

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final articlesList = (decoded['articles'] as List?) ?? [];
        setState(() {
          _articles = articlesList
              .map((a) => Article(
                    id: _uuid.v4(),
                    nom: a['nomArticle']?.toString() ?? '',
                    prix: (a['prixUnitaire'] as num?)?.toDouble() ?? 0,
                  ))
              .toList();
        });
      } else {
        error = true;
        if (response.body.isNotEmpty) {
          try {
            final decoded = jsonDecode(response.body);
            if (decoded is Map && decoded['error'] != null) {
              errorMessage = "Erreur : ${decoded['error']}";
            }
          } catch (_) {}
        }
      }
    } on SocketException {
      error = true;
      errorMessage = "Erreur réseau : impossible de joindre le serveur.";
    } on TimeoutException {
      error = true;
      errorMessage = "Délai d'attente dépassé. Veuillez vérifier votre connexion.";
    } catch (e) {
      error = true;
      errorMessage = e.toString();
    }

    // Termine la barre d’un coup et reset après une courte pause
    setState(() {
      _scanProgress = 1;
    });
    await Future.delayed(const Duration(milliseconds: 500));
    _progressCtrl?.dispose();
    _progressCtrl = null;
    setState(() {
      _isLoading = false;
      _scanProgress = 0;
    });

    if (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: Colors.red,
          action: SnackBarAction(
            label: "Réessayer",
            textColor: Colors.white,
            onPressed: () {
              _sendToBackend(imageBytes);
            },
          ),
        ),
      );
    }
  }

  // Ajout/Suppression articles/personnes
  void _addArticle() {
    final nameCtrl = TextEditingController(text: '');
    final priceCtrl = TextEditingController(text: '');

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text("Ajouter un article"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: "Nom de l'article"),
            ),
            TextField(
              controller: priceCtrl,
              decoration: const InputDecoration(labelText: "Prix (€)"),
              keyboardType: TextInputType.numberWithOptions(decimal: true),
            ),
          ],
        ),
        actions: [
          TextButton(
            child: const Text("Annuler"),
            onPressed: () => Navigator.pop(context),
          ),
          TextButton(
            child: Text("Ajouter"),
            onPressed: () {
              final nom = nameCtrl.text.trim();
              final prix = double.tryParse(priceCtrl.text.replaceAll(',', '.')) ?? 0.0;
              if (nom.isNotEmpty && prix > 0) {
                setState(() {
                    _articles.add(Article(id: _uuid.v4(), nom: nom, prix: prix));
                });
                Navigator.pop(context);
              }
            },
          ),
        ],
      ),
    );
  }


  void _removeArticle(String id) {
    setState(() {
      _articles.removeWhere((a) => a.id == id);
    });
  }

  void _addPerson() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Ajouter une personne'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                setState(() {
                  _persons.add(Person(id: _uuid.v4(), name: controller.text.trim()));
                });
              }
              Navigator.pop(context);
            },
            child: const Text('Ajouter'),
          ),
        ],
      ),
    );
  }

  void _removePerson(String id) {
    setState(() {
      _persons.removeWhere((p) => p.id == id);
      for (final art in _articles) {
        art.assignedPersonIds.remove(id);
      }
    });
  }

  // Attribuer personne(s) à un article
  void _toggleAssign(String articleId, String personId) {
    setState(() {
      final art = _articles.firstWhere((a) => a.id == articleId);
      if (art.assignedPersonIds.contains(personId)) {
        art.assignedPersonIds.remove(personId);
      } else {
        art.assignedPersonIds.add(personId);
      }
    });
  }

  // Calculs des totaux
  double get total => _articles.fold(0.0, (prev, a) => prev + a.prix);

  Map<String, double> get totalParPersonne {
    final map = <String, double>{};
    for (final person in _persons) {
      double somme = 0;
      for (final art in _articles) {
        if (art.assignedPersonIds.contains(person.id) && art.assignedPersonIds.isNotEmpty) {
          somme += art.prix / art.assignedPersonIds.length;
        }
      }
      map[person.id] = somme;
    }
    return map;
  }

  // Affichage dynamique
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("QuiPaieQuoi"), centerTitle: true),
      // floatingActionButton: FloatingActionButton.extended(
      //   onPressed: _pickAndCompressImage,
      //   icon: const Icon(Icons.camera_alt),
      //   label: const Text("Scanner un ticket"),
      // ),
      body: Padding(
        padding: const EdgeInsets.all(8.0),
        child: _isLoading
            ? Stack(
                alignment: Alignment.center,
                children: [
                  if (_displayedImage != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Image.memory(_displayedImage!, fit: BoxFit.contain),
                          Positioned.fill(child: _ScanAnimation()),
                        ],
                      ),
                    ),
                  Positioned(
                    top: 24,
                    left: 0,
                    right: 0,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: LinearProgressIndicator(
                        value: _scanProgress,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                        backgroundColor: Colors.green[50],
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    "Scan en cours...",
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: _bannerAd != null
                      ? SizedBox(
                          height: _bannerAd!.size.height.toDouble(),
                          width: _bannerAd!.size.width.toDouble(),
                          child: AdWidget(ad: _bannerAd!),
                        )
                      : SizedBox(),
                  ),
                ],
              )
            : SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PersonsList(
              persons: _persons,
              onAdd: _addPerson,
              onRemove: _removePerson,
            ),
            const SizedBox(height: 12),
            _ArticlesList(
              articles: _articles,
              persons: _persons,
              onRemove: _removeArticle,
              onToggleAssign: _toggleAssign,
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text("Ajouter article"),
                  onPressed: _addArticle,
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.person_add),
                  label: const Text("Ajouter personne"),
                  onPressed: _addPerson,
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.camera_alt),
                  label: const Text("Scanner un ticket"),
                  onPressed: _pickAndCompressImage,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                children: [
                  Text(
                    "Total : ${total.toStringAsFixed(2)} €",
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  ..._persons.map((p) => Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          "${p.name} : ${(totalParPersonne[p.id] ?? 0).toStringAsFixed(2)} €",
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Colors.green[900],
                              ),
                        ),
                      )),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _ScanAnimation extends StatefulWidget {
  const _ScanAnimation();
  @override
  State<_ScanAnimation> createState() => __ScanAnimationState();
}

class __ScanAnimationState extends State<_ScanAnimation> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (ctx, _) {
        return CustomPaint(
          painter: _ScanPainter(_ctrl.value),
        );
      },
    );
  }
}

class _ScanPainter extends CustomPainter {
  final double progress;
  _ScanPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [Colors.green.withOpacity(0.2), Colors.green, Colors.green.withOpacity(0.2)],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..blendMode = BlendMode.srcATop;
    final lineY = size.height * progress;
    canvas.drawRect(Rect.fromLTWH(0, lineY - 10, size.width, 20), paint);
  }

  @override
  bool shouldRepaint(_ScanPainter oldDelegate) => oldDelegate.progress != progress;
}

// --- Articles List widget ---
class _ArticlesList extends StatelessWidget {
  final List<Article> articles;
  final List<Person> persons;
  final void Function(String) onRemove;
  final void Function(String articleId, String personId) onToggleAssign;
  const _ArticlesList({
    required this.articles,
    required this.persons,
    required this.onRemove,
    required this.onToggleAssign,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: articles.length,
        separatorBuilder: (_, __) => const Divider(),
        itemBuilder: (context, index) {
          final a = articles[index];
          return ListTile(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.nom, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(
                  "Prix : ${a.prix.toStringAsFixed(2)} €",
                  style: const TextStyle(fontSize: 16),
                ),
              ],
            ),
            subtitle: persons.isEmpty
                ? null
                : Wrap(
                    spacing: 4,
                    children: persons
                        .map((p) => FilterChip(
                              selected: a.assignedPersonIds.contains(p.id),
                              label: Text(p.name),
                              onSelected: (_) => onToggleAssign(a.id, p.id),
                            ))
                        .toList(),
                  ),
            trailing: IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: () => onRemove(a.id),
            ),
          );
        },
      ),
    );
  }
}

// --- Persons List widget ---
class _PersonsList extends StatelessWidget {
  final List<Person> persons;
  final void Function() onAdd;
  final void Function(String) onRemove;
  const _PersonsList({required this.persons, required this.onAdd, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8.0),
            child: Text("Personnes", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
           ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: persons.length,
              separatorBuilder: (_, __) => const Divider(),
              itemBuilder: (context, index) {
                final p = persons[index];
                return ListTile(
                  title: Text(p.name),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => onRemove(p.id),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
