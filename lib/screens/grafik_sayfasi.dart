import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/hasta.dart';
import '../services/database_service.dart';
import 'gecmis_sayfasi.dart';

// ESP32 kodundaki UUID'lerle birebir eşleşmeli
const String cihazIsmi = "DizSensor";
const String servisUuid = "12345678-1234-1234-1234-1234567890ab";
const String karakteristikUuid = "abcd1234-ab12-cd34-ef56-1234567890ab";

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
  BluetoothDevice? _cihaz;
  int _kopmaSayaci = 0; // gerçek BLE kopması olursa otomatik yeniden bağlanmak için kullanılır
  StreamSubscription<BluetoothConnectionState>? _baglantiDurumuAbonelik;

  // Veri tazeliği: son paketin ne zaman geldiğini gösterip, sessizce bayatlamış
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
  }

  @override
  void dispose() {
    _ilkVeriBekleTimer?.cancel();
    _tazelikTimer?.cancel();
    _baglantiDurumuAbonelik?.cancel();
    _cihaz?.disconnect();
    super.dispose();
  }

  Future<void> _baglan() async {
    // 1. Adım: İzinleri iste
    setState(() => _durum = "İzinler isteniyor...");
    final durumlar = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    debugPrint("İzin sonuçları: $durumlar");

    final hepsiVerildi = durumlar.values.every((s) => s.isGranted);
    if (!hepsiVerildi) {
      setState(() => _durum = "İzin reddedildi — Ayarlar'dan Bluetooth/Konum iznini aç");
      debugPrint("HATA: Gerekli izinler verilmedi.");
      return;
    }

    // 2. Adım: Bluetooth açık mı kontrol et
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      setState(() => _durum = "Bluetooth kapalı — lütfen açın");
      debugPrint("HATA: Bluetooth adaptörü kapalı.");
      return;
    }

    // 3. Adım: Tara
    setState(() => _durum = "Taranıyor...");
    debugPrint("Tarama başladı, aranan cihaz ismi: $cihazIsmi");

    bool cihazBulundu = false;

    // ÖNEMLİ: Dinleyici, tarama başlamadan ÖNCE kurulmalı — aksi halde
    // startScan'in (timeout ile) tamamlanmasını beklerken gelen sonuçlar kaçırılır.
    late final StreamSubscription<List<ScanResult>> taramaAbonelik;
    taramaAbonelik = FlutterBluePlus.scanResults.listen((sonuclar) async {
      debugPrint("Taramada ${sonuclar.length} cihaz görüldü.");
      for (final sonuc in sonuclar) {
        debugPrint("  -> Bulunan cihaz: '${sonuc.device.platformName}'  RSSI: ${sonuc.rssi}");
        if (sonuc.device.platformName == cihazIsmi) {
          cihazBulundu = true;
          await taramaAbonelik.cancel();
          await FlutterBluePlus.stopScan();
          await _cihazaBaglan(sonuc.device);
          break;
        }
      }
    });

    // Dinleyici kurulduktan SONRA taramayı başlat (await ile bloklamıyoruz,
    // böylece kod hemen devam eder ve sonuçlar dinleyiciye akar)
    unawaited(FlutterBluePlus.startScan(timeout: const Duration(seconds: 8)));

    // 8 saniye sonra hâlâ bulunamadıysa kullanıcıyı bilgilendir
    Future.delayed(const Duration(seconds: 9), () {
      if (!cihazBulundu && mounted && _durum == "Taranıyor...") {
        setState(() => _durum = "Cihaz bulunamadı — ESP32 açık mı, yayında mı kontrol et");
        debugPrint("HATA: '$cihazIsmi' isimli cihaz 8 saniyede bulunamadı.");
      }
    });
  }

  Timer? _ilkVeriBekleTimer;
  bool _ilkVeriGeldi = false;

  Future<void> _cihazaBaglan(BluetoothDevice cihaz) async {
    final baslangic = DateTime.now();
    setState(() => _durum = "Bağlanıyor...");
    debugPrint("[${DateTime.now()}] Bağlanılıyor: ${cihaz.platformName}");
    _cihaz = cihaz;
    _ilkVeriGeldi = false;

    try {
      // Zaman aşımı ekliyoruz: bağlantı takılı kalırsa 15 saniyede hata verip
      // bekletmeden kullanıcıyı bilgilendirsin (eskiden süresiz bekliyordu).
      await cihaz.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );
      debugPrint("[${DateTime.now()}] Bağlantı kuruldu (${DateTime.now().difference(baslangic).inSeconds} sn), servisler taranıyor...");

      // Android varsayılan olarak bağlantıyı "düşük güç" moduna düşürebiliyor
      // (uzun connection interval / peripheral latency) — bu da ESP32'nin
      // saniyede gönderdiği paketlerin telefona onlarca saniye arayla,
      // toplu halde ulaşmasına neden olabilir. Bağlantı önceliğini
      // "high" isteyerek Android'den kısa aralıklı, düşük gecikmeli
      // bağlantı istiyoruz. (Sadece Android'de çalışır, iOS'ta no-op'tur.)
      try {
        await cihaz.requestConnectionPriority(
          connectionPriorityRequest: ConnectionPriority.high,
        );
        debugPrint("[${DateTime.now()}] Bağlantı önceliği 'high' olarak istendi.");
      } catch (e) {
        debugPrint("UYARI: requestConnectionPriority başarısız (muhtemelen iOS): $e");
      }

      // MTU artırma: BLE'de varsayılan MTU 23 bayttır ve bir bildirim en fazla
      // 20 bayt taşır. Bizim paketimiz ~130 karakter, yani varsayılan MTU ile
      // paket KESİLİR ve ayrıştırılamaz. ESP32 kendi tarafında setMTU(185) yapıyor
      // ama MTU pazarlığını telefonun (central) başlatması gerekir.
      try {
        await cihaz.requestMtu(247);
        debugPrint("[${DateTime.now()}] MTU isteği gönderildi (247).");
      } catch (e) {
        debugPrint("UYARI: requestMtu başarısız: $e");
      }

      // Gerçek bağlantı kopmalarını yakalamak için dinleyici.
      // Bu olmadan, BLE sessizce kopup tekrar bağlansa bile ekranda hiçbir iz kalmıyordu
      // ve "Bağlı — veri akıyor" yazısı donup kalıyordu; uzun sessizliklerin gerçek
      // sebebi kopma mı yoksa sadece paket kaybı mı, ayırt edilemiyordu.
      _baglantiDurumuAbonelik?.cancel();
      _baglantiDurumuAbonelik = cihaz.connectionState.listen((durum) {
        debugPrint("[${DateTime.now()}] BLE bağlantı durumu değişti: $durum");
        if (durum == BluetoothConnectionState.disconnected) {
          _kopmaSayaci++;
          _ilkVeriGeldi = false;
          if (mounted) {
            setState(() => _durum = "Bağlantı koptu (${_kopmaSayaci}. kez) — yeniden bağlanılıyor...");
          }
          debugPrint("UYARI: Gerçek BLE kopması tespit edildi (${_kopmaSayaci}. kez). Yeniden bağlanılıyor...");
          // Otomatik yeniden bağlan (ESP32 kopunca zaten tekrar yayına geçiyor)
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) _cihazaBaglan(cihaz);
          });
        }
      });

      final servisler = await cihaz.discoverServices();
      debugPrint("[${DateTime.now()}] Bulunan servis sayısı: ${servisler.length}");

      bool karakteristikBulundu = false;

      for (final servis in servisler) {
        debugPrint("  Servis: ${servis.uuid}");
        if (servis.uuid.toString().toLowerCase() == servisUuid.toLowerCase()) {
          for (final karak in servis.characteristics) {
            debugPrint("    Karakteristik: ${karak.uuid}");
            if (karak.uuid.toString().toLowerCase() == karakteristikUuid.toLowerCase()) {
              karakteristikBulundu = true;
              await karak.setNotifyValue(true);
              debugPrint("[${DateTime.now()}] Notify aktifleştirildi, veri bekleniyor...");
              karak.lastValueStream.listen((veri) {
                final metin = utf8.decode(veri, allowMalformed: true);
                debugPrint("[${DateTime.now()}] Gelen veri (${veri.length} bayt): $metin");

                if (!_ilkVeriGeldi) {
                  _ilkVeriGeldi = true;
                  _ilkVeriBekleTimer?.cancel();
                  if (mounted) setState(() => _durum = "Bağlı — veri akıyor");
                }
                _veriEkle(metin);
              });
            }
          }
        }
      }

      if (!karakteristikBulundu) {
        setState(() => _durum = "Servis/karakteristik UUID eşleşmedi — .ino dosyasındaki UUID'leri kontrol et");
        debugPrint("HATA: Beklenen servis/karakteristik UUID bulunamadı.");
        return;
      }

      // Notify açıldı ama henüz hiç paket gelmedi — bu gerçek durum.
      // "veri akıyor" yazısını ilk paket gelmeden GÖSTERMİYORUZ artık.
      setState(() => _durum = "Bildirim açıldı — ilk veri bekleniyor...");

      _ilkVeriBekleTimer?.cancel();
      _ilkVeriBekleTimer = Timer(const Duration(seconds: 10), () {
        if (mounted && !_ilkVeriGeldi) {
          setState(() => _durum = "10 saniyedir veri gelmiyor — ESP32 Serial Monitor'de paket akıyor mu kontrol et");
          debugPrint("UYARI: Notify açık ama 10 saniyedir hiç paket gelmedi.");
        }
      });
    } catch (e) {
      setState(() => _durum = "Bağlantı hatası: $e");
      debugPrint("HATA (bağlantı): $e");
    }
  }

  // "B1:30.55,B2:30.31,B3:30.35,B4:30.20,REF:30.13,DT1:..,DT2:..,DT3:..,DT4:..,ALARM:0/1,..." metnini ayrıştırır
  void _veriEkle(String ham) {
    try {
      final parcalar = ham.trim().split(',');
      final degerler = <String, String>{};
      for (final p in parcalar) {
        final ikili = p.split(':');
        if (ikili.length == 2) degerler[ikili[0]] = ikili[1];
      }

      final b1 = double.parse(degerler['B1']!);
      final b2 = double.parse(degerler['B2']!);
      final b3 = double.parse(degerler['B3']!);
      final b4 = double.parse(degerler['B4']!);
      final ref = double.parse(degerler['REF']!);
      final dt1 = double.parse(degerler['DT1']!);
      final dt2 = double.parse(degerler['DT2']!);
      final dt3 = double.parse(degerler['DT3']!);
      final dt4 = double.parse(degerler['DT4']!);
      final alarm = degerler['ALARM'] == '1';

      setState(() {
        _ekleVeSinirla(_b1, b1);
        _ekleVeSinirla(_b2, b2);
        _ekleVeSinirla(_b3, b3);
        _ekleVeSinirla(_b4, b4);
        _sonPaketZamani = DateTime.now();
      });

      // Her gelen paketi veritabanına kalıcı olarak kaydet (ölçüm geçmişi)
      _veritabani.olcumEkle(Olcum(
        hastaId: widget.hasta.id,
        zaman: DateTime.now().toIso8601String(),
        b1: b1, b2: b2, b3: b3, b4: b4, ref: ref,
        dt1: dt1, dt2: dt2, dt3: dt3, dt4: dt4,
        alarm: alarm,
      ));
    } catch (_) {
      // bozuk/eksik paket geldiyse yok say
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
                child: ElevatedButton(onPressed: _baglan, child: const Text('Cihaza Bağlan')),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}