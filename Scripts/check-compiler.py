#!/usr/bin/env python3
"""Production separate-module compiler boundaries and public consumer evidence."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, help='New evidence directory; defaults outside repository')
parser.add_argument('--known-crashes', action='store_true', help='Opt-in informational inferred-misuse probes')
parser.add_argument('--consumer', action='store_true', help='Run public SwiftPM, host and iOS consumers instead of fixtures')
args = parser.parse_args()
label = 'consumer' if args.consumer else 'compiler'
out = (args.output or ROOT.parent / 'ChildrenOfTasks Implementation Evidence' /
       (datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '-' + label)).resolve()
out.mkdir(parents=True, exist_ok=False)
results = []
metadata = {'root': str(ROOT), 'output': str(out), 'host': platform.platform(),
            'language_mode': '6', 'strict_concurrency': 'complete',
            'library_default_isolation': 'nonisolated (compiler default)',
            'consumer_default_isolation': ['nonisolated (compiler default)', 'MainActor explicit override'],
            'upcoming_features': [], 'experimental_features': [],
            'ios_runtime': 'Not executed; compile/link and Mach-O evidence only',
            'results': results}


def run(name, command, markers=(), reject=False, informational=False, timeout=120):
    command = list(map(str, command))
    start = time.monotonic()
    try:
        process = subprocess.Popen(command, cwd=out, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            raw, _ = process.communicate(timeout=timeout)
            code = process.returncode
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            raw, _ = process.communicate()
            code = process.returncode
            status = 'timeout'
        else:
            status = None
        log = raw.decode('utf-8', errors='replace')
        crash = code < 0 or any(s in log for s in ('Stack dump:', 'Please submit a bug report',
                 'failed due to signal', 'Segmentation fault', 'Assertion failed:'))
        errors = re.findall(r'(?:^|\n)[^\n]*?error: ([^\n]+)', log)
        if status is None:
            if crash:
                status = 'crash'
            elif informational:
                status = 'diagnostic-rejection' if code else 'unexpected-acceptance'
            elif reject:
                status = ('pass' if code != 0 and errors and
                          all(any(m in error for m in markers) for error in errors) and
                          all(any(m in error for error in errors) for m in markers) else 'fail')
            else:
                status = 'pass' if code == 0 and all(m in log for m in markers) else 'fail'
    except OSError as exc:
        code, status, log = None, 'unavailable', str(exc)
    record = {'name': name, 'command': command, 'expected': 'reject' if reject else 'accept',
              'diagnostic_markers': list(markers), 'status': status, 'returncode': code,
              'informational': informational, 'elapsed_seconds': round(time.monotonic()-start, 3),
              'log': name + '.log'}
    (out / record['log']).write_text(shlex.join(command) + '\n\n' + log)
    results.append(record)
    print(name + ': ' + status, flush=True)
    return status == 'pass', log


PAIRS = {
 'BorrowEscapeExplicit': ('BorrowControlExplicit', ['borrowed parameter']),
 'BorrowTaskExplicit': ('HandleTransfer', ['borrowed parameter', 'risks causing data races']),
 'BorrowAsyncLetExplicit': ('HandleTransfer', ['borrowed parameter', 'risks causing data races']),
 'BorrowActor': ('HandleTransfer', ['risks causing data races']),
 'BorrowSwap': ('LocalHandleMutation', ['cannot pass immutable value as inout argument']),
 'BorrowConsume': ('LocalHandleMutation', ['is borrowed and cannot be consumed']),
 'BorrowReplace': ('LocalHandleMutation', ["cannot assign to value"]),
 'NonSendableResult': ('SendableBoundaries', ['does not conform to the', 'Sendable']),
 'NonSendableCapture': ('SendableBoundaries', ['capture of', 'non-Sendable']),
 'WrongResult': ('TypeTransport', ['cannot convert value of type']),
 'WrongFailure': ('TypeTransport', ['invalid conversion of thrown error type']),
}

try:
    ok, version = run('compiler-identity', ['xcrun', 'swiftc', '--version'])
    metadata['compiler_identity'] = version
    if not ok or not re.search(r'Swift version 6\.4(?:\.|\s)', version):
        raise RuntimeError('This evidence lane requires Swift 6.4; no compiler boundary claim established')
    run('developer-selection', ['xcode-select', '-p'])
    sources = sorted((ROOT / 'Sources/ChildrenOfTasks').glob('*.swift'))
    if not sources:
        raise RuntimeError('Missing production Sources/ChildrenOfTasks/*.swift')
    inputs = sources + sorted((ROOT / 'Tests/CompilerFixtures').rglob('*.swift'))
    if args.consumer:
        inputs += sorted((ROOT / 'Integration/Consumer').rglob('*.swift'))
    input_bytes = {p: p.read_bytes() for p in inputs}
    metadata['sources'] = {str(p.relative_to(ROOT)): hashlib.sha256(data).hexdigest()
                           for p, data in input_bytes.items()}
    # All direct compiler invocations read the same captured bytes reported above.
    snapshot = out / 'Snapshot'
    for path, data in input_bytes.items():
        copy = snapshot / path.relative_to(ROOT)
        copy.parent.mkdir(parents=True, exist_ok=True)
        copy.write_bytes(data)
    copies = [snapshot / p.relative_to(ROOT) for p in sources]
    for sdk in (['macosx', 'iphoneos'] if args.consumer else ['macosx']):
        ok, sdk_path = run(sdk + '-sdk', ['xcrun', '--sdk', sdk, '--show-sdk-path'])
        if not ok:
            continue
        target = ((('arm64' if platform.machine() == 'arm64' else 'x86_64') + '-apple-macosx13.0')
                  if sdk == 'macosx' else 'arm64-apple-ios16.4')
        build = out / sdk
        build.mkdir()
        common = ['xcrun', '--sdk', sdk, 'swiftc', '-swift-version', '6',
                  '-strict-concurrency=complete', '-target', target, '-sdk', sdk_path.strip(), '-O']
        metadata.setdefault('settings', {})[sdk] = common
        ok, _ = run(sdk + '-library-compile', common + ['-parse-as-library', '-emit-object', '-emit-module',
                    '-whole-module-optimization', '-module-name', 'ChildrenOfTasks', *copies, '-emit-module-path', build / 'ChildrenOfTasks.swiftmodule',
                    '-o', build / 'ChildrenOfTasks.o'])
        if not ok:
            continue
        if not args.consumer:
            sil = common + ['-parse-as-library', '-I', build, '-emit-sil']
            controls = {}
            for path in sorted((snapshot / 'Tests/CompilerFixtures/Positive').glob('*.swift')):
                controls[path.stem], _ = run(path.stem, sil + ['-module-name', path.stem, path,
                                                            '-o', build / (path.stem + '.sil')])
            for name, (control, markers) in PAIRS.items():
                if not controls.get(control):
                    raise RuntimeError('Positive control failed for ' + name)
                run(name, sil + ['-module-name', name, snapshot / 'Tests/CompilerFixtures/Rejection' / (name + '.swift'),
                                '-o', build / (name + '.sil')], markers, reject=True)
                results[-1]['positive_control'] = control
            if args.known_crashes:
                for path in sorted((snapshot / 'Tests/CompilerFixtures/KnownCompilerCrashes').glob('*.swift')):
                    run('known-' + path.stem, sil + ['-module-name', path.stem, path,
                        '-o', build / (path.stem + '.sil')], informational=True)
            continue
        library = build / 'libChildrenOfTasks.dylib'
        ok, _ = run(sdk + '-library-link', common + ['-emit-library', build / 'ChildrenOfTasks.o', '-o', library,
                    '-Xlinker', '-install_name', '-Xlinker', '@rpath/libChildrenOfTasks.dylib'])
        if not ok:
            continue
        source = snapshot / 'Integration/Consumer/Sources/Consumer/Consumer.swift'
        for mode, extra in [('normal', []), ('mainactor', ['-default-isolation', 'MainActor'])]:
            obj = build / (mode + '.o')
            exe = build / mode
            ok, _ = run(sdk + '-' + mode + '-compile', common + extra + ['-parse-as-library', '-I', build,
                        '-emit-object', source, '-o', obj])
            if ok:
                ok, _ = run(sdk + '-' + mode + '-link', common + [obj, '-L', build, '-lChildrenOfTasks', '-o', exe,
                            '-Xlinker', '-rpath', '-Xlinker', '@executable_path'])
                if ok and sdk == 'macosx':
                    run(sdk + '-' + mode + '-run', [exe], ['Public consumer passed'], timeout=30)
                if ok and sdk == 'iphoneos':
                    run('ios-' + mode + '-build-version', ['xcrun', 'vtool', '-show-build', exe], ['platform IOS', 'minos 16.4'])
        if sdk == 'iphoneos':
            run('ios-library-build-version', ['xcrun', 'vtool', '-show-build', library], ['platform IOS', 'minos 16.4'])
    if args.consumer:
        run('swiftpm-public-consumer', ['xcrun', 'swift', 'run', '--package-path', ROOT / 'Integration/Consumer',
             '--scratch-path', out / 'swiftpm', '-c', 'release', 'Consumer'], ['Public consumer passed'], timeout=180)
except Exception as exc:
    metadata['runner_error'] = str(exc)
finally:
    metadata['pass'] = bool(results) and 'runner_error' not in metadata and all(
        r['status'] == 'pass' for r in results if not r['informational']) and not any(
            r['status'] == 'unexpected-acceptance' for r in results)
    (out / 'results.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print('Evidence: ' + str(out))
    print('Normal checks: ' + ('PASS' if metadata['pass'] else 'FAIL'))
sys.exit(0 if metadata['pass'] else 1)
