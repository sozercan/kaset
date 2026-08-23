import Foundation
import WebKit

if #available(macOS 14.0, *) {
    var count: UInt32 = 0
    if let methods = class_copyMethodList(WKWebExtension.self, &count) {
        for i in 0 ..< Int(count) {
            let sel = method_getName(methods[i])
            print("WKWebExtension: \(String(cString: sel_getName(sel)))")
        }
        free(methods)
    }
}
