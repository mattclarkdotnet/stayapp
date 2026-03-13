import Foundation
import Testing

@Suite("BundleMetadata")
struct BundleMetadataTests {
    @Test("Info.plist defines the expected Stay app identity")
    func infoPlistContainsExpectedBundleMetadata() throws {
        let plistURL = repositoryRoot()
            .appendingPathComponent("AppBundle", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)

        let data = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )

        #expect(plist["CFBundleIdentifier"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER)")
        #expect(plist["CFBundleExecutable"] as? String == "Stay")
        #expect(plist["CFBundleName"] as? String == "Stay")
        #expect(plist["CFBundleDisplayName"] as? String == "Stay")
        #expect(plist["CFBundlePackageType"] as? String == "APPL")
        #expect(plist["CFBundleIconName"] as? String == "AppIcon")
        #expect(plist["LSApplicationCategoryType"] as? String == "public.app-category.utilities")
        #expect(plist["LSMinimumSystemVersion"] as? String == "26.0")
        #expect(plist["LSUIElement"] as? Bool == true)
        #expect(plist["NSPrincipalClass"] as? String == "NSApplication")
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
