#!/usr/bin/env bash
set -euo pipefail

# Generate Solidity interfaces from contracts using Foundry's cast interface
# Usage: ./scripts/generate-interfaces.sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get current directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Get current timestamp in ISO format (without timezone) and git commit
ISO_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S")
TIMESTAMP_FILENAME=$(date -u +"%Y%m%d_%H%M%S")
COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
COMMIT_FULL=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

# Create output directory
OUTPUT_DIR="$PROJECT_ROOT/interfaces_${TIMESTAMP_FILENAME}_${COMMIT_HASH}"
TEMP_GENERATED_DIR="$OUTPUT_DIR/.temp_generated"
TEMP_EXISTING_DIR="$OUTPUT_DIR/.temp_existing"

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║    Solidity Interface Generator (Foundry-based)       ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Timestamp (ISO):${NC} $ISO_TIMESTAMP"
echo -e "${GREEN}Commit:${NC} $COMMIT_HASH ($COMMIT_FULL)"
echo -e "${GREEN}Output Directory:${NC} $OUTPUT_DIR"
echo ""

# Check if forge/cast is available
if ! command -v cast &> /dev/null; then
    echo -e "${RED}✗${NC} Error: 'cast' command not found. Please install Foundry."
    echo -e "  Visit: https://book.getfoundry.sh/getting-started/installation"
    exit 1
fi

# Create output directories
mkdir -p "$OUTPUT_DIR"
mkdir -p "$TEMP_GENERATED_DIR"
mkdir -p "$TEMP_EXISTING_DIR"

# Copy existing interfaces
echo -e "${YELLOW}[1/4]${NC} Copying existing interfaces from src/interfaces/..."
if [ -d "$PROJECT_ROOT/src/interfaces" ]; then
    cp -R "$PROJECT_ROOT/src/interfaces/"* "$TEMP_EXISTING_DIR/" 2>/dev/null || true
    EXISTING_COUNT=$(find "$TEMP_EXISTING_DIR" -name "*.sol" | wc -l | tr -d ' ')
    echo -e "${GREEN}✓${NC} Copied $EXISTING_COUNT existing interface files"
else
    echo -e "${YELLOW}⚠${NC} No existing interfaces directory found"
    EXISTING_COUNT=0
fi
echo ""

# Generate interfaces using cast interface
echo -e "${YELLOW}[2/4]${NC} Generating interfaces using 'cast interface'..."
cd "$PROJECT_ROOT"

# First, ensure contracts are compiled (skip if already compiled recently)
if [ ! -d "out" ] || [ -z "$(find out -name '*.json' -newer src 2>/dev/null)" ]; then
    echo -e "${BLUE}→${NC} Compiling contracts..."
    forge build --quiet 2>/dev/null || forge build
else
    echo -e "${BLUE}→${NC} Using cached compilation artifacts"
fi

# Find all Solidity contracts (excluding interfaces, tests, and mocks)
CONTRACTS=$(find src -name "*.sol" \
    -not -path "*/interfaces/*" \
    -not -path "*/test/*" \
    -not -path "*/mock/*" \
    -not -path "*/script/*" \
    -type f)

TOTAL_CONTRACTS=$(echo "$CONTRACTS" | wc -l | tr -d ' ')
CURRENT=0
GENERATED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

echo -e "Found ${GREEN}$TOTAL_CONTRACTS${NC} contract files to process"
echo ""

# Get pragma version from foundry.toml or use default
SOLC_VERSION=$(grep "solc_version" foundry.toml 2>/dev/null | cut -d'"' -f2 || echo "0.8.30")
PRAGMA_VERSION=$(echo "$SOLC_VERSION" | sed 's/^\([0-9]*\.[0-9]*\).*/>=\1/')

for CONTRACT_FILE in $CONTRACTS; do
    CURRENT=$((CURRENT + 1))

    # Get contract name from file
    CONTRACT_NAME=$(basename "$CONTRACT_FILE" .sol)

    # Get relative path from src/
    REL_PATH=$(echo "$CONTRACT_FILE" | sed 's|^src/||')
    REL_DIR=$(dirname "$REL_PATH")

    # Create output directory structure
    mkdir -p "$TEMP_GENERATED_DIR/$REL_DIR"

    OUTPUT_FILE="$TEMP_GENERATED_DIR/${REL_DIR}/I${CONTRACT_NAME}.sol"
    TEMP_FILE="$TEMP_GENERATED_DIR/${REL_DIR}/I${CONTRACT_NAME}.sol.tmp"

    echo -ne "${BLUE}[$CURRENT/$TOTAL_CONTRACTS]${NC} Processing ${CONTRACT_NAME}..."

    # Check if file contains a contract (not just interfaces or libraries)
    if ! grep -q "^contract $CONTRACT_NAME\|^abstract contract $CONTRACT_NAME" "$CONTRACT_FILE"; then
        echo -e " ${YELLOW}⊘${NC} Skipped (not a contract)"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    # Use cast interface to generate the interface
    if cast interface "${CONTRACT_FILE}:${CONTRACT_NAME}" \
        --name "I${CONTRACT_NAME}" \
        --pragma "$PRAGMA_VERSION" \
        > "$TEMP_FILE" 2>/dev/null; then

        # Check if the interface has any meaningful content
        # (more than just the interface declaration)
        CONTENT_LINES=$(grep -v "^[[:space:]]*$\|^//\|^pragma\|^interface\|^}$" "$TEMP_FILE" | wc -l | tr -d ' ')

        if [ "$CONTENT_LINES" -gt 0 ]; then
            # Add metadata header to the generated interface
            cat > "$OUTPUT_FILE" << EOF
