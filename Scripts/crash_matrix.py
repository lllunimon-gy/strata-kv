"""Run after swift build --product strata-tool. Uses only disposable temporary directories."""
import json
import pathlib
import subprocess
import tempfile

tool = pathlib.Path('.build/debug/strata-tool').resolve()
stages = {
    'afterHeader': 'old', 'afterPayload': 'old', 'afterCommit': 'new', 'afterSync': 'new',
    'compactionReady': 'old', 'compactionReplaced': 'old',
}
for stage, expected in stages.items():
    with tempfile.TemporaryDirectory(prefix='strata-crash-') as directory:
        subprocess.run([str(tool), 'seed', directory], check=True, capture_output=True)
        command = 'compact-crash' if stage.startswith('compaction') else 'crash'
        result = subprocess.run([str(tool), command, directory, stage], capture_output=True)
        assert result.returncode == 86, (stage, result.returncode, result.stderr)
        result = subprocess.run([str(tool), 'check', directory], check=True, capture_output=True, text=True)
        assert json.loads(result.stdout) == {'a': expected, 'b': expected}, (stage, result.stdout)
        print(stage + ': PASS')
print('Process termination matrix passed; this is not a power-loss test.')
