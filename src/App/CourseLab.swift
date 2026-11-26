import SwiftUI

enum LabAsset {
    static let logs = ["Warm baseline", "Cold revision", "Idle closure"]
    static func url(_ name: String, _ ext: String) throws -> URL {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "CourseLab") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}

private extension Lesson {
    var labTask: String {
        switch id {
        case "engine": return "Open Warm baseline. Compare the first sample with 2 s. Record which inputs changed as RPM increased."
        case "files", "baseline": return "Open the practice tune. Compare This tune and Difference, then save a working copy. Open Warm baseline and identify one quantity that changes with time."
        case "units": return "In Warm baseline at 2 s, subtract the barometric reading from MAP. Explain the negative gauge pressure in your notes."
        case "tables": return "In the fuel worksheet find 2,000 RPM at 50 kPa. Read the cell and both neighbours along the RPM axis. Estimate the value at 2,500 RPM on that row."
        case "fuel": return "Compare the fuel and lambda target worksheets at the same coordinates. Record their different units and the information you would need to predict injector pulse width."
        case "lambda": return "Scrub Warm baseline to 2 s. Record measured minus target lambda. Switch to Cold revision at the same time and compare the coolant readings."
        case "spark": return "Read the ignition worksheet at 2,000 RPM and 50 kPa. In Warm baseline at 2 s, reconcile base angle, temperature trim and final angle."
        case "control": return "Step through Idle closure. Find the first sample at the actuator limit. Write down its time, actual RPM and target error."
        case "edit": return "On the fuel worksheet, select 2,000 RPM at 50 kPa. Set it to 63. Switch to Difference, record the signed change, then Undo and verify zero."
        case "interpolate": return "Select the entire 40 kPa row of the fuel worksheet. Interpolate horizontally between 1,000 and 3,000 RPM. Check the 1,500 RPM cell against 25, then undo."
        case "diff": return "Set the 2,000 RPM / 50 kPa fuel cell to 63. Switch between This tune, Compared and Difference. Record all three values and their sign convention."
        case "capture": return "Open Idle closure. Find the first zero-throttle sample and the lowest RPM. Record both timestamps and the time between them."
        case "quality": return "Step between the second and third samples of Idle closure. Calculate the gap. Record one event that could go unseen in that interval."
        case "diagnose": return "Compare Warm baseline and Cold revision at 2 s and 7 s. Match speed and load, then identify the condition that prevents a clean comparison."
        case "limits": return "Inspect the channels in Warm baseline. Inventory the evidence available to evaluate oil-pressure protection and identify what is missing."
        case "handoff": return "Save your practice revision. Write a handoff naming the reference, changed cell, timestamp, observed effect and unresolved condition."
        default: return "Build candidate B by setting the fuel cell at 2,000 RPM / 50 kPa to 63. Check Difference, then compare both logs at 4 s. Write a release decision using the actual readings."
        }
    }

    var firstLog: String {
        ["control", "capture", "quality"].contains(id) ? "Idle closure" : "Warm baseline"
    }
}

struct CourseLab: View {
    let lesson: Lesson
    let worksheet: AppModel
    @EnvironmentObject var ecu: EcuManager
    @EnvironmentObject var live: LiveEngine
    @EnvironmentObject var model: AppModel
    @AppStorage("course.useECU") private var useECU = false
    @State private var tuneOpen = false
    @State private var logsOpen = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Practice source", selection: $useECU) {
                Text("Offline lab").tag(false)
                Text("My ECU").tag(true)
            }.pickerStyle(.segmented)
            if useECU {
                Text(ecu.connected ? "Link cable detected" : "Connect the Link USB cable to a powered ECU to use live readings.")
                    .font(.headline)
                Text(hardwareTask)
                HStack {
                    Button("Open live gauges & recorder") {
                        model.showLearn = false
                        model.showLive = true
                        live.select(.usb)
                    }.disabled(!ecu.connected || ecu.reading)
                    if model.tune == nil {
                        Button("Read ECU tune") { ecu.readTune(into: .open) }
                            .disabled(!ecu.connected || ecu.reading || live.recording)
                    }
                }
                Text("Review a saved recording from Live data & logs. Select Learn to return to this lesson.").font(.callout)
            } else {
                Text(lesson.labTask)
                HStack {
                    Button("Open practice tune") {
                        do {
                            if worksheet.tune == nil { try worksheet.openWorksheet(LabAsset.url("Practice baseline", "pclx")) }
                            tuneOpen = true
                        } catch { problem = error.localizedDescription }
                    }
                    Button("Explore sample logs") { logsOpen = true }
                }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $tuneOpen) {
            WorksheetView(lesson: lesson, table: lesson.id == "spark" ? 2366 : 2365).environmentObject(worksheet)
        }
        .sheet(isPresented: $logsOpen) { SampleLogView(initial: lesson.firstLog, task: lesson.labTask) }
    }

    private var hardwareTask: String {
        switch lesson.module {
        case "Foundations": return "With ignition on and engine stopped, inspect RPM, MAP and battery voltage. Record the units, timestamp and an unavailable reading if present."
        case "Calibration": return "Use a saved tune read and a recording from the same ECU. Compare available measured channels with the matching table and units. Mark missing target or trim channels as unknown."
        case "Offline editing": return "Read and save a backup of your ECU tune. Work on a separate file copy in Tune workspace, then compare it with the untouched backup."
        default: return "Record a stationary observation or inspect an existing run. Stop recording, open the CSV in Live data & logs, and use its timestamps and channels as evidence in your notebook."
        }
    }
}

