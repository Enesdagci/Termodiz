import 'dart:io';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/hasta.dart';
import '../services/database_service.dart';

/// Hastanın veritabanına kaydedilmiş TÜM geçmiş ölçümlerini gösteren ekran.
/// Canlı BLE akışından bağımsız çalışır: cihaz bağlı olmasa bile,
/// daha önce kaydedilmiş ölçümler buradan incelenebilir.
class GecmisSayfasi extends StatefulWidget {
  final Hasta hasta;
  const GecmisSayfasi({super.key, required this.hasta});

  @override
  State<GecmisSayfasi> createState() => _GecmisSayfasiState();
}

class _GecmisSayfasiState extends State<GecmisSayfasi> {
  final VeritabaniServisi _veritabani = VeritabaniServisi();

  List<Olcum> _olcumler = [];
  bool _yukleniyor = true;

  // false -> bölge sıcaklıkları (B1-B4), true -> sağlıklı dokuya göre fark (DT1-DT4)
  bool _farkGoster = false;

  @override
  void initState() {
    super.initState();
    _olcumleriYukle();
  }

  Future<void> _olcumleriYukle() async {
    setState(() => _yukleniyor = true);
    final liste = await _veritabani.hastaOlcumleriGetir(widget.hasta.id);
    if (!mounted) return;
    setState(() {
      _olcumler = liste;
      _yukleniyor = false;
    });
  }

