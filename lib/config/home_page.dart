import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'cloud_database.dart';
import 'print_receipt.dart';

const int HARGA_PER_METER = 2500;
const int ABODEMEN = 5000;

const List<String> statusOptions = [
  'SUDAH LUNAS',
  'KURANG',
  'KELEBIHAN BAYAR',
];

String formatRupiah(int value) {
  final negative = value < 0;
  final number = value.abs().toString();
  String result = '';

  for (int i = 0; i < number.length; i++) {
    if (i > 0 && (number.length - i) % 3 == 0) {
      result += '.';
    }
    result += number[i];
  }

  return '${negative ? '-' : ''}Rp $result';
}

String monthKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}';

String monthName(String key) {
  final parts = key.split('-');
  if (parts.length != 2) return key;

  final month = int.tryParse(parts[1]) ?? 1;
  final year = parts[0];

  const months = [
    'Januari',
    'Februari',
    'Maret',
    'April',
    'Mei',
    'Juni',
    'Juli',
    'Agustus',
    'September',
    'Oktober',
    'November',
    'Desember',
  ];

  if (month < 1 || month > 12) return key;
  return '${months[month - 1]} $year';
}

String formatDate(DateTime date) {
  const months = [
    'Januari',
    'Februari',
    'Maret',
    'April',
    'Mei',
    'Juni',
    'Juli',
    'Agustus',
    'September',
    'Oktober',
    'November',
    'Desember',
  ];

  return '${date.day} ${months[date.month - 1]} ${date.year}';
}

DateTime dateFromMonth(String key) {
  final parts = key.split('-');
  final year = int.tryParse(parts.first) ?? DateTime.now().year;
  final month = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 1;
  return DateTime(year, month);
}

String statusColorKey(String status) => status.toUpperCase();

class WaterRecord {
  String month;
  int previousMeter;
  int currentMeter;
  int usage;
  int waterPrice;
  int monthlyFee;
  int total;
  int paidAmount;
  int creditUsed;
  String status;
  String recordedAt;

  WaterRecord({
    required this.month,
    required this.previousMeter,
    required this.currentMeter,
    required this.usage,
    required this.waterPrice,
    required this.monthlyFee,
    required this.total,
    required this.paidAmount,
    required this.creditUsed,
    required this.status,
    required this.recordedAt,
  });

  DateTime get recordedDate =>
      DateTime.tryParse(recordedAt) ?? DateTime.now();

  int get billAfterCredit {
    final value = total - creditUsed;
    return value < 0 ? 0 : value;
  }

  int get remainingAmount {
    final value = billAfterCredit - paidAmount;
    return value > 0 ? value : 0;
  }

  int get overpaymentAmount {
    final value = paidAmount - billAfterCredit;
    return value > 0 ? value : 0;
  }

  Map<String, dynamic> toJson() => {
        'month': month,
        'previousMeter': previousMeter,
        'currentMeter': currentMeter,
        'usage': usage,
        'waterPrice': waterPrice,
        'monthlyFee': monthlyFee,
        'total': total,
        'paidAmount': paidAmount,
        'creditUsed': creditUsed,
        'status': status,
        'recordedAt': recordedAt,
      };

  factory WaterRecord.fromJson(Map<String, dynamic> json) {
    final total = (json['total'] as num?)?.toInt() ?? 0;

    // Kompatibel dengan data lama:
    // kalau data lama belum punya kolom pembayaran, anggap sudah lunas
    // supaya data lama tidak tiba-tiba berubah menjadi "KURANG".
    final hasPaymentData = json.containsKey('paidAmount');
    final paid = hasPaymentData
        ? ((json['paidAmount'] as num?)?.toInt() ?? 0)
        : total;

    final creditUsed = (json['creditUsed'] as num?)?.toInt() ?? 0;

    String status;
    if (json['status'] != null) {
      status = json['status'].toString();
    } else {
      final due = total - creditUsed;
      if (paid > due) {
        status = 'KELEBIHAN BAYAR';
      } else if (paid == due) {
        status = 'SUDAH LUNAS';
      } else {
        status = 'KURANG';
      }
    }

    return WaterRecord(
      month: json['month']?.toString() ?? '',
      previousMeter: (json['previousMeter'] as num?)?.toInt() ?? 0,
      currentMeter: (json['currentMeter'] as num?)?.toInt() ?? 0,
      usage: (json['usage'] as num?)?.toInt() ?? 0,
      waterPrice: (json['waterPrice'] as num?)?.toInt() ?? 0,
      monthlyFee: (json['monthlyFee'] as num?)?.toInt() ?? ABODEMEN,
      total: total,
      paidAmount: paid,
      creditUsed: creditUsed,
      status: status,
      recordedAt: json['recordedAt']?.toString() ??
          DateTime.now().toIso8601String(),
    );
  }
}

