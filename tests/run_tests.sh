#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Running lab-cli regression test suite..."
echo ""

chmod +x "${SCRIPT_DIR}"/test_*.sh

"${SCRIPT_DIR}/test_lab_test_runner.sh"
echo ""
"${SCRIPT_DIR}/test_deploy_gate.sh"
echo ""

echo "All lab-cli tests completed successfully!"
