#!/usr/bin/env bash
# Fetch the Blizzard UI source tests/harness_ui.lua runs against, pinned and checksummed, into tools/.cache.
set -euo pipefail

cd "$(dirname "$0")/.."
# Gethe/wow-ui-source 1.60.1 (69913), the client build the harness was written against.
revision=70ef1b2fd78061a73f886c4a1e79dc5b5cff6d5e
root=tools/.cache/blizzard-ui
while read -r sum file; do
	path=$root/Interface/AddOns/$file
	if [[ ! -f "$path" ]]; then
		mkdir -p "$(dirname "$path")"
		curl -fsSLo "$path.tmp" "https://raw.githubusercontent.com/Gethe/wow-ui-source/$revision/Interface/AddOns/$file"
		mv "$path.tmp" "$path"
	fi
	echo "$sum  $path" | sha256sum --quiet -c -
done <<'FILES'
28ad9798f0f68d8d5ddd26f99ec5f8ef5ceebacec9fd941f25b05406336335b7 Blizzard_SharedXML/Spinner.lua
5cb19b521d4073eee01c73a3f22fe0fbcf9a0f84ba389e7bb301fc2b057e4630 Blizzard_SharedXML/Spinner.xml
0e7c53d743f81543f0ebb8263a4b232e12bb5799b16eddab8aa3ea97c71db134 Blizzard_SharedMapDataProviders/FlightPointDataProvider.lua
ed58fd36928782eb79aaf6826a283ba432b708d3ef4a0fdb065fb8b2b169f251 Blizzard_SharedMapDataProviders/WaypointLocationDataProvider.lua
eb5945b8b5923f07c272a8c7a50ab5534426db888fc4ca2c6248697411cebcd9 Blizzard_SharedMapDataProviders/QuestDataProvider.lua
22d116c7d374116623ca1f4adab12a5dea48a6f94485606712578b96a59df7a0 Blizzard_MapCanvas/MapCanvas_DataProviderBase.lua
82c415d02d28565636e8dda2954081fbdd3218b68b8f42cdf3c324eedcff4a01 Blizzard_POIButton/POIButton.lua
9ee9e6f3e05882f3018ecbef8d356c0b5145ba489bff1f4dfa847191143019a4 Blizzard_ObjectiveTracker/Blizzard_QuestObjectiveTracker.lua
eee41538a4a98947d899447226f0c028353c0c5d76cd9c8b44b6853081a39d30 Blizzard_ObjectiveTracker/Camelot/Blizzard_QuestObjectiveTrackerOverride.lua
9fccbb21ab9a807fed8f6685c0adfe14f538250819cc8b44fc198c426d0e67df Blizzard_UIPanels_Game/Mainline/QuestMapFrame.lua
FILES
