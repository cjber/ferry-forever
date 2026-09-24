# Changelog

What changed in each release, in the terms someone finding their way would notice. Dates are UTC.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The entries are prose rather than bare
Added/Fixed lists.

Each version's entry is also its release notes on GitHub, CurseForge and Wago. Older entries are kept
verbatim rather than rewritten as the addon moves.

## [Unreleased]

**Journeys can start with your hearthstone.** The Hearthstone, a mage's city teleports (with a Rune of
Teleportation in your bags), a shaman's Astral Recall and a druid's Teleport: Moonglade are the first step when
they save time: *1. Use Hearthstone*, after its own icon and named in your game's language. A cooldown counts as waiting time, so a
hearth due in two minutes can still win. Your bind point is learned when you next set it at an innkeeper, and
forgotten if you bind somewhere else without the addon, or on a `/reload` or relog while the client does not load
addons' saved settings. Other addons' estimates from where you stand count
them too. *Use your hearthstone and teleports* in `/path` turns this off.

Walking legs are round breadcrumb dots, evenly spaced around every bend, instead of dashes, on the map and
the minimap alike, a little smaller on continent and world maps. Boats, zeppelins and flights keep their solid
coloured lines.

**Arrival alerts sound like the transport.** A boat rings the ship's bell it rings at the dock, a zeppelin
sounds its horn and the tram plays its own arrival, instead of the raid-warning sound, which reads as a boss
mechanic rather than your boat.

**Other addons can offer Shortest Path guidance.** The version 1 public API estimates travel time and starts
journeys through one or several stops in order. Numbered map pins, drawn as the Adventure Guide's gold-numbered
rings that glow when you hover them, mark the remaining stops, and the way on to each is drawn as you will
travel it: walks follow the paths round hills like the current leg, and boats, zeppelins and flights show in
their colours, never a line across the sea. A dotted straight line stands in only until that stretch is worked
out, a moment after the current leg's. Stops whose pins would overlap at the map's zoom share one, numbered like
*4-7* or *2, 5*, and hovering it names each stop in order. The stop you are heading for keeps its pin
at full strength, and later stops overlapping it join that pin rather than stack on it.
Guidance advances on arrival and shows your progress. An addon can check the current stop and cancel
only its own whole route, preserving a journey you start yourself. It can also show how a trip goes, such as
the boat, the flight and a new flight path to pick up on the way, say why no time is shown (in combat, or no
way there yet), and warn you before replacing a journey you are already on.

Docks, lifts, tram stations and portals now show on the minimap with the world map's icons, and hovering one
gives the same departures tooltip. They vanish at the minimap's rim like the game's own tracking icons, and
cost nothing away from them. *Transport* in the minimap's tracking menu, or the new setting in `/path`, turns
them off.

A journey step on a boat, lift or tram that nobody has timed yet no longer says “no sighting yet” beside a
wait it cannot know. Its wait reads *wait about 2:45* instead: half the loop, the average wait. Timed
crossings show their real wait as before.

Journeys through the Deeprun Tram no longer tell you to walk to “Unknown”. A step towards a passage or portal
names it, such as *Walk to Passage to Stormwind*, and a tram passage's map pin says where it leads.

Guide keeps its map pin hidden and removes it when a journey ends, tracking changes or you reload, while
preserving your own pins and tracking choices.

Clicking a dock, station or portal on the world map opens the map at the other end of the crossing and pings
where it comes in. A dock with boats or zeppelins to several places asks which one with a small menu. The
tooltip says when a click will take you somewhere.

New journeys show a destination pin and the familiar Group Finder spinner while finding the fastest way,
then reveal the route and steps together. Longer searches show their best route after three seconds
and keep it unless another is at least 30 seconds and 10% faster, or the route no longer works. While the
spinner turns, the route pulses gently on the world map and minimap, becoming steady when the search finishes.
Later checks happen quietly without pulsing routes or changing “finding” messages. Journey searches
retain less memory, clearing a journey frees its caches, and `/path perf` now collects unused memory
before reporting what remains.

The Journey header's time is the sum of the steps below it. It used to count down to the planned arrival, so
standing still it slipped a few seconds below the steps and jumped back every five seconds.

Walks in Stormwind no longer loop round the city through the canals. The game never reports your height, and
the walk started from the lowest floor under you, often the canal bed below a street. A walk from somewhere
with several levels, or to a map click or stop there, now starts from whichever one is quickest. Zeppelin
walks end on the tower's platform, not the ground below it, at Grom'gol, Tirisfal and the tower to Zephras.
A walk no longer runs out and back along the same street, as one from Stormwind's flight master to the Mage
Quarter did past the Trade District.

## [1.1.0] - 2026-09-23

A new icon across the addon and its walking maps, settings in the minimap's addon compartment, and a fixed place in the objective tracker.

- **Open the settings from the addon compartment** on the minimap, as with `/path`.
- **The Journey and Boats section keeps its place in the objective tracker** beside SkillUp Forever's shopping list: the two shared one slot, so their order could change; each now has its own, above your quests.
- **A new icon**, drawn to match the other WoW: Forever addons, now also on the three walking maps in the addon list.

