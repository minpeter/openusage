#!/usr/bin/python3
from __future__ import annotations

from collections.abc import Iterator

import pyatspi
from gi.repository import GLib


def descendants(node: object) -> Iterator[object]:
    yield node
    for child in node:
        yield from descendants(child)


def application() -> object | None:
    return next(
        (
            child
            for child in pyatspi.Registry.getDesktop(0)
            if "openusage" in (child.name or "").lower()
        ),
        None,
    )


app = application()
if app is None:
    def added(event: object) -> None:
        name = (getattr(getattr(event, "any_data", None), "name", None) or "")
        if "openusage" in name.lower():
            pyatspi.Registry.stop()

    pyatspi.Registry.registerEventListener(added, "object:children-changed:add")
    GLib.timeout_add_seconds(10, pyatspi.Registry.stop)
    pyatspi.Registry.start()
    pyatspi.Registry.deregisterEventListener(added, "object:children-changed:add")
    app = application()

if app is None:
    raise SystemExit("OpenUsage accessibility application was not found")

button = next(
    (
        node
        for node in descendants(app)
        if node.getRole() == pyatspi.ROLE_PUSH_BUTTON
        and (node.name or "").strip() == "JSON"
    ),
    None,
)
if button is None:
    raise SystemExit("JSON export button was not found")
result: list[str] = []


def export_finished(event: object) -> None:
    name = (getattr(getattr(event, "any_data", None), "name", None) or "")
    if name.startswith("Exported") or name.startswith("Could not export"):
        result.append(name)
        pyatspi.Registry.stop()


pyatspi.Registry.registerEventListener(
    export_finished,
    "object:children-changed:add",
)
if not button.queryAction().doAction(0):
    raise SystemExit("JSON export action failed")
GLib.timeout_add_seconds(10, pyatspi.Registry.stop)
pyatspi.Registry.start()
pyatspi.Registry.deregisterEventListener(
    export_finished,
    "object:children-changed:add",
)
if not result:
    result = [
        (node.name or "").strip()
        for node in descendants(app)
        if (node.name or "").startswith(("Exported", "Could not export"))
    ]
if not result:
    raise SystemExit("JSON export completion was not observed")
if result[0].startswith("Could not export"):
    raise SystemExit(result[0])
print(f"json-export-action=passed toast={result[0]}")
