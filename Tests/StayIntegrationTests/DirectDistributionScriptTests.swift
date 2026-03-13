import Foundation
import Testing

@Suite("DirectDistributionScripts")
struct DirectDistributionScriptTests {
    @Test("Build script keeps the direct-distribution bundle identity and icon path")
    func buildScriptContainsExpectedDefaults() throws {
        let script = try scriptContents(named: "build-stay-app.sh")

        #expect(
            script.contains(
                "PRODUCT_BUNDLE_IDENTIFIER=${PRODUCT_BUNDLE_IDENTIFIER:-net.mattclark.stay}"))
        #expect(script.contains("ASSET_CATALOG_SOURCE=\"$ROOT_DIR/AppBundle/Assets.xcassets\""))
        #expect(script.contains("xcrun actool"))
        #expect(script.contains("codesign"))
    }

    @Test("Install script targets the standard Applications folder")
    func installScriptTargetsApplicationsFolder() throws {
        let script = try scriptContents(named: "install-stay-app.sh")

        #expect(script.contains("INSTALL_ROOT=\"${INSTALL_ROOT:-/Applications}\""))
        #expect(script.contains("INSTALL_PATH=\"$INSTALL_ROOT/Stay.app\""))
    }

    @Test("Notarization scripts implement the supported direct-release flow")
    func notarizationScriptsMatchDirectDistributionFlow() throws {
        let storeCredentialsScript = try scriptContents(named: "store-notary-credentials.sh")
        let notarizeScript = try scriptContents(named: "notarize-stay-app.sh")

        #expect(storeCredentialsScript.contains("xcrun notarytool store-credentials"))
        #expect(notarizeScript.contains("\"$ROOT_DIR/Scripts/build-stay-app.sh\""))
        #expect(notarizeScript.contains("/usr/bin/ditto -c -k --keepParent"))
        #expect(notarizeScript.contains("xcrun notarytool submit"))
        #expect(notarizeScript.contains("xcrun stapler staple"))
        #expect(notarizeScript.contains("spctl -a -vv \"$APP_BUNDLE\""))
    }
}

private func scriptContents(named fileName: String) throws -> String {
    let scriptURL = repositoryRoot()
        .appendingPathComponent("Scripts", isDirectory: true)
        .appendingPathComponent(fileName, isDirectory: false)

    return try String(contentsOf: scriptURL, encoding: .utf8)
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
