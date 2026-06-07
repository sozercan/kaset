import Foundation
import Testing

@Suite(.serialized, .tags(.service))
struct ScriptingDefinitionTests {
    @Test("Standard quit command is bound to NSApplication terminate")
    func standardQuitCommandIsBoundToApplicationTerminate() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sdefURL = repositoryRoot.appendingPathComponent("Sources/Kaset/Resources/Kaset.sdef")
        let data = try Data(contentsOf: sdefURL)
        let document = try XMLDocument(data: data)

        let quitCommandNodes = try document.nodes(
            forXPath: "//suite[@name='Standard Suite']/command[@name='quit' and @code='aevtquit']/cocoa[@class='NSQuitCommand']"
        )
        #expect(!quitCommandNodes.isEmpty)

        let terminateBindingNodes = try document.nodes(
            forXPath: "//suite[@name='Standard Suite']/class[@name='application' and @code='capp']/responds-to[@command='quit']/cocoa[@method='terminate:']"
        )
        #expect(!terminateBindingNodes.isEmpty)
    }
}
