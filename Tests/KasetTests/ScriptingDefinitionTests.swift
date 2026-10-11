import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
struct ScriptingDefinitionTests {
    private func loadScriptingDefinition() throws -> XMLDocument {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sdefURL = repositoryRoot.appendingPathComponent("Sources/Kaset/Resources/Kaset.sdef")
        let data = try Data(contentsOf: sdefURL)
        return try XMLDocument(data: data)
    }

    @Test("Standard quit command is bound to NSApplication terminate")
    func standardQuitCommandIsBoundToApplicationTerminate() throws {
        let document = try self.loadScriptingDefinition()

        let quitCommandNodes = try document.nodes(
            forXPath: "//suite[@name='Standard Suite']/command[@name='quit' and @code='aevtquit']/cocoa[@class='NSQuitCommand']"
        )
        #expect(!quitCommandNodes.isEmpty)

        let terminateBindingNodes = try document.nodes(
            forXPath: "//suite[@name='Standard Suite']/class[@name='application' and @code='capp']/responds-to[@command='quit']/cocoa[@method='terminate:']"
        )
        #expect(!terminateBindingNodes.isEmpty)
    }

    @Test("Every scripting command class resolves to an NSScriptCommand subclass")
    func everyCommandClassResolves() throws {
        let document = try self.loadScriptingDefinition()
        let classNames = try document.nodes(forXPath: "//command/cocoa/@class").compactMap(\.stringValue)

        #expect(classNames.contains("KasetPlayVideosCommand"))
        for className in classNames {
            let commandClass: AnyClass? = NSClassFromString(className)
            #expect(commandClass?.isSubclass(of: NSScriptCommand.self) == true, "\(className) does not resolve")
        }
    }

    @Test("Command codes are unique")
    func commandCodesAreUnique() throws {
        let document = try self.loadScriptingDefinition()
        let codes = try document.nodes(forXPath: "//command/@code").compactMap(\.stringValue)

        #expect(codes.count == Set(codes).count)
    }

    @Test("Queue-by-ID commands take a list of video IDs and their optional parameters")
    func queueByIdCommandsAreDeclared() throws {
        let document = try self.loadScriptingDefinition()
        let suite = "//suite[@name='Kaset Suite']"

        let playVideos = try document.nodes(
            forXPath: "\(suite)/command[@name='play videos' and @code='Kastpvds']"
        )
        #expect(try !playVideos.isEmpty && !document.nodes(forXPath:
            "\(suite)/command[@name='play videos']/cocoa[@class='KasetPlayVideosCommand']").isEmpty)
        #expect(try !document.nodes(forXPath:
            "\(suite)/command[@name='play videos']/direct-parameter/type[@type='text' and @list='yes']").isEmpty)
        #expect(try !document.nodes(forXPath:
            "\(suite)/command[@name='play videos']/parameter[@name='starting at' and @type='integer' and @optional='yes']/cocoa[@key='startingAt']").isEmpty)

        #expect(try !document.nodes(forXPath:
            "\(suite)/command[@name='add to queue' and @code='Kastaddq']/cocoa[@class='KasetAddToQueueCommand']").isEmpty)
        #expect(try !document.nodes(forXPath:
            "\(suite)/command[@name='add to queue']/direct-parameter/type[@type='text' and @list='yes']").isEmpty)
        #expect(try !document.nodes(forXPath:
            "\(suite)/command[@name='add to queue']/parameter[@name='next' and @type='boolean' and @optional='yes']/cocoa[@key='next']").isEmpty)

        #expect(try !document.nodes(forXPath:
            "\(suite)/command[@name='remove from queue' and @code='Kastremq']/cocoa[@class='KasetRemoveFromQueueCommand']").isEmpty)
        #expect(try !document.nodes(forXPath:
            "\(suite)/command[@name='remove from queue']/direct-parameter[@type='text']").isEmpty)
    }
}
