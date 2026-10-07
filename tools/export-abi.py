import json
from pathlib import Path
names=['HashFrogHook','HashFrog','HFROG','FrogStaking','FrogRouter']
abis={n:json.loads(Path(f'out/{n}.sol/{n}.json').read_text())['abi'] for n in names}
Path('site/abi.json').write_text(json.dumps(abis,separators=(',',':'))+'\n')
