# Theme injection dash hygiene

## Context

`explain-to-me` theme injection can introduce en dash or em dash characters from bundled CSS comments or template copy. Stevie has a hard no-em-dash preference in generated docs and replies.

## Fix after theme injection

Run this before publishing or committing an explainer:

```bash
python3 - <<'PY' ./explainers/<slug>.html
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')
s = s.replace('—', '-').replace('–', '-')
p.write_text(s, encoding='utf-8')
print('dash_count', s.count('—') + s.count('–'))
PY
```

## Verification

`dash_count 0` before publish and before git commit.
