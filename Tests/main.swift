import Foundation
func check(_ condition: Bool) { precondition(condition) }
let line = [TracePoint(x:0,y:0), TracePoint(x:10,y:0)]
check(TraceGeometry.sample(line, spacing:3).map { $0.x } == [0,3,6,9])
check(TraceGeometry.sample(line, spacing:5).count == 3)
let bend = [TracePoint(x:0,y:0),TracePoint(x:3,y:0),TracePoint(x:3,y:4)]
check(TraceGeometry.length(bend) == 7)
check(TraceGeometry.sample(bend, spacing:2) == [TracePoint(x:0,y:0),TracePoint(x:2,y:0),TracePoint(x:3,y:1),TracePoint(x:3,y:3)])
check(TraceGeometry.sample([line[0],line[0],line[1]], spacing:3).count == 4)
check(TraceGeometry.sample(line, spacing:0).isEmpty)
check(TraceGeometry.sample([], spacing:3).isEmpty)
check(TraceGeometry.sample(line, spacing:14.55).count == 1)
print("8 geometry checks passed")
for spacingUM in [0.5, 1.0, 2.0, 5.0, 10.0] {
    let calibration = 2.91
    let path = [TracePoint(x: 0,y: 0), TracePoint(x: 100,y: 0), TracePoint(x:100,y:100)]
    let samples = TraceGeometry.sample(path, spacing: spacingUM * calibration)
    check(samples.count == Int(floor(200 / (spacingUM * calibration))) + 1)
    for (i,p) in samples.enumerated() {
        let distance = Double(i) * spacingUM * calibration
        let expected = distance <= 100 ? TracePoint(x: distance,y:0) : TracePoint(x:100,y:distance-100)
        check(hypot(p.x-expected.x,p.y-expected.y) < 1e-9)
    }
}
let radius = 100.0
let curve = (0...10000).map { i in TracePoint(x: radius*cos(Double(i)*Double.pi/10000), y:radius*sin(Double(i)*Double.pi/10000)) }
check(abs(TraceGeometry.length(curve)-Double.pi*radius) < 0.00001)
let sampled = TraceGeometry.sample(curve, spacing:2.91)
for (i,p) in sampled.enumerated() {
    let theta = Double(i)*2.91/radius
    check(hypot(p.x-radius*cos(theta),p.y-radius*sin(theta)) < 0.00001)
}
print("Spacing sweep and 10,000-segment curved reference checks passed")
let wobble = (0...100).map { TracePoint(x: Double($0), y: $0 % 2 == 0 ? 1 : -1) }
for strength in 1...3 {
 let result = CenterlineProcessing.process(wobble, strength: strength)
 check(result.first == wobble.first && result.last == wobble.last)
 check(TraceGeometry.length(result) <= TraceGeometry.length(wobble))
 check(result.allSatisfy { $0.y >= -1 && $0.y <= 1 })
 for spacing in [0.5,1,2,5,10] {
  check(TraceGeometry.sample(result, spacing: spacing * 2.91).count == Int(floor(TraceGeometry.length(result)/(spacing*2.91)))+1)
 }
}
check(CenterlineProcessing.process(wobble, strength:0) == wobble)
print("Smoothing endpoint, bounds, reversible raw, length and spacing checks passed")
