# Changelog

What changed in each release, in the terms someone waiting at a dock would notice. Dates are UTC.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The entries are prose rather than bare
Added/Fixed lists.

Each version's entry is also its release notes on GitHub, CurseForge and Wago. Older entries are kept
verbatim rather than rewritten as the addon moves.

## [Unreleased]

The first release. Every boat and zeppelin, including the new Forever crossings to Southshore,
Riverglades and Zephras Isle, has its dock marked on the world map, a ferry for boats and a zeppelin drawn
to match it for zeppelins. Hovering a dock lists where each boat goes next, counts down to its arrival and
departure, and lights up the docks it sails to. Docks that would overlap on a zoomed-out map share one
icon, with each pier named in the tooltip. The map's filter menu can hide the icons, or just the other
faction's routes. Near a dock, a Boats section above your quests shows the same countdowns.

Each route's loop time comes from the game's own path data, so a single ride fixes a boat's schedule for
hours. Ride once and it syncs, and the sighting is shared quietly with your guild, party and anyone at the
dock, so other players' rides time your boats too. Sharing can be turned off in the settings (`/ferry`).

The lifts at the Great Lift, Freewind Post, Thunder Bluff and Undercity, and both Deeprun Tram trains, are
timed the same way: countdowns on the map and in the tracker, synced from a ride and shared. The tram is
marked at its city entrances, and portals are marked with where they lead. Shift-click the world map to
plan the fastest way to that spot, combining walking, the flight points you know, boats and zeppelins with
their live waits, the tram and portals, and a flight master you haven't found yet when walking to it pays
off. **Plan journey** in a quest's right-click menu, or Shift-clicking its marker on the map, does the same
for its objective, or its turn-in once it is complete. The route is drawn on the world map and minimap as a
slim outlined line that reads on any map, walking legs dotted and the destination marked with the
navigation diamond, and its steps sit in the objective tracker like a tracked quest. **Guide**, on from the start of every journey and toggled from the tracker header,
moves the game's own navigation marker, wearing the quest diamond, along the route bend by bend and gives your tracked quest back when you finish, and replanning on board
keeps you on the boat. Flight masters are marked on the world map, known and undiscovered, and hovering a
dock draws its boat and zeppelin routes, curving across the loading-screen gap between continents.

On board, once the ride has synced, the tracker shows where the boat calls next and when it gets there. Half
a minute before a timed boat reaches the dock you are waiting at, and shortly before your own boat docks, a
raid-warning banner, a sound and a flashing taskbar icon let you know, even with the game in the
background. A `/reload` or logout mid-ride keeps the ride so far. Every map layer, the tracker, the alerts
and their sound, the planner and sharing can each be switched off in the settings.
