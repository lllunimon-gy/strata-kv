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

# Legacy migration must survive process exit on either side of publication.
import struct
import zlib
for stage in ['migrationReady', 'migrationReplaced']:
    with tempfile.TemporaryDirectory(prefix='strata-migration-') as directory:
        payload = b'\x01' + struct.pack('<II', 1, 3) + b'aold'
        crc = zlib.crc32(struct.pack('<QI', 1, 1) + payload)
        raw = b'STRATA01BCH1' + struct.pack('<IQII', len(payload), 1, crc, 1) + payload + b'CMIT'
        pathlib.Path(directory, 'store.log').write_bytes(raw)
        result = subprocess.run([str(tool), 'migration-crash', directory, stage], capture_output=True)
        assert result.returncode == 86, (stage, result.stderr)
        subprocess.run([str(tool), 'migrate', directory], check=True, capture_output=True)
        result = subprocess.run([str(tool), 'check', directory], check=True, capture_output=True, text=True)
        assert json.loads(result.stdout) == {'a':'old'}
        backups = list(pathlib.Path(directory).glob('legacy-backup-*.log'))
        assert backups and all(p.read_bytes() == raw for p in backups)
        print(stage + ': PASS')