class Resident {
  String id;
  String name;
  String rt;
  String? photoPath;
  List<WaterRecord> records;

  Resident({
    required this.id,
    required this.name,
    required this.rt,
    this.photoPath,
    required this.records,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'rt': rt,
        'photoPath': photoPath,
        'records': records.map((e) => e.toJson()).toList(),
      };

  factory Resident.fromJson(Map<String, dynamic> json) {
    final rawRecords = json['records'] as List? ?? [];
    return Resident(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      rt: json['rt']?.toString() ?? '',
      photoPath: json['photoPath']?.toString(),
      records: rawRecords
          .map((e) => WaterRecord.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

class HomePage extends StatefulWidget {
  final VoidCallback? onDataChanged;

  const HomePage({
    super.key,
    this.onDataChanged,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Resident> residents = [];
  bool loading = true;
  String selectedRT = 'Semua';
  final searchController = TextEditingController();
  StreamSubscription<void>? _changesSub;

  String get currentMonth => monthKey(DateTime.now());

  @override
  void initState() {
    super.initState();
    loadData();
    searchController.addListener(_searchChanged);
    _changesSub = CloudDatabase.changes.listen((_) {
      if (mounted) loadData();
    });
  }

  void _searchChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    searchController.removeListener(_searchChanged);
    searchController.dispose();
    super.dispose();
  }

  Future<void> loadData() async {
    final data = await CloudDatabase.getResidents();
    if (!mounted) return;

    setState(() {
      residents = data;
      loading = false;

      if (!['Semua', ...rtListWithoutAll].contains(selectedRT)) {
        selectedRT = 'Semua';
      }
    });
  }

  List<String> get rtListWithoutAll {
    final set = <String>{};
    for (final resident in residents) {
      if (resident.rt.trim().isNotEmpty) set.add(resident.rt);
    }
    final list = set.toList()..sort();
    return list;
  }

  List<String> get rtList => ['Semua', ...rtListWithoutAll];

  List<Resident> get filteredResidents {
    final q = searchController.text.trim().toLowerCase();

    return residents.where((resident) {
      final rtMatch = selectedRT == 'Semua' || resident.rt == selectedRT;
      final searchMatch = q.isEmpty ||
          resident.name.toLowerCase().contains(q) ||
          resident.rt.toLowerCase().contains(q);
      return rtMatch && searchMatch;
    }).toList();
  }

  int get recordedThisMonth => residents
      .where((r) => r.records.any((x) => x.month == currentMonth))
      .length;

  Future<void> addResident() async {
    final result = await showModalBottomSheet<Resident>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AddResidentSheet(),
    );

    if (result == null) return;

    setState(() => residents.add(result));
    await CloudDatabase.saveResident(result);
    widget.onDataChanged?.call();
  }

  Future<void> openResident(Resident resident) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ResidentDetailPage(
          resident: resident,
          allResidents: residents,
        ),
      ),
    );

    await loadData();
    widget.onDataChanged?.call();
  }

  Future<void> deleteResident(Resident resident) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hapus warga?'),
        content: Text(
          'Semua data ${resident.name}, termasuk riwayat meter, akan dihapus.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() {
      residents.removeWhere((e) => e.id == resident.id);
    });
    await CloudDatabase.deleteResident(resident);
    widget.onDataChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SafeArea(
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final data = filteredResidents;

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: loadData,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Data Air Warga',
                                style: TextStyle(
                                  fontSize: 27,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF12343B),
                                ),
                              ),
                              SizedBox(height: 5),
                              Text(
                                'Kelola meter air dengan lebih mudah',
                                style: TextStyle(color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        FloatingActionButton(
                          heroTag: 'addWarga',
                          mini: true,
                          onPressed: addResident,
                          child: const Icon(Icons.add),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    CurrentMonthSummary(
                      month: monthName(currentMonth),
                      totalResidents: residents.length,
                      recorded: recordedThisMonth,
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  controller: searchController,
                  decoration: const InputDecoration(
                    hintText: 'Cari nama atau RT...',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 14)),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 42,
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  scrollDirection: Axis.horizontal,
                  children: rtList.map((rt) {
                    final selected = selectedRT == rt;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(
                          rt == 'Semua' ? 'Semua RT' : 'RT $rt',
                        ),
                        selected: selected,
                        onSelected: (_) =>
                            setState(() => selectedRT = rt),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 14)),
            if (data.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyResident(),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
                sliver: SliverList.separated(
                  itemCount: data.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, index) {
                    final resident = data[index];
                    return ResidentCard(
                      resident: resident,
                      currentMonth: currentMonth,
                      onTap: () => openResident(resident),
                      onDelete: () => deleteResident(resident),
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

class CurrentMonthSummary extends StatelessWidget {
  final String month;
  final int totalResidents;
  final int recorded;

  const CurrentMonthSummary({
    super.key,
    required this.month,
    required this.totalResidents,
    required this.recorded,
  });

  @override
  Widget build(BuildContext context) {
    final remaining = totalResidents - recorded;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF12343B), Color(0xFF087E8B)],
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 25,
            backgroundColor: Color(0x33FFFFFF),
            child: Icon(Icons.calendar_month, color: Colors.white),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  month,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$recorded dari $totalResidents warga sudah dicatat',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$remaining',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Text(
                'belum',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class ResidentCard extends StatelessWidget {
  final Resident resident;
  final String currentMonth;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const ResidentCard({
    super.key,
    required this.resident,
    required this.currentMonth,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final record = resident.records.where(
      (r) => r.month == currentMonth,
    ).firstOrNull;

    final done = record != null;

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HousePhoto(path: resident.photoPath, size: 66),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      resident.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'RT ${resident.rt}',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 9),
                    StatusBadge(
                      done: done,
                      month: currentMonth,
                    ),
                    if (done) ...[
                      const SizedBox(height: 7),
                      Text(
                        '${record!.usage} m³ • ${formatRupiah(record.total)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF087E8B),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        record.status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: statusTextColor(record.status),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                onSelected: (value) {
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Hapus warga'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color statusTextColor(String status) {
  switch (statusColorKey(status)) {
    case 'SUDAH LUNAS':
      return Colors.green.shade700;
    case 'KELEBIHAN BAYAR':
      return Colors.blue.shade700;
    case 'KURANG':
      return Colors.orange.shade800;
    default:
      return Colors.grey.shade700;
  }
}

Color statusBackgroundColor(String status) {
  switch (statusColorKey(status)) {
    case 'SUDAH LUNAS':
      return const Color(0xFFE8F7EE);
    case 'KELEBIHAN BAYAR':
      return const Color(0xFFE8F2FF);
    case 'KURANG':
      return const Color(0xFFFFF3E0);
    default:
      return Colors.grey.shade100;
  }
}

class StatusBadge extends StatelessWidget {
  final bool done;
  final String month;

  const StatusBadge({
    super.key,
    required this.done,
    required this.month,
  });

  @override
  Widget build(BuildContext context) {
    final text = done
        ? 'Sudah dicatat — ${monthName(month)}'
        : 'Belum dicatat — ${monthName(month)}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: done
            ? const Color(0xFFE8F7EE)
            : const Color(0xFFFFF0F0),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: done ? Colors.green.shade700 : Colors.red.shade700,
        ),
      ),
    );
  }
}

class HousePhoto extends StatelessWidget {
  final String? path;
  final double size;

  const HousePhoto({
    super.key,
    required this.path,
    required this.size,
  });

  Widget _placeholder() => const Icon(
        Icons.home_outlined,
        size: 30,
        color: Color(0xFF087E8B),
      );

  Widget _buildImage() {
    final p = path;

    if (p == null || p.isEmpty) return _placeholder();

    // Foto yang baru diambil dan belum terunggah (file di HP ini).
    if (p.startsWith('/')) {
      if (!File(p).existsSync()) return _placeholder();

      return Image.file(
        File(p),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(
          Icons.home_outlined,
          color: Color(0xFF087E8B),
        ),
      );
    }

    // Foto yang sudah ada di Supabase Storage (bucket private).
    return FutureBuilder<String?>(
      future: CloudDatabase.photoUrl(p),
      builder: (context, snapshot) {
        final url = snapshot.data;
        if (url == null) return _placeholder();

        return Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(
            Icons.home_outlined,
            color: Color(0xFF087E8B),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Container(
        width: size,
        height: size,
        color: const Color(0xFFE1F2F4),
        child: _buildImage(),
      ),
    );
  }
}

class EmptyResident extends StatelessWidget {
  const EmptyResident({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.people_outline,
              size: 75,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 16),
            const Text(
              'Belum ada warga',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tambahkan profil warga untuk mulai mencatat meter air.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}

class AddResidentSheet extends StatefulWidget {
  const AddResidentSheet({super.key});

  @override
  State<AddResidentSheet> createState() => _AddResidentSheetState();
}

class _AddResidentSheetState extends State<AddResidentSheet> {
  final nameController = TextEditingController();
  final rtController = TextEditingController();
  String? photoPath;

  @override
  void dispose() {
    nameController.dispose();
    rtController.dispose();
    super.dispose();
  }

  Future<void> takePhoto() async {
    try {
      final image = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 75,
        maxWidth: 1200,
      );

      if (image == null) return;

      final directory = await getApplicationDocumentsDirectory();
      final target =
          '${directory.path}/rumah_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final copied = await File(image.path).copy(target);

      if (!mounted) return;
      setState(() => photoPath = copied.path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kamera tidak bisa dibuka.')),
      );
    }
  }

  void saveResident() {
    final name = nameController.text.trim();
    final rt = rtController.text.trim();

    if (name.isEmpty || rt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nama dan RT wajib diisi.')),
      );
      return;
    }

    Navigator.pop(
      context,
      Resident(
        id: CloudDatabase.newId(),
        name: name,
        rt: rt,
        photoPath: photoPath,
        records: [],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .90,
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 25),
        decoration: const BoxDecoration(
          color: Color(0xFFF5F8FA),
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(30),
          ),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            keyboardDismissBehavior:
                ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SheetHandle(),
                const SizedBox(height: 20),
                const Text(
                  'Tambah Warga',
                  style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Masukkan identitas warga dan foto rumah jika diperlukan.',
                  style: TextStyle(color: Colors.grey.shade600),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Nama warga',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: rtController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Nomor RT',
                    prefixIcon: Icon(Icons.location_on_outlined),
                  ),
                ),
                const SizedBox(height: 15),
                if (photoPath != null)
                  Center(child: HousePhoto(path: photoPath, size: 120)),
                if (photoPath != null) const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: takePhoto,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(55),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: Text(
                    photoPath == null
                        ? 'Foto Rumah (Opsional)'
                        : 'Ambil Ulang Foto',
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: saveResident,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(55),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text('Simpan Warga'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ResidentDetailPage extends StatefulWidget {
  final Resident resident;
  final List<Resident> allResidents;

  const ResidentDetailPage({
    super.key,
    required this.resident,
    required this.allResidents,
  });

  @override
  State<ResidentDetailPage> createState() => _ResidentDetailPageState();
}

class _ResidentDetailPageState extends State<ResidentDetailPage> {
  late Resident resident;

  String get currentMonth => monthKey(DateTime.now());

  @override
  void initState() {
    super.initState();
    resident = widget.resident;
  }

  Future<void> saveAll() async {
    await CloudDatabase.saveResident(resident);
  }

  Future<void> addWaterRecord() async {
    final result = await showModalBottomSheet<WaterRecord>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddWaterRecordSheet(resident: resident),
    );

    if (result == null) return;

    setState(() {
      resident.records.removeWhere((r) => r.month == result.month);
      resident.records.add(result);
      resident.records.sort((a, b) => a.month.compareTo(b.month));
    });

    await saveAll();
  }


  Future<void> changeResidentPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Pilih dari galeri'),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: const Text('Ambil foto baru'),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
        ]),
      ),
    );
    if (source == null) return;
    try {
      final image = await ImagePicker().pickImage(
        source: source, imageQuality: 80, maxWidth: 1400,
      );
      if (image == null) return;
      final directory = await getApplicationDocumentsDirectory();
      final target = '${directory.path}/warga_${resident.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final copied = await File(image.path).copy(target);
      if (!mounted) return;
      setState(() => resident.photoPath = copied.path);
      await saveAll();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Foto profil warga berhasil diperbarui.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Foto gagal diperbarui.')),
      );
    }
  }

  Future<void> deleteRecord(WaterRecord record) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hapus catatan?'),
        content: Text(
          'Catatan ${monthName(record.month)} akan dihapus.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() {
      resident.records.removeWhere((r) => r.month == record.month);
    });

    await CloudDatabase.deleteRecord(resident.id, record.month);
  }

  Future<void> editRecord(WaterRecord record) async {
    final result = await showModalBottomSheet<WaterRecord>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddWaterRecordSheet(
        resident: resident,
        editingRecord: record,
      ),
    );

    if (result == null) return;

    setState(() {
      resident.records.removeWhere((r) => r.month == result.month);
      resident.records.add(result);
      resident.records.sort((a, b) => a.month.compareTo(b.month));
    });

    await saveAll();
  }

  @override
  Widget build(BuildContext context) {
    final records = [...resident.records]
      ..sort((a, b) => b.month.compareTo(a.month));

    final currentRecord = resident.records
        .where((r) => r.month == currentMonth)
        .firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Profil Warga',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Ubah foto profil',
            onPressed: changeResidentPhoto,
            icon: const Icon(Icons.photo_camera_back_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => addWaterRecord(),
        icon: const Icon(Icons.add),
        label: Text(
          currentRecord == null ? 'Catat Meter' : 'Update Meter',
        ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 15),
              child: ResidentHeader(
                resident: resident,
                currentMonth: currentMonth,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: CurrentResidentStatus(
                resident: resident,
                currentMonth: currentMonth,
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 20)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Riwayat Pemakaian',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Text(
                    '${records.length} bulan',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          if (records.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyRecord(),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
              sliver: SliverList.separated(
                itemCount: records.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (_, index) {
                  final record = records[index];
                  return WaterRecordCard(
                    resident: resident,
                    record: record,
                    currentMonth: currentMonth,
                    onEdit: () => editRecord(record),
                    onDelete: () => deleteRecord(record),
                    onPrint: () => printWaterReceipt(context, resident, record),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class CurrentResidentStatus extends StatelessWidget {
  final Resident resident;
  final String currentMonth;

  const CurrentResidentStatus({
    super.key,
    required this.resident,
    required this.currentMonth,
  });

  @override
  Widget build(BuildContext context) {
    final current = resident.records
        .where((r) => r.month == currentMonth)
        .firstOrNull;

    final done = current != null;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: done
            ? const Color(0xFFE8F7EE)
            : const Color(0xFFFFF0F0),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.error_outline,
            color: done ? Colors.green.shade700 : Colors.red.shade700,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  done
                      ? 'Sudah dicatat — ${monthName(currentMonth)}'
                      : 'Belum dicatat — ${monthName(currentMonth)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: done
                        ? Colors.green.shade800
                        : Colors.red.shade800,
                  ),
                ),
                const SizedBox(height: 3),
                if (current != null)
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      Text(
                        'Dicatat ${formatDate(current.recordedDate)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade700,
                        ),
                      ),
                      Text(
                        '• ${current.status}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: statusTextColor(current.status),
                        ),
                      ),
                    ],
                  )
                else
                  Text(
                    'Bulan berikutnya tidak menghapus bulan sebelumnya.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade700,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ResidentHeader extends StatelessWidget {
  final Resident resident;
  final String currentMonth;

  const ResidentHeader({
    super.key,
    required this.resident,
    required this.currentMonth,
  });

  @override
  Widget build(BuildContext context) {
    final records = [...resident.records]
      ..sort((a, b) => a.month.compareTo(b.month));
    final latest = records.isEmpty ? null : records.last;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF12343B), Color(0xFF087E8B)],
        ),
        borderRadius: BorderRadius.circular(27),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HousePhoto(path: resident.photoPath, size: 85),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  resident.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  'RT ${resident.rt}',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 12),
                Text(
                  latest == null
                      ? 'Belum ada data meter'
                      : '${latest.usage} m³ • ${formatRupiah(latest.total)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyRecord extends StatelessWidget {
  const EmptyRecord({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.water_drop_outlined,
              size: 70,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 15),
            const Text(
              'Belum ada catatan meter',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              'Tekan tombol Catat Meter untuk memasukkan data.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}

class WaterRecordCard extends StatelessWidget {
  final Resident resident;
  final WaterRecord record;
  final String currentMonth;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onPrint;

  const WaterRecordCard({
    super.key,
    required this.resident,
    required this.record,
    required this.currentMonth,
    required this.onEdit,
    required this.onDelete,
    required this.onPrint,
  });

  @override
  Widget build(BuildContext context) {
    final isCurrent = record.month == currentMonth;

    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: isCurrent
            ? Border.all(
                color: const Color(0xFF087E8B),
                width: 1.2,
              )
            : null,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE3F4F5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    monthName(record.month),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF087E8B),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              if (isCurrent)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.check_circle,
                    color: Colors.green,
                    size: 19,
                  ),
                ),
              IconButton(
                tooltip: 'Cetak nota',
                onPressed: onPrint,
                icon: const Icon(Icons.print_outlined),
              ),
              IconButton(
                tooltip: 'Edit',
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: 'Hapus',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Dicatat: ${formatDate(record.recordedDate)}',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              MeterMetric(
                title: 'Meter lalu',
                value: '${record.previousMeter}',
              ),
              MeterMetric(
                title: 'Meter sekarang',
                value: '${record.currentMeter}',
              ),
              MeterMetric(
                title: 'Pemakaian',
                value: '${record.usage} m³',
                highlight: true,
              ),
            ],
          ),
          const Divider(height: 28),
          PriceRow(
            label: '${record.usage} m³ × Rp2.500',
            value: formatRupiah(record.waterPrice),
          ),
          const SizedBox(height: 8),
          PriceRow(
            label: 'Abodemen',
            value: formatRupiah(record.monthlyFee),
          ),
          const SizedBox(height: 12),
          _PaymentSummary(record: record),
        ],
      ),
    );
  }
}

class _PaymentSummary extends StatelessWidget {
  final WaterRecord record;

