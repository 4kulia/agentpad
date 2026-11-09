import copy
import errno
import importlib.util
import json
import math
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, call, patch

import chat_scroll_report as report


SPEC = importlib.util.spec_from_file_location('bench_chat_scroll', Path(__file__).with_name('bench-chat-scroll.py'))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


def event(cost=1, error=0):
    return {'kind': 'up', 'requested': -2, 'actual': -2 - error, 'documentHeight': 5000,
            'milliseconds': cost, 'threadCpuMilliseconds': .5, 'anchorBefore': 30,
            'anchorAfter': 32 + error, 'error': error, 'layoutError': 0,
            'valid': True, 'anchor': 'fixture-1', 'heights': {'fixture-1': 100}, 'phase': 1, 'segment': 'precise'}


def observation(stage, instant=1):
    return {'stage': stage, 'monotonic': instant, 'load': [3.99, 3.99, 6], 'locked': False, 'free_bytes': 4 * 2**30}


def log(kind):
    lines = [f"Test Case '-[AgentPadKitTests.{suite} {method}]' passed (1 seconds)."
             for suite, method in sorted(report.EXPECTED_TESTS[kind])]
    lines += [f'Executed {len(lines)} tests, with 0 failures',
              'QUIET PASS: frontmostApplication checks=12 test-app-frontmost=0; window/screen checks=34 intersections=0; os-key-main=0']
    return '\n'.join(lines)


def cleanup_proof(pid=42):
    return {'version': 1, 'scope': 'private-session', 'root_pid': pid, 'session': pid, 'root_start': [1, 1],
            'verified': True, 'uncertainty': [], 'groups': [pid], 'finished': 1,
            'processes': [{'pid': pid, 'parent': 1, 'group': pid, 'session': pid, 'start': [1, 1]}]}


@contextmanager
def process_evidence():
    # Keep process ownership and signal ledgers even when an assertion fails.
    # TMPDIR selects the caller's external evidence directory.
    root = Path(tempfile.mkdtemp(prefix='chat-scroll-process-'))
    try:
        yield root
    finally:
        print('Process-test evidence: ' + str(root), file=sys.stderr)


def wait_expiring_fixture(groups):
    deadline = time.monotonic() + 8
    while any(runner.group_members(group) for group in groups if group is not None):
        if time.monotonic() >= deadline:
            raise RuntimeError('bounded fixture did not exit; process evidence retained')
        time.sleep(.1)


