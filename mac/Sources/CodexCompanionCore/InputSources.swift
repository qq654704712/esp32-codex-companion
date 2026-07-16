#if os(macOS)
import Carbon
import Foundation

public struct InputSourceDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let localizedName: String

    public init(id: String, localizedName: String) {
        self.id = id
        self.localizedName = localizedName
    }
}

public enum InputSourceError: Error, Equatable {
    case sourceNotFound
    case selectionFailed(OSStatus)
}

public struct InputSourceCatalog {
    public init() {}

    public func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return propertyString(source, key: kTISPropertyInputSourceID)
    }

    public func installed() -> [InputSourceDescriptor] {
        let properties = [kTISPropertyInputSourceIsEnabled: true] as CFDictionary
        guard let list = TISCreateInputSourceList(properties, false)?.takeRetainedValue() else {
            return []
        }
        return (list as NSArray).compactMap { item in
            let source = item as! TISInputSource
            guard let id = propertyString(source, key: kTISPropertyInputSourceID) else {
                return nil
            }
            let name = propertyString(source, key: kTISPropertyLocalizedName) ?? id
            return InputSourceDescriptor(id: id, localizedName: name)
        }
    }

    public func select(id: String) throws {
        let properties = [kTISPropertyInputSourceID: id] as CFDictionary
        guard let list = TISCreateInputSourceList(properties, false)?.takeRetainedValue(),
              CFArrayGetCount(list) > 0 else {
            throw InputSourceError.sourceNotFound
        }
        let source = unsafeBitCast(CFArrayGetValueAtIndex(list, 0), to: TISInputSource.self)
        let status = TISSelectInputSource(source)
        guard status == noErr else { throw InputSourceError.selectionFailed(status) }
    }

    private func propertyString(_ source: TISInputSource, key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
#endif