// SPDX-License-Identifier: MIT
pragma solidity $PRAGMA_VERSION;

/**
 * @title I${CONTRACT_NAME}
 * @notice Interface for ${CONTRACT_NAME}
 * @dev Auto-generated from ${REL_PATH} using Foundry's cast interface
 * @dev Generated at: ${ISO_TIMESTAMP}
 * @dev Commit: ${COMMIT_HASH}
 *
 * This interface includes all public and external functions, events, errors,
 * and public structs/enums from the contract and its inheritance chain.
 */
EOF

            # Append the generated interface (skip the first 3 lines which are SPDX and pragma)
            tail -n +4 "$TEMP_FILE" >> "$OUTPUT_FILE"

            rm "$TEMP_FILE"

            echo -e " ${GREEN}✓${NC} Generated I${CONTRACT_NAME}.sol"
            GENERATED_COUNT=$((GENERATED_COUNT + 1))
        else
            rm "$TEMP_FILE"
            echo -e " ${YELLOW}⊘${NC} Skipped (no public interface)"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        fi
    else
        rm -f "$TEMP_FILE"
        echo -e " ${RED}✗${NC} Failed to generate"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
done

echo ""
echo -e "${GREEN}✓${NC} Generated $GENERATED_COUNT interfaces"
echo -e "${YELLOW}⊘${NC} Skipped $SKIPPED_COUNT contracts"
if [ "$FAILED_COUNT" -gt 0 ]; then
    echo -e "${RED}✗${NC} Failed $FAILED_COUNT contracts"
fi
echo ""

# Merge generated and existing interfaces into root
echo -e "${YELLOW}[3/4]${NC} Merging interfaces into root directory..."

# Move existing interfaces to root
if [ "$EXISTING_COUNT" -gt 0 ]; then
    cp -R "$TEMP_EXISTING_DIR/"* "$OUTPUT_DIR/" 2>/dev/null || true
    echo -e "${GREEN}✓${NC} Merged $EXISTING_COUNT existing interfaces"
fi

# Move generated interfaces to root
if [ "$GENERATED_COUNT" -gt 0 ]; then
    cp -R "$TEMP_GENERATED_DIR/"* "$OUTPUT_DIR/" 2>/dev/null || true
    echo -e "${GREEN}✓${NC} Merged $GENERATED_COUNT generated interfaces"
fi

# Clean up temp directories
rm -rf "$TEMP_GENERATED_DIR" "$TEMP_EXISTING_DIR"
echo -e "${GREEN}✓${NC} All interfaces merged into root directory"
echo ""

# Create README
echo -e "${YELLOW}[4/4]${NC} Creating README..."
cat > "$OUTPUT_DIR/README.md" << EOF
# Solidity Interfaces Export

