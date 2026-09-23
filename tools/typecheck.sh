#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
revision=d0b5b51fac4c52c493371b9b18e66ce604ea4326
library=.types/vscode-wow-api
mkdir -p .types
if [[ ! -e "$library" ]]; then
	checkout=$(mktemp -d .types/wow-api.XXXXXX)
	trap 'rm -rf "$checkout"' EXIT
	git init -q "$checkout"
	git -C "$checkout" remote add origin https://github.com/Ketho/vscode-wow-api.git
	git -C "$checkout" fetch --quiet --depth=1 origin "$revision"
	git -C "$checkout" checkout --quiet --detach FETCH_HEAD
	mv "$checkout" "$library"
	trap - EXIT
fi
if [[ $(git -C "$library" rev-parse HEAD) != "$revision" ]] ||
	[[ -n $(git -C "$library" status --porcelain) ]]; then
	echo "Expected clean WoW annotations at $revision in $library" >&2
	exit 1
fi
if [[ $(lua-language-server --version) != 3.19.1 ]]; then
	echo "Install lua-language-server 3.19.1 to match CI." >&2
	exit 1
fi

python3 tools/typecheck_coverage.py
python3 -m unittest discover -s tests -p 'test_typecheck.py'
python3 tools/lint_multivalue.py
# An interrupted check must never leave a stale report looking like this run's result.
report=.types/diagnostics.json
rm -f "$report"
status=0
lua-language-server --check . --checklevel=Information --check_format=json \
	--check_out_path="$report" --logpath=.types/luals-log || status=$?
python3 tools/typecheck_report.py "$report"
exit "$status"