class BenchmarkGuardTests(unittest.TestCase):
    def test_owner_decision_accepts_recorded_high_load_and_all_timing_outliers(self):
        checks = [dict(observation('preflight', 1), load=[8, 12, 6]),
                  dict(observation('finished', 2), load=[20, 30, 10])]
        report.validate_observations(checks, 1.1, 1.9)
        report.native_verdict({'metrics': {'events': 1360, 'jumps': 0, 'over16': 1360}},
                              'native-product', 'primary')

    def test_owner_decision_defaults_to_one_complete_functional_repetition(self):
        self.assertEqual(len(report.schedule()), 4)
        self.assertEqual({row['repetition'] for row in report.schedule()}, {1})
        self.assertEqual({row['renderer'] for row in report.schedule()}, {'native-product'})
        self.assertEqual([row['kind'] for row in report.schedule()], ['mount', 'primary', 'dense', 'loaded'])

    def test_owner_decision_does_not_wait_on_load_or_expired_controlled_budget(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report.write(root / 'wait.json', {'seconds': 43200, 'waiting_since': time.time() - 120})
            state = dict(observation('preflight'), load=[8, 12, 6])
            with patch.object(runner, 'sample', return_value=state), patch.object(runner.time, 'sleep') as sleep:
                self.assertIs(runner.wait_gate(root, 'test', 0), state)
                sleep.assert_not_called()
            self.assertGreaterEqual(report.read(root / 'wait.json')['seconds'], 43320)

    def freeze_reference(self, root):
        cases = []
        (root / 'scroll').mkdir()
        for name, count in report.PRIMARY.items():
            signatures = report.signatures(count)
            raw = [dict(zip(('kind', 'requested', 'phase', 'segment'), value)) for value in signatures]
            report.write(root / 'scroll' / (name + '.json'), raw)
            report.write(root / 'scroll' / (name + '-fixture.json'), [{'id': name}])
            report.write(root / 'scroll' / (name + '-settings.json'), {'responsive': False})
            cases.append(dict(name=name, movingEvents=count, rawEvents=len(raw), signatures=signatures,
                              heightPoints=600, widthPoints=420 if name.endswith('fixture-root') else 760,
                              referenceSamples='scroll/' + name + '.json', fixtureValues='scroll/' + name + '-fixture.json'))
        manifest = root / 'frozen.json'
        report.write(manifest, dict(primaryMovingEvents=1360, jumpTolerancePoints=.75, cases=cases))
        reference = report.load_reference(manifest)
        report.write(root / 'reference.json', reference)
        return manifest, reference

    def test_reference_snapshot_cannot_diverge_while_archived_files_stay_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            _, reference = self.freeze_reference(Path(temporary))
            self.assertTrue(report.reference_unchanged(reference))
            reference['cases']['media-channel']['fixture'] = [{'changed': True}]
            self.assertFalse(report.reference_unchanged(reference))

    def test_native_repetitions_keep_every_workload_unpooled(self):
        tasks = report.schedule(3)
        self.assertEqual(len(tasks), 12)
        self.assertEqual([task['renderer'] for task in tasks if task['kind'] == 'primary'],
                         ['native-product', 'native-product', 'native-product'])
        self.assertEqual([task['repetition'] for task in tasks if task['kind'] == 'primary'], [1, 2, 3])
        self.assertEqual({task['position'] for task in tasks}, {1})
        self.assertEqual([sum(group.values()) for group in report.GROUPS.values()], [1360, 400, 400])

    def test_primary_runs_explicit_native_media_entry_point(self):
        self.assertEqual(report.EXPECTED_TESTS['primary'],
                         {('ChatScrollContinuityTests', 'testNativeMixedHeightScrollContinuity'),
                          ('ChatScrollMediaTests', 'testNativeMediaPreciseScrollContinuityInChannelAndThread')})
        self.assertIn('/testNativeMediaPreciseScrollContinuityInChannelAndThread$', report.FILTERS['primary'])

    def test_archived_rotation_is_available_only_under_its_recorded_contract(self):
        tasks = report.schedule(3, report.ARCHIVED_CONTRACT)
        self.assertEqual(len(tasks), 36)
        self.assertEqual([task['renderer'] for task in tasks if task['kind'] == 'primary'],
                         ['swiftui-reference', 'hosted-reference', 'native-product',
                          'hosted-reference', 'native-product', 'swiftui-reference',
                          'native-product', 'swiftui-reference', 'hosted-reference'])
        with self.assertRaisesRegex(ValueError, 'unknown_acceptance_contract'):
            report.schedule(1, 'unrecognized')

    def test_runner_rejects_renderer_selection(self):
        with patch.object(sys, 'argv', ['bench-chat-scroll.py', '--run-root', 'fixture',
                                      '--reference-manifest', 'reference.json', '--renderers', 'native-product']):
            with self.assertRaises(SystemExit) as result:
                runner.main()
        self.assertEqual(result.exception.code, 2)

    def test_archived_signature_hashes_and_phase_end_retention(self):
        hashes = {480: 'c4d58914210fe0511d70bf6aa39b2d2f2a8b3679c6299bab197ca524dac44764',
                  200: '084d1acd4fc1573048fa5b39259a3f371f099a1fe125c3008167da7dec2f633f'}
        for count, expected in hashes.items():
            values = report.signatures(count)
            objects = [dict(zip(('kind', 'requested', 'phase', 'segment'), row)) for row in values]
            encoded = json.dumps(objects, sort_keys=True, separators=(',', ':')).encode()
            self.assertEqual(report.hashlib.sha256(encoded).hexdigest(), expected)
            self.assertEqual(len(values), count + (4 if count == 480 else 2))

    def test_strict_thresholds_and_reference_percentile(self):
        self.assertEqual(report.stats([event(16, .75), event(16.001, .751)]),
                         {'events': 2, 'jumps': 1, 'over16': 1, 'wallP50': 16, 'wallP95': 16,
                          'wallMax': 16.001, 'cpuP95': .5, 'maxError': .751})
        self.assertEqual(report.stats([event(value) for value in (100, 0, 9, 2, 8, 3, 7, 4, 6, 5, 1)])['wallP95'], 9)

    def test_every_numeric_field_rejects_missing_nonfinite_and_boolean(self):
        for key in report.NUMBERS:
            for value in (math.nan, math.inf, -math.inf, None, True):
                with self.subTest(key=key, value=value):
                    sample = event()
                    sample[key] = value
                    with self.assertRaises(ValueError):
                        report.stats([sample])

    def test_missing_anchor_inconsistent_errors_negative_timing_and_heights(self):
        for key, value in [('anchor', ''), ('valid', 1), ('valid', False), ('error', 1), ('layoutError', 1),
                           ('milliseconds', -1), ('threadCpuMilliseconds', -1), ('documentHeight', 0),
                           ('heights', {}), ('heights', {'fixture': math.nan})]:
            with self.subTest(key=key, value=value):
                sample = event()
                sample[key] = value
                with self.assertRaises(ValueError):
                    report.stats([sample])

    def test_load_records_console_and_disk_fail_closed(self):
        self.assertTrue(report.environment_allowed(observation('preflight')))
        for key, values in [('locked', [True, None, 0]), ('free_bytes', [3 * 2**30 - 1, None, math.nan]),
                            ('load', [[math.nan, 1, 1], [-1, 1, 1], [1, 1], [1, 1, math.inf]])]:
            for value in values:
                state = observation('preflight')
                state[key] = value
                self.assertFalse(report.environment_allowed(state), (key, value))

    def test_observations_cover_entire_attempt_including_final(self):
        checks = [observation('preflight', 1), observation('running', 6), observation('finished', 11)]
        report.validate_observations(checks, 1.1, 10.9)
        for mutation in ('missing-final', 'locked-final', 'gap', 'missing-preflight', 'span'):
            values = copy.deepcopy(checks)
            if mutation == 'missing-final': values.pop()
            if mutation == 'locked-final': values[-1]['locked'] = True
            if mutation == 'gap': values[1]['monotonic'] = 20
            if mutation == 'missing-preflight': values.pop(0)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                report.validate_observations(values, 0 if mutation == 'span' else 1.1, 10.9)

    def test_quiet_proof_and_exact_test_identities(self):
        valid = log('primary')
        self.assertEqual(report.validate_tests(valid, 'primary', 0), {'frontmostChecks': 12, 'screenChecks': 34, 'tests': 2})
        bad = [valid.replace('checks=12', 'checks=0'), valid.replace('checks=34', 'checks=0'),
               valid.replace('frontmost=0', 'frontmost=1'), valid.replace('intersections=0', 'intersections=1'),
               valid.replace('os-key-main=0', 'os-key-main=1'), valid + '\nQUIET FAIL: test',
               valid.replace('testNativeMediaPreciseScrollContinuityInChannelAndThread', 'testOther'),
               valid + '\n' + valid.splitlines()[0], valid.replace('passed', 'skipped'),
               valid.replace('Executed 2 tests', 'Executed 0 tests')]
        for content in bad:
            with self.subTest(content=content), self.assertRaises(ValueError):
                report.validate_tests(content, 'primary', 0)
        with self.assertRaises(ValueError):
            report.validate_tests(valid, 'primary', 1)

    def make_batch(self, folder, renderer='native-product'):
        samples = folder / 'samples' / renderer
        samples.mkdir(parents=True)
        reference = {'cases': {}}
        for name, count in report.PRIMARY.items():
            raw = []
            for kind, requested, phase, segment in report.signatures(count):
                value = event()
                value.update(kind=kind, requested=requested, actual=requested, anchorAfter=30-requested, phase=phase, segment=segment)
                raw.append(value)
            reference['cases'][name] = {'signatures': report.signatures(count), 'fixture': [{'id': name}], 'settings': {'responsive': False}}
            for suffix, value in [('.json', raw), ('-fixture.json', [{'id': name}]), ('-settings.json', {'responsive': False}),
                                  ('-counters.json', {'renderer': renderer, 'cellsCreated': 7, 'cellsReused': 8,
                                     'heightEntries': 100, 'contentEntries': 100, 'heightBytes': 1000, 'contentBytes': 2000})]:
                report.write(samples / (name + suffix), value)
        report.write(folder / 'environment.json', [observation('preflight', 1), observation('finished', 2)])
        report.write(folder / 'invocation.json', {'pid': 42, 'renderer': renderer, 'mode': 'normalized-quiet',
                     'command': ['python3', 'scripts/test-quiet.py', '--skip-build', '--log-dir', str(folder), '--filter', report.FILTERS['primary']]})
        (folder / 'tests.log').write_text(log('primary'))
        completion = {'renderer': renderer, 'kind': 'primary', 'reason': None, 'started': 1.1, 'finished': 1.9,
                      'exit_code': 0, 'sources_unchanged': True, 'binary_unchanged': True}
        return reference, completion

    def test_primary_cannot_pool_drop_events_or_change_reference(self):
        for mutation in ('jump', 'missing-event', 'invalid-phase-end', 'fixture', 'settings', 'source', 'binary', 'no-reuse', 'extra-file'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                folder = Path(temporary)
                reference, completion = self.make_batch(folder)
                good = report.validate_batch(folder, completion, reference)
                self.assertEqual(good['metrics']['events'], 1360)
                target = folder / 'samples/native-product/channel.json'
                values = report.read(target)
                if mutation == 'jump':
                    values[0]['anchorAfter'] += 1
                    values[0]['error'] += 1
                    values[0]['layoutError'] += 1
                if mutation == 'missing-event': values.pop(0)
                if mutation == 'invalid-phase-end': values[200]['phase'] = 2
                if mutation in ('fixture', 'settings'): report.write(target.with_name('channel-' + mutation + '.json'), {})
                if mutation == 'source': completion['sources_unchanged'] = False
                if mutation == 'binary': completion['binary_unchanged'] = False
                if mutation == 'no-reuse':
                    counters = report.read(target.with_name('channel-counters.json'))
                    counters['cellsReused'] = 0
                    report.write(target.with_name('channel-counters.json'), counters)
                if mutation == 'extra-file': report.write(target.with_name('unreported.json'), [])
                report.write(target, values)
                with self.assertRaises((ValueError, KeyError)):
                    report.validate_batch(folder, completion, reference)

    def test_native_keeps_all_timing_outliers_as_diagnostics(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            reference, completion = self.make_batch(folder)
            target = folder / 'samples/native-product/channel.json'
            values = report.read(target)
            for value in values: value['milliseconds'] = 17
            report.write(target, values)
            self.assertEqual(report.validate_batch(folder, completion, reference)['metrics']['over16'], 480)

    def test_archived_batch_keeps_original_test_identity_without_authorizing_new_reference_runs(self):
        for renderer in report.ARCHIVED_RENDERERS:
            with self.subTest(renderer=renderer), tempfile.TemporaryDirectory() as temporary:
                folder = Path(temporary)
                reference, completion = self.make_batch(folder, renderer=renderer)
                invocation = report.read(folder / 'invocation.json')
                invocation['command'][-1] = report.ARCHIVED_FILTERS['primary']
                report.write(folder / 'invocation.json', invocation)
                (folder / 'tests.log').write_text(log('primary').replace('testNativeMedia', 'testMedia'))
                self.assertEqual(report.validate_batch(folder, completion, reference, report.ARCHIVED_CONTRACT)
                                 ['metrics']['events'], 1360)
                with self.assertRaises(ValueError):
                    report.validate_batch(folder, completion, reference)

    def test_import_does_not_run_and_wait_returns_without_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report.write(root / 'wait.json', {'seconds': 0})
            state = observation('preflight')
            state['locked'] = True
            with patch.object(runner, 'sample', return_value=state), patch.object(runner.time, 'sleep') as sleep:
                self.assertIsNone(runner.wait_gate(root, 'test', 0))
                sleep.assert_not_called()

    def test_pending_wait_counts_across_resume_before_allowing_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report.write(root / 'wait.json', {'seconds': 10, 'waiting_since': time.time() - 120})
            with patch.object(runner, 'sample', return_value=observation('preflight')):
                self.assertIsNotNone(runner.wait_gate(root, 'test', 0))
            accounting = report.read(root / 'wait.json')
            self.assertGreaterEqual(accounting['seconds'], 130)
            self.assertIsNone(accounting['waiting_since'])

    def test_gate_closing_during_identity_hashing_prevents_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest, reference = self.freeze_reference(root)
            report.write(root / 'baseline.json', {'repository': str(runner.REPOSITORY), 'mode': 'normalized-quiet',
                         'acceptance_contract': report.ACCEPTANCE_CONTRACT, 'repetitions': 1,
                         'schedule': report.schedule(), 'sources': {}, 'build': {'binaries': {}}})
            report.write(root / 'primary-media-fixture.json', reference['cases']['media-channel']['fixture'])
            report.write(root / 'results.json', [])
            args = SimpleNamespace(run_root=root, reference_manifest=manifest.resolve(), resume=True, mode='normalized-quiet',
                                   repetitions=1, limit=None, prepare_only=False, wait_seconds=0)
            with patch.object(runner, 'snapshot_sources', return_value={}), \
                 patch.object(runner, 'wait_gate', side_effect=[observation('preflight'), None]), \
                 patch.object(runner, 'run_child') as child:
                self.assertEqual(runner.execute(args), 75)
                child.assert_not_called()
            self.assertEqual(report.read(root / 'status.json')['reason'], 'gate_changed_during_identity_checks')

    def test_resume_cannot_shrink_declared_repetitions_to_match_a_scoped_schedule(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest, reference = self.freeze_reference(root)
            report.write(root / 'baseline.json', {'repository': str(runner.REPOSITORY), 'mode': 'normalized-quiet',
                         'acceptance_contract': report.ACCEPTANCE_CONTRACT, 'repetitions': 3,
                         'schedule': report.schedule(3)[:4], 'sources': {}, 'build': {'binaries': {}}})
            report.write(root / 'primary-media-fixture.json', reference['cases']['media-channel']['fixture'])
            report.write(root / 'results.json', [])
            args = SimpleNamespace(run_root=root, reference_manifest=manifest.resolve(), resume=True, mode='normalized-quiet',
                                   repetitions=1, limit=None, prepare_only=False, wait_seconds=0)
            with patch.object(runner, 'snapshot_sources', return_value={}), \
                 patch.object(runner, 'wait_gate', return_value=None), patch.object(runner, 'run_child') as child:
                with self.assertRaisesRegex(ValueError, 'resume_repetitions_changed'):
                    runner.execute(args)
                child.assert_not_called()

    def test_incomplete_report_is_nonpassing_and_cannot_overwrite_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest, _ = self.freeze_reference(root)
            report.write(root / 'baseline.json', {'repository': str(root), 'sources': {'frozen.json': report.digest(manifest)}})
            report.write(root / 'results.json', [])
            report.write(root / 'status.json', {'state': 'complete'})
            output = root / 'report.md'
            summary = report.make_report(root, output)
            self.assertFalse(summary['accepted'])
            self.assertFalse(summary['complete'])
            before = output.read_bytes()
            with self.assertRaisesRegex(ValueError, 'report_output_exists'):
                report.make_report(root, output)
            self.assertEqual(output.read_bytes(), before)
            manifest.write_text('{"changed":true}')
            changed = report.make_report(root, root / 'changed.md')
            self.assertIn('reference_changed', changed['failures'])
            self.assertTrue(any(reason.startswith('source_changed') for reason in changed['failures']))

    def test_each_native_repetition_is_decided_independently(self):
        for outliers in (0, 1, 2, 1360):
            result = {'metrics': {'events': 1360, 'jumps': 0, 'over16': outliers}}
            report.native_verdict(result, 'native-product', 'primary')
        for field, value in (('events', 1359), ('jumps', 1)):
            result = {'metrics': {'events': 1360, 'jumps': 0, 'over16': 0}}
            result['metrics'][field] = value
            with self.assertRaises(ValueError):
                report.native_verdict(result, 'native-product', 'primary')

    def test_interrupted_attempt_keeps_raw_data_and_reason(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            task = report.schedule()[0]
            folder = root / 'rep-1-1-native-product-mount-attempt-1'
            folder.mkdir()
            (folder / 'raw.json').write_text('[1,2,3]')
            report.write(folder / 'environment.json', [observation('preflight')])
            report.write(folder / 'invocation.json', {'pid': 42})
            report.write(folder / 'ownership.json', cleanup_proof())
            results = []
            with patch.object(runner, 'group_members', return_value=[]):
                runner.recover_interrupted(root, results, [task])
            self.assertEqual(results[0]['reason'], 'interrupted_attempt')
            self.assertFalse(results[0]['accepted'])
            self.assertIsNone(results[0]['exit_code'])
            self.assertEqual((folder / 'raw.json').read_text(), '[1,2,3]')
            with patch.object(runner, 'group_members', return_value=[]):
                runner.recover_interrupted(root, results, [task])
            self.assertEqual(len(results), 1)

    def test_live_or_unknown_previous_child_blocks_recovery_without_signalling_pid(self):
        for label in ('build-1', 'rep-1-1-native-product-mount-attempt-1'):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                folder = root / label
                folder.mkdir()
                with self.assertRaisesRegex(ValueError, 'ownership_record_missing'):
                    runner.require_inactive_children(root)
                report.write(folder / 'invocation.json', {'pid': None})
                with self.assertRaisesRegex(ValueError, 'ownership_record_incomplete'):
                    runner.require_inactive_children(root)
                report.write(folder / 'invocation.json', {'pid': 42})
                report.write(folder / 'ownership.json', cleanup_proof())
                with patch.object(runner, 'group_members', return_value=[43]), patch.object(runner.os, 'killpg') as kill:
                    with self.assertRaisesRegex(ValueError, 'prior_child_group_still_running'):
                        runner.recover_interrupted(root, [], report.schedule())
                    kill.assert_not_called()

    def test_termination_drains_owned_child_and_preserves_rejection(self):
        script = '''
import importlib.util, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location('runner', Path(sys.argv[1]) / 'bench-chat-scroll.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
def sample(root, label, stage):
    return dict(stage=stage, monotonic=time.monotonic(), load=[1, 1, 1], locked=False, free_bytes=4*2**30)
runner.sample = sample
root = Path(sys.argv[2])
row = runner.run_child(root, 'build-1', [sys.executable, '-c', 'import time; time.sleep(5)'], {}, sample(root, '', 'preflight'))
runner.write(root / 'result.json', row)
'''
        with process_evidence() as root:
            process = subprocess.Popen([sys.executable, '-B', '-c', script, str(Path(__file__).parent), str(root)],
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            report.write(root / 'driver-invocation.json', {'pid': process.pid})
            pid = None
            try:
                deadline = time.monotonic() + 10
                while pid is None:
                    invocation = root / 'build-1/invocation.json'
                    if invocation.exists():
                        try:
                            pid = report.read(invocation).get('pid')
                        except json.JSONDecodeError:
                            pass
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(.02)
                report.write(root / 'driver-signal.json', {'pid': process.pid, 'signal': int(signal.SIGTERM)})
                process.terminate()
                output, _ = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 0, output.decode())
                self.assertEqual(runner.group_members(pid), [])
                self.assertEqual(report.read(root / 'result.json')['reason'], 'interrupted_attempt')
            finally:
                # These fixture children expire on their own. A failing cleanup
                # test never falls back to signalling a remembered numeric PID.
                output, _ = process.communicate(timeout=60)
                (root / 'driver.log').write_bytes(output)
                wait_expiring_fixture([pid])

    def test_recovery_requires_verified_cleanup_even_after_root_group_disappears(self):
        for label in ('build-1', 'rep-1-1-native-product-mount-attempt-1'):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                folder = root / label
                folder.mkdir()
                report.write(folder / 'invocation.json', {'pid': 42})
                with patch.object(runner, 'group_members', return_value=[]), patch.object(runner.os, 'killpg') as kill:
                    with self.assertRaisesRegex(ValueError, 'cleanup'):
                        runner.require_inactive_children(root)
                    report.write(folder / 'ownership.json', {'root_pid': 42, 'verified': False, 'groups': []})
                    with self.assertRaisesRegex(ValueError, 'cleanup'):
                        runner.require_inactive_children(root)
                    kill.assert_not_called()

    def test_private_session_classification_excludes_unrelated_live_sentinel(self):
        with process_evidence() as root:
            sentinel = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(1)'])
            owned = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(1)'], start_new_session=True)
            report.write(root / 'fixture-invocations.json', {'sentinel': sentinel.pid, 'owned': owned.pid})
            try:
                tracker = runner.OwnedProcesses(root)
                tracker.attach(owned)
                table, live = tracker.observe()
                self.assertIn(sentinel.pid, table)
                self.assertEqual(set(live), {owned.pid})
                self.assertEqual(set(tracker.records), {owned.pid})
                self.assertEqual(table[owned.pid]['session'], owned.pid)
                self.assertNotEqual(table[sentinel.pid]['session'], owned.pid)
                with patch.object(runner.os, 'killpg') as kill:
                    tracker.drain(owned)
                    self.assertEqual(kill.call_args_list, [call(owned.pid, signal.SIGTERM)])
                self.assertEqual(sentinel.wait(timeout=5), 0)
                self.assertEqual(owned.wait(timeout=5), 0)
            finally:
                sentinel.wait(timeout=5)
                owned.wait(timeout=5)

    def test_termination_drains_separate_group_in_private_session(self):
        self.check_separate_group_descendant('terminate')

    def test_unexpected_parent_exit_drains_known_descendant_but_recovery_fails_closed(self):
        self.check_separate_group_descendant('parent-exits')

    def check_separate_group_descendant(self, mode):
        script = '''
import importlib.util, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location('runner', Path(sys.argv[1]) / 'bench-chat-scroll.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
def sample(root, label, stage):
    return dict(stage=stage, monotonic=time.monotonic(), load=[1, 1, 1], locked=False, free_bytes=4*2**30)
runner.sample = sample
root = Path(sys.argv[2])
command = "import subprocess,sys,time,json; from pathlib import Path; p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(5)'],process_group=0); Path(sys.argv[1]).write_text(json.dumps(p.pid)); time.sleep(5)"
if sys.argv[3] == 'parent-exits':
    command = command.rsplit('time.sleep(5)', 1)[0] + 'time.sleep(.7); sys.exit(7)'
row = runner.run_child(root, 'build-1', [sys.executable, '-c', command, str(root / 'descendant.json')], {}, sample(root, '', 'preflight'))
runner.write(root / 'result.json', row)
'''
        with process_evidence() as root:
            process = subprocess.Popen([sys.executable, '-B', '-c', script, str(Path(__file__).parent), str(root), mode],
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            report.write(root / 'driver-invocation.json', {'pid': process.pid})
            child_pid = None
            descendant = None
            try:
                deadline = time.monotonic() + 10
                while descendant is None:
                    if (root / 'descendant.json').exists():
                        descendant = report.read(root / 'descendant.json')
                        child_pid = report.read(root / 'build-1/invocation.json')['pid']
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(.02)
                self.assertNotEqual(os.getpgid(child_pid), os.getpgid(descendant))
                self.assertEqual(os.getsid(child_pid), os.getsid(descendant))
                if mode == 'terminate':
                    report.write(root / 'driver-signal.json', {'pid': process.pid, 'signal': int(signal.SIGTERM)})
                    process.terminate()
                output, _ = process.communicate(timeout=20)
                self.assertEqual(process.returncode, 0, output.decode())
                self.assertEqual(runner.group_members(child_pid), [])
                self.assertEqual(runner.group_members(descendant), [])
                ownership = report.read(root / 'build-1/ownership.json')
                self.assertEqual(ownership['verified'], mode == 'terminate')
                self.assertIn(descendant, ownership['groups'])
                if mode == 'terminate':
                    self.assertEqual(report.read(root / 'result.json')['reason'], 'interrupted_attempt')
                    runner.require_inactive_children(root)
                else:
                    self.assertEqual(report.read(root / 'result.json')['reason'], 'owned_cleanup_unverified')
                    with self.assertRaisesRegex(ValueError, 'cleanup_unverified'):
                        runner.require_inactive_children(root)
            finally:
                output, _ = process.communicate(timeout=60)
                (root / 'driver.log').write_bytes(output)
                wait_expiring_fixture([child_pid, descendant])

    def test_reused_process_start_identity_is_not_signalled(self):
        with tempfile.TemporaryDirectory() as temporary:
            tracker = runner.OwnedProcesses(Path(temporary))
            row = {'pid': 42, 'parent': 1, 'group': 42, 'session': 42}
            tracker.state.update(root_pid=42, session=42, root_start=[1, 1])
            tracker.records[42] = dict(row, start=[1, 1])
            process = Mock(pid=42)
            process.poll.return_value = 0
            with patch.object(runner, 'process_snapshot', return_value={42: row}), \
                    patch.object(runner, 'process_identity', return_value=[2, 1]), patch.object(runner.os, 'killpg') as kill:
                tracker.drain(process)
                kill.assert_not_called()
            self.assertFalse(tracker.state['verified'])
            self.assertIn('private_session_identity_changed', tracker.state['uncertainty'])

    def test_process_exit_between_snapshot_and_identity_is_not_pid_reuse(self):
        for exiting in (42, 43, 44):
            with self.subTest(exiting=exiting), tempfile.TemporaryDirectory() as temporary:
                tracker = runner.OwnedProcesses(Path(temporary))
                tracker.state.update(root_pid=42, session=42, root_start=[1, 1])
                rows = {pid: {'pid': pid, 'parent': 42 if pid != 42 else 1,
                              'group': 42, 'session': 42} for pid in (42, 43, 44)}
                tracker.records = {pid: dict(rows[pid], start=[1, 1]) for pid in (42, 43)}
                with patch.object(runner, 'process_snapshot', return_value=dict(rows)), \
                        patch.object(runner, 'process_identity', side_effect=lambda pid: None if pid == exiting else [1, 1]), \
                        patch.object(runner.os, 'killpg') as kill:
                    table, live = tracker.observe()
                    kill.assert_not_called()
                self.assertEqual(tracker.state['uncertainty'], [])
                self.assertNotIn(exiting, table)
                self.assertNotIn(exiting, live)
                self.assertEqual(set(live), set(rows) - {exiting})

    def test_identity_lookup_only_treats_esrch_as_process_exit(self):
        for error in (errno.ESRCH, errno.EPERM, errno.EINVAL, 0):
            with self.subTest(error=error):
                library = Mock()
                library.proc_pidinfo.return_value = 0
                with patch.object(runner, 'PROCESS_LIBRARY', library), \
                        patch.object(runner.ctypes, 'get_errno', return_value=error):
                    if error == errno.ESRCH:
                        self.assertIsNone(runner.process_identity(42))
                    else:
                        with self.assertRaisesRegex(ValueError, 'process_identity_unavailable'):
                            runner.process_identity(42)

    def test_process_exit_before_signal_removes_only_exited_targets(self):
        for exiting in ({42}, {43}, {42, 43}):
            with self.subTest(exiting=exiting), tempfile.TemporaryDirectory() as temporary:
                tracker = runner.OwnedProcesses(Path(temporary))
                tracker.state.update(root_pid=42, session=42, root_start=[1, 1])
                rows = {pid: {'pid': pid, 'parent': 42 if pid != 42 else 1,
                              'group': 42, 'session': 42} for pid in (42, 43)}
                tracker.records = {pid: dict(row, start=[1, 1]) for pid, row in rows.items()}
                reads = {42: 0, 43: 0}

                def identity(pid):
                    reads[pid] += 1
                    if pid in exiting and reads[pid] >= (5 if pid == 42 else 3):
                        rows.pop(pid, None)
                        return None
                    return [1, 1]

                process = Mock(pid=42)
                process.poll.return_value = None
                with patch.object(runner, 'process_snapshot', side_effect=lambda: dict(rows)), \
                        patch.object(runner, 'process_identity', side_effect=identity), \
                        patch.object(runner.os, 'killpg', side_effect=lambda group, sig: rows.clear()) as kill:
                    tracker.drain(process)
                self.assertTrue(tracker.state['verified'], tracker.state['uncertainty'])
                remaining = {42, 43} - exiting
                if remaining:
                    kill.assert_called_once_with(42, signal.SIGTERM)
                    self.assertEqual({row['pid'] for row in tracker.state['signals'][0]['members']}, remaining)
                else:
                    kill.assert_not_called()

    def test_every_owned_signal_target_is_persisted_before_signal(self):
        with tempfile.TemporaryDirectory() as temporary:
            tracker = runner.OwnedProcesses(Path(temporary))
            tracker.state.update(root_pid=42, session=42, root_start=[1, 1])
            rows = {pid: {'pid': pid, 'parent': 42 if pid != 42 else 1,
                          'group': 42, 'session': 42} for pid in (42, 43)}
            tracker.records = {pid: dict(row, start=[1, 1]) for pid, row in rows.items()}
            process = Mock(pid=42)
            process.poll.return_value = None

            def signal_logged_group(group, sig):
                attempt = report.read(tracker.path)['signals'][-1]
                self.assertEqual(attempt['outcome'], 'pending')
                self.assertEqual(attempt['group'], group)
                self.assertEqual(attempt['signal'], int(sig))
                self.assertEqual(attempt['members'], list(tracker.records.values()))
                rows.clear()

            with patch.object(runner, 'process_snapshot', side_effect=lambda: dict(rows)), \
                    patch.object(runner, 'process_identity', return_value=[1, 1]), \
                    patch.object(runner.os, 'killpg', side_effect=signal_logged_group) as kill:
                tracker.drain(process)
            kill.assert_called_once_with(42, signal.SIGTERM)
            self.assertTrue(tracker.state['verified'])

    def test_attach_refuses_masked_or_shared_session_before_signalling(self):
        with tempfile.TemporaryDirectory() as temporary:
            tracker = runner.OwnedProcesses(Path(temporary))
            row = {'pid': 42, 'parent': os.getpid(), 'group': 42, 'session': 0}
            process = Mock(pid=42)
            process.poll.return_value = 0
            with patch.object(runner, 'process_snapshot', return_value={42: row}), \
                    patch.object(runner, 'process_identity', return_value=[1, 1]), \
                    patch.object(runner.os, 'getsid', return_value=0), patch.object(runner.os, 'killpg') as kill:
                with self.assertRaisesRegex(ValueError, 'root_session_not_private'):
                    tracker.attach(process)
                tracker.drain(process)
                kill.assert_not_called()
            self.assertFalse(tracker.state['verified'])

    def test_nonzero_root_exit_never_creates_cleanup_proof(self):
        with tempfile.TemporaryDirectory() as temporary:
            tracker = runner.OwnedProcesses(Path(temporary))
            tracker.state.update(root_pid=42, session=42, root_start=[1, 1])
            tracker.records[42] = {'pid': 42, 'parent': 1, 'group': 42, 'session': 42, 'start': [1, 1]}
            process = Mock(pid=42)
            process.poll.return_value = 7
            with patch.object(runner, 'process_snapshot', return_value={}), patch.object(runner.os, 'killpg') as kill:
                tracker.drain(process)
                kill.assert_not_called()
            self.assertFalse(tracker.state['verified'])
            self.assertIn('root_exited_before_session_drained', tracker.state['uncertainty'])

    def test_original_session_discovers_group_after_its_leader_exits(self):
        with tempfile.TemporaryDirectory() as temporary:
            tracker = runner.OwnedProcesses(Path(temporary))
            tracker.state.update(root_pid=42, session=42, root_start=[1, 1])
            tracker.records[42] = {'pid': 42, 'parent': 1, 'group': 42, 'session': 42, 'start': [1, 1]}
            table = {43: {'pid': 43, 'parent': 1, 'group': 43, 'session': 42}}
            process = Mock(pid=42)
            process.poll.return_value = 0
            with patch.object(runner, 'process_snapshot', side_effect=lambda: dict(table)), \
                    patch.object(runner, 'process_identity', return_value=[1, 1]), \
                    patch.object(runner.os, 'killpg', side_effect=lambda group, sig: table.clear()) as kill:
                tracker.drain(process)
                kill.assert_called_once_with(43, signal.SIGTERM)
            self.assertFalse(tracker.state['verified'])
            self.assertIn('root_exited_before_session_drained', tracker.state['uncertainty'])

    def test_observed_session_escape_rejects_without_signalling_escaped_group(self):
        with tempfile.TemporaryDirectory() as temporary:
            tracker = runner.OwnedProcesses(Path(temporary))
            tracker.state.update(root_pid=42, session=42, root_start=[1, 1])
            root = {'pid': 42, 'parent': 1, 'group': 42, 'session': 42}
            tracker.records[42] = dict(root, start=[1, 1])
            table = {42: root, 43: {'pid': 43, 'parent': 42, 'group': 43, 'session': 43}}
            process = Mock(pid=42)
            process.poll.return_value = None
            with patch.object(runner, 'process_snapshot', side_effect=lambda: dict(table)), \
                    patch.object(runner, 'process_identity', return_value=[1, 1]), \
                    patch.object(runner.os, 'killpg', side_effect=lambda group, sig: table.pop(group, None)) as kill:
                tracker.drain(process)
                kill.assert_called_once_with(42, signal.SIGTERM)
            self.assertIn(43, table)
            self.assertFalse(tracker.state['verified'])
            self.assertIn('process_left_private_session:43', tracker.state['uncertainty'])

    def test_normal_empty_session_proof_does_not_claim_other_sessions(self):
        with tempfile.TemporaryDirectory() as temporary:
            tracker = runner.OwnedProcesses(Path(temporary))
            tracker.state.update(root_pid=42, session=42, root_start=[1, 1])
            tracker.records[42] = {'pid': 42, 'parent': 1, 'group': 42, 'session': 42, 'start': [1, 1]}
            process = Mock(pid=42)
            process.poll.return_value = 0
            table = {43: {'pid': 43, 'parent': 1, 'group': 43, 'session': 43}}
            with patch.object(runner, 'process_snapshot', return_value=table), patch.object(runner.os, 'killpg') as kill:
                tracker.drain(process)
                kill.assert_not_called()
            self.assertTrue(tracker.state['verified'])
            self.assertEqual(tracker.state['scope'], 'private-session')
            self.assertEqual(tracker.state['groups'], [42])

    def test_normal_observed_tree_records_verified_cleanup(self):
        with process_evidence() as root:
            command = "import subprocess,sys,time; p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(.5)']); p.wait(); time.sleep(.5)"
            with patch.object(runner, 'sample', return_value=observation('finished')):
                row = runner.run_child(root, 'build-1', [sys.executable, '-c', command], {}, observation('preflight'))
            self.assertIsNone(row['reason'])
            self.assertEqual(row['exit_code'], 0)
            self.assertTrue(report.read(root / 'build-1/ownership.json')['verified'])
            runner.require_inactive_children(root)

    def test_report_requires_complete_declared_schedule_contract_and_distinct_processes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest, _ = self.freeze_reference(root)
            baseline = {'repository': str(root), 'sources': {'frozen.json': report.digest(manifest)},
                        'acceptance_contract': report.ACCEPTANCE_CONTRACT, 'repetitions': 1, 'schedule': report.schedule()}
            report.write(root / 'baseline.json', baseline)
            rows = []
            for index, task in enumerate(report.schedule(), 1):
                label = 'batch-' + str(index)
                (root / label).mkdir()
                report.write(root / label / 'invocation.json', {'pid': index})
                rows.append(dict(task, label=label, accepted=True, load_before=[1, 1, 1], load_after=[1, 1, 1]))
            report.write(root / 'results.json', rows)
            report.write(root / 'status.json', {'state': 'complete'})
            value = {'metrics': {'events': 1360, 'jumps': 0, 'over16': 0, 'wallP95': 1, 'wallMax': 2, 'cpuP95': 1},
                     'mount': {'scale': 2, 'locale': 'en_US', 'timeZone': 'Europe/Amsterdam'}}
            with patch.object(report, 'validate_batch', return_value=value):
                self.assertTrue(report.make_report(root, root / 'pass.md')['accepted'])
                for field, changed in [('acceptance_contract', 'historical-controlled'), ('repetitions', 0),
                                       ('schedule', report.schedule()[:-1])]:
                    report.write(root / 'baseline.json', dict(baseline, **{field: changed}))
                    self.assertFalse(report.make_report(root, root / (field + '.md'))['accepted'])
                report.write(root / 'baseline.json', baseline)
                report.write(root / 'results.json', rows[:-1])
                self.assertFalse(report.make_report(root, root / 'missing.md')['accepted'])
                report.write(root / 'results.json', [rows[1], rows[0], *rows[2:]])
                self.assertFalse(report.make_report(root, root / 'order.md')['accepted'])
                report.write(root / 'results.json', rows)
                report.write(root / rows[1]['label'] / 'invocation.json', {'pid': 1})
                self.assertFalse(report.make_report(root, root / 'pid.md')['accepted'])


if __name__ == '__main__':
    unittest.main()
