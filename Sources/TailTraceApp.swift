import SwiftUI
import PencilKit
import UniformTypeIdentifiers
import ImageIO

@main
struct TailTraceApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @AppStorage("traceThickness") private var traceThickness = 8.0
    @AppStorage("traceOpacity") private var traceOpacity = 0.45
    @AppStorage("smoothingStrength") private var smoothingStrength = 1
    @State private var settingsVisible = false
    @State private var exportSucceeded = false
    @State private var fitToken = 0
    @AppStorage("lastSpacing") private var rememberedSpacing = 5.0
    @AppStorage("lastCalibration") private var rememberedCalibration = 2.91
    @AppStorage("lastColor") private var rememberedColor = 0
    private func choose(_ identity: TailIdentity) {
        activeIdentity = identity.id; identityConfirmed = true
        reviewStatus = "Present"; rememberedColor = identity.paletteIndex; erasing = false
    }
    private var colorBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(identities) { identity in
                    Button { choose(identity) } label: {
                        VStack(spacing: 3) {
                            Circle().fill(Color(uiColor: identity.color)).frame(width: 42, height: 42)
                                .overlay(Circle().stroke(activeIdentity == identity.id ? Color.primary : .clear, lineWidth: 3).padding(-4))
                            Text(identity.name).font(.caption)
                        }
                    }.accessibilityLabel("Select " + identity.name)
                }
                Button {
                    let identity = TailIdentity(name: "Tail \(identities.count + 1)", paletteIndex: identities.count % 8)
                    identities.append(identity); choose(identity)
                } label: { Image(systemName: "plus.circle.fill").font(.largeTitle) }.accessibilityLabel("New tail identity")
            }.padding()
        }
    }
    @State private var showPrevious = false
    @State private var reviewStatus = "Not Reviewed"
    @State private var identityConfirmed = false
    @State private var frameNotes = ""
    private func saveReview() {
        guard frames.indices.contains(frameIndex), !activeIdentity.isEmpty else { return }
        frames[frameIndex].reviews[activeIdentity] = IdentityReview(status: reviewStatus, confirmed: identityConfirmed)
        frames[frameIndex].notes = frameNotes
    }
    private func loadReview() {
        guard frames.indices.contains(frameIndex) else { return }
        let review = frames[frameIndex].reviews[activeIdentity] ?? IdentityReview()
        reviewStatus = review.status; identityConfirmed = review.confirmed; frameNotes = frames[frameIndex].notes
    }
    private var previousDrawing: PKDrawing? {
        guard showPrevious, frameIndex > 0 else { return nil }
        return try? PKDrawing(data: frames[frameIndex - 1].drawing)
    }
    private func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private var stackCSV: String {
        var rows = ["Frame_ID,Image_Name,Tail_ID,Tail_Name,Color,Point_ID,X_px,Y_px,X_um,Y_um,Distance_um,Calibration_px_per_um,Spacing_um,Status,Smoothing_Method,Smoothing_Strength"]
        guard valid else { return rows[0] + "\r\n" }
        for frame in frames {
            guard let d = try? PKDrawing(data: frame.drawing) else { continue }
            for stroke in d.strokes {
                guard let id = frame.labels[key(stroke)] else { continue }
                let identity = identities.first { $0.id == id }
                let review = frame.reviews[id] ?? IdentityReview()
                let path = stroke.path.interpolatedPoints(by: .distance(0.25)).map { p -> TracePoint in
                    let q = p.location.applying(stroke.transform); return TracePoint(x: q.x, y: q.y)
                }
                for (n, point) in TraceGeometry.sample(CenterlineProcessing.process(path, strength: smoothingStrength), spacing: spacing * calibration).enumerated() {
                    let values = [point.x, point.y, point.x / calibration, point.y / calibration, Double(n) * spacing, calibration, spacing].map { String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), $0) }
                    rows.append(([quoted(frame.id), quoted(frame.name), quoted(id), quoted(identity?.name ?? id), quoted(identity?.hex ?? "#00FFFF"), String(n + 1)] + values + [quoted(review.status), quoted(smoothingStrength == 0 ? "raw" : "arc_resample_convex_average"), String(smoothingStrength)]).joined(separator: ","))
                }
            }
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }
    private var statusCSV: String {
        var rows = ["Frame_ID,Image_Name,Tail_ID,Tail_Name,Color,Status,Has_Annotation,Chronology_Confirmed,Notes"]
        for frame in frames {
            let strokes = (try? PKDrawing(data: frame.drawing).strokes) ?? []
            let present = Set(strokes.compactMap { frame.labels[key($0)] })
            for identity in identities {
                let review = frame.reviews[identity.id] ?? IdentityReview()
                rows.append([quoted(frame.id), quoted(frame.name), quoted(identity.id), quoted(identity.name), quoted(identity.hex), quoted(review.status), present.contains(identity.id) ? "true" : "false", chronologyConfirmed ? "true" : "false", quoted(frame.notes)].joined(separator: ","))
            }
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }
    @State private var frames: [StackFrame] = []
    @State private var frameIndex = 0
    @State private var identities: [TailIdentity] = []
    @State private var activeIdentity = ""
    @State private var chronologyConfirmed = false
    @State private var stackImporting = false
    @State private var ordering = false
    private var activeColor: UIColor { identities.first { $0.id == activeIdentity }?.color ?? .systemCyan }
    private func captureFrame() {
        guard frames.indices.contains(frameIndex) else { return }
        frames[frameIndex].drawing = drawing.dataRepresentation()
        frames[frameIndex].labels = labels
    }
    private func selectFrame(_ index: Int) {
        guard frames.indices.contains(index) else { return }
        saveReview(); captureFrame()
        do {
            let frame = frames[index]
            let data = try Data(contentsOf: URL(fileURLWithPath: frame.path))
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
            let restored = try PKDrawing(data: frame.drawing)
            frameIndex = index; image = UIImage(cgImage: cg); originalImageData = data
            imageName = frame.name; drawing = restored; labels = frame.labels; recolor()
            selectedTail = ""; history = []; future = []; loadReview()
        } catch { self.error = error.localizedDescription }
    }
    private func recolor() {
        drawing = PKDrawing(strokes: drawing.strokes.map { stroke in
            var copy = stroke
            if let identity = identities.first(where: { $0.id == labels[key(stroke)] }) {
                copy.ink = PKInk(.pen, color: identity.hidden ? .clear : identity.color)
            }
            return copy
        })
    }
    @State private var labels: [String: String] = [:]
    @State private var selectedTail = ""
    @State private var tailName = ""
    @State private var navigate = false
    @State private var replacementID: String?
    @State private var originalImageData: Data?
    private func key(_ stroke: PKStroke) -> String { String(stroke.path.creationDate.timeIntervalSinceReferenceDate) }
    private func tailID(_ index: Int) -> String {
        let k = key(drawing.strokes[index])
        return labels[k] ?? "Tail_" + k
    }
    private func changed(_ next: PKDrawing) {
        guard next.dataRepresentation() != drawing.dataRepresentation() else { return }
        history.append(EditSnapshot(drawing: drawing, labels: labels)); future.removeAll()
        let added = next.strokes.filter { labels[key($0)] == nil }
        if !added.isEmpty {
            guard !activeIdentity.isEmpty else { error = "Select an identity and explicitly confirm its assignment before drawing."; return }
            let existing = Set(drawing.strokes.compactMap { labels[key($0)] })
            if existing.contains(activeIdentity) && replacementID == nil {
                let retained = next.strokes.filter { labels[key($0)] != activeIdentity }
                for stroke in added { labels[key(stroke)] = activeIdentity }
                drawing = PKDrawing(strokes: retained); recolor(); captureFrame(); return
            }
            for stroke in added { labels[key(stroke)] = replacementID ?? activeIdentity }
            replacementID = nil
        }
        drawing = next
        recolor(); saveReview(); captureFrame()
    }
    @State private var image: UIImage?
    @State private var imageName = "image"
    @State private var showTable = false
    @State private var exporting = false
    @State private var document = ExportDocument()
    @State private var exportType: UTType = .commaSeparatedText
    @State private var openingProject = false
    @State private var showTrace = true
    @State private var showPoints = true
    @State private var erasing = false
    @State private var markerSize = 6.0
    private struct EditSnapshot {
        var drawing: PKDrawing
        var labels: [String: String]
    }
    @State private var canvasRevision = UUID()
    @State private var drawing = PKDrawing()
    @State private var history: [EditSnapshot] = []
    @State private var future: [EditSnapshot] = []
    @State private var importing = false
    @State private var spacing = 5.0
    @State private var calibration = 2.91
    @State private var error: String?
    @State private var fingerDrawing = false

    private var traces: [[TracePoint]] {
        drawing.strokes.map { stroke in
            // Dense evaluation follows PencilKit's interpolated curve, including its transform.
            CenterlineProcessing.process(stroke.path.interpolatedPoints(by: .distance(0.25)).map {
                let q = $0.location.applying(stroke.transform)
                return TracePoint(x: Double(q.x), y: Double(q.y))
            }, strength: smoothingStrength)
        }
    }
    private var valid: Bool { spacing.isFinite && spacing > 0 && calibration.isFinite && calibration > 0 }
    private var markers: [[TracePoint]] { valid ? traces.map { TraceGeometry.sample($0, spacing: spacing * calibration) } : [] }
    private var csv: String {
        var lines = ["Image_Name,Tail_ID,Point_ID,X_px,Y_px,X_um,Y_um,Distance_um,Calibration_px_per_um"]
        for (tail, points) in markers.enumerated() {
            for (index, point) in points.enumerated() {
                let name = "\"" + imageName.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                let numbers = [point.x, point.y, point.x / calibration, point.y / calibration, Double(index) * spacing, calibration].map { String(format: "%.10g", locale: Locale(identifier: "en_US_POSIX"), $0) }
                lines.append(([name, "\"" + tailID(tail).replacingOccurrences(of: "\"", with: "\"\"") + "\"", String(index + 1)] + numbers).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
    private func export(_ data: Data, type: UTType) {
        document = ExportDocument(data: data); exportType = type; exporting = true
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                colorBar
                HStack {
                    Text("Thickness \(Int(traceThickness)) px").font(.caption)
                    Slider(value: $traceThickness, in: 1...24).frame(maxWidth: 180)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Trace smoothing").font(.caption).bold()
                        Picker("Trace smoothing", selection: $smoothingStrength) {
                            Text("Off").tag(0); Text("Low").tag(1); Text("Medium").tag(2); Text("High").tag(3)
                        }.pickerStyle(.segmented)
                        Text(["Off: original trace, without smoothing.", "Low: gentle smoothing of small hand wobbles.", "Medium: stronger smoothing; may soften real bends.", "High: strongest smoothing; may remove fine curvature."][max(0, min(3, smoothingStrength))])
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: 380)
                }.padding(.horizontal)

                if let image {
                    TraceCanvas(image: image, drawing: $drawing, markers: markers.enumerated().map { i, points in identities.first { $0.id == labels[key(drawing.strokes[i])] }?.hidden == true ? [] : points }, fingerDrawing: fingerDrawing, showTrace: showTrace, showPoints: showPoints, markerSize: markerSize, erasing: erasing, navigate: navigate, inkColor: activeColor, previousDrawing: previousDrawing, fitToken: fitToken, resetRevision: canvasRevision, processedPaths: traces, thickness: traceThickness, opacity: traceOpacity, onFrame: { direction in
                        let next = frameIndex + direction
                        guard frames.indices.contains(next) else { return false }
                        selectFrame(next); return true
                    }, onSelect: { stroke in
                        selectedTail = key(stroke)
                        if let identity = identities.first(where: { $0.id == labels[key(stroke)] }) { choose(identity) }
                    }) { next in changed(next) }
                } else {
                    Spacer()
                    Button("Import Stack", systemImage: "photo.stack") { openingProject = false; stackImporting = true }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Text("TIFF · PNG · JPEG").foregroundStyle(.secondary).padding()
                    Spacer()
                }
                HStack(spacing: 20) {
                    Button("Previous", systemImage: "chevron.left") { selectFrame(frameIndex - 1) }.disabled(frameIndex <= 0)
                    Spacer()
                    VStack {
                        Text(frames.isEmpty ? "No stack" : "Frame \(frameIndex + 1) / \(frames.count)").font(.headline)
                        Text("\(drawing.strokes.count) traces · \(markers.reduce(0) { $0 + $1.count }) points").font(.caption)
                    }
                    Spacer()
                    Button("Next", systemImage: "chevron.right") { selectFrame(frameIndex + 1) }.disabled(frameIndex + 1 >= frames.count)
                }.buttonStyle(.bordered).controlSize(.large).padding()
                if exportSucceeded { Text("CSV exported successfully").font(.caption).foregroundStyle(.green) }
            }
            .navigationTitle("TailTrace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Import Stack", systemImage: "photo.stack") { openingProject = false; stackImporting = true }
                    Button("Undo", systemImage: "arrow.uturn.backward") {
                        if let prior = history.popLast() {
                            future.append(EditSnapshot(drawing: drawing, labels: labels))
                            drawing = prior.drawing; labels = prior.labels
                            canvasRevision = UUID()
                            captureFrame()
                        }
                    }.disabled(history.isEmpty)
                    Button(erasing ? "Done Erasing" : "Erase", systemImage: "eraser") { erasing.toggle() }.tint(erasing ? .red : .accentColor)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Fit Image", systemImage: "arrow.up.left.and.arrow.down.right") { fitToken += 1 }
                    Button("Settings", systemImage: "gearshape") { settingsVisible = true }
                    Button("Export CSV", systemImage: "square.and.arrow.up") {
                        saveReview(); captureFrame(); exportSucceeded = false
                        export(Data(stackCSV.utf8), type: .commaSeparatedText)
                    }.buttonStyle(.borderedProminent).disabled(frames.isEmpty || !valid)
                }
            }
            .sheet(isPresented: $settingsVisible) {
                NavigationStack {
                    Form {
                        Section("Measurement") {
                            Text("Opacity \(Int(traceOpacity * 100))%")
                            Slider(value: $traceOpacity, in: 0.1...1)
                            Text("Smoothing: Off keeps the original trace. Low gently reduces wobbles. Medium and High progressively smooth more and can remove real bends. Smoothing changes point coordinates and measured length; the original trace is preserved.").font(.caption)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Point spacing")
                                    Spacer()
                                    TextField("Spacing", value: $spacing, format: .number)
                                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                                        .accessibilityLabel("Point spacing in micrometers")
                                    Text("µm").foregroundStyle(.secondary)
                                }
                                Text("Distance between generated points along the traced curve.").font(.caption).foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Image calibration")
                                    Spacer()
                                    TextField("Calibration", value: $calibration, format: .number)
                                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                                        .accessibilityLabel("Image calibration in pixels per micrometer")
                                    Text("pixels/µm").foregroundStyle(.secondary)
                                }
                                Text("Original-image pixels per micrometer. Use the calibration for your microscopy images.").font(.caption).foregroundStyle(.secondary)
                            }
                            Toggle("Show points", isOn: $showPoints)
                            Slider(value: $markerSize, in: 2...20) { Text("Marker size") }
                        }
                        Section("Tracing") {
                            Toggle("Finger drawing", isOn: $fingerDrawing)
                            Text("Swipe left or right with one finger at Fit Image zoom to glide through frames. Pinch to zoom; use two fingers to pan. Glide is disabled during Finger drawing.").font(.caption)
                            Text("Selecting a color assigns that identity manually. Color does not establish biological identity.").font(.caption)
                        }
                    }.navigationTitle("Settings").toolbar { Button("Done") { settingsVisible = false } }
                }
            }
            .onAppear { spacing = rememberedSpacing; calibration = rememberedCalibration }
            .onChange(of: spacing) { _, value in if value > 0 && value.isFinite { rememberedSpacing = value } }
            .onChange(of: calibration) { _, value in if value > 0 && value.isFinite { rememberedCalibration = value } }
            .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: "TailTrace." + (exportType.preferredFilenameExtension ?? "data")) { result in
                if case .failure(let failure) = result { error = failure.localizedDescription } else { exportSucceeded = exportType == .commaSeparatedText }
            }
            .sheet(isPresented: $showTable) {
                NavigationStack {
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading) {
                            Text("Origin: image top-left (0, 0); x right, y down").font(.headline)
                            Grid(alignment: .leading, horizontalSpacing: 18) {
                                GridRow {
                                    ForEach(["Tail", "Point", "X px", "Y px", "X µm", "Y µm", "Distance µm"], id: \.self) { Text($0).bold() }
                                }
                                ForEach(Array(markers.enumerated()), id: \.offset) { tail, points in
                                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                                        GridRow {
                                            Text(tailID(tail))
                                            Text("\(index + 1)")
                                            Text(point.x, format: .number.precision(.fractionLength(3)))
                                            Text(point.y, format: .number.precision(.fractionLength(3)))
                                            Text(point.x / calibration, format: .number.precision(.fractionLength(3)))
                                            Text(point.y / calibration, format: .number.precision(.fractionLength(3)))
                                            Text(Double(index) * spacing, format: .number.precision(.fractionLength(3)))
                                        }
                                    }
                                }
                            }.font(.system(.caption, design: .monospaced))
                        }.padding()
                    }.navigationTitle("Point coordinates").toolbar { Button("Done") { showTable = false } }
                }
            }
            .fileImporter(isPresented: $stackImporting, allowedContentTypes: openingProject ? [.json] : [.tiff, .png, .jpeg], allowsMultipleSelection: !openingProject) { result in
                do {
                    if openingProject {

                    guard let url = try result.get().first else { return }; let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let payload = try Data(contentsOf: url)
                    if let archive = try? JSONDecoder().decode(StackArchive.self, from: payload) {
                        let restored = try archive.frames.map { try $0.restore() }
                        frames = restored; identities = archive.identities
                        activeIdentity = identities.first?.id ?? ""; chronologyConfirmed = archive.chronologyConfirmed
                        spacing = archive.spacing; calibration = archive.calibration
                        smoothingStrength = archive.smoothing ?? 0; traceThickness = archive.thickness ?? 8; traceOpacity = archive.opacity ?? 0.45
                        frameIndex = -1; selectFrame(0); return
                    }
                    frames = []
                    let project = try JSONDecoder().decode(SavedProject.self, from: payload)
                    guard let source = CGImageSourceCreateWithData(project.image as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil), project.spacing.isFinite, project.spacing > 0, project.calibration.isFinite, project.calibration > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    let restoredDrawing = try PKDrawing(data: project.drawing)
                    image = UIImage(cgImage: cg, scale: 1, orientation: .up); originalImageData = project.image; imageName = project.name; drawing = restoredDrawing
                    labels = project.labels ?? [:]; selectedTail = ""; replacementID = nil
                    spacing = project.spacing; calibration = project.calibration; history = []; future = []

                        return
                    }

                    let urls = try result.get().sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    let imported = try urls.map { try StackFrame.importFile($0) }
                    frames = imported; frameIndex = -1; chronologyConfirmed = false
                    if identities.isEmpty {
                        identities = (0..<3).map { TailIdentity(name: "Tail \($0 + 1)", paletteIndex: $0) }
                    }
                    choose(identities.first { $0.paletteIndex == rememberedColor } ?? identities[0])
                    selectFrame(0)
                } catch { self.error = error.localizedDescription }
            }
            .sheet(isPresented: $ordering) {
                NavigationStack {
                    List {
                        ForEach(frames) { frame in Text(frame.name) }
                        .onMove { from, to in
                            saveReview(); captureFrame(); let id = frames[frameIndex].id
                            frames.move(fromOffsets: from, toOffset: to)
                            frameIndex = frames.firstIndex { $0.id == id } ?? 0
                            chronologyConfirmed = false
                        }
                    }.environment(\.editMode, .constant(.active))
                    .navigationTitle("Frame order")
                    .toolbar { Button("Done") { ordering = false } }
                }
            }
            .alert("Import failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

struct TraceCanvas: UIViewRepresentable {
    let image: UIImage
    @Binding var drawing: PKDrawing
    let markers: [[TracePoint]]
    let fingerDrawing: Bool
    let showTrace: Bool
    let showPoints: Bool
    let markerSize: Double
    let erasing: Bool
    let navigate: Bool
    let inkColor: UIColor
    let previousDrawing: PKDrawing?
    let fitToken: Int
    let resetRevision: UUID
    let processedPaths: [[TracePoint]]
    let thickness: Double
    let opacity: Double
    let onFrame: (Int) -> Bool
    let onSelect: (PKStroke) -> Void
    let onChange: (PKDrawing) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> CanvasHost {
        let host = CanvasHost()
        host.canvas.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectTrace(_:)))
        tap.cancelsTouchesInView = false
        host.selectionTap = tap
        host.canvas.addGestureRecognizer(tap)
        return host
    }
    static func dismantleUIView(_ host: CanvasHost, coordinator: Coordinator) {
        coordinator.invalidate()
        host.canvas.delegate = nil
    }
    func updateUIView(_ host: CanvasHost, context: Context) {
        context.coordinator.parent = self
        if let revision = host.resetRevision, revision != resetRevision {
            context.coordinator.cancelPendingCommit()
            host.resetDrawingSurface(delegate: context.coordinator)
        }
        host.resetRevision = resetRevision
        if host.erasing != erasing || host.inkColor != inkColor {
            host.inkColor = inkColor
            host.erasing = erasing
            host.canvas.tool = erasing ? PKEraserTool(.vector) : PKInkingTool(.pen, color: inkColor, width: 1.5)
        }
        if host.fitToken != fitToken { host.fitToken = fitToken; host.requestFit() }
        host.onFrame = onFrame
        host.glideEnabled = !fingerDrawing && !navigate
        host.previous.drawing = previousDrawing
        host.canvas.isUserInteractionEnabled = !navigate
        host.scroll.panGestureRecognizer.minimumNumberOfTouches = navigate ? 1 : 2
        host.canvas.alpha = showTrace ? opacity : 0.01
        host.comfort.isHidden = !showTrace
        host.comfort.paths = processedPaths
        host.comfort.colors = drawing.strokes.map { $0.ink.color }
        host.comfort.thickness = thickness
        host.comfort.opacity = opacity
        host.comfort.setNeedsDisplay()
        host.overlay.isHidden = !showPoints
        host.overlay.markerSize = markerSize
        host.configure(image: image, drawing: drawing, markers: markers, fingerDrawing: fingerDrawing)
    }
    class Coordinator: NSObject, PKCanvasViewDelegate {
        @objc func selectTrace(_ gesture: UITapGestureRecognizer) {
            guard let canvas = gesture.view as? PKCanvasView else { return }
            let point = gesture.location(in: canvas)
            var nearest: PKStroke?
            var distance = 12.0
            for stroke in canvas.drawing.strokes {
                for p in stroke.path.interpolatedPoints(by: .distance(2)) {
                    let q = p.location.applying(stroke.transform)
                    let d = hypot(q.x - point.x, q.y - point.y)
                    if d < distance { distance = d; nearest = stroke }
                }
            }
            if let nearest { parent.onSelect(nearest) }
        }
        var isDrawing = false
        func cancelPendingCommit() { pendingUserEdit = false; isDrawing = false; commitWork?.cancel() }
        private var valid = true
        func invalidate() { valid = false; pendingUserEdit = false; commitWork?.cancel() }
        private var pendingUserEdit = false
        private var commitWork: DispatchWorkItem?
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            commitWork?.cancel(); isDrawing = true; pendingUserEdit = true
        }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isDrawing = false; scheduleCommit(canvasView)
        }
        private func scheduleCommit(_ canvasView: PKCanvasView) {
            guard pendingUserEdit, !isDrawing else { return }
            commitWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak canvasView] in
                guard let self, let canvasView, self.valid, self.pendingUserEdit, !self.isDrawing else { return }
                self.pendingUserEdit = false
                guard canvasView.drawing.dataRepresentation() != self.parent.drawing.dataRepresentation() else { return }
                self.parent.onChange(canvasView.drawing)
            }
            commitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
        }
        var parent: TraceCanvas
        init(_ parent: TraceCanvas) { self.parent = parent }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Final PencilKit data may arrive after tool-end. Only an actual
            // tool session can schedule a commit; programmatic Undo cannot.
            scheduleCommit(canvasView)
        }

    }
}

