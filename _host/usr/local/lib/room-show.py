#!/usr/bin/env python3
# room-show: designed light "looks" for a room's Hue lamps (2026-10-19, rebuilt the same day).
# Each look is three colours that belong together: a BASE that washes the walls (floor lantern,
# uplighter), an ACCENT on the desk (lightbars, strip) and a HIGHLIGHT on the small shelf lamps.
# Inside a look the colours drift gently; every 100 s the room crossfades (20 s) to the next look.
# Colours blend by hue (never through grey). Feeds HyperHDR at priority 80 (above tv-mood's 90)
# through the Hue entertainment area. Ends after DURATION or when someone pauses the lamps.
import colorsys, json, base64, math, socket, sys, time

HH = ("127.0.0.1", 19444)
DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 6 * 3600
FPS = 25
LOOK, XFADE = 100.0, 20.0   # seconds per look, seconds of crossfade
DRIFT = 34.0                # seconds per gentle drift inside a look

# (name, base hue, accent hue, highlight hue) in degrees
LOOKS = [("Nebula", 248, 292, 330),
         ("Desert sunset", 30, 8, 325),
         ("Aurora", 172, 215, 268),
         ("Ember and ocean", 228, 275, 32),
         ("Royal", 268, 300, 40)]

# Hue channel order (same as tv-mood): where each lamp sits on the base -> accent -> highlight scale
ROLE = [0.42, 0.58, 0.5,    # Left Lightbar, Right Lightbar, LED Strip  (desk: accent)
        0.12, 0.0,          # Floor Lantern, Floor Uplighter            (wall washes: base)
        0.86, 0.72,         # Retro, Cozy                               (shelf: highlight)
        1.0, 0.92]          # Mushroom, Glowing Sphere


def hmix(a, b, f):          # blend two hues the short way round the colour wheel
    d = ((b - a + 180) % 360) - 180
    return (a + d * f) % 360


def look_hue(look, t):      # t 0 = base, 0.5 = accent, 1 = highlight
    _, b, a, h = look
    t = max(0.0, min(1.0, t))
    return hmix(b, a, t * 2) if t < 0.5 else hmix(a, h, (t - 0.5) * 2)


def ease(f): return f * f * (3 - 2 * f)


def main():
    c = socket.create_connection(HH, timeout=5); f = c.makefile("rb")
    rpc = lambda o: (c.sendall((json.dumps(o) + "\n").encode()), json.loads(f.readline()))[1]
    rpc({"command": "componentstate", "componentstate": {"component": "LEDDEVICE", "state": True}})
    start = time.time(); seen_on = False; tick = 0
    while time.time() - start < DURATION:
        t = time.time() - start
        k = int(t // LOOK); into = t - k * LOOK
        cur, nxt = LOOKS[k % len(LOOKS)], LOOKS[(k + 1) % len(LOOKS)]
        mixf = ease(max(0.0, (into - (LOOK - XFADE)) / XFADE))
        fade = min(1.0, t / 4.0)
        px = []
        for n, role in enumerate(ROLE):
            r = role + 0.14 * math.sin(2 * math.pi * (t / DRIFT + n * 0.13))
            hue = hmix(look_hue(cur, r), look_hue(nxt, r), mixf)
            val = (0.86 + 0.14 * math.sin(2 * math.pi * (t / 13.0 + n * 0.11))) * fade
            px += [max(0, min(255, int(v * 255))) for v in colorsys.hsv_to_rgb(hue / 360, 0.97, val)]
        rpc({"command": "image", "imagewidth": len(ROLE), "imageheight": 4, "format": "rgb",
             "imagedata": base64.b64encode(bytes(px) * 4).decode(), "priority": 80,
             "origin": "Room show", "duration": 2000})
        tick += 1
        if tick % FPS == 0:                      # once a second: stop if someone paused the lamps
            info = rpc({"command": "serverinfo"})["info"]
            on = next(x["enabled"] for x in info["components"] if x["name"] == "LEDDEVICE")
            if on: seen_on = True
            elif seen_on: break
        time.sleep(1 / FPS)
    rpc({"command": "clear", "priority": 80})


if __name__ == "__main__":
    main()
