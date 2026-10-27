#!/usr/bin/env python3
"""Generate the wizard's step lists from docs/WIZARD_FLOW.md.

The checklists define the order of the wizard and WIZARD_FLOW.md maps every
checklist line to a step. To keep the app and the document from drifting
apart, the app does not hard-code its steps: this script reads the tables in
WIZARD_FLOW.md and writes one JSON file per profile, which the app embeds.

Run it after every change to WIZARD_FLOW.md and commit the result:

    python3 tools/flowgen/generate_flows.py

Output: src/WOSetup.Core/Flows/wo7.flow.json and wo6.flow.json.
A unit test (FlowTests) checks that the generated files load and are valid.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
DOC = ROOT / "docs" / "WIZARD_FLOW.md"
OUT = ROOT / "src" / "WOSetup.Core" / "Flows"

# Steps the app runs itself. Everything else is shown with its instructions
# and the command to use; automating those checks comes in a later milestone.
ENGINE = {
    "WO7-03.2": {"phase": "PreUpdate", "audit": False},
    "WO6-03.2": {"phase": "PreUpdate", "audit": False},
    "WO7-09.3": {"phase": "PostInstall", "audit": False},
    "WO6-08.4": {"phase": "PostInstall", "audit": False},
    "WO7-09.2a": {"phase": "PostInstall", "audit": True},
    "WO6-08.3a": {"phase": "PostInstall", "audit": True},
    # Final audit: both phases, PostInstall first.
    "WO7-10.3e": {"phase": "Both", "audit": True},
    "WO6-10.5b": {"phase": "Both", "audit": True},
}

# Steps that are only finished once the machine has really restarted.
REBOOT_STEPS = {"WO7-03.2a", "WO7-09.5", "WO6-03.2a", "WO6-08.7", "WO6-10.1"}

# Steps the app completes by itself when it starts.
AUTO_DONE = {"W-00.1", "W-00.4"}

# Steps that open the options page.
OPTIONS_STEPS = {"WO7-09.2", "WO6-08.3"}

SECTION_RE = re.compile(r"^### (WO[67]) §(\d+) (.+)$")
ROW_RE = re.compile(r"^\| (W-\d\d(?:\.\d+)?|WO[67]-\d\d\.\d+[a-z]?) \|(.*)\|\s*$")


def split_row(rest: str) -> list[str]:
    # Cells are separated by "|", except escaped "\|" inside code.
    cells = re.split(r"(?<!\\)\|", rest)
    return [c.replace("\\|", "|").strip() for c in cells]


def clean(text: str) -> str:
    # Bold markers are noise in a plain-text UI; code backticks are kept so
    # commands stay recognisable.
    return text.replace("**", "").strip()


def kind_of(step_id: str, type_label: str) -> str:
    t = type_label.replace("**", "").strip()
    if step_id in ENGINE and ENGINE[step_id]["audit"]:
        return "check"
    if t.startswith("A"):
        return "automated"
    if t.startswith("C"):
        return "check"
    return "manual"


def roles_of(title: str, uses: str) -> list[str]:
    text = f"{title} {uses}"
    if "Production only" in text or title.startswith("Production PC:"):
        return ["Production"]
    if "Display role only" in text:
        return ["Display"]
    return ["Display", "Production"]


def parse():
    lines = DOC.read_text(encoding="utf-8").splitlines()
    wizard_start = []
    wizard_end = {}   # profile -> Finish step (each profile table ends with its own W-99 row)
    profiles = {"WO7": [], "WO6": []}
    current = None  # (profile, section dict)
    for line in lines:
        m = SECTION_RE.match(line)
        if m:
            profile, num, title = m.group(1), int(m.group(2)), m.group(3)
            title = re.sub(r"\s*\(.*?\)\s*$", "", title).strip()   # drop "(guidance only)" etc.
            title = title.replace("✈", "").replace("🌐", "").strip()
            sec = {"id": f"{profile}-{num:02d}", "number": num, "title": title, "steps": []}
            profiles[profile].append(sec)
            current = (profile, sec)
            continue
        m = ROW_RE.match(line)
        if not m:
            continue
        step_id = m.group(1)
        cells = split_row(m.group(2))
        if len(cells) != 4:
            sys.exit(f"Unexpected table row for {step_id}: {cells}")
        title, type_label, uses, reboot = cells
        step = {
            "id": step_id,
            "title": clean(title),
            "kind": kind_of(step_id, type_label),
            "typeLabel": clean(type_label),
            "details": clean(uses) if uses not in ("—", "") else "",
            "reboot": clean(reboot),
            "roles": roles_of(title, uses),
            "preWindows": "pre-Win" in type_label,
            "needsInternet": "🌐" in type_label,
            "mustBeOffline": "✈" in type_label,
            "confirm": "🔒" in type_label,
            "rebootStep": step_id in REBOOT_STEPS,
            "autoDone": step_id in AUTO_DONE,
            "optionsStep": step_id in OPTIONS_STEPS,
            "uncertain": "[Uncertain" in f"{title} {uses}",
        }
        if step_id in ENGINE:
            step["engine"] = ENGINE[step_id]
        if step_id.startswith("W-00"):
            wizard_start.append(step)
        elif step_id == "W-99":
            wizard_end[current[0]] = step
        else:
            if current is None:
                sys.exit(f"Row {step_id} outside a section")
            current[1]["steps"].append(step)
    return wizard_start, wizard_end, profiles


def resolve_references(wo6_sections, wo7_sections):
    # "As WO7-03.4" in the WO6 table: show the WO7 text instead of a pointer.
    wo7 = {s["id"]: s for sec in wo7_sections for s in sec["steps"]}
    for sec in wo6_sections:
        for s in sec["steps"]:
            m = re.search(r"\bas (WO7-\d\d\.\d+[a-z]?)", s["details"], flags=re.I)
            if m and m.group(1) in wo7 and wo7[m.group(1)]["details"]:
                same = "Same as " + m.group(1) + ": " + wo7[m.group(1)]["details"]
                rest = s["details"].replace(m.group(0), "").strip(" .;")
                s["details"] = same if not rest else same + "\n\n" + s["details"]


def add_wo6_winutil(wo6_sections, wo7_sections):
    # WIZARD_FLOW gives WO6 §6 as "same tick lists as WO7 §6" with two
    # wording differences from the WO6 checklist.
    sec6 = next(s for s in wo6_sections if s["number"] == 6)
    wo7_6 = next(s for s in wo7_sections if s["number"] == 6)
    for s in wo7_6["steps"]:
        c = json.loads(json.dumps(s))
        c["id"] = s["id"].replace("WO7-", "WO6-")
        if c["id"] == "WO6-06.3":
            c["title"] = ("Skip: Edge removal (keeps WebView2), IPv6 disable (the script unbinds it per adapter), "
                          "UTC time, O&O ShutUp10++, \"Disable all updates\" (PostInstall does the same, after all updates are in)")
        if c["id"] == "WO6-06.5":
            c["title"] = "Do NOT click either Ultimate Performance button (PostInstall makes its own \"WATCHOUT 6\" plan)"
        sec6["steps"].append(c)


def main():
    start, end, profiles = parse()
    # The WO6 Finish row only says "As WO7".
    if end["WO6"]["details"].strip() == "As WO7":
        end["WO6"]["details"] = end["WO7"]["details"]
    add_wo6_winutil(profiles["WO6"], profiles["WO7"])
    resolve_references(profiles["WO6"], profiles["WO7"])
    meta = {
        "WO7": {"checklistDate": "2026-10-14", "title": "WATCHOUT 7", "script": "WO7-Setup.ps1"},
        "WO6": {"checklistDate": "2026-10-23", "title": "WATCHOUT 6", "script": "WO6-Setup.ps1"},
    }
    OUT.mkdir(parents=True, exist_ok=True)
    for profile, sections in profiles.items():
        flow = {
            "schemaVersion": 1,
            "profile": profile,
            "title": meta[profile]["title"],
            "script": meta[profile]["script"],
            "checklistDate": meta[profile]["checklistDate"],
            "generatedFrom": "docs/WIZARD_FLOW.md",
            "sections": [{"id": "W-00", "number": 0, "title": "Wizard start", "steps": start}]
                        # Sections without steps (Maintenance) are information pages
                        # in WIZARD_FLOW, not steps.
                        + [sec for sec in sections if sec["steps"]]
                        + [{"id": "W-99", "number": 99, "title": "Finish", "steps": [end[profile]]}],
        }
        path = OUT / f"{profile.lower()}.flow.json"
        path.write_text(json.dumps(flow, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        count = sum(len(s["steps"]) for s in flow["sections"])
        print(f"{path.relative_to(ROOT)}: {len(flow['sections'])} sections, {count} steps")


if __name__ == "__main__":
    main()