final class MarkerView: UIView {
    var zoom = 1.0
    var markerSize = 6.0 { didSet { setNeedsDisplay() } }
    var points: [[TracePoint]] = [] { didSet { setNeedsDisplay() } }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.clear(rect)
        for (tail, points) in points.enumerated() {
            for (index, p) in points.enumerated() {
                let size = markerSize / max(0.001, zoom)
                let rect = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
                context.setStrokeColor(UIColor.black.cgColor)
                context.setLineWidth(1.2 / max(0.001, zoom))
                context.setFillColor(UIColor.systemYellow.cgColor); context.fillEllipse(in: rect); context.strokeEllipse(in: rect)
                let label = "\(tail + 1).\(index + 1)" as NSString
                label.draw(at: CGPoint(x: p.x + 4 / max(0.001, zoom), y: p.y - 8 / max(0.001, zoom)), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 10 / max(0.001, zoom)), .foregroundColor: UIColor.systemYellow, .strokeColor: UIColor.black, .strokeWidth: -2])
            }
        }
    }
}
final class CanvasHost: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onFrame: ((Int) -> Bool)?
    var glideEnabled = true
    private var transitioning = false
    private lazy var framePan = UIPanGestureRecognizer(target: self, action: #selector(glide(_:)))
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === framePan else { return true }
        let v = framePan.velocity(in: self)
        return glideEnabled && !transitioning && scroll.zoomScale <= scroll.minimumZoomScale * 1.02 && abs(v.x) > abs(v.y) * 1.5
    }
    @objc private func glide(_ gesture: UIPanGestureRecognizer) {
        let dx = gesture.translation(in: self).x
        switch gesture.state {
        case .changed:
            scroll.transform = CGAffineTransform(translationX: dx * 0.75, y: 0)
        case .ended:
            let velocity = gesture.velocity(in: self).x
            let advance = abs(dx) > bounds.width * 0.18 || abs(velocity) > 650
            let direction = dx < 0 ? 1 : -1
            if advance {
                let old = scroll.snapshotView(afterScreenUpdates: false)
                old?.frame = scroll.frame
                if let old { addSubview(old) }
                scroll.transform = .identity
                if onFrame?(direction) == true {
                    transitioning = true
                    scroll.transform = CGAffineTransform(translationX: CGFloat(direction) * bounds.width, y: 0)
                    DispatchQueue.main.async {
                        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                            self.scroll.transform = .identity
                            old?.transform = CGAffineTransform(translationX: -CGFloat(direction) * self.bounds.width, y: 0)
                        } completion: { _ in old?.removeFromSuperview(); self.transitioning = false }
                    }
                } else {
                    old?.removeFromSuperview()
                    scroll.transform = CGAffineTransform(translationX: dx * 0.75, y: 0)
                    UIView.animate(withDuration: 0.22) { self.scroll.transform = .identity }
                }
            } else { UIView.animate(withDuration: 0.22) { self.scroll.transform = .identity } }
        case .cancelled, .failed:
            UIView.animate(withDuration: 0.22) { self.scroll.transform = .identity }
        default: break
        }
    }
    var fitToken = 0
    func requestFit() { needsFit = true; setNeedsLayout() }
    var inkColor = UIColor.systemCyan
    var erasing = false
    let scroll = UIScrollView()
    let content = UIView()
    let photo = UIImageView()
    var canvas = PKCanvasView()
    var resetRevision: UUID?
    var selectionTap: UITapGestureRecognizer?
    func resetDrawingSurface(delegate: PKCanvasViewDelegate) {
        let old = canvas
        old.delegate = nil
        old.undoManager?.removeAllActions()
        let replacement = PKCanvasView(frame: old.frame)
        replacement.isOpaque = false
        replacement.backgroundColor = .clear
        replacement.isScrollEnabled = false
        replacement.tool = old.tool
        replacement.drawingPolicy = old.drawingPolicy
        replacement.delegate = delegate
        if let selectionTap { replacement.addGestureRecognizer(selectionTap) }
        old.removeFromSuperview()
        content.insertSubview(replacement, belowSubview: comfort)
        canvas = replacement
    }
    let overlay = MarkerView()
    let previous = PreviousTraceView()
    let comfort = ComfortTraceView()
    private var currentImage: UIImage?
    private var needsFit = true
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        framePan.delegate = self
        framePan.maximumNumberOfTouches = 1
        framePan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(framePan)
        addSubview(scroll); scroll.addSubview(content)
        content.addSubview(photo); content.addSubview(previous); content.addSubview(canvas); content.addSubview(comfort); content.addSubview(overlay)
        scroll.delegate = self
        scroll.maximumZoomScale = 16
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        canvas.isOpaque = false; canvas.backgroundColor = .clear
        canvas.isScrollEnabled = false
        canvas.tool = PKInkingTool(.pen, color: .systemCyan, width: 1.5)
        overlay.isUserInteractionEnabled = false; overlay.backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func configure(image: UIImage, drawing: PKDrawing, markers: [[TracePoint]], fingerDrawing: Bool) {
        if currentImage !== image {
            let sameSize = currentImage?.size == image.size
            let priorZoom = scroll.zoomScale
            let priorOffset = scroll.contentOffset
            currentImage = image; scroll.zoomScale = 1
            content.frame = CGRect(origin: .zero, size: image.size)
            photo.frame = content.bounds; previous.frame = content.bounds; comfort.frame = content.bounds; canvas.frame = content.bounds; overlay.frame = content.bounds
            photo.image = image; scroll.contentSize = image.size; needsFit = !sameSize
            if sameSize { scroll.zoomScale = priorZoom; scroll.contentOffset = priorOffset }
        }
        if canvas.drawing.dataRepresentation() != drawing.dataRepresentation() {
            let delegate = canvas.delegate
            canvas.delegate = nil
            canvas.drawing = drawing
            canvas.undoManager?.removeAllActions()
            canvas.delegate = delegate
        }
        let policy: PKCanvasViewDrawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
        overlay.points = markers
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews(); scroll.frame = bounds
        if needsFit, let image = currentImage, bounds.width > 0, bounds.height > 0 {
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            scroll.minimumZoomScale = min(fit, 1); scroll.zoomScale = fit
            needsFit = false
        }
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { comfort.zoom = scrollView.zoomScale; comfort.setNeedsDisplay(); overlay.zoom = scrollView.zoomScale; overlay.setNeedsDisplay() }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
}

