#!/usr/bin/env python3
"""Generate every app's design values from design/tokens.json.

    python3 scripts/gen-design-tokens.py          # write the files
    python3 scripts/gen-design-tokens.py --check  # fail if any is out of date (CI)

Writes:
  frontend/lib/design/tokens.g.dart                    Flutter (desktop, web)
  android-native/tv/src/main/res/values/pb_tokens.xml  Android TV app and Launcher
  design/tokens.css                                    previews and docs

Both apps read only these generated values, so a colour or size changes in one
place and the TV, the Launcher and desktop stay the same.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "design" / "tokens.json"
DART = ROOT / "frontend" / "lib" / "design" / "tokens.g.dart"
XML = ROOT / "android-native" / "tv" / "src" / "main" / "res" / "values" / "pb_tokens.xml"
CSS = ROOT / "design" / "tokens.css"

HEADER = "Generated from design/tokens.json by scripts/gen-design-tokens.py. Do not edit."


def argb(hex_value: str) -> str:
    """#RRGGBB or #AARRGGBB -> AARRGGBB."""
    h = hex_value.lstrip("#").upper()
    return h if len(h) == 8 else "FF" + h


def snake(name: str) -> str:
    out = ""
    for c in name:
        out += ("_" + c.lower()) if c.isupper() else c
    return out


def kebab(name: str) -> str:
    return snake(name).replace("_", "-")


def css_color(hex_value: str) -> str:
    h = argb(hex_value)
    a, rgb = int(h[:2], 16), h[2:]
    return f"#{rgb}" if a == 255 else f"#{rgb}{h[:2]}"


def dart(t: dict) -> str:
    lines = [f"// {HEADER}", "// ignore_for_file: constant_identifier_names", "",
             "import 'package:flutter/painting.dart';", "",
             "/// PeanutButter's colours (see design/tokens.json for what each is for).",
             "abstract final class PbColors {"]
    for name, c in t["color"].items():
        lines.append(f"  /// {c['note']}")
        lines.append(f"  static const Color {name} = Color(0x{argb(c['value'])});")
    lines += ["}", "", "/// Font families. Bundled with the app.", "abstract final class PbFonts {"]
    for name, f in t["font"].items():
        lines.append(f"  static const String {name} = '{f['family']}';")
    lines += ["}", "", "/// Desktop type scale (logical pixels).", "abstract final class PbType {"]
    for name, s in t["type"].items():
        fam = "PbFonts." + s["font"]
        lines.append(f"  /// {s['note']}")
        lines.append(
            f"  static const TextStyle {name} = TextStyle(fontFamily: {fam}, fontSize: {s['desktop']}, "
            f"fontWeight: FontWeight.w{s['weight']}, height: {s['line']}, letterSpacing: {s['tracking']});"
        )
    lines += ["}", "", "/// TV type scale, for the same names on a 10-foot screen.", "abstract final class PbTypeTv {"]
    for name, s in t["type"].items():
        fam = "PbFonts." + s["font"]
        lines.append(
            f"  static const TextStyle {name} = TextStyle(fontFamily: {fam}, fontSize: {s['tv']}, "
            f"fontWeight: FontWeight.w{s['weight']}, height: {s['line']}, letterSpacing: {s['tracking']});"
        )
    lines += ["}", "", "abstract final class PbSpace {"]
    for name, v in t["space"].items():
        lines.append(f"  static const double {name} = {float(v)};")
    lines += ["}", "", "abstract final class PbRadius {"]
    for name, v in t["radius"].items():
        lines.append(f"  static const double {name} = {float(v)};")
    lines += ["}", "", "abstract final class PbSize {"]
    for name, v in t["size"].items():
        lines.append(f"  static const double {name} = {float(v)};")
    lines += ["}", "", "/// Animation durations.", "abstract final class PbMotion {"]
    for name, v in t["motion"].items():
        lines.append(f"  static const Duration {name} = Duration(milliseconds: {v});")
    lines += ["}", ""]
    return "\n".join(lines)


def xml(t: dict) -> str:
    lines = ['<?xml version="1.0" encoding="utf-8"?>', f"<!-- {HEADER} -->", "<resources>"]
    for name, c in t["color"].items():
        lines.append(f'    <!-- {c["note"]} -->')
        lines.append(f'    <color name="pbt_{snake(name)}">#{argb(c["value"])}</color>')
    for name, s in t["type"].items():
        lines.append(f'    <dimen name="pbt_type_{snake(name)}">{s["tv"]}sp</dimen>')
    for name, v in t["space"].items():
        lines.append(f'    <dimen name="pbt_space_{snake(name)}">{v}dp</dimen>')
    for name, v in t["radius"].items():
        lines.append(f'    <dimen name="pbt_radius_{snake(name)}">{v}dp</dimen>')
    for name, v in t["size"].items():
        if name == "focusScaleTv":
            lines.append(f'    <item name="pbt_focus_scale" format="float" type="dimen">{v}</item>')
        else:
            lines.append(f'    <dimen name="pbt_size_{snake(name)}">{v}dp</dimen>')
    for name, v in t["motion"].items():
        lines.append(f'    <integer name="pbt_motion_{snake(name)}">{v}</integer>')
    lines.append("</resources>")
    return "\n".join(lines) + "\n"


def css(t: dict) -> str:
    lines = [f"/* {HEADER} */", ":root {"]
    for name, c in t["color"].items():
        lines.append(f"  --pb-{kebab(name)}: {css_color(c['value'])};")
    for name, f in t["font"].items():
        lines.append(f"  --pb-font-{name}: \"{f['family']}\", {f['fallback']};")
    for name, s in t["type"].items():
        lines.append(f"  --pb-type-{name}: {s['desktop']}px;")
        lines.append(f"  --pb-type-{name}-tv: {s['tv']}px;")
    for group in ("space", "radius", "size"):
        for name, v in t[group].items():
            unit = "" if name == "focusScaleTv" else "px"
            lines.append(f"  --pb-{group}-{kebab(name)}: {v}{unit};")
    for name, v in t["motion"].items():
        lines.append(f"  --pb-motion-{name}: {v}ms;")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main() -> int:
    tokens = json.loads(SRC.read_text())
    outputs = {DART: dart(tokens), XML: xml(tokens), CSS: css(tokens)}
    if "--check" in sys.argv:
        stale = [p for p, text in outputs.items() if not p.exists() or p.read_text() != text]
        for p in stale:
            print(f"out of date: {p.relative_to(ROOT)} (run scripts/gen-design-tokens.py)")
        return 1 if stale else 0
    for path, text in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        print(f"wrote {path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
