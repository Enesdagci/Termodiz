// Hasta verisini temsil eden model sınıfı.
// Veritabanı (sqflite) ile uygulama arasında veri taşımak için kullanılır.
class Hasta {
  final String id;
  final String ad;
  final String kayitTarihi;
  final double referansSicaklik;

  Hasta({
    required this.id,
    required this.ad,
    required this.kayitTarihi,
    this.referansSicaklik = 0.0,
  });

  // Veritabanına yazarken kullanılacak Map formatı
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'ad': ad,
      'kayitTarihi': kayitTarihi,
      'referansSicaklik': referansSicaklik,
    };
  }

  // Veritabanından okurken Map -> Hasta dönüşümü
  factory Hasta.fromMap(Map<String, dynamic> map) {
    return Hasta(
      id: map['id'] as String,
      ad: map['ad'] as String,
      kayitTarihi: map['kayitTarihi'] as String,
      referansSicaklik: (map['referansSicaklik'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

// Tek bir ölçüm kaydını temsil eden model sınıfı (geçmiş ölçümler için)
class Olcum {
  final int? id;
  final String hastaId;
  final String zaman;
  final double b1, b2, b3, b4, ref;
  final double dt1, dt2, dt3, dt4;
  final bool alarm;

  Olcum({
    this.id,
    required this.hastaId,
    required this.zaman,
    required this.b1,
    required this.b2,
    required this.b3,
    required this.b4,
    required this.ref,
    required this.dt1,
    required this.dt2,
    required this.dt3,
    required this.dt4,
    required this.alarm,
  });

  Map<String, dynamic> toMap() {
    return {
      'hastaId': hastaId,
      'zaman': zaman,
      'b1': b1,
      'b2': b2,
      'b3': b3,
      'b4': b4,
      'ref': ref,
      'dt1': dt1,
      'dt2': dt2,
      'dt3': dt3,
      'dt4': dt4,
      'alarm': alarm ? 1 : 0,
    };
  }

  factory Olcum.fromMap(Map<String, dynamic> map) {
    return Olcum(
      id: map['id'] as int?,
      hastaId: map['hastaId'] as String,
      zaman: map['zaman'] as String,
      b1: (map['b1'] as num).toDouble(),
      b2: (map['b2'] as num).toDouble(),
      b3: (map['b3'] as num).toDouble(),
      b4: (map['b4'] as num).toDouble(),
      ref: (map['ref'] as num).toDouble(),
      dt1: (map['dt1'] as num).toDouble(),
      dt2: (map['dt2'] as num).toDouble(),
      dt3: (map['dt3'] as num).toDouble(),
      dt4: (map['dt4'] as num).toDouble(),
      alarm: (map['alarm'] as int) == 1,
    );
  }
}