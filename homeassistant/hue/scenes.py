#!/usr/bin/env python3
"""Hue scenes for one room (v2). Creates or updates them on the Hue bridge.

Run: sudo python3 ~/docker/homeassistant/hue/scenes.py [scene name ...]
(reads the bridge key from HA's hue entry). Scenes with the same name are updated in place.

The room's lamps, from the Hue light placement screen:
  desk wall (left)      Left Lightbar, Right Lightbar (Hue Play, behind a monitor), LED Strip (under the desk)
  corner left of the TV Floor Lantern (tall torchiere)
  TV                    Floor Uplighter
  shelves right of TV   Retro Lamp (top shelf), Cozy Light (middle), Mushroom Lamp (shelf), Glowing Sphere (low)

It also keeps the bridge tidy (idempotent): light names = device names, power-cut behaviour
"powerfail" (lamps come back as they were, not full white), zones Desk and Shelves, and it
deletes scenes not defined here (export the bridge's scenes before the first run).

Rules (from feedback on v1: "lights don't match brightness", "some turn off and not alongside the others"):
  * every light is on in every scene (only Sleep keeps the shelf lamps off); no effects (the bridge runs effects at their own brightness)
  * brightness is balanced so every lamp LOOKS equally bright: each lamp's percentage is
    worked out from its lumen output and from how bright its colour is (deep blue and red
    give far fewer lumens than amber at the same %), then the whole scene is scaled to its level.
"""
import json, math, ssl, sys, urllib.error, urllib.request

LUMENS = {"Left Lightbar": 530, "Right Lightbar": 530, "LED Strip": 1000,  # strip 1600 lm, half hidden under the desk
          "Floor Lantern": 800, "Floor Uplighter": 800, "Retro Lamp": 800, "Cozy Light": 800,
          "Mushroom Lamp": 800, "Glowing Sphere": 800}
DESK, CORNER, TV = ("Left Lightbar", "Right Lightbar", "LED Strip"), "Floor Lantern", "Floor Uplighter"

SHELVES = ("Retro Lamp", "Cozy Light", "Mushroom Lamp", "Glowing Sphere")
ROOM = "Living room"  # the Hue room the scenes belong to; HA names them scene.living_room_<scene>
ZONES = {"Desk": (DESK, "office"), "Shelves": (SHELVES, "lounge")}
AMBER = "#FE9F2C"  # the house amber (Cozy / Movie / Cinematic)