  const _PaymentSummary({required this.record});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: statusBackgroundColor(record.status),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Column(
        children: [
          PriceRow(
            label: 'Total tagihan',
            value: formatRupiah(record.total),
          ),
          if (record.creditUsed > 0) ...[
            const SizedBox(height: 6),
            PriceRow(
              label: 'Potongan saldo bulan lalu',
              value: '- ${formatRupiah(record.creditUsed)}',
            ),
          ],
          const Divider(height: 20),
          PriceRow(
            label: 'Sudah dibayar',
            value: formatRupiah(record.paidAmount),
          ),
          const SizedBox(height: 7),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              record.status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: statusTextColor(record.status),
                fontWeight: FontWeight.w900,
                fontSize: 13,
              ),
            ),
          ),
          if (record.remainingAmount > 0) ...[
            const SizedBox(height: 5),
            PriceRow(
              label: 'Kekurangan',
              value: formatRupiah(record.remainingAmount),
            ),
          ],
          if (record.overpaymentAmount > 0) ...[
            const SizedBox(height: 5),
            PriceRow(
              label: 'Saldo untuk bulan depan',
              value: formatRupiah(record.overpaymentAmount),
            ),
          ],
        ],
      ),
    );
  }
}

class MeterMetric extends StatelessWidget {
  final String title;
  final String value;
  final bool highlight;

