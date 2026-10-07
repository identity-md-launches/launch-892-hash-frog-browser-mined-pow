"""Measure a complete packed snapshot without writing to the repository's .git.
Generated dependencies and scratch inputs are excluded explicitly. The temporary
Git repository lives under /tmp and is removed automatically.
"""
import json, os, subprocess, tempfile
from pathlib import Path
root = Path(__file__).resolve().parent.parent
os.chdir(root)
raw = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'])
excluded = {'.git', '.imd', '.playwright-mcp', 'node_modules', '.cache', '.vite', '__pycache__'}
files = sorted({p for p in raw.decode().split('\0') if p and Path(p).is_file()
                and not excluded.intersection(Path(p).parts)
                and not p.startswith(('test/scratch/', 'out/', 'cache/', 'broadcast/'))})
assert not any(Path(p).suffix in ('.tgz', '.bundle') for p in files)
changes = subprocess.check_output(['git', 'diff', '--name-only']).decode().splitlines()
for p in changes:
    assert p not in ('foundry.toml', 'foundry.lock', 'remappings.txt', '.gitmodules', 'package.json', 'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', '.gitignore'), p
    assert not p.startswith(('lib/', '.github/', '.git/', 'node_modules/')), p
    assert not Path(p).name.startswith('.env'), p
stages = subprocess.check_output(['git', 'ls-files', '--stage']).decode().splitlines()
assert not any(s.startswith('160000') for s in stages), 'Submodule found'
with tempfile.TemporaryDirectory(prefix='hashfrog-submission-', dir='/tmp') as temp:
    temp = Path(temp)
    subprocess.run(['git', 'init', '-q', str(temp)], check=True)
    git = ['git', '--git-dir='+str(temp/'.git'), '--work-tree='+str(root)]
    manifest = temp/'paths'
    manifest.write_bytes(('\0'.join(files)+'\0').encode())
    subprocess.run(git+['add', '--pathspec-from-file='+str(manifest), '--pathspec-file-nul'], check=True)
    subprocess.run(git+['-c', 'user.name=Local Size Check', '-c', 'user.email=check@localhost', 'commit', '-qm', 'Complete submission snapshot'], check=True)
    bundle = temp/'submission.bundle'
    subprocess.run(git+['bundle', 'create', str(bundle), '--all'], check=True)
    packed = bundle.stat().st_size
    assert packed <= 8388608, f'Submission exceeds 8 MiB: {packed}'
    export = sum(p.stat().st_size for p in Path('dist').rglob('*') if p.is_file())
    result = {'method':'Full-tree Git bundle in a temporary /tmp repository, including unchanged tracked dependencies; original .git remains untouched',
              'fileCount':len(files),'uncompressedFileBytes':sum(Path(p).stat().st_size for p in files),
              'packedBundleBytes':packed,'limitBytes':8388608,'productionExportBytes':export,
              'excluded':['provided inputs','generated node_modules/caches','browser logs','test/scratch','contract build output'],
              'protectedPathsUnchanged':True,'submodules':0}
    print(json.dumps(result, indent=2))
    Path('docs/submission-size.json').write_text(json.dumps(result, indent=2)+'\n')