# level = % of the lamp that has to work hardest (deep blue on a Play bar, usually).
S = {
 # routine scenes (HA scripts use them), balanced
 "Daylight": dict(level=100, c={n: "2570K" for n in LUMENS}),
 "Cozy": dict(level=95, c={n: AMBER for n in LUMENS}),
 "Movie": dict(level=72, c={n: AMBER for n in LUMENS}),
 "Cinematic": dict(level=24, c={n: AMBER for n in LUMENS}),
 "Sleep": dict(level=12, c={n: (None if n in SHELVES else "#FEA026") for n in LUMENS}),
 # mood scenes
 "Golden Hour": dict(level=90, c={"Left Lightbar": "#FF9A3C", "Right Lightbar": "#FF9A3C", "LED Strip": "#FF8A2A",
    CORNER: "#FFB648", TV: "#FF8A2A", "Retro Lamp": "2200K", "Cozy Light": "#FFA552",
    "Mushroom Lamp": "#FFB76B", "Glowing Sphere": "#FF8F45"}),
 "Fireplace": dict(level=70, c={"Left Lightbar": "#FF5A14", "Right Lightbar": "#FF5A14", "LED Strip": "#E8420A",
    CORNER: "#FF7A1A", TV: "#E8420A", "Retro Lamp": "#FF8C2E", "Cozy Light": "#FF6A1A",
    "Mushroom Lamp": "#FF7F24", "Glowing Sphere": "#D9380C"}),
 "Embers": dict(level=30, c={"Left Lightbar": "#FF4D0A", "Right Lightbar": "#FF4D0A", "LED Strip": "#FF4D0A",
    CORNER: "#FF6A14", TV: "#FF5A0F", "Retro Lamp": "#FF7A1F", "Cozy Light": "#FF5A0F",
    "Mushroom Lamp": "#FF6A14", "Glowing Sphere": "#FF4D0A"}),
 "Neon Nights": dict(level=85, c={"Left Lightbar": "#FF1F8E", "Right Lightbar": "#FF1F8E", "LED Strip": "#8A2BFF",
    CORNER: "#00D8FF", TV: "#6A3BFF", "Retro Lamp": "#FF2E9A", "Cozy Light": "#B32BFF",
    "Mushroom Lamp": "#00C8FF", "Glowing Sphere": "#FF1F8E"}),
 "Horror Night": dict(level=35, c={"Left Lightbar": "#FF1010", "Right Lightbar": "#FF1010", "LED Strip": "#E00008",
    CORNER: "#FF1A00", TV: "#E00000", "Retro Lamp": "#FF2000", "Cozy Light": "#D00010",
    "Mushroom Lamp": "#FF0000", "Glowing Sphere": "#C00010"}),
 "Northern Lights": dict(level=80, c={"Left Lightbar": "#00F5A0", "Right Lightbar": "#00F5A0", "LED Strip": "#00E0C0",
    CORNER: "#8B5CFF", TV: "#22FF88", "Retro Lamp": "#00D4B8", "Cozy Light": "#3B82F6",
    "Mushroom Lamp": "#A26BFF", "Glowing Sphere": "#2EF2A0"}),
 "Rainy Night": dict(level=60, c={"Left Lightbar": "#3A63B8", "Right Lightbar": "#3A63B8", "LED Strip": "#2A4F9E",
    CORNER: "#4F7BD0", TV: "#2E5AAC", "Retro Lamp": "2200K", "Cozy Light": "#5A83D6",
    "Mushroom Lamp": "#3E6CC4", "Glowing Sphere": "#2A54A8"}),
 "Focus": dict(level=100, c={"Left Lightbar": "5000K", "Right Lightbar": "5000K", "LED Strip": "4300K",
    CORNER: "4300K", TV: "4300K", "Retro Lamp": "4300K", "Cozy Light": "4300K",
    "Mushroom Lamp": "4300K", "Glowing Sphere": "4300K"}),
 "Game On": dict(level=85, c={"Left Lightbar": "#2F6BFF", "Right Lightbar": "#2F6BFF", "LED Strip": "#8B3DFF",
    CORNER: "#9B4DFF", TV: "#3A5BFF", "Retro Lamp": "#7A3DFF", "Cozy Light": "#00B8FF",
    "Mushroom Lamp": "#5B4BFF", "Glowing Sphere": "#8B3DFF"}),
 "Pure Cinema": dict(level=14, c={n: "6500K" for n in LUMENS}),
 "Party": dict(level=90, speed=0.75, auto_dynamic=True, c={"Left Lightbar": "#FF2DAA", "Right Lightbar": "#7C3AED",
    "LED Strip": "#00E5FF", CORNER: "#A855F7", TV: "#FF2DAA", "Retro Lamp": "#FF6B00", "Cozy Light": "#FF3D7F",
    "Mushroom Lamp": "#22D3EE", "Glowing Sphere": "#7C3AED"}),
}


def lin(c):
    return ((c + 0.055) / 1.055) ** 2.4 if c > 0.04045 else c / 12.92


def xy(hexc):
    r, g, b = (lin(int(hexc[i:i + 2], 16) / 255) for i in (1, 3, 5))
    X, Y, Z = r * .4124 + g * .3576 + b * .1805, r * .2126 + g * .7152 + b * .0722, r * .0193 + g * .1192 + b * .9505
    return {"x": round(X / (X + Y + Z), 4), "y": round(Y / (X + Y + Z), 4)}


def colour_yield(c):
    """Share of a lamp's full lumens it can give in this colour (white ~1, amber ~0.6, deep blue ~0.12)."""
    if c.endswith("K"):
        return min(1.0, 0.6 + (int(c[:-1]) - 2000) / 5000)
    r, g, b = (lin(int(c[i:i + 2], 16) / 255) for i in (1, 3, 5))
    m = max(r, g, b)
    return max(0.12, (0.2126 * r + 0.7152 * g + 0.0722 * b) / m)


