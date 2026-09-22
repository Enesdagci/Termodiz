import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/hasta.dart';
import '../services/database_service.dart';
import 'gecmis_sayfasi.dart';

// ESP32 artık kendi ağını yaymıyor — telefonun mobil hotspot'una istemci
// (station) olarak bağlanıyor. Bu yüzden IP adresi SABİT DEĞİL: telefon,
// hotspot'a her katılan cihaza DHCP ile farklı bir IP verebilir. Bu yüzden
// IP'yi koda sabit yazmak yerine kullanıcıdan alıp SharedPreferences'ta
// saklıyoruz — Serial Monitor'de "ESP32 adresi: http://..." satırında
// yazan IP'yi kullanıcı bir kere girer, sonraki açılışlarda hatırlanır.
const String _varsayilanEsp32Ip = "192.168.4.1";
const String _esp32IpAnahtari = "esp32_ip_adresi";

class GrafikSayfasi extends StatefulWidget {
  final Hasta hasta;
  const GrafikSayfasi({super.key, required this.hasta});

  @override
  State<GrafikSayfasi> createState() => _GrafikSayfasiState();
}

class _GrafikSayfasiState extends State<GrafikSayfasi> {
  final VeritabaniServisi _veritabani = VeritabaniServisi();

  // Her bölge için son 30 ölçümü tutan liste (grafik için)
  final List<double> _b1 = [];
  final List<double> _b2 = [];
  final List<double> _b3 = [];
  final List<double> _b4 = [];

  String _durum = "Bağlı değil";
  bool _bagli = false;
  String _esp32Ip = _varsayilanEsp32Ip;
  Timer? _pollTimer;
  bool _istekDevamEdiyor = false; // önceki HTTP isteği bitmeden yenisini başlatma

  // store-and-forward senkronizasyon: ESP32'nin ürettiği kayıtlar "sira" ile
  // numaralanıyor. Biz en son işlediğimiz sira'yı hatırlıyoruz ve her istekte
  // "bundan sonrasını ver" diyoruz — böylece ekran kapansa/uygulama kapansa
  // bile kaldığımız yerden devam ederiz, veri kaybolmaz.
  int _sonSira = 0;
  String get _sonSiraAnahtari => 'son_sira_${widget.hasta.id}';

  int _paketSayaci = 0; // başarıyla işlenen TOPLAM kayıt sayısı
  int _toplamIstekSayisi = 0; // atılan TOPLAM HTTP isteği sayısı (teşhis için)
  int _ardisikBasarisizSayisi = 0; // üst üste başarısız istek sayısı
  int _kopmaSayaci = 0; // bağlantının kaybedildiği tespit edilen an sayısı
  String _sonHam = ""; // en son gelen HTTP yanıtının (kısaltılmış) metni
  bool _veriKaybiUyarisiGosterildi = false; // ESP32 arabelleği taşıp veri kalıcı kaybolduysa

  // Veri tazeliği: son kaydın ne zaman geldiğini gösterip, sessizce bayatlamış
  // veriyi "canlı" gibi göstermeyi önler.
  DateTime? _sonPaketZamani;
  Timer? _tazelikTimer;

  @override
  void initState() {
    super.initState();
    // Ekranı saniyede bir yeniler ki "son veri X sn önce geldi" göstergesi
    // yeni paket gelmeden de güncel kalsın.
    _tazelikTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _esp32IpYukle();
  }

  // Daha önce kaydedilmiş ESP32 IP'si varsa yükler (uygulama yeniden açılsa
  // bile kullanıcı IP'yi tekrar girmek zorunda kalmasın diye).
  Future<void> _esp32IpYukle() async {
    try {
      final tercihler = await SharedPreferences.getInstance();
      final kayitliIp = tercihler.getString(_esp32IpAnahtari);
      if (kayitliIp != null && kayitliIp.isNotEmpty && mounted) {
        setState(() => _esp32Ip = kayitliIp);
      }
    } catch (e) {
      debugPrint("UYARI: Kaydedilmiş ESP32 IP okunamadı: $e");
    }
  }

