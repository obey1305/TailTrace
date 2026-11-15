import Foundation

struct TracePoint: Equatable {
    var x: Double
    var y: Double
}
struct TraceGeometry {
    static func length(_ points: [TracePoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }
    static func sample(_ points: [TracePoint], spacing: Double) -> [TracePoint] {
        guard let first = points.first, spacing.isFinite, spacing > 0 else { return [] }
        let total = length(points)
        guard total.isFinite, total / spacing < 100_000 else { return [] }
        var result = [first]
        var cumulative = 0.0
        var index = 1
        for (a, b) in zip(points, points.dropFirst()) {
            let segment = hypot(b.x-a.x, b.y-a.y)
            guard segment > 0 else { continue }
            let end = cumulative + segment
            while Double(index) * spacing <= end {
                let t = (Double(index) * spacing - cumulative) / segment
                result.append(TracePoint(x: a.x + t*(b.x-a.x), y: a.y + t*(b.y-a.y)))
                index += 1
            }
            cumulative = end
        }
        return result
    }
}

// Convex local averaging on an arc-length-resampled polyline. Endpoints stay fixed.
struct CenterlineProcessing {
    static func process(_ raw: [TracePoint], strength: Int) -> [TracePoint] {
        guard strength > 0, raw.count > 2 else { return raw }
        let length = TraceGeometry.length(raw)
        guard length.isFinite, length > 0 else { return raw }
        let step = max(0.5, length / 20000)
        var points = TraceGeometry.sample(raw, spacing: step)
        if let last = raw.last, points.last != last { points.append(last) }
        guard points.count > 2 else { return raw }
        for _ in 0..<min(6, strength * 2) {
            let old = points
            for i in 1..<(old.count - 1) {
                points[i] = TracePoint(x: old[i-1].x * 0.25 + old[i].x * 0.5 + old[i+1].x * 0.25,
                                       y: old[i-1].y * 0.25 + old[i].y * 0.5 + old[i+1].y * 0.25)
            }
        }
        return points
    }
}