def brightness(spec):
    # light output ~ (bri/100)^2 on the Hue dimming curve; equal output -> bri ~ 1/sqrt(lumens * yield)
    need = {n: 1 / math.sqrt(LUMENS[n] * colour_yield(c)) for n, c in spec["c"].items() if c}
    top = max(need.values())
    return {n: max(1.0, round(spec["level"] * v / top, 1)) for n, v in need.items()}


def main():
    e = [x for x in json.load(open("/home/pi/docker/homeassistant/config/.storage/core.config_entries"))["data"]["entries"] if x["domain"] == "hue"][0]
    key, host = e["data"]["api_key"], e["data"]["host"]
    ctx = ssl._create_unverified_context()

    def api(method, path, body=None):
        req = urllib.request.Request(f"https://{host}/clip/v2/resource/{path}", method=method,
                                     headers={"hue-application-key": key, "Content-Type": "application/json"},
                                     data=json.dumps(body).encode() if body is not None else None)
        try:
            return json.load(urllib.request.urlopen(req, context=ctx))
        except urllib.error.HTTPError as err:
            sys.exit(f"{method} {path}: {err.code} {err.read().decode()[:300]}")

    devices = {d["id"]: d for d in api("GET", "device")["data"]}
    for l in api("GET", "light")["data"]:
        want = devices[l["owner"]["rid"]]["metadata"]["name"]
        fix = {}
        if l["metadata"]["name"] != want:
            fix["metadata"] = {"name": want, "archetype": l["metadata"]["archetype"]}
        if l.get("powerup", {}).get("preset") != "powerfail":
            fix["powerup"] = {"preset": "powerfail"}
        if fix:
            api("PUT", f"light/{l['id']}", fix)
            print("fixed light", want, list(fix))
    lights = {l["metadata"]["name"]: l["id"] for l in api("GET", "light")["data"]}
    zones = {z["metadata"]["name"]: z for z in api("GET", "zone")["data"]}
    for zname, (members, archetype) in ZONES.items():
        children = [{"rid": lights[n], "rtype": "light"} for n in members]
        if zname not in zones:
            api("POST", "zone", {"type": "zone", "metadata": {"name": zname, "archetype": archetype}, "children": children})
            print("created zone", zname)
    room = next(r["id"] for r in api("GET", "room")["data"] if r["metadata"]["name"] == ROOM)
    existing = {s["metadata"]["name"]: s["id"] for s in api("GET", "scene")["data"] if s["group"]["rid"] == room}
    only = sys.argv[1:]
    for name, spec in S.items():
        if only and name not in only:
            continue
        bri = brightness(spec)
        actions = []
        for lname, c in spec["c"].items():
            if not c:
                actions.append({"target": {"rid": lights[lname], "rtype": "light"}, "action": {"on": {"on": False}}})
                continue
            a = {"on": {"on": True}, "dimming": {"brightness": bri[lname]}}
            a.update({"color_temperature": {"mirek": round(1e6 / int(c[:-1]))}} if c.endswith("K") else {"color": {"xy": xy(c)}})
            actions.append({"target": {"rid": lights[lname], "rtype": "light"}, "action": a})
        body = {"actions": actions, "speed": spec.get("speed", 0.5), "auto_dynamic": spec.get("auto_dynamic", False)}
        if spec.get("auto_dynamic"):
            cols = list(dict.fromkeys(c for c in spec["c"].values() if c and not c.endswith("K")))[:9]
            body["palette"] = {"color": [{"color": {"xy": xy(c)}, "dimming": {"brightness": spec["level"]}} for c in cols],
                               "dimming": [], "color_temperature": [], "effects": []}
        else:
            body["palette"] = {"color": [], "dimming": [], "color_temperature": [], "effects": []}
        if name in existing:
            api("PUT", f"scene/{existing[name]}", body)
        else:
            body.update(type="scene", metadata={"name": name}, group={"rid": room, "rtype": "room"})
            api("POST", "scene", body)
        print(f"{name:16}", " ".join(f"{n[:6]}={bri.get(n, 'off')}" for n in spec["c"]))
    if not only:
        for name, sid in existing.items():
            if name not in S:
                api("DELETE", f"scene/{sid}")
                print("deleted scene", name)


main()
