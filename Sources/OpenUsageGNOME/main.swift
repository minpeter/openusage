import Adwaita

@MainActor
private func runOpenUsage() {
    let application = Application(id: "io.github.minpeter.OpenUsage")
    var controller: DashboardController?

    application.onActivate {
        if let controller {
            controller.present()
            return
        }

        let newController = DashboardController(application: application)
        controller = newController
        newController.present()
        newController.start()
    }
    application.onShutdown {
        controller?.stop()
        controller = nil
    }

    application.run()
}

runOpenUsage()
