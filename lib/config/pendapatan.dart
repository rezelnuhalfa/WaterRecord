import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cloud_database.dart';
import 'home_page.dart';

class IncomePage extends StatefulWidget {
  const IncomePage({super.key});

  @override
  State<IncomePage> createState() => _IncomePageState();
}

class _IncomePageState extends State<IncomePage> {
  List<Resident> residents = [];
  bool loading = true;
  late String selectedMonth;
  int todayCash = 0;
  StreamSubscription<void>? _changesSub;

  @override
  void initState() {
    super.initState();
    selectedMonth = monthKey(DateTime.now());
    loadData();
    loadTodayCash();
    _changesSub = CloudDatabase.changes.listen((_) {
      if (mounted) loadData();
    });
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    super.dispose();
  }

  Future<void> loadTodayCash() async {
    final amount = await CloudDatabase.getTodayCash();
    if (mounted) setState(() => todayCash = amount);
  }

  Future<void> editTodayCash() async {
    final controller = TextEditingController();
    final amount = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tambah saldo uang tunai hari ini'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Nominal uang yang ditambahkan',
            prefixText: 'Rp ',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
          FilledButton(
            onPressed: () => Navigator.pop(context, todayCash + (int.tryParse(controller.text) ?? 0)),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (amount == null) return;
    await CloudDatabase.setTodayCash(amount);
    if (mounted) setState(() => todayCash = amount);
  }

  Future<void> loadData() async {
    final data = await CloudDatabase.getResidents();
    if (!mounted) return;

    setState(() {
      residents = data;
      loading = false;
    });
  }

  List<String> get months {
    final set = <String>{selectedMonth};

    for (final resident in residents) {
      for (final record in resident.records) {
        set.add(record.month);
      }
    }

    // Tetap sediakan rentang bulan sehingga pengguna bisa berpindah
    // September -> Oktober -> September lagi tanpa kehilangan pilihan.
    final now = DateTime.now();
    for (int offset = -24; offset <= 12; offset++) {
      set.add(monthKey(DateTime(now.year, now.month + offset)));
    }

    final list = set.toList()..sort();
    return list.reversed.toList();
  }

  WaterRecord? recordFor(Resident resident, String month) {
    for (final record in resident.records) {
      if (record.month == month) return record;
    }
    return null;
  }

  int get currentIncome => residents.fold(
        0,
        (sum, resident) =>
            sum + (recordFor(resident, selectedMonth)?.total ?? 0),
      );

  int get totalPaid => residents.fold(
        0,
        (sum, resident) =>
            sum + (recordFor(resident, selectedMonth)?.paidAmount ?? 0),
      );

  int get previousArrears => residents.fold(
        0,
        (sum, resident) => sum + resident.records
            .where((record) => dateFromMonth(record.month).isBefore(dateFromMonth(selectedMonth)))
            .fold<int>(0, (subtotal, record) => subtotal + record.remainingAmount),
      );

  int get totalPotentialIncome => currentIncome + previousArrears;

  int get currentUsage => residents.fold(
        0,
        (sum, resident) =>
            sum + (recordFor(resident, selectedMonth)?.usage ?? 0),
      );

  int get recordedResidents =>
      residents.where((r) => recordFor(r, selectedMonth) != null).length;

  int get lunasCount => residents.where((r) {
        final record = recordFor(r, selectedMonth);
        return record?.status == 'SUDAH LUNAS';
      }).length;

  int get kurangCount => residents.where((r) {
        final record = recordFor(r, selectedMonth);
        return record?.status == 'KURANG';
      }).length;

  int get overpayCount => residents.where((r) {
        final record = recordFor(r, selectedMonth);
        return record?.status == 'KELEBIHAN BAYAR';
      }).length;

  String get previousMonth {
    final parts = selectedMonth.split('-');
    final year = int.tryParse(parts[0]) ?? DateTime.now().year;
    final month = int.tryParse(parts[1]) ?? DateTime.now().month;

    return monthKey(DateTime(year, month - 1));
  }

  int get previousIncome => residents.fold(
        0,
        (sum, resident) =>
            sum + (recordFor(resident, previousMonth)?.total ?? 0),
      );

  int get difference => currentIncome - previousIncome;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SafeArea(
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: loadData,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Pendapatan',
                        style: TextStyle(
                          fontSize: 27,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF12343B),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: loadData,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 15, 20, 15),
                child: DropdownButtonFormField<String>(
                  value: months.contains(selectedMonth)
                      ? selectedMonth
                      : months.first,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Pilih bulan',
                    prefixIcon: Icon(Icons.calendar_month),
                  ),
                  items: months.map((month) {
                    return DropdownMenuItem<String>(
                      value: month,
                      child: Text(
                        monthName(month),
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => selectedMonth = value);
                  },
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF12343B), Color(0xFF087E8B)],
                    ),
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        monthName(selectedMonth),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Total Tagihan',
                        style: TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 5),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          formatRupiah(currentIncome),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: SmallStat(
                              title: 'Pemakaian',
                              value: '$currentUsage m³',
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: SmallStat(
                              title: 'Sudah dicatat',
                              value: '$recordedResidents/${residents.length}',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SmallStat(
                        title: 'Uang sudah dibayar',
                        value: formatRupiah(totalPaid),
                      ),
                      const SizedBox(height: 12),
                      SmallStat(
                        title: 'Tunggakan bulan sebelumnya (tidak otomatis memotong tagihan baru)',
                        value: formatRupiah(previousArrears),
                      ),
                      const SizedBox(height: 12),
                      SmallStat(
                        title: 'Target pendapatan + tunggakan',
                        value: formatRupiah(totalPotentialIncome),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      const CircleAvatar(
                        backgroundColor: Color(0xFFE3F4F5),
                        child: Icon(Icons.account_balance_wallet, color: Color(0xFF087E8B)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Saldo uang kembalian hari ini', style: TextStyle(fontWeight: FontWeight.w800)),
                            const SizedBox(height: 3),
                            Text(formatRupiah(todayCash), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF087E8B))),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Tambah atau ubah saldo',
                        onPressed: editTodayCash,
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    CountChip(
                      label: 'Lunas $lunasCount',
                      icon: Icons.check_circle,
                      color: Colors.green,
                    ),
                    CountChip(
                      label: 'Kurang $kurangCount',
                      icon: Icons.warning_amber_rounded,
                      color: Colors.orange,
                    ),
                    CountChip(
                      label: 'Lebih bayar $overpayCount',
                      icon: Icons.add_circle,
                      color: Colors.blue,
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 25, 20, 12),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Rincian Warga',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    Text(
                      monthName(selectedMonth),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ),
            if (residents.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('Belum ada warga.')),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
                sliver: SliverList.separated(
                  itemCount: residents.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, index) {
                    final resident = residents[index];
                    final record = recordFor(resident, selectedMonth);

                    return IncomeResidentCard(
                      resident: resident,
                      record: record,
                      month: selectedMonth,
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

class SmallStat extends StatelessWidget {
  final String title;
  final String value;

  const SmallStat({
    super.key,
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    );
  }
}

class IncomeSmallCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;

  const IncomeSmallCard({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      constraints: const BoxConstraints(minHeight: 115),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFF087E8B)),
          const SizedBox(height: 10),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.grey.shade600),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CountChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;

  const CountChip({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 11,
        vertical: 8,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class IncomeResidentCard extends StatelessWidget {
  final Resident resident;
  final WaterRecord? record;
  final String month;

  const IncomeResidentCard({
    super.key,
    required this.resident,
    required this.record,
    required this.month,
  });

  @override
  Widget build(BuildContext context) {
    final done = record != null;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HousePhoto(path: resident.photoPath, size: 52),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  resident.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'RT ${resident.rt}',
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 7),
                if (done)
                  Wrap(
                    spacing: 5,
                    runSpacing: 3,
                    children: [
                      Text(
                        record!.status,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: statusTextColor(record!.status),
                        ),
                      ),
                      Text(
                        '• ${record!.usage} m³',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  )
                else
                  Text(
                    'Belum dicatat',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.red.shade700,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    done ? formatRupiah(record!.total) : '-',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: done ? const Color(0xFF087E8B) : Colors.grey,
                    ),
                  ),
                ),
                if (done) const SizedBox(height: 3),
                if (done)
                  Text(
                    'Bayar ${formatRupiah(record!.paidAmount)}',
                    maxLines: 2,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.grey.shade600,
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
