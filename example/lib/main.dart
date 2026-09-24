import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'demo_controller.dart';

void main() => runApp(const ResilienceDemoApp());

class ResilienceDemoApp extends StatelessWidget {
  const ResilienceDemoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Resilience Lab',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF286455)),
      scaffoldBackgroundColor: const Color(0xFFF4F6F3),
    ),
    home: const DemoScreen(),
  );
}

class DemoScreen extends StatefulWidget {
  const DemoScreen({super.key});
  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
  final controller = DemoController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      systemOverlayStyle: SystemUiOverlayStyle.dark,
      title: const Text('Resilience Lab'),
      backgroundColor: Colors.transparent,
    ),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'Make failure predictable.',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Run real Dio recovery code against simulated API failures. No external server or internet connection is used.',
                ),
                const SizedBox(height: 24),
                Text(
                  'Choose a scenario',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final scenario in DemoScenario.values)
                      ChoiceChip(
                        key: ValueKey('scenario-${scenario.name}'),
                        label: Text(scenario.label),
                        selected: controller.selected == scenario,
                        onSelected: controller.running
                            ? null
                            : (_) => controller.select(scenario),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(controller.selected.description),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('run-scenario'),
                      onPressed: controller.running ? null : controller.run,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(
                        controller.running ? 'Running…' : 'Run scenario',
                      ),
                    ),
                    if (controller.canCancel)
                      OutlinedButton.icon(
                        key: const ValueKey('cancel-request'),
                        onPressed: controller.cancel,
                        icon: const Icon(Icons.close),
                        label: const Text('Cancel request'),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            controller.status,
                            key: const ValueKey('scenario-status'),
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: controller.status == 'Failed'
                                      ? Theme.of(context).colorScheme.error
                                      : Theme.of(context).colorScheme.primary,
                                ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          controller.detail,
                          key: const ValueKey('scenario-detail'),
                        ),
                        if (controller.running) ...[
                          const SizedBox(height: 16),
                          const LinearProgressIndicator(),
                        ],
                        if (!controller.running && controller.attempts > 0) ...[
                          const SizedBox(height: 12),
                          Text(
                            '${controller.attempts} transport attempts observed',
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Request timeline',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF192C28),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: SelectableText(
                    controller.timeline.isEmpty
                        ? 'Your request timeline will appear here.'
                        : controller.timeline,
                    key: const ValueKey('request-timeline'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.6,
                      color: Color(0xFFDDEEE7),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'These scenarios validate application recovery. They do not simulate physical Wi-Fi changes, cellular radios, or OS background limits.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
