import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:torch_light/torch_light.dart';

class FlashlightPage extends StatefulWidget {
  const FlashlightPage({super.key});

  @override
  State<FlashlightPage> createState() => _FlashlightPageState();
}

class _FlashlightPageState extends State<FlashlightPage> {
  bool isOn = false;
  bool available = false;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    checkTorch();
  }

  Future<void> checkTorch() async {
    try {
      final result = await TorchLight.isTorchAvailable();
      if (mounted) setState(() { available = result; loading = false; });
    } catch (_) {
      if (mounted) setState(() { available = false; loading = false; });
    }
  }

  Future<void> toggleTorch() async {
    try {
      if (isOn) {
        await TorchLight.disableTorch();
      } else {
        await TorchLight.enableTorch();
      }
      if (mounted) setState(() => isOn = !isOn);
    } on PlatformException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Senter tidak dapat diaktifkan di perangkat ini.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Terjadi kesalahan saat mengaktifkan senter.')),
      );
    }
  }

  @override
  void dispose() {
    if (isOn) TorchLight.disableTorch();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Senter')),
      body: Center(
        child: loading
            ? const CircularProgressIndicator()
            : !available
                ? const Text('Perangkat ini tidak memiliki lampu flash yang tersedia.')
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isOn ? Icons.flashlight_on : Icons.flashlight_off,
                        size: 110,
                        color: isOn ? Colors.amber : Colors.blueGrey,
                      ),
                      const SizedBox(height: 18),
                      Text(isOn ? 'Senter aktif' : 'Senter mati',
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: toggleTorch,
                        icon: Icon(isOn ? Icons.flash_off : Icons.flash_on),
                        label: Text(isOn ? 'Matikan senter' : 'Aktifkan senter'),
                      ),
                    ],
                  ),
      ),
    );
  }
}

class CalculatorPage extends StatefulWidget {
  const CalculatorPage({super.key});

  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<CalculatorPage> {
  String display = '0';
  double? first;
  String? operation;
  bool replaceDisplay = false;

  void input(String value) {
    setState(() {
      if (replaceDisplay) {
        display = value == '.' ? '0.' : value;
        replaceDisplay = false;
      } else if (value == '.') {
        if (!display.contains('.')) display += '.';
      } else {
        display = display == '0' ? value : display + value;
      }
    });
  }

  void chooseOperation(String op) {
    final value = double.tryParse(display);
    if (value == null) return;
    setState(() {
      first = value;
      operation = op;
      replaceDisplay = true;
    });
  }

  void calculate() {
    final second = double.tryParse(display);
    if (first == null || operation == null || second == null) return;
    double result;
    switch (operation) {
      case '+': result = first! + second; break;
      case '−': result = first! - second; break;
      case '×': result = first! * second; break;
      case '÷':
        if (second == 0) {
          setState(() { display = 'Tidak bisa dibagi 0'; first = null; operation = null; });
          return;
        }
        result = first! / second;
        break;
      default: return;
    }
    setState(() {
      display = result == result.roundToDouble()
          ? result.toInt().toString()
          : result.toStringAsPrecision(10).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
      first = null;
      operation = null;
      replaceDisplay = true;
    });
  }

  void clear() => setState(() { display = '0'; first = null; operation = null; replaceDisplay = false; });

  void backspace() => setState(() {
    if (replaceDisplay || display.length <= 1 || display == 'Tidak bisa dibagi 0') {
      display = '0';
      replaceDisplay = false;
    } else {
      display = display.substring(0, display.length - 1);
    }
  });

  @override
  Widget build(BuildContext context) {
    const keys = [
      ['C', '⌫', '÷', '×'],
      ['7', '8', '9', '−'],
      ['4', '5', '6', '+'],
      ['1', '2', '3', '='],
      ['0', '00', '.', '='],
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Kalkulator')),
      body: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(22),
              alignment: Alignment.centerRight,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
              child: Text(display, maxLines: 2, textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900)),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Column(
                children: keys.map((row) => Expanded(
                  child: Row(
                    children: row.map((key) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: key == '=' || ['÷', '×', '−', '+'].contains(key)
                                ? const Color(0xFF087E8B)
                                : const Color(0xFFE3F0F2),
                            foregroundColor: key == '=' || ['÷', '×', '−', '+'].contains(key)
                                ? Colors.white : const Color(0xFF12343B),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          onPressed: () {
                            if (key == 'C') clear();
                            else if (key == '⌫') backspace();
                            else if (key == '=') calculate();
                            else if (['÷', '×', '−', '+'].contains(key)) chooseOperation(key);
                            else input(key);
                          },
                          child: Text(key, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
                        ),
                      ),
                    )).toList(),
                  ),
                )).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

