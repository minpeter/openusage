import Adwaita
import Foundation
import OpenUsageLinuxCore

// MARK: - Onboarding and loading

extension OverviewView {
    func rebuildOnboarding(isRefreshing: Bool) {
        while let child = spinnerBox.firstChild {
            spinnerBox.remove(child)
        }

        if isRefreshing, let spinner = Spinner() {
            spinner.setSizeRequest(width: 32, height: 32)
            spinnerBox.append(spinner)
            statusPage.title = "Reading Local Credentials"
            statusPage.description = "Checking the Claude and Codex sign-ins on this account."
        } else {
            statusPage.title = "Welcome to OpenUsage"
            statusPage.description = "Check every AI account, quota, and cost without opening "
                + "provider websites. Sign in with Claude Code or Codex on this machine, "
                + "then refresh."
            let refresh = Button(label: "Refresh Now", onClicked: { [weak self] in self?.onRefresh() })
            refresh.addCSSClass(.suggestedAction)
            refresh.addCSSClass(.pill)
            refresh.halign = GTK_ALIGN_CENTER
            refresh.setAccessibleLabel("Refresh provider usage")
            spinnerBox.append(refresh)
        }

        statusPage.child = spinnerBox
        content.append(statusPage)
    }
}
