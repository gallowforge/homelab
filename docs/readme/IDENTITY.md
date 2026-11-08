# homelab: visual identity

**One idea.** The house sleeps; the station never does. One Raspberry Pi runs the household like a power station that is staffed around the clock.

**Signature concept.** Every image is one panel of the same control-room mimic board: the wall diagrams of power stations and rail control rooms. Services are labelled lamps on navy enamel, flow lines are the real traffic paths (house, DNS, the Caddy TLS edge, the service bus; archives out to the PC and MacBook; pushes to the phone; the dead-man switch), and the real timers are engraved like duty-roster plates (05:00 backup, 05:30 updates, Sunday 05:45 restore drill, 07:30 health check, 08:10 operator round, 5-minute heartbeat). A small house with one lit window sits in the corner of the main board, and the station clock reads 05:00:02, the stamp of the demo backup.

**Panels.** Each feature gets the control-room instrument that already does its job: `M1` main mimic (hero), `B0` plant status (panel meters with ghost segments), `B1` front door (the internet breaker locked out, with a tag), `B2` backup hall (the event printer, failures in red as on a two-colour ribbon), `B3` restore drill (a synchroscope: archive in sync with live), `B4` annunciator (alarm windows and the one push), `B5` configuration (discrepancy switches beside a white-phosphor VDU), `B6` duty operator (standing orders and an emergency stop). The README reads like a walk along the board.

**Type.**
- **Saira** (variable width and weight) descends from the squared instrument lettering of Eurostile and Microgramma, the faces engraved on real control panels. Width 125% gives the engraved caps of labels and plates; width 100% carries headlines and prose. One family does both.
- **Martian Mono** (variable width) is a technical mono with character. It runs condensed at 75% for long terminal output on printouts and the VDU, and at 87.5% for captions and readouts.

**Palette.** 60/30/10, with two signal colours used only as lamps.

| Role | Hex | Use |
|---|---|---|
| Control-room navy (field, 60) | `#10202f` (gradient `#15293c` to `#0b1825`) | the enamel board |
| Engraved ivory (support, 30) | `#ebe5d5`, secondary `#b8c2cb`, captions `#7d90a2` | engraving, plates, paper |
| Signal amber (accent, 10) | `#f5a63c` | activity only: live paths, the bus, running jobs, the lit window |
| All-clear green | `#52d68a` | lamps that say healthy |
| Alarm red | `#ff4b3a` (ink `#c3301f`) | at most once per panel: a failure, the emergency stop |
| Paper | `#efe9da`, ink `#1a2633` | printouts, tags, standing orders |

**Composition grammar.** Square-cornered enamel panels with countersunk screws, never rounded cards. A label rail across the top of every panel: an ivory board-number plate, the title in engraved caps, a short note. Left-aligned, one dominant instrument per panel, an engraved source line at the foot saying where the content came from. No glows except lamps, no gradients except light falling on enamel.

**Voice.** Steady and proud. Short declaratives, engraved labels, the facts a duty engineer would write on a plate: "Locked by the ISP. Kept locked on purpose."

**Rebuild.** `scripts/readme-visuals.sh` renders every page in `docs/readme/src/` (shared `board.css` and `common.js`). Terminal content comes from `docs/readme/src/demo/`, captured by `scripts/readme-demo.sh`.