  // Kullanıcıya ESP32'nin güncel IP'sini (Serial Monitor'den okuduğu) girmesi
  // için bir diyalog gösterir ve girilen değeri kalıcı olarak kaydeder.
  Future<void> _ipDegistirDiyaloguGoster() async {
    final denetleyici = TextEditingController(text: _esp32Ip);
    final yeniIp = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ESP32 IP Adresi'),
        content: TextField(
          controller: denetleyici,
          autofocus: true,
          keyboardType: TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            hintText: 'örn: 10.245.88.47',
            helperText: 'Serial Monitor\'deki "ESP32 adresi: http://..." satırında yazan IP',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('İptal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, denetleyici.text.trim()),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );

    if (yeniIp != null && yeniIp.isNotEmpty && yeniIp != _esp32Ip) {
      setState(() => _esp32Ip = yeniIp);
      try {
        final tercihler = await SharedPreferences.getInstance();
        await tercihler.setString(_esp32IpAnahtari, yeniIp);
      } catch (e) {
        debugPrint("UYARI: ESP32 IP kaydedilemedi: $e");
      }
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tazelikTimer?.cancel();
    super.dispose();
  }

  Future<void> _baglan() async {
    _pollTimer?.cancel();
    setState(() {
      _durum = "ESP32'ye bağlanılıyor...";
      _bagli = false;
    });

    // Kaldığımız yeri (varsa, önceki oturumdan) yükle — böylece uygulama
    // yeniden açılsa bile veri baştan değil, kaldığı sıradan senkronize edilir.
    try {
      final tercihler = await SharedPreferences.getInstance();
      _sonSira = tercihler.getInt(_sonSiraAnahtari) ?? 0;
      debugPrint("[${DateTime.now()}] Kaydedilmiş son sıra yüklendi: $_sonSira");
    } catch (e) {
      debugPrint("UYARI: Kaydedilmiş sıra okunamadı: $e");
      _sonSira = 0;
    }

    // ESP32'ye gerçekten ulaşılabiliyor mu diye önce /durum ile test ediyoruz.
    // Bu, kullanıcıya "WiFi ağına bağlanmayı unuttun" ile "ESP32 kapalı/menzil dışı"
    // durumlarını net bir mesajla ayırt etmemizi sağlıyor.
    try {
      final yanit = await http
          .get(Uri.parse('http://$_esp32Ip/durum'))
          .timeout(const Duration(seconds: 5));
      if (yanit.statusCode != 200) throw Exception('HTTP ${yanit.statusCode}');
      debugPrint("[${DateTime.now()}] ESP32 /durum yanıtı: ${yanit.body}");
    } catch (e) {
      setState(() {
        _durum = 'ESP32\'ye ($_esp32Ip) ulaşılamıyor — hotspot açık mı, ESP32 çalışıyor mu '
            've IP doğru mu kontrol et (Serial Monitor\'den doğrula)';
      });
      debugPrint("HATA: /durum isteğine ulaşılamadı: $e");
      return;
    }

    setState(() {
      _bagli = true;
      _durum = "Bağlı — veri senkronize ediliyor...";
      _ardisikBasarisizSayisi = 0;
    });

    // İlk isteği hemen at (bekletmeden), sonra saniyede bir tekrar et.
    // ESP32 saniyede 1 kayıt ürettiği için bu aralık yeterli; eğer araya
    // uzun bir kopukluk girdiyse ilk birkaç istek arka arkaya 100'er kayıtlık
    // "geçmişi kapatma" turları yapar (bkz. _veriCek içindeki mesaj).
    _veriCek();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _veriCek());
  }

  Future<void> _veriCek() async {
    if (_istekDevamEdiyor) return; // önceki istek hâlâ sürüyorsa üst üste binmesin
    _istekDevamEdiyor = true;
    _toplamIstekSayisi++;

    try {
      final yanit = await http
          .get(Uri.parse('http://$_esp32Ip/gecmis?sonSira=$_sonSira'))
          .timeout(const Duration(seconds: 4));

      if (yanit.statusCode != 200) {
        throw Exception('HTTP ${yanit.statusCode}');
      }

      // Bağlantı sağlıklı: ardışık başarısızlık sayacını sıfırla.
      _ardisikBasarisizSayisi = 0;

      final govde = jsonDecode(yanit.body) as Map<String, dynamic>;
      final kayitlar = (govde['kayitlar'] as List).cast<Map<String, dynamic>>();
      final veriAtlandi = govde['veriAtlandi'] == true;

      _sonHam = yanit.body.length > 200 ? '${yanit.body.substring(0, 200)}…' : yanit.body;

      if (veriAtlandi && !_veriKaybiUyarisiGosterildi) {
        _veriKaybiUyarisiGosterildi = true;
        debugPrint(
            "UYARI: ESP32'nin arabelleği (30 dk) dolup taştığı için bazı geçmiş kayıtlar kalıcı olarak kayboldu.");
      }

      for (final kayit in kayitlar) {
        final b1 = (kayit['b1'] as num).toDouble();
        final b2 = (kayit['b2'] as num).toDouble();
        final b3 = (kayit['b3'] as num).toDouble();
        final b4 = (kayit['b4'] as num).toDouble();
        final ref = (kayit['ref'] as num).toDouble();
        final dt1 = (kayit['dt1'] as num).toDouble();
        final dt2 = (kayit['dt2'] as num).toDouble();
        final dt3 = (kayit['dt3'] as num).toDouble();
        final dt4 = (kayit['dt4'] as num).toDouble();
        final alarm = kayit['alarm'] == true;
        final sira = (kayit['sira'] as num).toInt();

        _ekleVeSinirla(_b1, b1);
        _ekleVeSinirla(_b2, b2);
        _ekleVeSinirla(_b3, b3);
        _ekleVeSinirla(_b4, b4);

        _sonSira = sira;
        _paketSayaci++;

        // Her kaydı veritabanına kalıcı olarak yaz (ölçüm geçmişi).
        // zaman olarak ESP32'nin kendi saatini değil, HTTP yanıtının telefona
        // ULAŞTIĞI anı kullanıyoruz — ESP32'nin zamanMs değeri sadece kendi
        // açılışından beri geçen süre, gerçek saat değil.
        unawaited(_veritabani.olcumEkle(Olcum(
          hastaId: widget.hasta.id,
          zaman: DateTime.now().toIso8601String(),
          b1: b1, b2: b2, b3: b3, b4: b4, ref: ref,
          dt1: dt1, dt2: dt2, dt3: dt3, dt4: dt4,
          alarm: alarm,
        )));
      }

      if (kayitlar.isNotEmpty) {
        _sonPaketZamani = DateTime.now();
        unawaited(_sonSirayiKaliciKaydet());
      }

      if (mounted) {
        setState(() {
          _durum = kayitlar.length >= 100
              ? 'Bağlı — geçmiş veriler senkronize ediliyor (bu turda ${kayitlar.length} kayıt alındı)...'
              : 'Bağlı — veri akıyor';
        });
      }
    } catch (e) {
      _ardisikBasarisizSayisi++;
      debugPrint("HATA (HTTP istek, sonSira=$_sonSira): $e");
      // Her başarısız denemede değil, sadece kopmanın BAŞLADIĞI anda sayaç
      // artsın ve kullanıcı bilgilendirilsin (3 ardışık başarısızlık ~ birkaç sn).
      if (_ardisikBasarisizSayisi == 3 && mounted) {
        _kopmaSayaci++;
        setState(() {
          _bagli = false;
          _durum = "ESP32'ye ulaşılamıyor (${_kopmaSayaci}. kez) — WiFi ağını ve ESP32'yi kontrol et";
        });
      }
    } finally {
      _istekDevamEdiyor = false;
    }
  }

  Future<void> _sonSirayiKaliciKaydet() async {
    try {
      final tercihler = await SharedPreferences.getInstance();
      await tercihler.setInt(_sonSiraAnahtari, _sonSira);
    } catch (e) {
      debugPrint("UYARI: son sıra kaydedilemedi: $e");
    }
  }

  void _ekleVeSinirla(List<double> liste, double deger) {
    liste.add(deger);
    if (liste.length > 30) liste.removeAt(0);
  }

  List<FlSpot> _spotlarOlustur(List<double> liste) {
    return List.generate(liste.length, (i) => FlSpot(i.toDouble(), liste[i]));
  }

  // Tüm çizgilerdeki en küçük/en büyük değere göre, biraz pay bırakarak Y ekseni sınırlarını hesaplar
  double _yEksenMin() {
    final tumDegerler = [..._b1, ..._b2, ..._b3, ..._b4];
    if (tumDegerler.isEmpty) return 0;
    final minDeger = tumDegerler.reduce((a, b) => a < b ? a : b);
    return (minDeger - 1).floorToDouble();
  }

  double _yEksenMax() {
    final tumDegerler = [..._b1, ..._b2, ..._b3, ..._b4];
    if (tumDegerler.isEmpty) return 40;
    final maxDeger = tumDegerler.reduce((a, b) => a > b ? a : b);
    return (maxDeger + 1).ceilToDouble();
  }

  // Ekranda en fazla ~6 etiket görünecek şekilde aralığı hesaplar (etiketlerin sıkışmasını önler)
  double _yEksenAralik() {
    final aralik = _yEksenMax() - _yEksenMin();
    if (aralik <= 0) return 1;
    final adimAdayi = (aralik / 6).ceilToDouble();
    return adimAdayi < 1 ? 1 : adimAdayi;
  }

  // Son verinin ne kadar önce geldiğini renkli bir göstergeyle sunar.
  // Bayat veriyi asla "canlı"ymış gibi göstermemek için: yeşil (<5 sn),
  // sarı (5-20 sn), kırmızı (20 sn+ — bağlantı sorunu olabilir).
  Widget _tazelikGostergesi() {
    if (_sonPaketZamani == null) {
      return const Text('Henüz veri alınmadı', style: TextStyle(fontSize: 12, color: Colors.grey));
    }
    final gecenSaniye = DateTime.now().difference(_sonPaketZamani!).inSeconds;
    Color renk;
    String metin;
    if (gecenSaniye < 5) {
      renk = Colors.green;
      metin = 'Canlı — az önce güncellendi';
    } else if (gecenSaniye < 20) {
      renk = Colors.orange;
      metin = '$gecenSaniye sn önce güncellendi';
    } else {
      renk = Colors.red;
      metin = '$gecenSaniye sn\'dir veri gelmiyor — bağlantı sorunu olabilir';
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(color: renk, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(metin, style: TextStyle(fontSize: 12, color: renk, fontWeight: FontWeight.w600)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.hasta.ad} — Sıcaklık Grafiği'),
        actions: [
          IconButton(
            tooltip: 'Ölçüm geçmişi',
            icon: const Icon(Icons.history),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => GecmisSayfasi(hasta: widget.hasta),
                ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text(_durum, style: const TextStyle(fontSize: 14, color: Colors.grey)),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      'ESP32 adresi: http://$_esp32Ip',
                      style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'IP adresini değiştir',
                    icon: const Icon(Icons.edit, size: 16),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: _ipDegistirDiyaloguGoster,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // TEŞHİS KUTUSU: istek sayısı ile işlenen kayıt sayısı birlikte
              // izlenerek "hiç bağlanamıyoruz" ile "bağlanıyoruz ama veri
              // gelmiyor" durumları ayırt edilebiliyor.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'İstek: $_toplamIstekSayisi   |   İşlenen kayıt: $_paketSayaci   |   Bağlantı kaybı: $_kopmaSayaci',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _sonHam.isEmpty
                          ? 'Son yanıt: (henüz yok)'
                          : 'Son yanıt: $_sonHam',
                      style: const TextStyle(fontSize: 10, color: Colors.black87),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (_veriKaybiUyarisiGosterildi)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          'UYARI: ESP32 arabelleği (30 dk) dolduğu için bazı geçmiş kayıtlar kalıcı olarak kayboldu.',
                          style: TextStyle(fontSize: 10, color: Colors.red, fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (_b1.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _tazelikGostergesi(),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 16,
                        runSpacing: 4,
                        children: [
                          Text('B1: ${_b1.last.toStringAsFixed(2)}°C', style: const TextStyle(fontSize: 13, color: Colors.blue, fontWeight: FontWeight.w600)),
                          Text('B2: ${_b2.last.toStringAsFixed(2)}°C', style: const TextStyle(fontSize: 13, color: Colors.green, fontWeight: FontWeight.w600)),
                          Text('B3: ${_b3.last.toStringAsFixed(2)}°C', style: const TextStyle(fontSize: 13, color: Colors.orange, fontWeight: FontWeight.w600)),
                          Text('B4: ${_b4.last.toStringAsFixed(2)}°C', style: const TextStyle(fontSize: 13, color: Colors.red, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: _b1.isEmpty
                    ? const Center(child: Text('Henüz veri yok'))
                    : LineChart(
                        LineChartData(
                          minY: _yEksenMin(),
                          maxY: _yEksenMax(),
                          gridData: const FlGridData(show: true),
                          titlesData: FlTitlesData(
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 44,
                                interval: _yEksenAralik(),
                                getTitlesWidget: (deger, meta) => Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Text(
                                    deger.toStringAsFixed(0),
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                              ),
                            ),
                            bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          ),
                          lineBarsData: [
                            LineChartBarData(spots: _spotlarOlustur(_b1), color: Colors.blue, dotData: const FlDotData(show: false)),
                            LineChartBarData(spots: _spotlarOlustur(_b2), color: Colors.green, dotData: const FlDotData(show: false)),
                            LineChartBarData(spots: _spotlarOlustur(_b3), color: Colors.orange, dotData: const FlDotData(show: false)),
                            LineChartBarData(spots: _spotlarOlustur(_b4), color: Colors.red, dotData: const FlDotData(show: false)),
                          ],
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _baglan,
                  child: Text(_bagli ? 'Yeniden Senkronize Et' : 'ESP32\'ye Bağlan'),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}