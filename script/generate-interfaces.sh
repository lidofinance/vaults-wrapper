#!/usr/bin/env bash
set -euo pipefail

# Generate Solidity interfaces for Wrapper-related contracts into cache/interfaces-<commit>

ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT_DIR"

COMMIT_SHA=$(git rev-parse --short HEAD)
OUT_DIR="cache/interfaces-${COMMIT_SHA}"
mkdir -p "$OUT_DIR"

echo "Output directory: $OUT_DIR"

# Discover wrapper-related source files
FILES=(
  $(ls src/Wrapper*.sol 2>/dev/null || true)
  $(ls src/WithdrawalQueue.sol 2>/dev/null || true)
  $(ls src/proxy/*.sol 2>/dev/null || true)
)

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No wrapper-related sources found."
  exit 0
fi

render_interface() {
  local fqn="$1"   # fully qualified name: path:Contract
  local name="$2"  # ContractName
  local out_file="$3"

  local tmp
  tmp=$(mktemp)
  if ! forge inspect "$fqn" abi --json >"$tmp" 2>/dev/null; then
    echo "Warning: forge inspect failed for $fqn, skipping" >&2
    rm -f "$tmp"
    return 0
  fi
  if [ ! -s "$tmp" ]; then
    echo "Warning: empty ABI for $fqn, skipping" >&2
    rm -f "$tmp"
    return 0
  fi

  python3 -c "$(cat <<'PY'
import json, sys

name = sys.argv[1]
out_path = sys.argv[2]
abi_path = sys.argv[3]
with open(abi_path, 'r') as f:
    abi = json.load(f)

def render_type(param):
    t = param.get('type')
    if t is None:
        return 'bytes'
    if t.startswith('tuple'):
        # preserve array suffix if any (e.g., tuple[], tuple[3])
        suffix = t[5:]
        comps = param.get('components', [])
        inner = ','.join(render_type(c) for c in comps)
        return f'({inner}){suffix}'
    return t

def render_inputs(inputs):
    parts = []
    for i, inp in enumerate(inputs or []):
        t = render_type(inp)
        n = inp.get('name') or f'arg{i}'
        parts.append(f"{t} {n}")
    return ', '.join(parts)

def render_outputs(outputs):
    outs = outputs or []
    if not outs:
        return ''
    parts = []
    for i, outp in enumerate(outs):
        t = render_type(outp)
        n = outp.get('name') or ''
        parts.append((t, n))
    sig = ', '.join([f"{t} {n}".rstrip() for t, n in parts])
    return f" returns ({sig})"

def render_fn(item):
    name = item['name']
    ins = render_inputs(item.get('inputs'))
    mut = item.get('stateMutability', '')
    mut_kw = ''
    if mut in ('view','pure'):
        mut_kw = f' {mut}'
    elif mut == 'payable':
        mut_kw = ' payable'
    outs = render_outputs(item.get('outputs'))
    return f"    function {name}({ins}) external{mut_kw}{outs};"

def render_event(item):
    name = item['name']
    args = []
    for i, inp in enumerate(item.get('inputs') or []):
        t = render_type(inp)
        n = inp.get('name') or f'arg{i}'
        indexed = ' indexed' if inp.get('indexed') else ''
        args.append(f"{t}{indexed} {n}")
    sig = ', '.join(args)
    return f"    event {name}({sig});"

def render_error(item):
    name = item['name']
    args = ', '.join(render_type(i) for i in (item.get('inputs') or []))
    return f"    error {name}({args});"

functions = [render_fn(i) for i in abi if i.get('type') == 'function']
events = [render_event(i) for i in abi if i.get('type') == 'event']
errors = [render_error(i) for i in abi if i.get('type') == 'error']

lines = []
lines.append('// SPDX-License-Identifier: MIT')
lines.append('pragma solidity >=0.8.25;')
lines.append('')
lines.append(f'interface I{name} {{')
for e in events:
    lines.append(e)
if events:
    lines.append('')
for er in errors:
    lines.append(er)
if errors:
    lines.append('')
for fn in functions:
    lines.append(fn)
lines.append('}')

with open(out_path, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PY
)" "$name" "$out_file" "$tmp"
  rm -f "$tmp"
}

for file in "${FILES[@]}"; do
  [ -f "$file" ] || continue
  CONTRACTS=$(grep -Eo 'contract[[:space:]]+[A-Za-z0-9_]+' "$file" | awk '{print $2}')
  for c in $CONTRACTS; do
    FQN="${file}:${c}"
    OUT_FILE="$OUT_DIR/I${c}.sol"
    echo "Generating interface for $FQN -> $OUT_FILE"
    render_interface "$FQN" "$c" "$OUT_FILE"
  done
done

echo "Done. Interfaces written to $OUT_DIR"