  const MeterMetric({
    super.key,
    required this.title,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: highlight
                  ? const Color(0xFF087E8B)
                  : const Color(0xFF26383D),
            ),
          ),
        ],
      ),
    );
  }
}

class PriceRow extends StatelessWidget {
  final String label;
  final String value;

  const PriceRow({
    super.key,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}

class AddWaterRecordSheet extends StatefulWidget {
  final Resident resident;
  final WaterRecord? editingRecord;

  const AddWaterRecordSheet({
    super.key,
    required this.resident,
    this.editingRecord,
  });

  @override
  State<AddWaterRecordSheet> createState() => _AddWaterRecordSheetState();
}

class _AddWaterRecordSheetState extends State<AddWaterRecordSheet> {
  final previousController = TextEditingController();
  final currentController = TextEditingController();
  final paidController = TextEditingController();

  late String selectedMonth;
  int? usage;
  int? total;
  int? waterPrice;
  int creditUsed = 0;
  bool usePreviousCredit = false;

  List<String> get availableMonths {
    final now = DateTime.now();
    final set = <String>{};

    // Sediakan bulan ke belakang dan ke depan supaya bulan yang
    // terlewat tetap bisa diinput kapan saja.
    for (int offset = -24; offset <= 12; offset++) {
      final date = DateTime(now.year, now.month + offset);
      set.add(monthKey(date));
    }

    for (final record in widget.resident.records) {
      set.add(record.month);
    }

    if (widget.editingRecord != null) {
      set.add(widget.editingRecord!.month);
    }

    final list = set.toList()..sort();
    return list.reversed.toList();
  }

  @override
  void initState() {
    super.initState();

    selectedMonth =
        widget.editingRecord?.month ?? monthKey(DateTime.now());

    if (widget.editingRecord != null) {
      final record = widget.editingRecord!;
      previousController.text = record.previousMeter.toString();
      currentController.text = record.currentMeter.toString();
      paidController.text = record.paidAmount.toString();
      usePreviousCredit = record.creditUsed > 0;
    } else {
      _fillPreviousMeter();
    }

    previousController.addListener(calculate);
    currentController.addListener(calculate);
    paidController.addListener(calculate);

    WidgetsBinding.instance.addPostFrameCallback((_) => calculate());
  }

  @override
  void dispose() {
    previousController.dispose();
    currentController.dispose();
    paidController.dispose();
    super.dispose();
  }

  WaterRecord? recordForMonth(String month) {
    for (final record in widget.resident.records) {
      if (record.month == month && record != widget.editingRecord) {
        return record;
      }
    }
    return null;
  }

  int availableCreditBefore(String month) {
    final target = dateFromMonth(month);

    final earlier = widget.resident.records.where((record) {
      final recordDate = dateFromMonth(record.month);
      return recordDate.isBefore(target) && record != widget.editingRecord;
    }).toList()
      ..sort((a, b) => a.month.compareTo(b.month));

    // Saldo hanya berasal dari catatan terakhir sebelumnya. Jika catatan
    // setelahnya sudah memakai saldo, kelebihan lama tidak boleh dipakai lagi.
    return earlier.isEmpty ? 0 : earlier.last.overpaymentAmount;
  }

  void _fillPreviousMeter() {
    final target = dateFromMonth(selectedMonth);

    final earlier = widget.resident.records.where((record) {
      return dateFromMonth(record.month).isBefore(target) &&
          record != widget.editingRecord;
    }).toList()
      ..sort((a, b) => a.month.compareTo(b.month));

    if (earlier.isNotEmpty) {
      previousController.text = earlier.last.currentMeter.toString();
    } else {
      previousController.clear();
    }
  }

  void _monthChanged(String? value) {
    if (value == null) return;

    setState(() {
      selectedMonth = value;
      if (widget.editingRecord == null) usePreviousCredit = false;
    });

    // Kalau edit data lama, jangan mengubah meter secara otomatis.
    if (widget.editingRecord == null) {
      _fillPreviousMeter();
    }

    calculate();
  }

  void calculate() {
    final previous = int.tryParse(previousController.text);
    final current = int.tryParse(currentController.text);
    final paid = int.tryParse(paidController.text) ?? 0;

    final credit = usePreviousCredit ? availableCreditBefore(selectedMonth) : 0;

    if (!mounted) return;

    if (previous == null ||
        current == null ||
        current < previous) {
      setState(() {
        usage = null;
        waterPrice = null;
        total = null;
        creditUsed = credit;
      });
      return;
    }

    final used = current - previous;
    final price = used * HARGA_PER_METER;
    final grandTotal = price + ABODEMEN;

    setState(() {
      usage = used;
      waterPrice = price;
      total = grandTotal;
      creditUsed = credit > grandTotal ? grandTotal : credit;
    });
  }

  String calculatedStatus(int bill, int paid) {
    final due = bill - creditUsed;
    if (paid > due) return 'KELEBIHAN BAYAR';
    if (paid == due) return 'SUDAH LUNAS';
    return 'KURANG';
  }

  void saveRecord() {
    final previous = int.tryParse(previousController.text);
    final current = int.tryParse(currentController.text);
    final paid = int.tryParse(paidController.text) ?? 0;

    if (previous == null || current == null) {
      showError('Meter sebelumnya dan meter sekarang wajib diisi.');
      return;
    }

    if (current < previous) {
      showError(
        'Meter sekarang tidak boleh lebih kecil dari meter sebelumnya.',
      );
      return;
    }

    if (paid < 0) {
      showError('Nominal pembayaran tidak boleh negatif.');
      return;
    }

    final used = current - previous;
    final price = used * HARGA_PER_METER;
    final grandTotal = price + ABODEMEN;
    final credit = usePreviousCredit ? availableCreditBefore(selectedMonth) : 0;
    final actualCredit = credit > grandTotal ? grandTotal : credit;

    final record = WaterRecord(
      month: selectedMonth,
      previousMeter: previous,
      currentMeter: current,
      usage: used,
      waterPrice: price,
      monthlyFee: ABODEMEN,
      total: grandTotal,
      paidAmount: paid,
      creditUsed: actualCredit,
      status: calculatedStatus(grandTotal, paid),
      recordedAt: DateTime.now().toIso8601String(),
    );

    Navigator.pop(context, record);
  }

  void showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    final bill = total ?? 0;
    final paid = int.tryParse(paidController.text) ?? 0;
    final due = bill - creditUsed;
    final status = total == null
        ? null
        : calculatedStatus(bill, paid);
    final remaining = due - paid;
    final overpayment = paid - due;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .92,
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 25),
        decoration: const BoxDecoration(
          color: Color(0xFFF5F8FA),
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(30),
          ),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            keyboardDismissBehavior:
                ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SheetHandle(),
                const SizedBox(height: 18),
                Text(
                  widget.editingRecord == null
                      ? 'Catat Meter Air'
                      : 'Edit Data Meter',
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${widget.resident.name} • ${monthName(selectedMonth)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.grey.shade600),
                ),
                const SizedBox(height: 18),

                DropdownButtonFormField<String>(
                  value: selectedMonth,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Bulan pencatatan',
                    prefixIcon: Icon(Icons.calendar_month),
                  ),
                  items: availableMonths.map((month) {
                    return DropdownMenuItem<String>(
                      value: month,
                      child: Text(
                        monthName(month),
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                  onChanged: _monthChanged,
                ),

                const SizedBox(height: 12),
                TextField(
                  controller: previousController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Meter sebelumnya',
                    prefixIcon: Icon(Icons.history),
                    suffixText: 'm³',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: currentController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Meter sekarang',
                    prefixIcon: Icon(Icons.water_drop_outlined),
                    suffixText: 'm³',
                  ),
                ),
                const SizedBox(height: 12),
                if (availableCreditBefore(selectedMonth) > 0)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Gunakan saldo kelebihan bulan lalu'),
                    subtitle: Text('Saldo tersedia ${formatRupiah(availableCreditBefore(selectedMonth))}. Jika dimatikan, tagihan bulan ini tidak dipotong.'),
                    value: usePreviousCredit,
                    onChanged: (value) {
                      setState(() => usePreviousCredit = value);
                      calculate();
                    },
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: paidController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Nominal yang dibayar',
                    prefixIcon: Icon(Icons.payments_outlined),
                    prefixText: 'Rp ',
                  ),
                ),
                const SizedBox(height: 18),

                if (total != null && usage != null && waterPrice != null)
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(21),
                      border: Border.all(
                        color: const Color(0xFFE0E8EA),
                      ),
                    ),
                    child: Column(
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.calculate_outlined,
                              color: Color(0xFF087E8B),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Hasil Perhitungan',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        PriceRow(
                          label: 'Pemakaian',
                          value: '$usage m³',
                        ),
                        const SizedBox(height: 8),
                        PriceRow(
                          label: 'Air',
                          value: formatRupiah(waterPrice!),
                        ),
                        const SizedBox(height: 7),
                        PriceRow(
                          label: 'Abodemen',
                          value: formatRupiah(ABODEMEN),
                        ),
                        if (creditUsed > 0) ...[
                          const SizedBox(height: 7),
                          PriceRow(
                            label: 'Saldo bulan lalu',
                            value: '- ${formatRupiah(creditUsed)}',
                          ),
                        ],
                        const Divider(height: 25),
                        PriceRow(
                          label: 'Tagihan setelah saldo',
                          value: formatRupiah(
                            due < 0 ? 0 : due,
                          ),
                        ),
                        const SizedBox(height: 8),
                        PriceRow(
                          label: 'Dibayar',
                          value: formatRupiah(paid),
                        ),
                        const SizedBox(height: 12),
                        if (status != null)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: statusBackgroundColor(status),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(
                                  status,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: statusTextColor(status),
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                if (remaining > 0)
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(top: 5),
                                    child: Text(
                                      'Kurang ${formatRupiah(remaining)}',
                                      style: TextStyle(
                                        color:
                                            statusTextColor(status),
                                      ),
                                    ),
                                  ),
                                if (overpayment > 0)
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(top: 5),
                                    child: Text(
                                      'Saldo ${formatRupiah(overpayment)} tersedia; potongan bulan depan hanya jika diaktifkan.',
                                      style: TextStyle(
                                        color:
                                            statusTextColor(status),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),

                const SizedBox(height: 20),
                FilledButton(
                  onPressed: saveRecord,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    widget.editingRecord == null
                        ? 'Simpan ${monthName(selectedMonth)}'
                        : 'Simpan Perubahan',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 45,
        height: 5,
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
