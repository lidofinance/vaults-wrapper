#!/bin/bash
# Forge Build Warnings and Notes Analyzer
# Usage: ./scripts/analyze-forge-warnings.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Running forge build --force...${NC}"
forge build --force 2>&1 | tee /tmp/forge_output.txt

echo -e "\n${GREEN}Analyzing warnings and notes...${NC}\n"

# Create Python analysis script
cat > /tmp/analyze_warnings.py << 'PYEOF'
import re
import sys

def analyze_forge_output(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    # Split into individual warnings/notes
    items = re.split(r'\n(?=(?:Warning \(\d+\)|warning\[|note\[))', content)

    src_counts = {}
    test_counts = {}
    script_counts = {}
    total_counts = {}

    for item in items:
        # Extract type
        type_match = re.match(r'(Warning \(\d+\)|warning\[([^\]]+)\]|note\[([^\]]+)\])', item)
        if not type_match:
            continue

        if type_match.group(1).startswith('Warning ('):
            warning_type = 'solc-warning'
        elif type_match.group(2):
            warning_type = f'warning[{type_match.group(2)}]'
        elif type_match.group(3):
            warning_type = f'note[{type_match.group(3)}]'
        else:
            continue

        # Extract file path
        file_match = re.search(r'-->\s+([^:]+):', item)
        if not file_match:
            continue

        filepath = file_match.group(1)

        # Track totals
        total_counts[warning_type] = total_counts.get(warning_type, 0) + 1

        # Categorize by directory
        if filepath.startswith('src/'):
            src_counts[warning_type] = src_counts.get(warning_type, 0) + 1
        elif filepath.startswith('test/'):
            test_counts[warning_type] = test_counts.get(warning_type, 0) + 1
        elif filepath.startswith('script/'):
            script_counts[warning_type] = script_counts.get(warning_type, 0) + 1

    # Calculate totals
    src_total = sum(src_counts.values())
    test_total = sum(test_counts.values())
    script_total = sum(script_counts.values())
    grand_total = src_total + test_total + script_total

    # Count types
    solc_warnings = sum(v for k, v in total_counts.items() if k == 'solc-warning')
    lint_warnings = sum(v for k, v in total_counts.items() if k.startswith('warning['))
    lint_notes = sum(v for k, v in total_counts.items() if k.startswith('note['))

    # Print summary
    print("=" * 80)
    print("FORGE BUILD ANALYSIS - WARNINGS AND NOTES")
    print("=" * 80)
    print()
    print(f"Total Issues: {grand_total}")
    print(f"  - Solidity Compiler Warnings: {solc_warnings}")
    print(f"  - Forge Lint Warnings: {lint_warnings}")
    print(f"  - Forge Lint Notes: {lint_notes}")
    print()

    print("=" * 80)
    print("DISTRIBUTION BY DIRECTORY")
    print("=" * 80)
    print(f"  src/    : {src_total:3d} ({src_total/grand_total*100:5.1f}%)")
    print(f"  test/   : {test_total:3d} ({test_total/grand_total*100:5.1f}%)")
    print(f"  script/ : {script_total:3d} ({script_total/grand_total*100:5.1f}%)")
    print()

    def print_section(title, counts):
        if not counts:
            return
        print(f"\n{title} ({sum(counts.values())} issues)")
        print("-" * 80)

        # Group by category
        solc_warns = {k: v for k, v in counts.items() if k == 'solc-warning'}
        warnings = {k: v for k, v in counts.items() if k.startswith('warning[')}
        notes = {k: v for k, v in counts.items() if k.startswith('note[')}

        if solc_warns:
            print("\nSolidity Compiler Warnings:")
            for k, v in sorted(solc_warns.items()):
                print(f"  {k}: {v}")

        if warnings:
            print("\nForge Lint Warnings:")
            for k, v in sorted(warnings.items()):
                print(f"  {k}: {v}")

        if notes:
            print("\nForge Lint Notes:")
            for k, v in sorted(notes.items()):
                print(f"  {k}: {v}")

    print("=" * 80)
    print_section("SRC DIRECTORY", src_counts)
    print_section("TEST DIRECTORY", test_counts)
    print_section("SCRIPT DIRECTORY", script_counts)

    print("\n" + "=" * 80)
    print("SUMMARY BY TYPE")
    print("=" * 80)
    for k, v in sorted(total_counts.items(), key=lambda x: (-x[1], x[0])):
        print(f"  {k:40s}: {v:3d}")
    print()

if __name__ == "__main__":
    analyze_forge_output('/tmp/forge_output.txt')
PYEOF

# Run Python analysis
python3 /tmp/analyze_warnings.py

# Cleanup
rm -f /tmp/analyze_warnings.py

echo -e "\n${YELLOW}Analysis complete!${NC}"
echo -e "${BLUE}Output saved to: /tmp/forge_output.txt${NC}"
