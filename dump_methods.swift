import Foundation
import WebKit

if #available(macOS 14.0, *) {
    var count2: UInt32 = 0
    if let methods2 = class_copyMethodList(WKWebExtensionContext.self, &count2) {
        for i in 0 ..< Int(count2) {
            let sel = method_getName(methods2[i])
            print("WKWebExtensionContext: \(String(cString: sel_getName(sel)))")
        }
        free(methods2)
    }
}
