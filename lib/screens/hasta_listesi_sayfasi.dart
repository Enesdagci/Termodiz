import 'package:flutter/material.dart';
import '../models/hasta.dart';
import '../services/database_service.dart';
import 'grafik_sayfasi.dart';

class HastaListesiSayfasi extends StatefulWidget {
  const HastaListesiSayfasi({super.key});

  @override
  State<HastaListesiSayfasi> createState() => _HastaListesiSayfasiState();
}

class _HastaListesiSayfasiState extends State<HastaListesiSayfasi> {
  final VeritabaniServisi _veritabani = VeritabaniServisi();
  List<Hasta> _hastalar = [];
  bool _yukleniyor = true;

  @override
  void initState() {
    super.initState();
    _hastalariYukle();
  }

  Future<void> _hastalariYukle() async {
    setState(() => _yukleniyor = true);
    final liste = await _veritabani.tumHastalariGetir();
    setState(() {
      _hastalar = liste;
      _yukleniyor = false;
    });
  }

  Future<void> _hastaEkle(String ad) async {
    final yeniHasta = Hasta(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      ad: ad,
      kayitTarihi: DateTime.now().toIso8601String(),
    );
    await _veritabani.hastaEkle(yeniHasta);
    await _hastalariYukle();
  }

  Future<void> _hastaSil(String id) async {
    await _veritabani.hastaSil(id);
    await _hastalariYukle();
  }

  void _hastaEkleDiyalogGoster() {
    final denetleyici = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Yeni Hasta Ekle'),
          content: TextField(
            controller: denetleyici,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Hasta adı soyadı'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('İptal'),
            ),
            ElevatedButton(
              onPressed: () {
                final ad = denetleyici.text.trim();
                if (ad.isNotEmpty) {
                  _hastaEkle(ad);
                  Navigator.pop(context);
                }
              },
              child: const Text('Ekle'),
            ),
          ],
        );
      },
    );
  }

  void _hastaSilOnayGoster(Hasta hasta) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Hastayı Sil'),
          content: Text('${hasta.ad} adlı hastayı ve tüm ölçüm geçmişini silmek istediğine emin misin?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Vazgeç'),
            ),
            TextButton(
              onPressed: () {
                _hastaSil(hasta.id);
                Navigator.pop(context);
              },
              child: const Text('Sil', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  String _tarihiBicimlendir(String isoTarih) {
    final tarih = DateTime.tryParse(isoTarih);
    if (tarih == null) return isoTarih;
    return '${tarih.day.toString().padLeft(2, '0')}.${tarih.month.toString().padLeft(2, '0')}.${tarih.year}  '
        '${tarih.hour.toString().padLeft(2, '0')}:${tarih.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hastalar')),
      body: _yukleniyor
          ? const Center(child: CircularProgressIndicator())
          : _hastalar.isEmpty
              ? const Center(child: Text('Henüz kayıtlı hasta yok. "+" ile ekleyebilirsin.'))
              : ListView.builder(
                  itemCount: _hastalar.length,
                  itemBuilder: (context, index) {
                    final hasta = _hastalar[index];
                    return Dismissible(
                      key: ValueKey(hasta.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      confirmDismiss: (_) async {
                        _hastaSilOnayGoster(hasta);
                        return false; // silme işlemini diyalog kontrol ediyor
                      },
                      child: ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.person)),
                        title: Text(hasta.ad),
                        subtitle: Text('Kayıt: ${_tarihiBicimlendir(hasta.kayitTarihi)}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => GrafikSayfasi(hasta: hasta),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _hastaEkleDiyalogGoster,
        child: const Icon(Icons.add),
      ),
    );
  }
}