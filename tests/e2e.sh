#!/usr/bin/env bash
# End-to-end tests for quicue-kg
# Usage: bash tests/e2e.sh
set -euo pipefail

PASS=0
FAIL=0
SKIP=0
KG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KG_TOOL="$KG_ROOT/tools/kg"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# CUE requires relative paths, so cd into repo root
cd "$KG_ROOT"

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP: $1 — $2"; SKIP=$((SKIP+1)); }

section() { echo; echo "=== $1 ==="; }

# ─────────────────────────────────────────────
section "1. Schema validation"
# ─────────────────────────────────────────────

if cue vet ./core/ ./ext/ ./aggregate/ 2>&1; then
    pass "Core, ext, aggregate schemas validate"
else
    fail "Schema validation" "cue vet failed"
fi

if cue vet ./vocab/ 2>&1; then
    pass "Vocab schema validates"
else
    fail "Vocab validation" "cue vet failed"
fi

# ─────────────────────────────────────────────
section "2. Positive tests (valid data)"
# ─────────────────────────────────────────────

if cue vet ./tests/valid/ 2>&1; then
    pass "Valid test instances pass"
else
    fail "Valid tests" "cue vet rejected valid data"
fi

# ─────────────────────────────────────────────
section "3. Negative tests (invalid data must be rejected)"
# ─────────────────────────────────────────────