struct SavedProject: Codable {
    let image: Data
    let name: String
    let drawing: Data
    let spacing: Double
    let calibration: Double
    var labels: [String: String]? = nil
}
struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct TailIdentity: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var paletteIndex: Int
    var hidden = false
    var hex: String { ["#FF3B30", "#007AFF", "#34C759", "#FF9500", "#AF52DE", "#FF2D55", "#32ADE6", "#FFCC00"][max(0, min(7, paletteIndex))] }
    static let names = ["Red", "Blue", "Green", "Orange", "Purple", "Pink", "Cyan", "Yellow"]
    var color: UIColor { [UIColor.systemRed, .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemCyan, .systemYellow][max(0, min(7, paletteIndex))] }
}
struct StackFrame: Identifiable {
    var id = UUID().uuidString
    var name: String
    var path: String
    var width: Int
    var height: Int
    var drawing = PKDrawing().dataRepresentation()
    var labels: [String: String] = [:]
    var reviews: [String: IdentityReview] = [:]
    var notes = ""
    static func importFile(_ url: URL) throws -> StackFrame {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { throw CocoaError(.fileReadCorruptFile) }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Frames")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        try FileManager.default.copyItem(at: url, to: target)
        return StackFrame(name: url.lastPathComponent, path: target.path, width: w, height: h)
    }
}
struct ArchivedFrame: Codable {
    var id: String
    var name: String
    var data: Data
    var width: Int
    var height: Int
    var drawing: Data
    var labels: [String: String]
    var reviews: [String: IdentityReview]? = nil
    var notes: String? = nil
    init(frame: StackFrame) throws {
        id = frame.id; name = frame.name; data = try Data(contentsOf: URL(fileURLWithPath: frame.path))
        width = frame.width; height = frame.height; drawing = frame.drawing; labels = frame.labels; reviews = frame.reviews; notes = frame.notes
    }
    func restore() throws -> StackFrame {
        _ = try PKDrawing(data: drawing)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        var frame = try StackFrame.importFile(url)
        try? FileManager.default.removeItem(at: url)
        frame.id = id; frame.name = name; frame.drawing = drawing; frame.labels = labels; frame.reviews = reviews ?? [:]; frame.notes = notes ?? ""
        return frame
    }
}
struct StackArchive: Codable {
    var frames: [ArchivedFrame]
    var identities: [TailIdentity]
    var chronologyConfirmed: Bool
    var spacing: Double
    var calibration: Double
    var smoothing: Int? = nil
    var thickness: Double? = nil
    var opacity: Double? = nil
}