  Future<void> _gecmisiTemizle() async {
    final onay = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Geçmişi Temizle'),
        content: Text(
          '${widget.hasta.ad} adlı hastanın kayıtlı ${_olcumler.length} ölçümünün tamamı silinecek. Emin misin?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sil', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (onay == true) {
      await _veritabani.hastaOlcumleriniSil(widget.hasta.id);
      await _olcumleriYukle();
    }
  }

  // Tüm ölçüm geçmişini CSV dosyası olarak dışa aktarır ve paylaşım
  // menüsünü açar (e-posta, dosyalar, bilgisayara aktarma vb. için).
  Future<void> _disaAktar() async {
    if (_olcumler.isEmpty) return;

    final buffer = StringBuffer();
    buffer.writeln('id,hastaId,zaman,b1,b2,b3,b4,ref,dt1,dt2,dt3,dt4,alarm');
    for (final o in _olcumler) {
      buffer.writeln(
        '${o.id ?? ''},${o.hastaId},${o.zaman},'
        '${o.b1},${o.b2},${o.b3},${o.b4},${o.ref},'
        '${o.dt1},${o.dt2},${o.dt3},${o.dt4},${o.alarm ? 1 : 0}',
      );
    }

    final dizin = await getTemporaryDirectory();
    final guvenliAd = widget.hasta.ad.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    final dosyaAdi = 'olcumler_${guvenliAd}_${DateTime.now().millisecondsSinceEpoch}.csv';
    final dosya = File('${dizin.path}/$dosyaAdi');
    await dosya.writeAsString(buffer.toString());

    if (!mounted) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(dosya.path)],
        text: '${widget.hasta.ad} — Ölçüm Geçmişi (${_olcumler.length} kayıt)',
      ),
    );
  }

  // ---------------- Yardımcı hesaplamalar ----------------

  List<double> _seri(int bolgeNo) {
    return _olcumler.map((o) {
      if (_farkGoster) {
        switch (bolgeNo) {
          case 1:
            return o.dt1;
          case 2:
            return o.dt2;
          case 3:
            return o.dt3;
          default:
            return o.dt4;
        }
      } else {
        switch (bolgeNo) {
          case 1:
            return o.b1;
          case 2:
            return o.b2;
          case 3:
            return o.b3;
          default:
            return o.b4;
        }
      }
    }).toList();
  }

  // Ölçüm sayısı çok arttığında (uzun süreli izlemede saatte binlerce satır
  // birikebiliyor) grafiğe TÜMÜNÜ çizmek performansı düşürür. Bu yüzden
  // grafik için en fazla ~400 noktaya eşit aralıklarla örnekleme yapıyoruz.
  // ÖNEMLİ: örnekleme yalnızca grafik çizimini etkiler — veritabanındaki
  // hiçbir kayıt silinmez, özet ve liste bölümünde tüm ölçümler görünür.
  static const int _maxGrafikNoktasi = 400;

  List<int> _ornekIndeksleri() {
    final n = _olcumler.length;
    if (n <= _maxGrafikNoktasi) return List.generate(n, (i) => i);
    final adim = n / _maxGrafikNoktasi;
    final indeksler = <int>{};
    for (int i = 0; i < _maxGrafikNoktasi; i++) {
      indeksler.add((i * adim).floor());
    }
    indeksler.add(n - 1); // son noktayı her zaman dahil et
    final sonuc = indeksler.toList()..sort();
    return sonuc;
  }

  List<FlSpot> _spotlar(List<double> liste, List<int> indeksler) {
    return List.generate(indeksler.length, (i) => FlSpot(i.toDouble(), liste[indeksler[i]]));
  }

  List<double> _tumDegerler() {
    return [..._seri(1), ..._seri(2), ..._seri(3), ..._seri(4)];
  }

  double _yMin() {
    final degerler = _tumDegerler();
    if (degerler.isEmpty) return 0;
    final enKucuk = degerler.reduce((a, b) => a < b ? a : b);
    return (enKucuk - 0.5).floorToDouble();
  }

  double _yMax() {
    final degerler = _tumDegerler();
    if (degerler.isEmpty) return 40;
    final enBuyuk = degerler.reduce((a, b) => a > b ? a : b);
    return (enBuyuk + 0.5).ceilToDouble();
  }

  double _yAralik() {
    final aralik = _yMax() - _yMin();
    if (aralik <= 0) return 1;
    final adim = (aralik / 6);
    return adim < 0.5 ? 0.5 : adim.ceilToDouble();
  }

  String _saatBicimlendir(String isoTarih) {
    final tarih = DateTime.tryParse(isoTarih);
    if (tarih == null) return isoTarih;
    return '${tarih.hour.toString().padLeft(2, '0')}:'
        '${tarih.minute.toString().padLeft(2, '0')}:'
        '${tarih.second.toString().padLeft(2, '0')}';
  }

  String _tarihSaatBicimlendir(String isoTarih) {
    final tarih = DateTime.tryParse(isoTarih);
    if (tarih == null) return isoTarih;
    return '${tarih.day.toString().padLeft(2, '0')}.'
        '${tarih.month.toString().padLeft(2, '0')}.${tarih.year}  '
        '${tarih.hour.toString().padLeft(2, '0')}:'
        '${tarih.minute.toString().padLeft(2, '0')}';
  }

  // ---------------- Arayüz ----------------

  Widget _ozetKutusu() {
    final ilk = _olcumler.first;
    final son = _olcumler.last;
    final alarmliSayisi = _olcumler.where((o) => o.alarm).length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Toplam ölçüm: ${_olcumler.length}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('İlk kayıt: ${_tarihSaatBicimlendir(ilk.zaman)}',
              style: const TextStyle(fontSize: 12)),
          Text('Son kayıt: ${_tarihSaatBicimlendir(son.zaman)}',
              style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Text(
            alarmliSayisi > 0
                ? 'Alarm veren ölçüm: $alarmliSayisi'
                : 'Alarm veren ölçüm yok',
            style: TextStyle(
              fontSize: 12,
              color: alarmliSayisi > 0 ? Colors.red : Colors.green.shade700,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _gosterge(Color renk, String etiket) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 14, height: 3, color: renk),
        const SizedBox(width: 4),
        Text(etiket, style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  Widget _grafikCiz() {
    final indeksler = _ornekIndeksleri();
    return LineChart(
      LineChartData(
        minY: _yMin(),
        maxY: _yMax(),
        gridData: const FlGridData(show: true),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              interval: _yAralik(),
              getTitlesWidget: (deger, meta) => Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  deger.toStringAsFixed(1),
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ),
          ),
          bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        lineBarsData: [
          LineChartBarData(
              spots: _spotlar(_seri(1), indeksler),
              color: Colors.blue,
              barWidth: 2,
              dotData: const FlDotData(show: false)),
          LineChartBarData(
              spots: _spotlar(_seri(2), indeksler),
              color: Colors.green,
              barWidth: 2,
              dotData: const FlDotData(show: false)),
          LineChartBarData(
              spots: _spotlar(_seri(3), indeksler),
              color: Colors.orange,
              barWidth: 2,
              dotData: const FlDotData(show: false)),
          LineChartBarData(
              spots: _spotlar(_seri(4), indeksler),
              color: Colors.red,
              barWidth: 2,
              dotData: const FlDotData(show: false)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.hasta.ad} — Geçmiş'),
        actions: [
          IconButton(
            tooltip: 'Yenile',
            onPressed: _olcumleriYukle,
            icon: const Icon(Icons.refresh),
          ),
          if (_olcumler.isNotEmpty)
            IconButton(
              tooltip: 'CSV olarak dışa aktar',
              onPressed: _disaAktar,
              icon: const Icon(Icons.ios_share),
            ),
          if (_olcumler.isNotEmpty)
            IconButton(
              tooltip: 'Geçmişi temizle',
              onPressed: _gecmisiTemizle,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: _yukleniyor
          ? const Center(child: CircularProgressIndicator())
          : _olcumler.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Bu hasta için henüz kayıtlı ölçüm yok.\n'
                      'Cihaza bağlanıp veri aldığında ölçümler otomatik olarak buraya kaydedilir.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _ozetKutusu(),
                      const SizedBox(height: 12),

                      // Görünüm seçici: ham sıcaklık mı, fark mı
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: false,
                            label: Text('Sıcaklık', style: TextStyle(fontSize: 12)),
                          ),
                          ButtonSegment(
                            value: true,
                            label: Text('Fark (ΔT)', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                        selected: {_farkGoster},
                        onSelectionChanged: (secim) {
                          setState(() => _farkGoster = secim.first);
                        },
                      ),
                      const SizedBox(height: 8),

                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          _gosterge(Colors.blue, 'Bölge 1 (Üst-Sağ)'),
                          _gosterge(Colors.green, 'Bölge 2 (Üst-Sol)'),
                          _gosterge(Colors.orange, 'Bölge 3 (Alt-Sağ)'),
                          _gosterge(Colors.red, 'Bölge 4 (Alt-Sol)'),
                        ],
                      ),
                      const SizedBox(height: 8),

                      Builder(builder: (context) {
                        final indeksler = _ornekIndeksleri();
                        if (indeksler.length < _olcumler.length) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              '${_olcumler.length} ölçümden ${indeksler.length} nokta gösteriliyor (performans için örneklendi)',
                              style: const TextStyle(fontSize: 10, color: Colors.grey, fontStyle: FontStyle.italic),
                            ),
                          );
                        }
                        return const SizedBox.shrink();
                      }),

                      SizedBox(
                        height: 240,
                        child: _grafikCiz(),
                      ),

                      // X ekseni yerine: ilk ve son kaydın saati
                      Padding(
                        padding: const EdgeInsets.only(left: 44, top: 2),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_saatBicimlendir(_olcumler.first.zaman),
                                style: const TextStyle(fontSize: 10, color: Colors.grey)),
                            Text(_saatBicimlendir(_olcumler.last.zaman),
                                style: const TextStyle(fontSize: 10, color: Colors.grey)),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),
                      const Text('Kayıtlar (en yeniden eskiye)',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),

                      Expanded(
                        child: ListView.builder(
                          itemCount: _olcumler.length,
                          itemBuilder: (context, index) {
                            // Listeyi ters sırada göster (en yeni en üstte)
                            final olcum = _olcumler[_olcumler.length - 1 - index];
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                olcum.alarm ? Icons.warning_amber : Icons.check_circle_outline,
                                color: olcum.alarm ? Colors.red : Colors.green,
                                size: 20,
                              ),
                              title: Text(
                                'B1 ${olcum.b1.toStringAsFixed(2)}  '
                                'B2 ${olcum.b2.toStringAsFixed(2)}  '
                                'B3 ${olcum.b3.toStringAsFixed(2)}  '
                                'B4 ${olcum.b4.toStringAsFixed(2)}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              subtitle: Text(
                                '${_tarihSaatBicimlendir(olcum.zaman)}   REF ${olcum.ref.toStringAsFixed(2)}',
                                style: const TextStyle(fontSize: 11),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}