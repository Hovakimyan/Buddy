import Testing

// Shared by BuddyMacTests and BuddyPhoneTests.
private let container = "iCloud.com.sergeyhovakimyan.buddy"

@Suite struct CloudEntitlementTests {
    private func values(_ containers: Any?, _ services: Any?) -> (String) -> Any? {
        { key in
            switch key {
            case CloudEntitlement.containerKey: containers
            case CloudEntitlement.servicesKey: services
            default: nil
            }
        }
    }

    @Test func grantedWhenContainerAndCloudKitServiceArePresent() {
        #expect(CloudEntitlement.isGranted(container: container, value: values([container], ["CloudKit"])))
        #expect(CloudEntitlement.isGranted(container: container, value: values(["iCloud.other", container], ["CloudKit", "CloudDocuments"])))
    }

    @Test func notGrantedWithoutAnyEntitlement() {
        #expect(!CloudEntitlement.isGranted(container: container, value: { _ in nil }))
    }

    @Test func notGrantedForAnotherContainerOrWithoutTheCloudKitService() {
        #expect(!CloudEntitlement.isGranted(container: container, value: values(["iCloud.other"], ["CloudKit"])))
        #expect(!CloudEntitlement.isGranted(container: container, value: values([container], ["CloudDocuments"])))
        #expect(!CloudEntitlement.isGranted(container: container, value: values([container], nil)))
        #expect(!CloudEntitlement.isGranted(container: container, value: values(nil, ["CloudKit"])))
        #expect(!CloudEntitlement.isGranted(container: container, value: values([], ["CloudKit"])))
    }

    @Test func malformedEntitlementValuesAreNotGranted() {
        #expect(!CloudEntitlement.isGranted(container: container, value: values(container, "CloudKit")))  // strings, not arrays
        #expect(!CloudEntitlement.isGranted(container: container, value: values([1, 2], [true])))
    }

    @Test func onlyATrueInfoPlistFlagCounts() {
        #expect(CloudEntitlement.isFlagged(info: [CloudEntitlement.infoPlistKey: true]))
        #expect(!CloudEntitlement.isFlagged(info: [CloudEntitlement.infoPlistKey: false]))
        #expect(!CloudEntitlement.isFlagged(info: [CloudEntitlement.infoPlistKey: "true"]))  // a string is not the flag
        #expect(!CloudEntitlement.isFlagged(info: [CloudEntitlement.infoPlistKey: 1]))
        #expect(!CloudEntitlement.isFlagged(info: [:]))
        #expect(!CloudEntitlement.isFlagged(info: nil))
    }

    @Test func theTestProcessHasNoCloudKitEntitlement() {
        // The unit tests (and the default ad-hoc build) are not signed with iCloud: the live check says no.
        #expect(!CloudEntitlement.currentProcessHasCloudKit)
    }
}