struct IdentityReview: Codable {
    var status = "Not Reviewed"
    var confirmed = false
}
final class PreviousTraceView: UIView {
    var drawing: PKDrawing? { didSet { setNeedsDisplay() } }
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let drawing else { return }
        context.setStrokeColor(UIColor.systemOrange.withAlphaComponent(0.4).cgColor)
        context.setLineWidth(1.5); context.setLineDash(phase: 0, lengths: [6, 4])
        for stroke in drawing.strokes {
            let points = stroke.path.interpolatedPoints(by: .distance(1)).map { $0.location.applying(stroke.transform) }
            guard let first = points.first else { continue }
            context.beginPath(); context.move(to: first)
            for point in points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        }
    }
}

final class ComfortTraceView: UIView {
    var paths: [[TracePoint]] = []
    var colors: [UIColor] = []
    var thickness = 8.0
    var opacity = 0.45
    var zoom = 1.0
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        c.clear(rect)
        c.setLineCap(.round); c.setLineJoin(.round)
        for (i, points) in paths.enumerated() {
            guard let first = points.first, colors.indices.contains(i) else { continue }
            let path = CGMutablePath(); path.move(to: CGPoint(x: first.x, y: first.y))
            for p in points.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
            c.addPath(path); c.setStrokeColor(colors[i].withAlphaComponent(colors[i].cgColor.alpha * opacity).cgColor)
            c.setLineWidth(thickness / max(0.001, zoom)); c.strokePath()
            c.addPath(path); c.setStrokeColor(colors[i].cgColor); c.setLineWidth(0.8 / max(0.001, zoom)); c.strokePath()
        }
    }
}
