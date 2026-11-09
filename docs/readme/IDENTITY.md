# homelab: the README's look

**Glass.** The README belongs to the same family as the author's GitHub profile: real output as frosted-glass windows floating in light, with depth, refraction and one part of each window lifted out toward the viewer. Nothing in a window is drawn by hand. The terminals are the real output of this repo's scripts (`scripts/readme-demo.sh` runs them on synthetic data); the charter, the numbers and the diagram are typeset from `docs/ai-operator.md` and the repo's own config.

**One idea per image.** Each image lifts out the one line that proves its point: the drill's result, Vaultwarden restored and identical to live, the push that was held back, the drifted line put back, the command that stops the operator, the internet with no way in.

**Dark first.** The dark images are the main work: a night room with soft shafts of green-white light, dark glass and dark terminals, edges that dissolve into GitHub's `#0d1117`. The light images use the same compositions in daylight, with paper-white terminals and soft window shadows, dissolving into `#ffffff`. Colour is spent only on meaning: green for checks that passed, amber for drift and held-back pushes, red for a failure.

**Type.** Geist for headings, numbers and prose; Geist Mono for terminals and labels.

**Motion.** The hero is an 8-second loop: the glass holds still while the light moves through the room and the drill's result floats in front. Every other image is a still.

**Rebuild.** `scripts/readme-visuals.sh` (see its header). Sources: `docs/readme/src/textures.mjs` (window content), `docs/readme/src/layouts.js` (compositions), `docs/readme/src/glass/` (the renderer: three.js in headless Chromium). Dates and archive names are removed from the captured lines so the images do not age; nothing else in them is changed.