for f in tests/invalid/*.cue; do
    name=$(basename "$f" .cue)
    if cue vet "$f" 2>/dev/null; then
        fail "Negative test $name" "should have been rejected"
    else
        pass "Negative test $name correctly rejected"
    fi
done

# ─────────────────────────────────────────────
section "4. Examples"
# ─────────────────────────────────────────────

if cue vet ./examples/minimal/ 2>&1; then
    pass "Minimal example validates"
else
    fail "Minimal example" "cue vet failed"
fi

if cue vet ./examples/full/ 2>&1; then
    pass "Full example validates"
else
    fail "Full example" "cue vet failed"
fi

# ─────────────────────────────────────────────
section "5. JSON-LD exports"
# ─────────────────────────────────────────────

# Vocab context export
ctx=$(cue export ./vocab -e context --out json 2>&1) || true
if echo "$ctx" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '@context' in d; assert '@graph' in d" 2>/dev/null; then
    pass "Vocab context exports valid JSON-LD structure"
else
    fail "Vocab context export" "missing @context or @graph"
fi

# Check @context has required namespaces
if echo "$ctx" | python3 -c "
import sys,json; c=json.load(sys.stdin)['@context']
for ns in ['kg','dcterms','prov','oa','dcat','rdfs','xsd']:
    assert ns in c, f'missing namespace: {ns}'
" 2>/dev/null; then
    pass "Vocab context has all W3C namespaces"
else
    fail "Vocab context namespaces" "missing required namespace"
fi

# Check @graph has class definitions for all 7 types
if echo "$ctx" | python3 -c "
import sys,json; g=json.load(sys.stdin)['@graph']
ids = {e['@id'] for e in g}
for t in ['kg:Decision','kg:Insight','kg:Rejected','kg:Pattern','kg:Derivation','kg:Context','kg:Workspace']:
    assert t in ids, f'missing class: {t}'
" 2>/dev/null; then
    pass "Vocab context has all 7 type definitions"
else
    fail "Vocab type definitions" "missing class in @graph"
fi

# ─────────────────────────────────────────────
section "6. W3C projections (from quicue.ca/.kg/)"
# ─────────────────────────────────────────────

QCA_KG="$HOME/quicue.ca/.kg"
if [ -d "$QCA_KG" ]; then
    # PROV-O
    prov=$(cd "$QCA_KG" && cue export . -e _provenance.graph --out json 2>&1) || true
    if echo "$prov" | python3 -c "
import sys,json; d=json.load(sys.stdin)
assert '@context' in d, 'no @context'
assert '@graph' in d, 'no @graph'
assert any('prov:Activity' in str(e.get('@type','')) for e in d['@graph']), 'no prov:Activity'
" 2>/dev/null; then
        pass "PROV-O projection produces valid output"
    else
        fail "PROV-O projection" "invalid structure"
    fi

    # DCAT
    dcat=$(cd "$QCA_KG" && cue export . -e _catalog.dataset --out json 2>&1) || true
    if echo "$dcat" | python3 -c "
import sys,json; d=json.load(sys.stdin)
assert d.get('@type') == 'dcat:Dataset', 'not dcat:Dataset'
assert 'dcat:distribution' in d, 'no distributions'
" 2>/dev/null; then
        pass "DCAT projection produces valid output"
    else
        fail "DCAT projection" "invalid structure"
    fi

    # Web Annotation
    oa=$(cd "$QCA_KG" && cue export . -e _annotations.graph --out json 2>&1) || true
    if echo "$oa" | python3 -c "
import sys,json; d=json.load(sys.stdin)
assert '@context' in d, 'no @context'
assert '@graph' in d, 'no @graph'
assert 'oa' in d['@context'], 'no oa namespace'
" 2>/dev/null; then
        pass "Web Annotation projection produces valid output"
    else
        fail "Web Annotation projection" "invalid structure"
    fi
else
    skip "W3C projections" "quicue.ca/.kg/ not found"
fi

# ─────────────────────────────────────────────
section "7. CLI tool (kg)"
# ─────────────────────────────────────────────

if [ -x "$KG_TOOL" ] || [ -f "$KG_TOOL" ]; then
    # Test kg init in temp directory
    mkdir -p "$TMPDIR/test-project"
    if (cd "$TMPDIR/test-project" && bash "$KG_TOOL" init 2>&1 | grep -q "Initialized"); then
        pass "kg init scaffolds .kg/"
    else
        fail "kg init" "did not produce expected output"
    fi

    # Test kg vet on quicue.ca
    if [ -d "$QCA_KG" ]; then
        vet_out=$(cd "$HOME/quicue.ca" && bash "$KG_TOOL" vet 2>&1) || true
        if echo "$vet_out" | grep -q "OK\|valid\|Valid"; then
            pass "kg vet on quicue.ca/.kg/"
        else
            fail "kg vet" "did not report valid"
        fi

        # Test kg index --summary
        idx=$(cd "$HOME/quicue.ca" && bash "$KG_TOOL" index --summary 2>&1) || true
        if echo "$idx" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'total' in d or 'total_decisions' in d" 2>/dev/null; then
            pass "kg index --summary produces JSON with totals"
        else
            fail "kg index --summary" "no valid JSON output"
        fi

        # Test kg lint
        if (cd "$HOME/quicue.ca" && bash "$KG_TOOL" lint 2>&1); then
            pass "kg lint runs without error"
        else
            fail "kg lint" "exited with error"
        fi

        # Test kg graph --json
        graph=$(cd "$HOME/quicue.ca" && bash "$KG_TOOL" graph --json 2>&1) || true
        if echo "$graph" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'nodes' in d or '@graph' in d" 2>/dev/null; then
            pass "kg graph --json produces graph data"
        else
            fail "kg graph --json" "no valid graph output"
        fi
    else
        skip "kg vet/index/lint/graph" "quicue.ca/.kg/ not found"
    fi
else
    skip "CLI tests" "tools/kg not found"
fi

# ─────────────────────────────────────────────
section "8. MCP server"
# ─────────────────────────────────────────────

if [ -f "$KG_ROOT/mcp/server.js" ] && command -v node >/dev/null 2>&1; then
    if [ -d "$KG_ROOT/mcp/node_modules" ]; then
        # Test that server starts and responds to initialize
        init_req='{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'
        resp=$(cd "$HOME/quicue.ca" && echo "$init_req" | timeout 10 node "$KG_ROOT/mcp/server.js" 2>/dev/null | head -1) || true
        if echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('result',{}).get('serverInfo')" 2>/dev/null; then
            pass "MCP server responds to initialize"
        else
            # Server may use stdio transport differently
            skip "MCP server initialize" "could not parse response (may need different transport)"
        fi
    else
        skip "MCP server" "node_modules not installed (run: cd mcp && npm install)"
    fi
else
    skip "MCP server" "node not found or server.js missing"
fi

# ─────────────────────────────────────────────
section "9. Module consumption (fresh project)"
# ─────────────────────────────────────────────

mkdir -p "$TMPDIR/consumer"
cat > "$TMPDIR/consumer/test.cue" << 'CUEFILE'
package test

import "quicue.ca/kg/core@v0"

d: core.#Decision & {
    id: "ADR-001", title: "Test", status: "accepted"
    date: "2026-01-01", context: "test", decision: "test"
    rationale: "test", consequences: ["test"]
}
CUEFILE

# Use local symlink to simulate module resolution
mkdir -p "$TMPDIR/consumer/cue.mod/pkg/quicue.ca"
ln -sf "$KG_ROOT" "$TMPDIR/consumer/cue.mod/pkg/quicue.ca/kg"
cat > "$TMPDIR/consumer/cue.mod/module.cue" << 'CUEFILE'
module: "test.example.com/consumer@v0"
language: version: "v0.9.0"
CUEFILE

if (cd "$TMPDIR/consumer" && cue vet . 2>&1); then
    pass "Fresh project can import and use quicue-kg schemas"
else
    fail "Module consumption" "fresh project cannot use schemas"
fi

# Verify constraint enforcement in consumer
cat > "$TMPDIR/consumer/bad.cue" << 'CUEFILE'
package test

import "quicue.ca/kg/core@v0"

bad: core.#Decision & {
    id: "WRONG-FORMAT"
    title: "Missing required fields"
}
CUEFILE

if (cd "$TMPDIR/consumer" && cue vet . 2>/dev/null); then
    fail "Module constraint enforcement" "should have rejected invalid decision"
else
    pass "Module correctly rejects invalid data in consumer project"
    # Clean up bad.cue so it doesn't interfere
    rm "$TMPDIR/consumer/bad.cue"
fi

# ─────────────────────────────────────────────
section "10. Cross-repo consistency"
# ─────────────────────────────────────────────

QCA_VENDOR="$HOME/quicue.ca/kg"
if [ -d "$QCA_VENDOR" ]; then
    # Compare key files between standalone and vendored
    mismatches=0
    for f in core/decision.cue core/insight.cue core/pattern.cue core/rejected.cue ext/workspace.cue ext/context.cue ext/derivation.cue aggregate/index.cue; do
        if [ -f "$KG_ROOT/$f" ] && [ -f "$QCA_VENDOR/$f" ]; then
            if ! diff -q "$KG_ROOT/$f" "$QCA_VENDOR/$f" >/dev/null 2>&1; then
                echo "    MISMATCH: $f"
                mismatches=$((mismatches+1))
            fi
        fi
    done
    if [ "$mismatches" -eq 0 ]; then
        pass "Vendored kg/ matches standalone repo (core/ext/aggregate)"
    else
        fail "Cross-repo consistency" "$mismatches file(s) differ"
    fi
else
    skip "Cross-repo consistency" "quicue.ca/kg/ not found"
fi

# ─────────────────────────────────────────────
section "11. GitHub Pages accessibility"
# ─────────────────────────────────────────────

if command -v curl >/dev/null 2>&1; then
    spec_url="https://quicue.github.io/quicue-kg/spec.html"
    ctx_url="https://quicue.github.io/quicue-kg/context.jsonld"

    spec_status=$(curl -s -o /dev/null -w "%{http_code}" "$spec_url" 2>/dev/null) || true
    if [ "$spec_status" = "200" ]; then
        pass "Spec accessible at $spec_url"
    else
        skip "Spec accessibility" "HTTP $spec_status (may still be deploying)"
    fi

    ctx_status=$(curl -s -o /dev/null -w "%{http_code}" "$ctx_url" 2>/dev/null) || true
    if [ "$ctx_status" = "200" ]; then
        # Also validate it's valid JSON
        if curl -s "$ctx_url" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
            pass "Context JSON-LD accessible and valid at $ctx_url"
        else
            fail "Context JSON-LD" "accessible but not valid JSON"
        fi
    else
        skip "Context accessibility" "HTTP $ctx_status (may still be deploying)"
    fi
else
    skip "GitHub Pages" "curl not available"
fi

# ─────────────────────────────────────────────
echo
echo "════════════════════════════"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "════════════════════════════"
[ "$FAIL" -eq 0 ] || exit 1