## [1.0.0] - 2026-09-23

A route finder for WoW: Forever: pick a spot on the map or a quest and it plans the
fastest way there and walks you to it. Every boat and zeppelin, including the new Forever crossings to Southshore,
Riverglades and Zephras Isle, has its dock marked on the world map, a ferry for boats and a zeppelin drawn
to match it for zeppelins. Hovering a dock lists where each boat goes next, counts down to its arrival and
departure, and lights up the docks it sails to. Docks that would overlap on a zoomed-out map share one
icon, with each pier named in the tooltip. The map's filter menu can hide the icons, or just the other
faction's routes. Near a dock, a Boats section above your quests shows the same countdowns.

Each route's loop time comes from the game's own path data, so a single ride fixes a boat's schedule for
hours. Ride once and it syncs, and the sighting is shared quietly with your guild, party and anyone at the
dock, so other players' rides time your boats too. Sharing can be turned off in the settings (`/path`).

The lifts at the Great Lift, Freewind Post, Thunder Bluff and Undercity, and both Deeprun Tram trains, are
timed the same way: countdowns on the map and in the tracker, synced from a ride and shared. The tram is
marked at its city entrances, and portals are marked with where they lead. Shift-click the world map or minimap to
plan the fastest way to that spot, combining walking, the flight points you know, boats and zeppelins with
their live waits, the lifts, the tram and portals, and a flight master you haven't found yet when walking to it pays
off. **Plan journey** in a quest's right-click menu, or Shift-clicking its marker on the map, does the same
for its objective, or its turn-in once it is complete. The route is drawn on the world map and minimap as a
slim outlined line that reads on any map, walking legs dotted and the destination marked with the
waypoint pin, and its steps sit in the objective tracker like a tracked quest. **Guide**, on from the start of every journey and toggled from the tracker header,
moves the game's own waypoint marker along the route turn by turn (or only to where each step ends, a setting), and gives your tracked quest back when you finish. Walking legs follow the ground round walls, cliffs and water on Eastern Kingdoms, Kalimdor
and Zephras Isle, from walking maps that come in the same download. They take tunnels such as Dun Algaz and
the Undercity's lower levels, ride a lift when the way round on foot is longer, and take the boat rather than
a long swim. Walks keep out of water, unless you have Water Walking or Levitate, when the step asks you to
cast it and the route crosses. Walks between docks, flight masters and portals are measured ahead of time and
ship with the addon, so plans spend less time checking walks. Replanning on board
keeps you on the boat. Flight masters are marked on the world map, known and undiscovered, and hovering a
dock draws its boat and zeppelin routes. On the Azeroth map, crossings curve from dock to dock across the
sea; closer maps keep the real sailing path to the map edge.

While a journey's walks are being checked, the tracker says it is finding the fastest way and the route
pulses softly on the map and minimap. Easy routes settle quickly, and longer searches stop once unchecked
alternatives cannot beat the chosen route, without searching the whole continent. Drawn paths stay visible
during refreshes. Route finding uses less memory and shares its work across frames to reduce hitches; the
first walking-map load starts after the click. Repeated journeys to the same destination reuse their walking costs. Your position is
checked again when you leave the path or once a minute; standing still or moving a few yards within the same
walking-map cell reuses its costs. Once settled, the arrival countdown returns. Walk
steps name the dock, pier, lift or flight master you are heading for. An optional compass strip follows your facing and
marks Guide's next two turns, the next stop and your destination, with yards to the next turn. It is off
by default and can be turned on in `/path`. Its heading glides smoothly as you turn, with stock UI fonts,
a soft frame and correctly proportioned markers. Marks for the same place or bearing combine into one,
keeping the destination or transport icon and the distance to your next turn.

Guide and the route survive temporarily unavailable player coordinates, and the drawn walking leg
trims as you move without waiting for the next route search. On the minimap, the final 30 yards fade into
the destination and the whole line fades as you approach within 40 yards. Guide's final marker uses a
fading arrow nearby so its native waypoint does not cover the goal; the world-map route keeps its contrast.

On board, once the ride has synced, the tracker shows where the boat calls next and when it gets there. Half
a minute before a timed boat reaches the dock you are waiting at, and shortly before your own boat docks, a
raid-warning banner, a sound and a flashing taskbar icon let you know, even with the game in the
background. A `/reload` or logout mid-ride keeps the ride so far. Every map layer, the tracker, the alerts
and their sound, the planner and sharing can each be switched off in the settings.

The Journey section in the objective tracker shows the time and yards remaining across every leg,
following measured walking paths and transport routes. The destination stays on its own line, and the
totals update as you travel without rebuilding the tracker layout.

Background polling sleeps when you are stationary away from travel activity. Docks and passive boat
or lift rides still wake the countdowns and observation; unchanged tracker content is reused, and shared
sightings don't rebuild unrelated map layers. Walking searches and tracker updates wait through
combat. Less terrain bookkeeping is built at login, and `/path perf` shows the client's measured CPU cost
and addon memory for checking performance in game.
