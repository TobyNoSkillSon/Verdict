#!/usr/bin/env python3
"""Write Resources/THIRD_PARTY_NOTICES.txt: the licence of every package in Package.resolved and of the code MLX
vendors, copied verbatim from the resolved checkouts (.build/checkouts; run `swift package resolve` first).

Run after changing a dependency pin, review the diff, commit. scripts/build.sh ships the file in
Verdict.app/Contents/Resources; Tests/VerdictCoreTests checks it covers every pin and still matches the checkouts.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECKOUTS = ROOT / '.build/checkouts'
OUT = ROOT / 'Resources/THIRD_PARTY_NOTICES.txt'

# (package identity, component, what Verdict uses it for, licence, files: [(path in checkout, line range or None)])
# A line range copies a licence header from a source file (1-based, inclusive).
INVENTORY = [
    ('mlx-swift', 'mlx-swift', 'Swift API for MLX: the model runtime', 'MIT', [('LICENSE', None)]),
    ('mlx-swift', 'MLX (vendored in mlx-swift)', 'array library, Metal kernels (mlx.metallib)', 'MIT',
     [('Source/Cmlx/mlx/LICENSE', None)]),
    ('mlx-swift', 'mlx-c (vendored in mlx-swift)', 'C API between MLX and Swift', 'MIT', [('Source/Cmlx/mlx-c/LICENSE', None)]),
    ('mlx-swift', 'fmt (vendored in mlx-swift)', 'string formatting inside MLX', 'MIT', [('Source/Cmlx/fmt/LICENSE', None)]),
    ('mlx-swift', 'nlohmann/json (vendored in mlx-swift)', 'JSON inside MLX', 'MIT', [('Source/Cmlx/json/LICENSE.MIT', None)]),
    ('mlx-swift', 'metal-cpp (vendored in mlx-swift)', 'C++ Metal bindings inside MLX', 'Apache-2.0',
     [('Source/Cmlx/metal-cpp/LICENSE.txt', None)]),
    ('mlx-swift', 'pocketfft (vendored in MLX)', 'CPU FFT inside MLX', 'BSD-3-Clause',
     [('Source/Cmlx/mlx/mlx/3rdparty/pocketfft.h', (1, 35))]),
    ('mlx-swift', 'ThreadPool (adapted in MLX)', 'thread pool inside MLX', 'zlib', [('Source/Cmlx/mlx/mlx/threadpool.h', (1, 20))]),
    ('mlx-swift', 'NVIDIA CCCL complex math (adapted in MLX Metal kernels)', 'complex exponential kernel', 'Apache-2.0',
     [('Source/Cmlx/mlx/mlx/backend/metal/kernels/cexpf.h', (1, 18))]),
    ('swift-numerics', 'swift-numerics', 'real-number protocols used by mlx-swift', 'Apache-2.0 with Runtime Library Exception',
     [('LICENSE.txt', None)]),
    ('swift-transformers', 'swift-transformers (Tokenizers, Hub)', 'fallback tokenizer and tokenizer.json loading', 'Apache-2.0',
     [('LICENSE', None)]),
    ('swift-jinja', 'swift-jinja', 'chat templates, linked by swift-transformers', 'Apache-2.0', [('LICENSE', None)]),
    ('swift-huggingface', 'swift-huggingface', 'Hugging Face client, linked by swift-transformers', 'Apache-2.0', [('LICENSE', None)]),
    ('eventsource', 'EventSource', 'server-sent events, linked by swift-huggingface', 'MIT', [('LICENSE.md', None)]),
    ('yyjson', 'yyjson', 'JSON parsing, linked by swift-transformers', 'MIT', [('LICENSE', None)]),
    ('swift-collections', 'swift-collections (OrderedCollections)', 'ordered dictionaries, linked by swift-transformers',
     'Apache-2.0 with Runtime Library Exception', [('LICENSE.txt', None)]),
    ('swift-crypto', 'swift-crypto', 'hashing, linked by swift-transformers (forwards to CryptoKit on macOS)', 'Apache-2.0',
     [('NOTICE.txt', None), ('LICENSE.txt', None)]),
    ('swift-asn1', 'swift-asn1', 'resolved dependency of swift-crypto', 'Apache-2.0', [('NOTICE.txt', None), ('LICENSE.txt', None)]),
]
# Checkout directory names differ from identities for some packages.
DIRECTORY = {'eventsource': 'EventSource'}


def excerpt(path, lines):
    text = path.read_text(encoding='utf-8')
    if lines:
        a, b = lines
        text = '\n'.join(text.splitlines()[a - 1:b]) + '\n'
    return text.rstrip() + '\n'


def main():
    pins = {p['identity']: p for p in json.loads((ROOT / 'Package.resolved').read_text())['pins']}
    covered = {identity for identity, *_ in INVENTORY}
    missing = sorted(set(pins) - covered)
    if missing:
        sys.exit(f'Package.resolved pins with no inventory entry: {missing}')
    out = ['Third-party notices for Verdict',
           '',
           'Verdict.app links the packages below (Swift Package Manager, pinned in Package.resolved). Each licence',
           'or notice is reproduced verbatim from the pinned checkout. Verdict itself: LICENSE and NOTICE.',
           '']
    for identity, component, use, licence, files in INVENTORY:
        pin = pins[identity]
        state = pin['state']
        version = state.get('version') or 'revision'
        out += ['=' * 78, f'{component}', f'  package  {identity} {version} ({state["revision"]})', f'  source   {pin["location"]}',
                f'  licence  {licence}', f'  used for {use}', '=' * 78, '']
        for rel, lines in files:
            path = CHECKOUTS / DIRECTORY.get(identity, identity) / rel
            if not path.exists():
                sys.exit(f'missing {path}; run: swift package resolve')
            out += [f'--- {rel}' + (f' (lines {lines[0]}-{lines[1]})' if lines else ''), '', excerpt(path, lines)]
    text = '\n'.join(out).rstrip() + '\n'
    text = re.sub(r'[ \t]+\n', '\n', text)   # trailing whitespace only; content unchanged
    OUT.write_text(text, encoding='utf-8')
    print(f'wrote {OUT.relative_to(ROOT)} ({len(INVENTORY)} components, {len(pins)} pins)')


if __name__ == '__main__':
    main()
