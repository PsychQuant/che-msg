import Foundation

/// Path syntax as the OS reads it: by Unicode scalar, not by Character
/// (PsychQuant/che-msg#21). A "/" followed by a combining mark (U+0301,
/// U+200D, U+FE0F, U+034F, …) is one Character, so `String.split(separator:
/// "/")` and `hasPrefix("/")` see no separator there, while the OS does:
/// `/tmp/..` + "/" + U+0301 + `x.md` climbs out of `/tmp`. Components are
/// also compared scalar by scalar, never by Swift's canonical equivalence.
public enum ScalarPath {
    /// Whether `path` begins with the "/" scalar.
    public static func isAbsolute(_ path: String) -> Bool {
        path.unicodeScalars.first == "/"
    }

    /// The components of `path`, split at every "/" scalar. Empty components
    /// (the leading "/", "//") are dropped; each keeps its exact scalars.
    public static func components(of path: String) -> [String] {
        path.unicodeScalars.split(separator: "/").map { String(String.UnicodeScalarView($0)) }
    }

    /// Whether `component` is exactly `..`.
    public static func isParent(_ component: String) -> Bool {
        same(component, "..")
    }

    /// Whether `component` is exactly `.`.
    public static func isCurrent(_ component: String) -> Bool {
        same(component, ".")
    }

    /// Scalar-for-scalar equality.
    public static func same(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }
}
