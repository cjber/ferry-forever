#!/usr/bin/env bash
# Shortest Path Forever: bake walkable ground for whole maps from a local WoW client and package ShortestPathForever_Nav<map>.
# Reads the install read-only (CASC local storage only, no CDN) and writes everything under $OUT.
#   WOW=<install root holding .build.info> MAPS="0 1 2991" ./bake.sh
# Resumable: a rerun skips tiles that already have a status file under $OUT/mm<map>/status.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/work}
WOW=${WOW:-"$HOME/Games/battlenet/drive_c/Program Files (x86)/World of Warcraft"}
PRODUCT=${PRODUCT:-wow_classic_beta}
MAPS=${MAPS:-"0 1 2991"}
THREADS=${THREADS:-8}                                 # bake threads; peak RSS is ~5-9 GB at 8
JOBS=${JOBS:-6}                                       # gen_nav rasterizer processes
MAPPSTER_REV=d93fd3b347d8c63663cff536955e3cae97fa28a6 # F0RSV1NNA/Mappster, MIT
CASCLIB_REV=2a280f5a231966dc5d1b534978dd9f9f04a374cd  # ladislav-zezula/CascLib, MIT
DBD_REV=7539907c14f9ac88c6db20f5fa699425ad35ac84      # wowdev/WoWDBDefs, CC BY-SA 4.0 (fetched, never committed)
declare -A DBD_SHA=(
	[Map]=c879e3d74284fa9096e49feecc984fe56fd9e12e61b4cf5525854829e1c45f05
	[LiquidType]=06dd61c3a20a18d56781fa45fe3c896a64baf191deed9a8feaeeb8aad3e4db0b
)
declare -A TITLE=([0]="Eastern Kingdoms" [1]="Kalimdor" [2991]="Zephras Isle")
mkdir -p "$OUT"

export DOTNET_ROOT=${DOTNET_ROOT:-$OUT/dotnet} DOTNET_CLI_TELEMETRY_OPTOUT=1 NUGET_PACKAGES=${NUGET_PACKAGES:-$OUT/nuget} DOTNET_CLI_HOME=$OUT/dnhome
if [ ! -x "$DOTNET_ROOT/dotnet" ]; then
	curl -sSL https://dot.net/v1/dotnet-install.sh -o "$OUT/dotnet-install.sh"
	bash "$OUT/dotnet-install.sh" --channel 10.0 --install-dir "$DOTNET_ROOT"
fi

# Mappster sources only: its WoW-Tools CascLib submodule (no licence) is deliberately not fetched.
if [ ! -d "$OUT/Mappster" ]; then
	git clone -q https://github.com/F0RSV1NNA/Mappster "$OUT/Mappster"
	git -C "$OUT/Mappster" checkout -q $MAPPSTER_REV
	git -C "$OUT/Mappster" apply "$HERE/mappster.patch"
fi
if [ ! -f "$OUT/casclib/build/libcasc.so" ]; then
	git clone -q https://github.com/ladislav-zezula/CascLib "$OUT/casclib"
	git -C "$OUT/casclib" checkout -q $CASCLIB_REV
	cmake -S "$OUT/casclib" -B "$OUT/casclib/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
		-DCASC_BUILD_SHARED_LIB=ON -DCASC_BUILD_STATIC_LIB=OFF >/dev/null
	cmake --build "$OUT/casclib/build" -j"$(nproc)" >/dev/null
fi
mkdir -p "$OUT/dbd"
for t in "${!DBD_SHA[@]}"; do
	f=$OUT/dbd/$t.dbd
	[ -f "$f" ] || curl -sSfL "https://raw.githubusercontent.com/wowdev/WoWDBDefs/$DBD_REV/definitions/$t.dbd" -o "$f"
	echo "${DBD_SHA[$t]}  $f" | sha256sum -c --quiet
done
export NAV_DBD=$OUT/dbd

"$DOTNET_ROOT/dotnet" build -c Release -nologo -v q "$HERE/src/NavBaker.csproj" -o "$OUT/bin" \
	-p:MappsterDir="$OUT/Mappster" -p:BaseIntermediateOutputPath="$OUT/obj/" | tail -1
cp -P "$OUT"/casclib/build/libcasc.so* "$OUT/bin/"

mkdir -p "$OUT/run"
for m in $MAPS; do
	# CascLib keeps nothing on disk; the working directory only collects .NET crash dumps.
	(cd "$OUT/run" && "$DOTNET_ROOT/dotnet" "$OUT/bin/NavBaker.dll" --continent "$WOW" "$PRODUCT" "$m" "$OUT/mm$m" "$THREADS") \
		2>&1 | grep --line-buffered -v '^delaunayHull' | tee -a "$OUT/bake$m.log"
	if grep -q '^FAILED' "$OUT/mm$m/status/"*; then
		echo "map $m: failed tiles (see $OUT/mm$m/status/); rerun after deleting their status files" >&2
		exit 1
	fi
	name=${TITLE[$m]:-${MAP_NAME:?set MAP_NAME for map $m}}
	addon=$OUT/addons/ShortestPathForever_Nav$m
	mkdir -p "$addon"
	NAV_MM=$OUT/mm$m NAV_JOBS=$JOBS python3 "$HERE/gen_nav.py" "$addon/Nav$m.lua" --map "$m" --name "$name"
	cat >"$addon/ShortestPathForever_Nav$m.toc" <<TOC
## Interface: 16001
## Title: Shortest Path Forever - Walking map ($name)
## Notes: Walkable ground for Shortest Path Forever's walking routes on $name. Loaded when a route needs it.
## LoadOnDemand: 1
## Dependencies: ShortestPathForever
## X-License: GPL-3.0-or-later

Nav$m.lua
TOC
done
