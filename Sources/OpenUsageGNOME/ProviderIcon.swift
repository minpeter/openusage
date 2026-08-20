import Adwaita
import OpenUsagePricingResources

@MainActor
enum ProviderIcon {
    private static var registeredDirectory: String?

    static func make(
        providerID: String,
        displayName: String,
        size: Int = 28
    ) -> Widget {
        guard
            let iconURL = LinuxPricingResources.providerIconURL(for: providerID),
            let display = gdk_display_get_default()
        else {
            return Avatar(size: size, text: displayName, showInitials: true)
        }

        let directory = iconURL.deletingLastPathComponent().path
        let theme = gtk_icon_theme_get_for_display(display)
        if registeredDirectory != directory {
            gtk_icon_theme_add_search_path(theme, directory)
            registeredDirectory = directory
        }

        guard let paintable = gtk_icon_theme_lookup_icon(
            theme,
            "\(providerID)-symbolic",
            nil,
            Int32(size),
            1,
            GTK_TEXT_DIR_NONE,
            GTK_ICON_LOOKUP_FORCE_SYMBOLIC
        ) else {
            return Avatar(size: size, text: displayName, showInitials: true)
        }

        let image = Image()
        gtk_image_set_from_paintable(
            OpaquePointer(image.widgetPointer),
            paintable
        )
        g_object_unref(UnsafeMutableRawPointer(paintable))

        image.pixelSize = size
        image.setSizeRequest(width: size, height: size)
        image.valign = GTK_ALIGN_CENTER
        image.addCSSClass("ou-provider-mark")
        image.setAccessibleLabel("\(displayName) provider")
        return image
    }
}
