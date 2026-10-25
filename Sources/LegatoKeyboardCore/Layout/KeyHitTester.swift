import Foundation

public struct KeyPoint: Sendable, Equatable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct KeyRect: Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

public struct KeyFrame: Sendable, Equatable {
    public let id: String
    public let row: Int
    public let rect: KeyRect
    public init(id: String, row: Int, rect: KeyRect) { self.id = id; self.row = row; self.rect = rect }
}

/// Maps a touch to the nearest key: first the nearest row, then the nearest key in it, so gaps and the
/// area beyond the edges still hit a key.
public struct KeyHitTester: Sendable {
    private let rows: [(minY: Double, maxY: Double, frames: [KeyFrame])]

    public init(frames: [KeyFrame]) {
        rows = Dictionary(grouping: frames, by: \.row).sorted { $0.key < $1.key }.map { _, fs in
            (fs.map(\.rect.y).min()!, fs.map(\.rect.maxY).max()!, fs.sorted { $0.rect.x < $1.rect.x })
        }
    }

    private static func distance(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        v < lo ? lo - v : v > hi ? v - hi : 0
    }

    public func key(at p: KeyPoint) -> String? {
        guard let row = rows.min(by: {
            Self.distance(p.y, $0.minY, $0.maxY) < Self.distance(p.y, $1.minY, $1.maxY)
        }) else { return nil }
        return row.frames.min(by: {
            Self.distance(p.x, $0.rect.x, $0.rect.maxX) < Self.distance(p.x, $1.rect.x, $1.rect.maxX)
        })?.id
    }
}
