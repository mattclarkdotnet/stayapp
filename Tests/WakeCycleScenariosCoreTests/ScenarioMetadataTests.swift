import Testing
import WakeCycleScenariosCore

@Suite("WakeCycleScenarioMetadata")
struct ScenarioMetadataTests {
    @Test("Finder metadata is stable")
    func finderMetadata() {
        #expect(WakeCycleScenario.finder.appName == "Finder")
        #expect(WakeCycleScenario.finder.bundleID == "com.apple.finder")
        #expect(WakeCycleScenario.finder.candidateBundleIDs == ["com.apple.finder"])
    }

    @Test("TextEdit metadata is stable")
    func appMetadata() {
        #expect(WakeCycleScenario.app.appName == "TextEdit")
        #expect(WakeCycleScenario.app.bundleID == "com.apple.TextEdit")
        #expect(WakeCycleScenario.app.candidateBundleIDs == ["com.apple.TextEdit"])
    }

    @Test("Workspace TextEdit metadata is stable")
    func appWorkspaceMetadata() {
        #expect(WakeCycleScenario.appWorkspace.appName == "TextEdit")
        #expect(WakeCycleScenario.appWorkspace.bundleID == "com.apple.TextEdit")
        #expect(WakeCycleScenario.appWorkspace.candidateBundleIDs == ["com.apple.TextEdit"])
    }

    @Test("FreeCAD metadata includes both known bundle IDs")
    func freecadMetadata() {
        #expect(WakeCycleScenario.freecad.appName == "FreeCAD")
        #expect(WakeCycleScenario.freecad.bundleID == "org.freecad.FreeCAD")
        #expect(
            WakeCycleScenario.freecad.candidateBundleIDs
                == ["org.freecad.FreeCAD", "org.freecadweb.FreeCAD"])
    }

    @Test("KiCad metadata includes stable bundle IDs")
    func kicadMetadata() {
        #expect(WakeCycleScenario.kicad.appName == "KiCad")
        #expect(WakeCycleScenario.kicad.bundleID == "org.kicad.kicad")
        #expect(
            WakeCycleScenario.kicad.candidateBundleIDs
                == ["org.kicad.kicad", "org.kicad.kicad-nightly"])
    }
}
