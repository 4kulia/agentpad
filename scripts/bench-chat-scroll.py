import argparse
import ctypes
import ctypes.util
import errno
import fcntl
import json
import os
import plistlib
import signal
import subprocess
import sys
import time
from pathlib import Path

from chat_scroll_report import ACCEPTANCE_CONTRACT, FILTERS, batch_data, digest, environment_allowed, load_reference, make_report, native_verdict
from chat_scroll_report import read, reference_unchanged, require, schedule, validate_batch, write


REPOSITORY = Path(__file__).resolve().parent.parent


class ProcessInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in
                ('flags', 'status', 'exit_status', 'pid', 'parent', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('command', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ('files', 'group', 'jobs', 'tty', 'tty_group', 'nice')]
    _fields_ += [('started_seconds', ctypes.c_uint64), ('started_microseconds', ctypes.c_uint64)]


PROCESS_LIBRARY = ctypes.CDLL(ctypes.util.find_library('proc') or 'libproc.dylib', use_errno=True) if sys.platform == 'darwin' else None
if PROCESS_LIBRARY is not None:
    PROCESS_LIBRARY.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    PROCESS_LIBRARY.proc_pidinfo.restype = ctypes.c_int


def process_identity(pid: int) -> list[int] | None:
    require(PROCESS_LIBRARY is not None, 'process_ownership_requires_macos')
    value = ProcessInfo()
    size = ctypes.sizeof(value)
    ctypes.set_errno(0)
    count = PROCESS_LIBRARY.proc_pidinfo(pid, 3, 0, ctypes.byref(value), size)
    if count == 0:
        require(ctypes.get_errno() == errno.ESRCH, 'process_identity_unavailable')
        return None
    require(count == size and value.pid == pid, 'process_identity_unavailable')
    return [value.started_seconds, value.started_microseconds]


def process_snapshot() -> dict[int, dict]:
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,pgid=,stat='], text=True, timeout=10).splitlines()
    result = {}
    for row in rows:
        parts = row.split()
        if len(parts) != 4 or parts[3].startswith('Z'):
            continue
        pid = int(parts[0])
        try:
            session = os.getsid(pid)
        except ProcessLookupError:
            continue
        require(session > 0, 'process_session_unavailable')
        result[pid] = {'pid': pid, 'parent': int(parts[1]), 'group': int(parts[2]), 'session': session}
    return result


class OwnedProcesses:
    # The fixed quiet Python -> Swift -> XCTest chain stays in this private
    # session. Polling cannot prove absence of an unobserved detached session;
    # never represent this bounded check as general process-tree containment.
    def __init__(self, folder: Path):
        self.path = folder / 'ownership.json'
        self.records: dict[int, dict] = {}
        self.state = {'version': 1, 'scope': 'private-session', 'root_pid': None, 'session': None, 'root_start': None,
                      'processes': [], 'groups': [], 'signals': [], 'verified': False, 'uncertainty': []}
        self.stopping = False
        self.persist()

    def persist(self) -> None:
        self.state['processes'] = list(self.records.values())
        self.state['groups'] = sorted(set(self.state['groups']) | {row['group'] for row in self.records.values()})
        write(self.path, self.state)

    def uncertain(self, reason: str) -> None:
        if reason not in self.state['uncertainty']:
            self.state['uncertainty'].append(reason)

    def attach(self, process: subprocess.Popen) -> None:
        self.state['root_pid'] = process.pid
        table = process_snapshot()
        identity = process_identity(process.pid)
        require(process.pid in table and identity is not None, 'root_identity_unavailable')
        require(process.pid > 1 and table[process.pid]['parent'] == os.getpid()
                and table[process.pid]['group'] == table[process.pid]['session'] == os.getsid(process.pid) == process.pid
                and process.pid not in (os.getpgrp(), os.getsid(0)), 'root_session_not_private')
        self.state.update(session=process.pid, root_start=identity)
        self.records[process.pid] = dict(table[process.pid], start=identity)
        self.persist()

    def observe(self) -> tuple[dict[int, dict], dict[int, dict]]:
        table = process_snapshot()
        live = {}
        session = self.state['session']
        if session is None:
            self.uncertain('private_session_not_attached')
            self.persist()
            return table, live
        if session in table:
            identity = process_identity(session)
            if identity is None:
                table.pop(session)
            elif identity != self.state['root_start']:
                self.uncertain('private_session_identity_changed')
                self.persist()
                return table, live
        for pid, recorded in list(self.records.items()):
            if pid not in table:
                continue
            identity = process_identity(pid)
            if identity is None:
                table.pop(pid)
                continue
            if identity != recorded['start']:
                self.uncertain('process_identity_changed:' + str(pid))
                continue
            current = table[pid]
            if not self.stopping and current['parent'] != recorded['parent'] and recorded['parent'] in self.records:
                self.uncertain('parent_lineage_lost:' + str(pid))
            if current['group'] != recorded['group'] or current['session'] != recorded['session']:
                self.records[pid] = dict(current, start=identity)
            if current['session'] != session:
                self.uncertain('process_left_private_session:' + str(pid))
            else:
                live[pid] = self.records[pid]
        # The original SID remains discoverable even after its leader exits.
        # Session membership admits another PGID, never another session.
        additions = [row for pid, row in table.items() if pid not in self.records
                     and (row['session'] == session or row['parent'] in live)]
        for row in additions:
            identity = process_identity(row['pid'])
            if identity is None:
                table.pop(row['pid'])
                continue
            self.records[row['pid']] = dict(row, start=identity)
            if row['session'] != session:
                self.uncertain('process_left_private_session:' + str(row['pid']))
            else:
                live[row['pid']] = self.records[row['pid']]
        self.persist()
        return table, live

    def drain(self, process: subprocess.Popen) -> None:
        table, live = self.observe()
        code = process.poll()
        if code is not None and (code != 0 or live):
            self.uncertain('root_exited_before_session_drained')
        self.stopping = True
        for sig in (signal.SIGTERM, signal.SIGKILL):
            table, live = self.observe()
            groups = sorted({row['group'] for row in live.values()}, key=lambda group: (group == process.pid, group))
            for group in groups:
                members = {}
                for pid, row in list(table.items()):
                    if row['group'] != group:
                        continue
                    identity = process_identity(pid)
                    if identity is None:
                        table.pop(pid)
                        live.pop(pid, None)
                    else:
                        members[pid] = identity
                if not members:
                    continue
                if group <= 1 or group in (os.getpgrp(), os.getsid(0)) or any(
                        pid not in live or live[pid]['session'] != self.state['session']
                        or live[pid]['session'] == os.getsid(0)
                        or identity != live[pid]['start'] for pid, identity in members.items()):
                    self.uncertain('group_identity_not_proven:' + str(group))
                    continue
                attempt = {'group': group, 'signal': int(sig), 'members': [live[pid] for pid in members],
                           'time': time.time(), 'outcome': 'pending'}
                self.state['signals'].append(attempt)
                self.persist()
                try:
                    os.killpg(group, sig)
                except ProcessLookupError:
                    attempt['outcome'] = 'already_exited'
                except OSError as error:
                    attempt['outcome'] = 'failed'
                    attempt['errno'] = error.errno
                    self.uncertain('owned_signal_failed:' + str(group))
                    self.persist()
                    raise
                else:
                    attempt['outcome'] = 'sent'
                self.persist()
            deadline = time.monotonic() + 3
            while live and time.monotonic() < deadline:
                time.sleep(.1)
                table, live = self.observe()
            if not live:
                break
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.uncertain('owned_root_did_not_exit')
        table, live = self.observe()
        if live or any(row['session'] == self.state['session'] or row['group'] in self.state['groups'] for row in table.values()):
            self.uncertain('owned_descendants_did_not_exit')
        self.state['verified'] = bool(self.records) and not self.state['uncertainty']
        self.state['finished'] = time.time()
        self.persist()


def snapshot_sources(repository: Path) -> dict:
    paths = [repository / 'Package.swift', repository / 'Package.resolved']
    for directory in ('Sources', 'Tests', 'scripts'):
        paths.extend(path for path in (repository / directory).rglob('*')
                     if path.is_file() and '__pycache__' not in path.parts and path.suffix != '.pyc')
    return {str(path.relative_to(repository)): digest(path) for path in sorted(paths)}


def binary_hashes() -> dict:
    folder = (REPOSITORY / '.build/debug').resolve()
    products = [path for bundle in folder.glob('*.xctest') for path in (bundle / 'Contents/MacOS').glob('*') if path.is_file()]
    require(bool(products), 'missing_test_binaries')
    paths = products + [folder / 'libAgentPadQuietInterposer.dylib', folder / 'libAgentPadQuietTestSupport.dylib']
    paths.extend(path for path in (folder / 'PackageFrameworks').rglob('*') if path.is_file() and path.suffix == '')
    return {str(path): digest(path) for path in paths}


def binaries_unchanged(expected: dict) -> bool:
    return all(Path(name).is_file() and digest(Path(name)) == value for name, value in expected.items())


def sample(root: Path, label: str, stage: str) -> dict:
    df = subprocess.check_output(['df', '-k', str(REPOSITORY)], text=True, timeout=10)
    console = plistlib.loads(subprocess.check_output(['ioreg', '-n', 'Root', '-d1', '-a'], timeout=10))
    state = {'time': time.time(), 'monotonic': time.monotonic(), 'label': label, 'stage': stage,
             'load': list(os.getloadavg()), 'locked': console.get('IOConsoleLocked'),
             'free_bytes': int(df.splitlines()[-1].split()[3]) * 1024, 'df': df}
    with (root / 'gate-checks.jsonl').open('a') as output:
        output.write(json.dumps(state) + '\n')
        output.flush()
    return state


def wait_gate(root: Path, label: str, budget: float) -> dict | None:
    state_path = root / 'wait.json'
    accounting = read(state_path)
    began = time.monotonic()
    while True:
        state = sample(root, label, 'preflight')
        now = time.time()
        if accounting.get('waiting_since') is not None:
            require(now >= accounting['waiting_since'], 'wait_clock_moved_backwards')
            accounting['seconds'] += now - accounting['waiting_since']
        accounting['waiting_since'] = None
        write(state_path, accounting)
        print(json.dumps({'gate': label, 'load': state['load'], 'locked': state['locked'],
                          'free_GiB': state['free_bytes'] / 2**30, 'waited_seconds': accounting['seconds']}), flush=True)
        require(state['free_bytes'] >= 3 * 2**30, 'disk_below_3GiB')
        require(environment_allowed(dict(state, locked=False)), 'disk_or_load_record_invalid')
        if state['locked'] is False:
            return state
        accounting['waiting_since'] = now
        write(state_path, accounting)
        if time.monotonic() - began + 120 > budget:
            return None
        time.sleep(120)


def group_members(group: int) -> list[int]:
    rows = subprocess.check_output(['ps', '-axo', 'pid=,pgid=,stat='], text=True, timeout=10).splitlines()
    return [int(parts[0]) for row in rows if len(parts := row.split()) == 3
            and int(parts[1]) == group and not parts[2].startswith('Z')]


def require_inactive_children(root: Path) -> None:
    for folder in sorted([*root.glob('build-*'), *root.glob('rep-*-attempt-*')]):
        if not folder.is_dir():
            continue
        invocation = folder / 'invocation.json'
        require(invocation.exists(), 'prior_child_ownership_record_missing:' + folder.name)
        pid = read(invocation).get('pid')
        require(type(pid) is int and pid > 0, 'prior_child_ownership_record_incomplete:' + folder.name)
        ownership = folder / 'ownership.json'
        require(ownership.exists(), 'prior_child_cleanup_proof_missing:' + folder.name)
        proof = read(ownership)
        require(proof.get('version') == 1 and proof.get('scope') == 'private-session'
                and proof.get('root_pid') == proof.get('session') == pid and proof.get('verified') is True
                and proof.get('uncertainty') == [] and proof.get('processes') and proof.get('finished') is not None
                and isinstance(proof.get('groups'), list) and pid in proof['groups']
                and all(type(group) is int and group > 0 for group in proof['groups']),
                'prior_child_cleanup_unverified:' + folder.name)
        require(not any(group_members(group) for group in proof['groups']), 'prior_child_group_still_running:' + folder.name)


def run_child(root: Path, label: str, command: list[str], environment: dict,
              preflight: dict) -> dict:
    folder = root / label
    folder.mkdir(exist_ok=False)
    checks = [preflight]
    reason = None
    started = time.monotonic()
    ownership = OwnedProcesses(folder)
    interrupted = []
    signals = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    handlers = {value: signal.getsignal(value) for value in signals}
    for value in signals:
        signal.signal(value, lambda number, frame: interrupted.append(number))
    process = None
    try:
        with (folder / 'runner.log').open('w') as output:
            invocation = {'command': command, 'pid': None, 'started': started,
                          'renderer': environment.get('AGENTPAD_CHAT_BENCH_RENDERER'), 'mode': 'normalized-quiet'}
            write(folder / 'invocation.json', invocation)
            process = subprocess.Popen(command, cwd=REPOSITORY, env=environment, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            write(folder / 'invocation.json', dict(invocation, pid=process.pid))
            ownership.attach(process)
            next_sample = time.monotonic() + 5
            while process.poll() is None and not interrupted:
                try:
                    process.wait(timeout=.25)
                except subprocess.TimeoutExpired:
                    pass
                ownership.observe()
                if ownership.state['uncertainty']:
                    reason = 'owned_cleanup_unverified'
                    break
                if time.monotonic() < next_sample:
                    continue
                state = sample(root, label, 'running')
                next_sample = time.monotonic() + 5
                checks.append(state)
                write(folder / 'environment.json', checks)
                if state['locked'] is not False:
                    reason = 'console_unavailable'
                elif not environment_allowed(state):
                    reason = 'disk_or_load_record_invalid'
                elif time.monotonic() - started > 1800:
                    reason = 'child_deadline_exceeded'
                if reason:
                    break
    finally:
        try:
            if process is not None:
                ownership.drain(process)
        finally:
            for value, handler in handlers.items():
                signal.signal(value, handler)
    if interrupted:
        reason = 'interrupted_attempt'
    if ownership.state['verified'] is not True:
        reason = 'owned_cleanup_unverified'
    finished = time.monotonic()
    checks.append(sample(root, label, 'finished'))
    write(folder / 'environment.json', checks)
    if checks[-1]['locked'] is not False:
        reason = reason or 'console_unavailable'
    elif not environment_allowed(checks[-1]):
        reason = reason or 'disk_or_load_record_invalid'
    return {'label': label, 'reason': reason, 'exit_code': process.returncode, 'started': started, 'finished': finished,
            'load_before': checks[0]['load'], 'load_after': checks[-1]['load'],
            'load_max': [max(item['load'][index] for item in checks) for index in range(3)]}


def clean_environment() -> dict:
    require(not any(value for key, value in os.environ.items() if key.startswith('AGENTPAD_CHAT_NATIVE_W09')), 'capture_mode_not_allowed')
    require(not any(key in os.environ for key in ('AGENTPAD_CHAT_BENCH_RENDERER', 'AGENTPAD_CHAT_BENCH_MEDIA_FIXTURE', 'AGENTPAD_SCROLL_EVIDENCE')),
            'benchmark_environment_must_be_owned_by_runner')
    return dict(os.environ)


def recover_interrupted(root: Path, results: list[dict], tasks: list[dict]) -> None:
    require_inactive_children(root)
    recorded = {row['label'] for row in results}
    for task in tasks:
        prefix = f"rep-{task['repetition']}-{task['position']}-{task['renderer']}-{task['kind']}-attempt-"
        for folder in sorted(root.glob(prefix + '*')):
            if folder.name in recorded:
                continue
            completion = folder / 'completion.json'
            if completion.exists():
                row = read(completion)
                require(all(row[key] == task[key] for key in task) and row['label'] == folder.name, 'recovery_identity_mismatch')
            else:
                checks = read(folder / 'environment.json') if (folder / 'environment.json').exists() else []
                row = dict(task, label=folder.name, accepted=False, reason='interrupted_attempt', exit_code=None,
                           load_before=checks[0]['load'] if checks else None, load_after=checks[-1]['load'] if checks else None)
                write(completion, row)
            results.append(row)
            write(root / 'results.json', results)


def initialize(args) -> dict:
    require(not args.run_root.exists(), 'run_root_already_exists_use_explicit_resume')
    require(not args.run_root.is_relative_to(REPOSITORY), 'evidence_root_must_be_outside_checkout')
    reference = load_reference(args.reference_manifest)
    args.run_root.mkdir(parents=True)
    write(args.run_root / 'reference.json', reference)
    write(args.run_root / 'primary-media-fixture.json', reference['cases']['media-channel']['fixture'])
    write(args.run_root / 'results.json', [])
    write(args.run_root / 'wait.json', {'seconds': 0})
    baseline = {'repository': str(REPOSITORY), 'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPOSITORY, text=True).strip(),
                'sources': snapshot_sources(REPOSITORY), 'reference_manifest': str(args.reference_manifest),
                'mode': args.mode, 'acceptance_contract': ACCEPTANCE_CONTRACT, 'repetitions': args.repetitions,
                'schedule': schedule(args.repetitions)[:args.limit], 'started': time.time(),
                'machine': {'os': subprocess.check_output(['sw_vers'], text=True).strip(),
                            'hardware': subprocess.check_output(['sysctl', '-n', 'hw.model'], text=True).strip(),
                            'swift': subprocess.check_output(['xcrun', 'swift', '--version'], text=True).strip()},
                'build': None}
    write(args.run_root / 'baseline.json', baseline)
    write(args.run_root / 'status.json', {'state': 'initialized'})
    return baseline


def execute(args) -> int:
    environment = clean_environment()
    root = args.run_root
    baseline = read(root / 'baseline.json') if args.resume else initialize(args)
    require(baseline.get('acceptance_contract') == ACCEPTANCE_CONTRACT, 'acceptance_contract_changed_use_fresh_root')
    require(baseline['repository'] == str(REPOSITORY) and baseline['mode'] == args.mode, 'resume_identity_changed')
    require(baseline.get('repetitions') == args.repetitions, 'resume_repetitions_changed')
    require(baseline['schedule'] == schedule(args.repetitions)[:args.limit], 'resume_schedule_changed')
    reference = read(root / 'reference.json')
    require(reference['manifest'] == str(args.reference_manifest), 'resume_reference_changed')
    require(reference_unchanged(reference), 'reference_changed')
    require(read(root / 'primary-media-fixture.json') == reference['cases']['media-channel']['fixture'], 'frozen_media_fixture_changed')
    require(snapshot_sources(REPOSITORY) == baseline['sources'], 'source_changed')
    with (root / 'runner.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        require_inactive_children(root)
        if baseline['build'] is None:
            label = 'build-' + str(len(list(root.glob('build-*'))) + 1)
            preflight = wait_gate(root, label, args.wait_seconds)
            if preflight is None:
                write(root / 'status.json', {'state': 'waiting', 'reason': 'console_locked_before_build'})
                return 75
            command = [sys.executable, 'scripts/test-quiet.py', '--log-dir', str(root / label),
                       '--filter', 'ChatScrollHarnessTests/testWorkloadSignaturesMatchArchivedPrimaryRecords|ChatScrollBenchmarkTests']
            result = run_child(root, label, command, environment, preflight)
            write(root / label / 'completion.json', result)
            require(result['exit_code'] == 0 and result['reason'] is None, 'build_or_smoke_failed')
            baseline['build'] = {'label': label, 'binaries': binary_hashes()}
            require(snapshot_sources(REPOSITORY) == baseline['sources'], 'source_changed_during_build')
            write(root / 'baseline.json', baseline)
        require(binaries_unchanged(baseline['build']['binaries']), 'binary_changed_or_missing')
        if args.prepare_only:
            write(root / 'status.json', {'state': 'prepared'})
            return 0
        results = read(root / 'results.json')
        recover_interrupted(root, results, baseline['schedule'])
        for task in baseline['schedule']:
            previous = [row for row in results if all(row[key] == task[key] for key in task)]
            accepted = [row for row in previous if row['accepted']]
            require(len(accepted) <= 1, 'duplicate_accepted_batch')
            if accepted:
                validate_batch(root / accepted[0]['label'], accepted[0], reference)
                continue
            if previous and previous[-1]['reason'] not in ('disk_or_load_record_invalid', 'console_unavailable', 'console_disk_or_load_record_invalid', 'interrupted_attempt'):
                raise ValueError('failed_batch_requires_new_candidate_root:' + previous[-1]['label'])
            label = f"rep-{task['repetition']}-{task['position']}-{task['renderer']}-{task['kind']}-attempt-{len(previous) + 1}"
            preflight = wait_gate(root, label, args.wait_seconds)
            if preflight is None:
                write(root / 'status.json', {'state': 'waiting', 'next': task, 'reason': 'console_gate'})
                return 75
            require(snapshot_sources(REPOSITORY) == baseline['sources'] and reference_unchanged(reference), 'source_or_reference_changed')
            require(binaries_unchanged(baseline['build']['binaries']), 'binary_changed')
            # Hashing can take time; the actual launch needs a fresh gate sample.
            preflight = wait_gate(root, label, 0)
            if preflight is None:
                write(root / 'status.json', {'state': 'waiting', 'next': task, 'reason': 'gate_changed_during_identity_checks'})
                return 75
            command = [sys.executable, 'scripts/test-quiet.py', '--skip-build', '--log-dir', str(root / label), '--filter', FILTERS[task['kind']]]
            child_environment = dict(environment, AGENTPAD_CHAT_BENCH_RENDERER=task['renderer'],
                                     AGENTPAD_CHAT_BENCH_MEDIA_FIXTURE=str(root / 'primary-media-fixture.json'),
                                     AGENTPAD_SCROLL_EVIDENCE=str(root / label / 'samples'))
            write(root / 'status.json', {'state': 'running', 'task': task, 'label': label})
            row = dict(run_child(root, label, command, child_environment, preflight), **task)
            row['sources_unchanged'] = snapshot_sources(REPOSITORY) == baseline['sources'] and reference_unchanged(reference)
            row['binary_unchanged'] = binaries_unchanged(baseline['build']['binaries'])
            row['accepted'] = False
            try:
                row['verified'] = batch_data(root / label, row, reference)
                native_verdict(row['verified'], row['renderer'], row['kind'])
                row['accepted'] = True
            except (ValueError, KeyError, TypeError, OSError) as error:
                row['reason'] = row['reason'] or str(error)
            write(root / label / 'completion.json', row)
            results.append(row)
            write(root / 'results.json', results)
            print(json.dumps(row), flush=True)
            if not row['accepted']:
                write(root / 'status.json', {'state': 'rejected', 'reason': row['reason'], 'label': label})
                return 1
        complete = baseline['schedule'] == schedule(baseline['repetitions'])
        write(root / 'status.json', {'state': 'complete' if complete else 'incomplete', 'finished': time.time(),
                                     'reason': None if complete else 'scoped_schedule'})
        return 0 if complete else 1


def main() -> int:
    parser = argparse.ArgumentParser(description='Fresh-process native chat scroll workloads; timings are diagnostics and raw evidence is never overwritten.')
    parser.add_argument('--run-root', type=Path, required=True)
    parser.add_argument('--reference-manifest', type=Path, required=True)
    parser.add_argument('--report-output', type=Path)
    parser.add_argument('--report-only', action='store_true')
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--wait-only', action='store_true')
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--repetitions', type=int, choices=(1, 2, 3), default=1)
    parser.add_argument('--limit', type=int, choices=range(1, 13))
    parser.add_argument('--concurrency', type=int, choices=[1], default=1)
    parser.add_argument('--mode', choices=['normalized-quiet'], default='normalized-quiet')
    parser.add_argument('--max-jumps', type=int, choices=[0], default=0)
    parser.add_argument('--wait-seconds', type=int, choices=range(0, 481), default=480)
    args = parser.parse_args()
    args.run_root = args.run_root.resolve()
    args.reference_manifest = args.reference_manifest.resolve()
    try:
        if args.wait_only:
            require(args.resume and (args.run_root / 'wait.json').exists(), 'wait_requires_prepared_root_and_resume')
            with (args.run_root / 'runner.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return 0 if wait_gate(args.run_root, 'waiting', args.wait_seconds) is not None else 75
        if args.report_only:
            require(args.report_output is not None, 'report_output_required')
            result = make_report(args.run_root, args.report_output.resolve())
            return 0 if result['accepted'] else 1
        code = execute(args)
        if args.report_output:
            make_report(args.run_root, args.report_output.resolve())
        return code
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('Functional workloads INCOMPLETE / FAIL: ' + str(error), flush=True)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