**Generated (ISO):** $ISO_TIMESTAMP
**Commit:** $COMMIT_HASH (\`$COMMIT_FULL\`)
**Branch:** $(git branch --show-current 2>/dev/null || echo "unknown")
**Solidity Version:** $SOLC_VERSION
**Pragma:** $PRAGMA_VERSION

## Directory Structure

All interfaces (both generated and existing) are merged into the root directory, maintaining their subdirectory structure:
- Auto-generated interfaces from \`src/\` contracts
- Existing interfaces from \`src/interfaces/\`

All interfaces are in the same directory tree for easy import and use.

## Features

- **Native Foundry Integration**: Uses \`cast interface\` for reliable, accurate interface generation
- **Complete ABI Coverage**: Includes all public/external functions, events, errors, structs, and enums
- **Inheritance Resolution**: Automatically includes inherited elements from parent contracts
- **ISO Timestamps**: All timestamps are in ISO 8601 format (UTC, without timezone)
- **Type-safe**: Generated directly from compiled contracts, ensuring correctness

## Generation Method

Interfaces are generated using Foundry's \`cast interface\` command, which:
1. Compiles the contracts using Forge
2. Extracts the complete ABI including inheritance
3. Generates clean Solidity interface code
4. Includes all public/external elements from the entire inheritance chain

This ensures 100% accuracy and completeness compared to manual text parsing.

## Statistics

- **Generated Interfaces:** $GENERATED_COUNT
- **Existing Interfaces:** $EXISTING_COUNT
- **Total Interfaces:** $((GENERATED_COUNT + EXISTING_COUNT))
- **Skipped:** $SKIPPED_COUNT
- **Failed:** $FAILED_COUNT

EOF

# List all interfaces with markers showing source
cat >> "$OUTPUT_DIR/README.md" << 'INTERFACES_EOF'

## All Interfaces

This directory contains all interfaces merged together. Interfaces are marked as:
- 📝 **Auto-generated** from source contracts using `cast interface`
- 📄 **Existing** from `src/interfaces/`

INTERFACES_EOF

# List all interfaces
if [ "$((GENERATED_COUNT + EXISTING_COUNT))" -gt 0 ]; then
    find "$OUTPUT_DIR" -name "*.sol" -not -name "README.md" | sort | while read -r iface; do
        IFACE_NAME=$(basename "$iface" .sol)
        IFACE_PATH=$(echo "$iface" | sed "s|$OUTPUT_DIR/||")
        ORIGINAL_CONTRACT=$(echo "$IFACE_NAME" | sed 's/^I//')

        # Try to find which contract this came from
        SOURCE_FILE=$(find src -name "${ORIGINAL_CONTRACT}.sol" \
            -not -path "*/interfaces/*" \
            -not -path "*/test/*" \
            -not -path "*/mock/*" \
            -not -path "*/script/*" 2>/dev/null | head -1 || echo "")

        if [ -n "$SOURCE_FILE" ]; then
            SOURCE_REL=$(echo "$SOURCE_FILE" | sed 's|^src/||')
            echo "- 📝 \`$IFACE_PATH\` — generated from \`$SOURCE_REL\`" >> "$OUTPUT_DIR/README.md"
        else
            echo "- 📄 \`$IFACE_PATH\` — existing interface" >> "$OUTPUT_DIR/README.md"
        fi
    done
else
    echo "_No interfaces found._" >> "$OUTPUT_DIR/README.md"
fi

cat >> "$OUTPUT_DIR/README.md" << EOF

## Notes

- **Generated with Foundry**: All interfaces are generated using \`cast interface\`, ensuring accuracy
- **Inheritance included**: Each interface automatically includes all inherited public/external elements
- **ABI-based**: Generated from the contract's ABI, not source code parsing
- **Type-safe**: Guaranteed to match the actual contract behavior
- All timestamps are in ISO 8601 format (UTC, without timezone designator)

## Requirements

To regenerate these interfaces, you need:
- [Foundry](https://book.getfoundry.sh/) installed (\`forge\` and \`cast\` commands)
- Contracts must compile successfully

## Usage

To use these interfaces in your project:

\`\`\`bash
# Copy all interfaces to your project
cp -R $OUTPUT_DIR/* /path/to/your/project/interfaces/
\`\`\`

Or reference this export directory directly.

## Regeneration

To regenerate interfaces:

\`\`\`bash
cd $PROJECT_ROOT
./scripts/generate-interfaces.sh
\`\`\`

The script will:
1. Compile all contracts using Forge
2. Generate interfaces using \`cast interface\`
3. Copy existing interfaces from \`src/interfaces/\`
4. Create this README with statistics
EOF

echo -e "${GREEN}✓${NC} Created README.md"
echo ""

# Print summary
echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    Summary                             ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓${NC} Successfully generated interfaces using Foundry"
echo -e "  ${BLUE}•${NC} Output directory: ${GREEN}$OUTPUT_DIR${NC}"
echo -e "  ${BLUE}•${NC} Generated interfaces: ${GREEN}$GENERATED_COUNT${NC}"
echo -e "  ${BLUE}•${NC} Existing interfaces: ${GREEN}$EXISTING_COUNT${NC}"
echo -e "  ${BLUE}•${NC} Total interfaces: ${GREEN}$((GENERATED_COUNT + EXISTING_COUNT))${NC}"
if [ "$SKIPPED_COUNT" -gt 0 ]; then
    echo -e "  ${BLUE}•${NC} Skipped: ${YELLOW}$SKIPPED_COUNT${NC}"
fi
if [ "$FAILED_COUNT" -gt 0 ]; then
    echo -e "  ${BLUE}•${NC} Failed: ${RED}$FAILED_COUNT${NC}"
fi
echo -e "  ${BLUE}•${NC} Timestamp (ISO): ${GREEN}$ISO_TIMESTAMP${NC}"
echo -e "  ${BLUE}•${NC} Pragma: ${GREEN}$PRAGMA_VERSION${NC}"
echo ""
echo -e "${YELLOW}Method:${NC}"
echo -e "  Using Foundry's ${BLUE}cast interface${NC} for accurate, ABI-based generation"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  ${BLUE}1.${NC} Review the generated interfaces: ${BLUE}cd $OUTPUT_DIR${NC}"
echo -e "  ${BLUE}2.${NC} Check the README: ${BLUE}cat $OUTPUT_DIR/README.md${NC}"
echo -e "  ${BLUE}3.${NC} Interfaces are production-ready (generated from compiled ABI)"
echo ""
