import hashlib
import json
import math
import re
from pathlib import Path


RENDERERS = ('native-product',)
ACCEPTANCE_CONTRACT = 'native-functional-continuity-2026-11-08'
ARCHIVED_CONTRACT = 'functional-continuity-2026-11-08'
ARCHIVED_RENDERERS = ('swiftui-reference', 'hosted-reference', 'native-product')
PRIMARY = {'channel': 480, 'fixture-root': 480, 'media-channel': 200, 'media-fixture-root': 200}
GROUPS = {'primary': PRIMARY, 'dense': {'dense-media-channel': 200, 'dense-media-fixture-root': 200},
          'loaded': {'loaded-media-channel': 200, 'loaded-media-fixture-root': 200}}
FILTERS = {
    'mount': r'^AgentPadKitTests.ChatScrollBenchmarkTests/testFreshProcessMount$',
    'primary': r'^AgentPadKitTests.ChatScrollContinuityTests/testNativeMixedHeightScrollContinuity$|^AgentPadKitTests.ChatScrollMediaTests/testNativeMediaPreciseScrollContinuityInChannelAndThread$',
    'dense': r'^AgentPadKitTests.ChatScrollMediaTests/testDenseReactionsPreciseScrollContinuityInChannelAndThread$',
    'loaded': r'^AgentPadKitTests.ChatScrollMediaTests/testLoadedImagesPreciseScrollContinuityInChannelAndThread$',
}
EXPECTED_TESTS = {
    'mount': {('ChatScrollBenchmarkTests', 'testFreshProcessMount')},
    'primary': {('ChatScrollContinuityTests', 'testNativeMixedHeightScrollContinuity'),
                ('ChatScrollMediaTests', 'testNativeMediaPreciseScrollContinuityInChannelAndThread')},
    'dense': {('ChatScrollMediaTests', 'testDenseReactionsPreciseScrollContinuityInChannelAndThread')},
    'loaded': {('ChatScrollMediaTests', 'testLoadedImagesPreciseScrollContinuityInChannelAndThread')},
}
ARCHIVED_FILTERS = dict(FILTERS, primary=FILTERS['primary'].replace('/testNativeMedia', '/testMedia'))
ARCHIVED_TESTS = dict(EXPECTED_TESTS, primary={
    ('ChatScrollContinuityTests', 'testNativeMixedHeightScrollContinuity'),
    ('ChatScrollMediaTests', 'testMediaPreciseScrollContinuityInChannelAndThread')})
NUMBERS = ('requested', 'actual', 'documentHeight', 'milliseconds', 'threadCpuMilliseconds',
           'anchorBefore', 'anchorAfter', 'error', 'layoutError')
BOUNDARY = ('Functional continuity acceptance only (owner decision 2026-11-08). Timings and load are diagnostics, '
            'with no timing or load threshold. Main-thread busy wall and thread CPU in normalized quiet mode; five-second recorded observations, '
            'not continuous load proof, FPS, GPU/WindowServer cost, input-to-photon latency or hardware momentum. '
            'Hardware/VoiceOver acceptance remains a separate pre-release requirement.')


def read(path: Path):
    with path.open() as source:
        return json.load(source)


def write(path: Path, value) -> None:
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')
    temporary.replace(path)


def digest(path: Path) -> str:
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise ValueError(reason)


def finite(value) -> bool:
    return type(value) in (int, float) and math.isfinite(value)


def signature(raw: list[dict]) -> list[list]:
    return [[item[key] for key in ('kind', 'requested', 'phase', 'segment')] for item in raw]


