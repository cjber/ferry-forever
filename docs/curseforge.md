I wanted a proper "get me there" for WoW: Forever, so Shortest Path Forever finds the fastest way across the world. Shift-click a destination on the map, or pick a quest, and it joins walking paths, flight paths, boats, zeppelins, lifts, the Deeprun Tram, portals and your hearthstone or class teleports into one journey. Directions use the game's own waypoint marker, map pins and objective tracker, so it looks like it came with the game. Walking maps for Eastern Kingdoms, Kalimdor and Zephras Isle come in the same download.

![Eight-second demo of a route settling, the countdown and compass](https://raw.githubusercontent.com/cjber/shortest-path-forever/main/docs/screenshots/demo.gif)

## Features

- **A journey from where you stand.** Walking paths go around walls, hills and water, and through tunnels. The planner uses the flight points you know and can walk you to an undiscovered flight master when that saves time. Boat waits count towards the arrival time.
- **Directions on the map and minimap.** Walking legs are round breadcrumb dots, transport legs have their own colours, and a waypoint pin marks your destination. The Group Finder spinner turns while a new journey is checked.
- **Guide, on with every journey.** The game's own waypoint marker leads you to the next boat, lift, flight master or your destination, or round each turn of the walk if you prefer. Click the Journey header to toggle Guide, or right-click it to show the destination on the map or clear the journey. An optional compass marks your next turns, stop and destination.
- **Back to your corpse.** As a ghost, a red dotted path in your tombstone's colour leads back to your body, and your journey picks up again once you are alive.
- **Live departures.** Hover a dock, on the world map or the minimap, to see where its boats go, when they arrive and when they leave. Destination docks light up; click one to open the map at the other end. Nearby departures appear in the objective tracker; aboard a timed boat, it shows the next stop.
- **Lifts, trams and portals.** Landings and stations have their own countdowns. Portals show where they lead, and clicking one opens that map. All three can be part of a journey.
- **Schedules learned from real rides.** Ride once to sync a transport. Sightings are shared quietly with your guild, party and nearby players. Unsynced services say “no sighting yet”, and a journey shows their guessed wait as “leaves in about”.
- **Arrival alerts.** A banner, the ship's own bell and a flashing taskbar icon warn when your boat is due, for when you're AFK. Zeppelins sound their horn instead.

![Journey steps from Auberdine to Silithus, with time and distance remaining](https://raw.githubusercontent.com/cjber/shortest-path-forever/main/docs/screenshots/tracker.png)

The journey in the objective tracker, step by step, with time and distance left.

![Auberdine’s piers on the minimap, with the dotted route and Guide’s native waypoint](https://raw.githubusercontent.com/cjber/shortest-path-forever/main/docs/screenshots/minimap.png)

On the minimap, the route in dots and Guide using the game's own waypoint.

![Hovering Auberdine’s piers shows departures and lights destination docks](https://raw.githubusercontent.com/cjber/shortest-path-forever/main/docs/screenshots/docks.png)

Hover a dock to see where its boats go and when.

![The optional compass strip with the next turns and destination](https://raw.githubusercontent.com/cjber/shortest-path-forever/main/docs/screenshots/compass.png)

The optional compass, for your next turns and destination.

![A journey from Auberdine through Menethil and Theramore to Silithus](https://raw.githubusercontent.com/cjber/shortest-path-forever/main/docs/screenshots/kalimdor.png)

A longer trip: Auberdine to Menethil, then Theramore, then Silithus.

## Usage

Shift-click the world map or minimap to plan a journey. For a quest, choose **Plan journey** from its right-click menu in the quest log or objective tracker, or Shift-click its map marker. Completed quests route to their turn-in.

- `/path` opens settings, also under **Options → AddOns → Shortest Path Forever**.
- `/path perf` prints the addon's CPU time and memory use.
- `/path debug` enables a saved trace for reporting a ride that did not sync.

Every feature has its own switch in the settings. The world map's filter menu hides flight masters, docks, lifts, the tram, portals and the other faction's routes.

It's in English for now. Translations are welcome on the project's [Localization page](https://legacy.curseforge.com/wow/addons/shortest-path-forever/localization).

Source code and issues: [github.com/cjber/shortest-path-forever](https://github.com/cjber/shortest-path-forever) (GPL-3.0).
