#!/usr/bin/python3
from __future__ import annotations

import sys
from collections.abc import Iterator

import pyatspi
from gi.repository import GLib


def descendants(node: object) -> Iterator[object]:
    yield node
    for child in node:
        yield from descendants(child)


def find_application() -> object | None:
    desktop = pyatspi.Registry.getDesktop(0)
    return next(
        (
            child
            for child in desktop
            if "openusage" in (child.name or "").strip().lower()
        ),
        None,
    )


application = find_application()
if application is None:
    def application_added(event: object) -> None:
        name = (getattr(getattr(event, "any_data", None), "name", None) or "")
        if "openusage" in name.strip().lower():
            pyatspi.Registry.stop()

    pyatspi.Registry.registerEventListener(
        application_added,
        "object:children-changed:add",
    )
    GLib.timeout_add_seconds(10, pyatspi.Registry.stop)
    pyatspi.Registry.start()
    pyatspi.Registry.deregisterEventListener(
        application_added,
        "object:children-changed:add",
    )
    application = find_application()

if application is None:
    available = [
        (child.name or "").strip()
        for child in pyatspi.Registry.getDesktop(0)
    ]
    raise SystemExit(
        f"OpenUsage accessibility application was not found; available={available}"
    )

nodes = list(descendants(application))
interactive_roles = {
    pyatspi.ROLE_CHECK_BOX,
    pyatspi.ROLE_COMBO_BOX,
    pyatspi.ROLE_PAGE_TAB,
    pyatspi.ROLE_PUSH_BUTTON,
    pyatspi.ROLE_SPIN_BUTTON,
    pyatspi.ROLE_TOGGLE_BUTTON,
}
unnamed = [
    node
    for node in nodes
    if node.getRole() in interactive_roles and not (node.name or "").strip()
]
progress = [node for node in nodes if node.getRole() == pyatspi.ROLE_PROGRESS_BAR]
unnamed_progress = [node for node in progress if not (node.name or "").strip()]
names = {(node.name or "").strip() for node in nodes}
required = {"Overview", "Providers", "History", "Settings", "Refresh usage"}
missing = sorted(required - names)

print(f"accessible_nodes={len(nodes)}")
print(f"interactive_nodes={sum(node.getRole() in interactive_roles for node in nodes)}")
print(f"progress_bars={len(progress)}")

if unnamed:
    print(f"unnamed_interactive={len(unnamed)}", file=sys.stderr)
if unnamed_progress:
    print(f"unnamed_progress={len(unnamed_progress)}", file=sys.stderr)
if missing:
    print(f"missing_required={','.join(missing)}", file=sys.stderr)
if unnamed or unnamed_progress or missing:
    raise SystemExit(1)
