@_exported import OpenUsageCore
import Foundation
import OpenUsagePricingResources

public extension ModelPricing {
    static func bundled() throws -> ModelPricing {
        func data(_ name: String) throws -> Data {
            do {
                return try LinuxPricingResources.data(named: name)
            } catch {
                throw PricingResourceError.missing(name)
            }
        }

        return try bundled(
            supplementData: data("pricing_supplement"),
            primaryData: data("pricing_litellm_snapshot"),
            secondaryData: data("pricing_models_dev_snapshot"))
    }
}
