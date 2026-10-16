"""Build immutable revisions, then interleave identical probes on one macOS host.

Outputs raw per-round measurements. No performance thresholds or selective retrying.
All generated source/data lives in a newly created directory passed as --workspace.
"""
import argparse
import hashlib
import json
import pathlib
import platform
import statistics
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--workspace', required=True, type=pathlib.Path)
parser.add_argument('--output', required=True, type=pathlib.Path)
parser.add_argument('--rounds', type=int, default=6)
args = parser.parse_args()
assert 3 <= args.rounds <= 20
root = pathlib.Path(__file__).resolve().parents[1]
workspace = args.workspace.resolve()
workspace.mkdir(parents=True, exist_ok=False)
def output(*command, cwd=root):
    return subprocess.check_output(command, cwd=cwd, text=True).strip()
probe = (root/'Benchmarks/ComparisonProbe.swift').read_bytes()
revisions = [('v0.2', 'ae680dcec12fe06c1e7bf006460da91b7cd4de32'),
             ('v0.4', '27f09dd6c547e5c0d855422886bd20e77f27f4b0'),
             ('candidate', output('git', 'rev-parse', 'HEAD'))]
binaries = {}
for label, sha in revisions:
    checkout = workspace/label
    # Separate local clone, never reset or mutate the user's checkout.
    subprocess.run(['git', 'clone', '--quiet', '--no-hardlinks', str(root), str(checkout)], check=True)
    subprocess.run(['git', 'checkout', '--quiet', '--detach', sha], cwd=checkout, check=True)
    source = checkout/'Sources/StrataTool'
    for file in source.glob('*.swift'):
        assert workspace in file.resolve().parents
        file.unlink()
    (source/'main.swift').write_bytes(probe)
    command = ['swift', 'build', '-c', 'release', '--product', 'strata-tool']
    if label != 'v0.2': command += ['-Xswiftc', '-DSTRATA_GROUPED']
    subprocess.run(command, cwd=checkout, check=True)
    binaries[label] = checkout/'.build/release/strata-tool'
    print('built ' + label, flush=True)

def run(label, trial):
    return json.loads(output(str(binaries[label]), str(workspace/f'data-{trial}-{label}')))
for label, _ in revisions:
    run(label, 'warmup')
rows = []
# Rotate and reverse order; six rounds balance both position and direction.
orders = [['v0.2', 'v0.4', 'candidate'], ['candidate', 'v0.4', 'v0.2'],
          ['v0.4', 'candidate', 'v0.2'], ['v0.2', 'candidate', 'v0.4'],
          ['candidate', 'v0.2', 'v0.4'], ['v0.4', 'v0.2', 'candidate']]
for trial in range(args.rounds):
    for position, label in enumerate(orders[trial % len(orders)]):
        rows.append({'round': trial, 'position': position, 'revision': label, 'measurements': run(label, trial)})
        print(f'round {trial + 1}/{args.rounds}: {label}', flush=True)
summary = {}
for label, _ in revisions:
    names = [m['name'] for m in next(r for r in rows if r['revision'] == label)['measurements']]
    summary[label] = {}
    for name in names:
        samples = [next(m for m in r['measurements'] if m['name'] == name) for r in rows if r['revision'] == label]
        summary[label][name] = {
            'medianOfRoundP50': statistics.median(s['p50Microseconds'] for s in samples),
            'medianOfRoundP99': statistics.median(s['p99Microseconds'] for s in samples),
            'minRoundP50': min(s['p50Microseconds'] for s in samples),
            'maxRoundP50': max(s['p50Microseconds'] for s in samples),
        }
report = {'revisions': dict(revisions), 'probeSHA256': hashlib.sha256(probe).hexdigest(),
          'platform': platform.platform(), 'swift': output('swift', '--version'),
          'rounds': args.rounds, 'warmupRounds': 1, 'orders': orders, 'raw': rows, 'summary': summary,
          'notes': ['Same host/toolchain/probe; fresh directory for every revision and round.',
                    'Warm caches; compaction-live has one sample per round, so its P99 is not a tail estimate.',
                    'Stage instrumentation uses fault callbacks (three writes), separate from uninstrumented fast path.',
                    'No power-loss claims or production latency guarantees.']}
args.output.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
