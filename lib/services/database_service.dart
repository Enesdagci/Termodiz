import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/hasta.dart';

// Uygulama genelinde tek bir veritabanı bağlantısı kullanmak için Singleton deseni
class VeritabaniServisi {
  static final VeritabaniServisi _instance = VeritabaniServisi._internal();
  factory VeritabaniServisi() => _instance;
  VeritabaniServisi._internal();

  static Database? _db;

  Future<Database> get veritabani async {
    if (_db != null) return _db!;
    _db = await _veritabaniniAc();
    return _db!;
  }

  Future<Database> _veritabaniniAc() async {
    final yol = await getDatabasesPath();
    final dosyaYolu = join(yol, 'diz_sensor.db');

    return await openDatabase(
      dosyaYolu,
      version: 1,
      onCreate: (db, versiyon) async {
        // Hastalar tablosu
        await db.execute('''
          CREATE TABLE hastalar (
            id TEXT PRIMARY KEY,
            ad TEXT NOT NULL,
            kayitTarihi TEXT NOT NULL,
            referansSicaklik REAL NOT NULL DEFAULT 0
          )
        ''');

        // Ölçümler tablosu (her hastanın geçmiş ölçüm kayıtları)
        await db.execute('''
          CREATE TABLE olcumler (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            hastaId TEXT NOT NULL,
            zaman TEXT NOT NULL,
            b1 REAL, b2 REAL, b3 REAL, b4 REAL, ref REAL,
            dt1 REAL, dt2 REAL, dt3 REAL, dt4 REAL,
            alarm INTEGER,
            FOREIGN KEY (hastaId) REFERENCES hastalar (id) ON DELETE CASCADE
          )
        ''');
      },
    );
  }

  // ---------------- HASTA İŞLEMLERİ ----------------

  Future<void> hastaEkle(Hasta hasta) async {
    final db = await veritabani;
    await db.insert(
      'hastalar',
      hasta.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> hastaSil(String id) async {
    final db = await veritabani;
    // İlişkili ölçümleri de sil
    await db.delete('olcumler', where: 'hastaId = ?', whereArgs: [id]);
    await db.delete('hastalar', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Hasta>> tumHastalariGetir() async {
    final db = await veritabani;
    final sonuc = await db.query('hastalar', orderBy: 'kayitTarihi DESC');
    return sonuc.map((satir) => Hasta.fromMap(satir)).toList();
  }

  // ---------------- ÖLÇÜM İŞLEMLERİ ----------------

  Future<void> olcumEkle(Olcum olcum) async {
    final db = await veritabani;
    await db.insert('olcumler', olcum.toMap());
  }

  Future<List<Olcum>> hastaOlcumleriGetir(String hastaId) async {
    final db = await veritabani;
    final sonuc = await db.query(
      'olcumler',
      where: 'hastaId = ?',
      whereArgs: [hastaId],
      orderBy: 'zaman ASC',
    );
    return sonuc.map((satir) => Olcum.fromMap(satir)).toList();
  }

  // Bir hastanın tüm ölçüm geçmişini siler (hasta kaydı silinmez).
  // Yeni bir test turuna temiz başlamak için kullanılır.
  Future<void> hastaOlcumleriniSil(String hastaId) async {
    final db = await veritabani;
    await db.delete('olcumler', where: 'hastaId = ?', whereArgs: [hastaId]);
  }

  Future<Olcum?> sonOlcumuGetir(String hastaId) async {
    final db = await veritabani;
    final sonuc = await db.query(
      'olcumler',
      where: 'hastaId = ?',
      whereArgs: [hastaId],
      orderBy: 'zaman DESC',
      limit: 1,
    );
    if (sonuc.isEmpty) return null;
    return Olcum.fromMap(sonuc.first);
  }
}