import 'package:flutter_test/flutter_test.dart';
import 'package:mirushin/features/library/application/google_drive_sync_controller.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 12);
  for (final scenario in [
    (
      name: 'normal edit uses segments',
      count: 1,
      age: const Duration(minutes: 1),
      bootstrap: false,
      expected: false,
    ),
    (
      name: '99 segments stay incremental',
      count: 99,
      age: const Duration(hours: 23),
      bootstrap: false,
      expected: false,
    ),
    (
      name: '100 segments publish a checkpoint',
      count: 100,
      age: const Duration(minutes: 1),
      bootstrap: false,
      expected: true,
    ),
    (
      name: 'one day permits a new checkpoint',
      count: 1,
      age: const Duration(days: 1),
      bootstrap: false,
      expected: true,
    ),
    (
      name: 'an old unchanged library is not uploaded again',
      count: 0,
      age: const Duration(days: 2),
      bootstrap: false,
      expected: false,
    ),
    (
      name: 'first publication handles missing history',
      count: 1,
      age: null,
      bootstrap: false,
      expected: true,
    ),
    (
      name: 'first restore can seed a checkpoint without new segments',
      count: 0,
      age: const Duration(minutes: 1),
      bootstrap: true,
      expected: true,
    ),
  ]) {
    test(scenario.name, () {
      expect(
        driveLibraryCheckpointDue(
          uncheckpointedSegments: scenario.count,
          lastPublishedAt: scenario.age == null
              ? null
              : now.subtract(scenario.age!),
          now: now,
          needsBootstrap: scenario.bootstrap,
        ),
        scenario.expected,
      );
    });
  }
}