def signatures(count: int) -> list[list]:
    result = []
    for direction in (-1, 1):
        for index in range(count // 2):
            if count == 480 and index == 200:
                result.append(['phase-end', 0, 4, 'precise'])
            magnitude = (2, 4, 8, 12, 16, 12, 8, 4)[index % 8] if index < 200 else max(1, 16 - (index - 200) // 2)
            result.append(['up' if direction < 0 else 'down', direction * magnitude,
                           1 if index in (0, 200) else 2, 'decaying-precise' if index >= 200 else 'precise'])
        result.append(['phase-end', 0, 4, 'decaying-precise' if count == 480 else 'precise'])
    return result


def load_reference(path: Path) -> dict:
    manifest = read(path)
    require(manifest['primaryMovingEvents'] == 1360 and manifest['jumpTolerancePoints'] == .75,
            'reference_contract_changed')
    cases = {item['name']: item for item in manifest['cases']}
    require(len(manifest['cases']) == 4 and set(cases) == set(PRIMARY), 'reference_cases_changed')
    result = {'manifest': str(path.resolve()), 'sha256': digest(path), 'files': {}, 'cases': {}}
    for name, count in PRIMARY.items():
        item = cases[name]
        expected = signatures(count)
        require(item['movingEvents'] == count and item['rawEvents'] == len(expected), 'reference_count_changed')
        require(item['signatures'] == expected, 'reference_signature_changed')
        require(item['heightPoints'] == 600 and item['widthPoints'] == (420 if name.endswith('fixture-root') else 760),
                'reference_viewport_changed')
        paths = {'samples': path.parent / item['referenceSamples'], 'fixture': path.parent / item['fixtureValues'],
                 'settings': path.parent / 'scroll' / (name + '-settings.json')}
        require(signature(read(paths['samples'])) == expected, 'reference_raw_signature_changed')
        result['cases'][name] = {'signatures': expected, 'fixture': read(paths['fixture']), 'settings': read(paths['settings'])}
        for target in paths.values():
            result['files'][str(target.resolve())] = digest(target)
    return result


def reference_unchanged(reference: dict) -> bool:
    files = dict(reference['files'], **{reference['manifest']: reference['sha256']})
    if not all(Path(name).is_file() and digest(Path(name)) == value for name, value in files.items()):
        return False
    try:
        return load_reference(Path(reference['manifest'])) == reference
    except (ValueError, KeyError, TypeError, OSError):
        return False


def stats(samples: list[dict]) -> dict:
    require(bool(samples), 'empty_samples')
    for sample in samples:
        require(sample.get('valid') is True and isinstance(sample.get('anchor'), str) and bool(sample['anchor']), 'invalid_anchor')
        require(all(finite(sample.get(key)) for key in NUMBERS), 'nonfinite_or_missing_sample')
        require(sample['milliseconds'] >= 0 and sample['threadCpuMilliseconds'] >= 0 and sample['documentHeight'] > 0,
                'negative_timing_or_invalid_geometry')
        require(abs(sample['anchorAfter'] - sample['anchorBefore'] + sample['requested'] - sample['error']) < 1e-7,
                'movement_error_mismatch')
        require(abs(sample['anchorAfter'] - sample['anchorBefore'] + sample['actual'] - sample['layoutError']) < 1e-7,
                'layout_error_mismatch')
        require(isinstance(sample.get('heights'), dict) and bool(sample['heights']) and
                all(finite(value) and value >= 0 for value in sample['heights'].values()), 'invalid_height')
    wall = sorted(sample['milliseconds'] for sample in samples)
    cpu = sorted(sample['threadCpuMilliseconds'] for sample in samples)
    return {'events': len(samples), 'jumps': sum(abs(sample['error']) > .75 for sample in samples),
            'over16': sum(value > 16 for value in wall), 'wallP50': wall[math.floor((len(wall) - 1) * .5)],
            'wallP95': wall[math.floor((len(wall) - 1) * .95)], 'wallMax': wall[-1],
            'cpuP95': cpu[math.floor((len(cpu) - 1) * .95)], 'maxError': max(abs(sample['error']) for sample in samples)}


def environment_allowed(state: dict) -> bool:
    loads = state.get('load', [])
    return (len(loads) == 3 and all(finite(value) and value >= 0 for value in loads)
            and state.get('locked') is False
            and finite(state.get('free_bytes')) and state['free_bytes'] >= 3 * 2**30)


def validate_observations(checks: list[dict], started: float, finished: float) -> None:
    require(len(checks) >= 2 and checks[0]['stage'] == 'preflight' and checks[-1]['stage'] == 'finished', 'missing_preflight_or_final_observation')
    require(all(environment_allowed(state) for state in checks), 'console_disk_or_load_record_invalid')
    times = [state['monotonic'] for state in checks]
    require(all(finite(value) for value in times) and times[0] <= started <= finished <= times[-1], 'observation_span_invalid')
    require(all(0 <= after - before <= 7 for before, after in zip(times, times[1:])), 'observation_gap')


def validate_tests(content: str, kind: str, exit_code: int, expected_tests: dict = EXPECTED_TESTS) -> dict:
    require(exit_code == 0, 'test_exit_nonzero')
    require('QUIET FAIL:' not in content, 'quiet_failure')
    proofs = re.findall(r'QUIET PASS: frontmostApplication checks=(\d+) test-app-frontmost=(\d+); window/screen checks=(\d+) intersections=(\d+);[^\n]*os-key-main=(\d+)', content)
    parsed = [tuple(map(int, values)) for values in proofs]
    active = [values for values in parsed if values[0] > 0 and values[2] > 0]
    require(bool(active) and all(front == intersection == focus == 0 for _, front, _, intersection, focus in parsed), 'missing_or_failed_active_quiet_proof')
    passed = re.findall(r"Test Case '-\[AgentPadKitTests\.(\w+) (\w+)\]' passed", content)
    expected = expected_tests[kind]
    require(len(passed) == len(expected) and set(passed) == expected, 'test_identity_or_count_mismatch')
    count = len(expected)
    require(re.search(rf'Executed {count} tests?, with 0 failures', content) is not None, 'test_summary_missing')
    require(re.search(r"Test Case .* (failed|skipped)", content) is None, 'failed_or_skipped_test')
    return {'frontmostChecks': sum(row[0] for row in active), 'screenChecks': sum(row[2] for row in active), 'tests': count}


def batch_data(folder: Path, completion: dict, reference: dict, contract: str = ACCEPTANCE_CONTRACT) -> dict:
    require(contract in (ACCEPTANCE_CONTRACT, ARCHIVED_CONTRACT), 'unknown_acceptance_contract')
    renderers = RENDERERS if contract == ACCEPTANCE_CONTRACT else ARCHIVED_RENDERERS
    filters = FILTERS if contract == ACCEPTANCE_CONTRACT else ARCHIVED_FILTERS
    tests = EXPECTED_TESTS if contract == ACCEPTANCE_CONTRACT else ARCHIVED_TESTS
    kind, renderer = completion['kind'], completion['renderer']
    require(renderer in renderers and kind in filters, 'unknown_batch')
    require(completion.get('reason') is None, completion.get('reason') or 'rejected')
    invocation = read(folder / 'invocation.json')
    command = invocation['command']
    require(invocation['renderer'] == renderer and invocation['mode'] == 'normalized-quiet'
            and type(invocation['pid']) is int and invocation['pid'] > 0
            and command[1:] == ['scripts/test-quiet.py', '--skip-build', '--log-dir', str(folder), '--filter', filters[kind]],
            'invocation_contract_changed')
    validate_observations(read(folder / 'environment.json'), completion['started'], completion['finished'])
    quiet = validate_tests((folder / 'tests.log').read_text(), kind, completion['exit_code'], tests)
    require(completion.get('sources_unchanged') is True and completion.get('binary_unchanged') is True, 'source_or_binary_drift')
    samples_root = folder / 'samples' / renderer
    result = {'quiet': quiet}
    if kind == 'mount':
        value = read(samples_root / 'mount.json')
        require(value['renderer'] == renderer and value['width'] == 760 and value['height'] == 600, 'mount_identity_or_viewport')
        require(all(finite(value.get(key)) and value[key] > 0 for key in ('firstOpenMS', 'rssBefore', 'rssAfterOpen', 'scale')), 'mount_diagnostics_invalid')
        require(value['appKitSettings'] == reference['cases']['channel']['settings'], 'mount_settings_changed')
        result['mount'] = value
        return result
    all_samples = []
    result['cases'] = {}
    expected_files = set()
    for name, count in GROUPS[kind].items():
        base = name.removeprefix('dense-').removeprefix('loaded-')
        frozen = reference['cases'][base]
        raw = read(samples_root / (name + '.json'))
        require(signature(raw) == frozen['signatures'], 'event_signature_mismatch:' + name)
        require(all(finite(sample.get(key)) for sample in raw
                    for key in ('requested', 'actual', 'documentHeight', 'milliseconds', 'threadCpuMilliseconds')),
                'nonfinite_record:' + name)
        moving = [sample for sample in raw if sample['requested'] != 0]
        require(len(moving) == count, 'event_count_mismatch:' + name)
        require(read(samples_root / (name + '-fixture.json')) == frozen['fixture'], 'fixture_changed:' + name)
        require(read(samples_root / (name + '-settings.json')) == frozen['settings'], 'settings_changed:' + name)
        result['cases'][name] = stats(moving)
        all_samples.extend(moving)
        expected_files.update(name + suffix for suffix in ('.json', '-fixture.json', '-settings.json', '-counters.json'))
        counters = read(samples_root / (name + '-counters.json'))
        require(counters['renderer'] == renderer, 'counter_renderer_mismatch')
        if renderer == 'native-product':
            require(counters['cellsReused'] > 0 and counters['cellsCreated'] > 0, 'no_native_reuse')
            require(0 < counters['heightEntries'] <= 512 and 0 < counters['contentEntries'] <= 512
                    and 0 < counters['heightBytes'] <= 256 * 1024 and 0 < counters['contentBytes'] <= 4 * 1024**2,
                    'native_cache_budget')
    require({path.name for path in samples_root.glob('*.json')} == expected_files, 'unexpected_or_missing_sample_files')
    result['metrics'] = stats(all_samples)
    return result


def native_verdict(result: dict, renderer: str, kind: str) -> None:
    if renderer == 'native-product' and kind != 'mount':
        require(result['metrics']['jumps'] == 0, 'native_jumps')
        if kind == 'primary':
            require(result['metrics']['events'] == 1360, 'native_primary_count')


def validate_batch(folder: Path, completion: dict, reference: dict, contract: str = ACCEPTANCE_CONTRACT) -> dict:
    result = batch_data(folder, completion, reference, contract)
    native_verdict(result, completion['renderer'], completion['kind'])
    return result


def schedule(repetitions: int = 1, contract: str = ACCEPTANCE_CONTRACT) -> list[dict]:
    require(contract in (ACCEPTANCE_CONTRACT, ARCHIVED_CONTRACT), 'unknown_acceptance_contract')
    orders = [RENDERERS] * repetitions if contract == ACCEPTANCE_CONTRACT else [
        ARCHIVED_RENDERERS[index:] + ARCHIVED_RENDERERS[:index] for index in range(repetitions)]
    return [{'repetition': rep, 'position': position, 'renderer': renderer, 'kind': kind}
            for rep, order in enumerate(orders, 1)
            for position, renderer in enumerate(order, 1) for kind in FILTERS]


def make_report(root: Path, output: Path) -> dict:
    require(not output.exists() and not output.with_suffix('.json').exists(), 'report_output_exists')
    baseline = read(root / 'baseline.json')
    reference = read(root / 'reference.json')
    results = read(root / 'results.json')
    state = read(root / 'status.json')
    failures = []
    contract = baseline.get('acceptance_contract')
    if contract not in (ACCEPTANCE_CONTRACT, ARCHIVED_CONTRACT):
        failures.append('acceptance_contract_changed_use_fresh_root')
    repetitions = baseline.get('repetitions')
    valid_schedule = type(repetitions) is int and repetitions in (1, 2, 3) and contract in (ACCEPTANCE_CONTRACT, ARCHIVED_CONTRACT)
    expected_schedule = schedule(repetitions, contract) if valid_schedule else []
    if not valid_schedule or baseline.get('schedule') != expected_schedule:
        failures.append('incomplete_or_invalid_schedule')
    accepted = []
    for row in results:
        if row['accepted']:
            try:
                verified = validate_batch(root / row['label'], row, reference, contract)
                accepted.append(dict(row, verified=verified))
            except (ValueError, KeyError, TypeError, OSError) as error:
                failures.append(row['label'] + ': ' + str(error))
    keys = [(row['repetition'], row['renderer'], row['kind']) for row in accepted]
    expected = [(row['repetition'], row['renderer'], row['kind']) for row in expected_schedule]
    complete = bool(expected) and len(keys) == len(expected) and keys == expected and state['state'] == 'complete'
    unchanged = reference_unchanged(reference)
    if not unchanged:
        failures.append('reference_changed')
    source_changes = [name for name, value in baseline['sources'].items()
                      if not (Path(baseline['repository']) / name).is_file()
                      or digest(Path(baseline['repository']) / name) != value]
    if source_changes:
        failures.append('source_changed: ' + ', '.join(source_changes))
    additions = [str(path.relative_to(Path(baseline['repository'])))
                 for directory in ('Sources', 'Tests', 'scripts')
                 for path in (Path(baseline['repository']) / directory).rglob('*')
                 if path.is_file() and '__pycache__' not in path.parts and path.suffix != '.pyc'
                 and str(path.relative_to(Path(baseline['repository']))) not in baseline['sources']]
    if additions:
        failures.append('source_added: ' + ', '.join(additions))
    pids = [read(root / row['label'] / 'invocation.json')['pid'] for row in accepted]
    if len(pids) != len(set(pids)):
        failures.append('fresh_process_identity_reused')
    environments = [(row['verified']['mount']['scale'], row['verified']['mount']['locale'], row['verified']['mount']['timeZone'])
                    for row in accepted if row['kind'] == 'mount']
    if environments and any(value != environments[0] for value in environments):
        failures.append('mount_environment_changed')
    summary = {'accepted': complete and unchanged and not failures, 'complete': complete,
               'acceptance_contract': contract, 'timings': 'diagnostics_only',
               'failures': failures, 'batches': accepted, 'rejected': [row for row in results if not row['accepted']],
               'state': state, 'boundary': BOUNDARY, 'regression': baseline.get('regression', 'See the separately retained full Chat and repository logs.'),
               'parity': baseline.get('parity', 'See the separately retained native behavior and parity evidence.')}
    lines = ['# Native functional scroll workloads' if contract == ACCEPTANCE_CONTRACT else '# Archived W10 functional scroll workloads',
             '', 'Workload verdict: ' + ('PASS' if summary['accepted'] else 'INCOMPLETE / FAIL'), '',
             BOUNDARY, '', '## Primary (each repetition independently)', '']
    for row in accepted:
        if row['kind'] != 'primary':
            continue
        value = row['verified']['metrics']
        lines.append(f"- Rep {row['repetition']} {row['renderer']}: {value['events']} events; {value['jumps']} jumps; "
                     f"timing diagnostics: {value['over16']} >16ms; wall p95/max {value['wallP95']:.3f}/{value['wallMax']:.3f}ms; "
                     f"CPU p95 {value['cpuP95']:.3f}ms; load before/after {row['load_before']} / {row['load_after']}.")
    lines += ['', '## Supplemental and mount diagnostics', '']
    for row in accepted:
        if row['kind'] == 'primary':
            continue
        value = row['verified'].get('metrics', row['verified'].get('mount'))
        lines.append(f"- Rep {row['repetition']} {row['renderer']} {row['kind']}: {json.dumps(value, sort_keys=True)}")
    lines += ['', '## Rejected attempts', '']
    lines += [f"- {row['label']}: {row['reason']}; exit {row['exit_code']}; load {row['load_before']} / {row['load_after']}"
              for row in summary['rejected']] or ['None.']
    lines += ['', '## Mutation, regression and parity evidence', '', str(summary['regression']), '', str(summary['parity']), '',
              'Every attempt retains its invocation, raw event/fixture/settings data, five-second environment observations and quiet XCTest logs. '
              'Phase-end records are retained and excluded only from moving-event statistics. No timing outliers are removed. '
              'Controls require valid data and quiet containment. Native primary and supplemental workloads require zero jumps; '
              'there is no timing or load acceptance threshold for any renderer.', '',
              'State: ' + json.dumps(state, sort_keys=True), 'Validation errors: ' + json.dumps(failures), '']
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text('\n'.join(lines))
    write(output.with_suffix('.json'), summary)
    return summary