private struct WorksheetView: View {
    let lesson: Lesson
    @State var table: Int
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Practice tune").font(.title.bold()); Spacer(); Button("Done") { dismiss() } }
            Text("Synthetic worksheet for offline editing. Edits stay in this session. Save a copy to keep them.")
            Text(lesson.labTask).font(.headline)
            if ["diff", "edit", "capstone"].contains(lesson.id),
               let value = model.tune?.parameter(2365)?.rows[1][2] {
                Label(value == 63 ? "Target edit verified at 2,000 RPM and 50 kPa" : "Target cell: " + fmtLive(value) + "% (goal 63%)",
                      systemImage: value == 63 ? "checkmark.circle.fill" : "scope")
            } else if lesson.id == "interpolate", let row = model.tune?.parameter(2365)?.rows.first {
                Label(row == [20, 25, 30, 40] ? "Interpolated row verified" : "Inspect the 40 kPa row before and after interpolation.",
                      systemImage: row == [20, 25, 30, 40] ? "checkmark.circle.fill" : "scope")
            }
            Picker("Table", selection: $table) {
                Text("Fuel (%)").tag(2365); Text("Ignition (°)").tag(2366); Text("Lambda target").tag(3890)
            }.pickerStyle(.segmented)
            TableEditor(id: table).id(table)
            HStack {
                Button("Undo") { model.undo() }.disabled(!model.canUndo)
                Button("Redo") { model.redo() }.disabled(!model.canRedo)
                Spacer()
                Text("\(model.diffs.count) tables differ from baseline")
                Button("Save working copy…") { model.saveAs() }
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }.padding(20).frame(minWidth: 840, minHeight: 500)
    }
}

private struct SampleLogView: View {
    let task: String
    @State private var name: String
    @State private var csv: String?
    @State private var error: String?
    @Environment(\.dismiss) var dismiss

    init(initial: String, task: String) {
        _name = State(initialValue: initial)
        self.task = task
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Sample logs").font(.title.bold()); Spacer(); Button("Done") { dismiss() } }
            Text(task)
            Picker("Synthetic recording", selection: $name) {
                ForEach(LabAsset.logs, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            if let csv { LogInspector(table: LogTable(csv: csv)).id(name) }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .onChange(of: name, initial: true) { _, new in
            do { csv = try String(contentsOf: LabAsset.url(new, "csv"), encoding: .utf8); error = nil }
            catch { csv = nil; self.error = error.localizedDescription }
        }
        .padding(20).frame(width: 680, height: 570)
    }
}

struct LogInspector: View {
    let table: LogTable
    @State private var index = 0

    var body: some View {
        if table.time.isEmpty {
            ContentUnavailableView("No samples", systemImage: "waveform")
        } else {
            HStack {
                Button("Previous sample") { index -= 1 }.disabled(index == 0)
                Spacer()
                Text("\(table.time[index], specifier: "%.3f") s  ·  Sample \(index + 1) of \(table.time.count)").monospacedDigit()
                Spacer()
                Button("Next sample") { index += 1 }.disabled(index + 1 == table.time.count)
            }
            if table.time.count > 1 {
                Slider(value: Binding(get: { Double(index) }, set: { index = Int($0.rounded()) }),
                       in: 0...Double(table.time.count - 1), step: 1).accessibilityLabel("Sample position")
            }
            List(table.columns.indices, id: \.self) { col in
                LabeledContent(table.columns[col], value: table.data[col][index].map { String(format: "%.6g", $0) } ?? "Missing")
                    .monospacedDigit()
            }
        }
    }
}
