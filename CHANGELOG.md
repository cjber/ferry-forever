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
their live waits, the tram and portals, with a button to set a waypoint on the first stop.

On board, once the ride has synced, the tracker shows where the boat calls next and when it gets there. Half
a minute before a timed boat reaches the dock you are waiting at, and shortly before your own boat docks, a
raid-warning banner, a sound and a flashing taskbar icon let you know, even with the game in the
background. A `/reload` or logout mid-ride keeps the ride so far. Every map layer, the tracker, the alerts
and their sound, the planner and sharing can each be switched off in the settings.
