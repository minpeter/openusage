# Linux Screen-Share Privacy

The macOS menu-bar privacy feature cannot be implemented faithfully on GNOME
Wayland. OpenUsage therefore exposes the setting as unavailable instead of
claiming protection that the compositor cannot enforce.

## Verified API Boundary

The XDG ScreenCast portal is request-scoped: an application can create its own
capture session, choose sources, start that session, and open its PipeWire
remote. Version 6 exposes no method, property, or signal that reveals whether a
different application is sharing the screen:

- https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html
- https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.impl.portal.ScreenCast.html

GNOME Shell 50.1 was also inspected directly in a private Wayland session:

```text
interface org.gnome.Mutter.ScreenCast {
  methods:
    CreateSession(in a{sv} properties, out o session_path);
  signals:
  properties:
    readonly i Version = 4;
}
```

The manager has no `ListSessions`, capture-active property, or observer signal.
Sessions created through it are owned by the requesting capture client.

GTK 4 and libadwaita do not expose a surface flag that excludes a window, tray
indicator, or selected widget from compositor capture. The Wayland
`content-type-v1` protocol is a content hint, not capture protection, while the
image-copy-capture protocols grant a capture client access to its own selected
sources rather than notifying unrelated clients.

## Product Behavior

- Settings does not show Hide From Screen Share. The control is a macOS
  menu-bar feature, and GNOME/Wayland has no equivalent capture-exclusion API.
- OpenUsage does not poll private GNOME Shell state or infer capture from
  PipeWire processes; either approach would be incomplete and produce false
  security claims.
- If GNOME or the XDG portal later ships a public global capture-state signal or
  capture-exclusion protocol, that API is the integration point for a working
  Linux control.
