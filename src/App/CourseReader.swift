import SwiftUI

struct CourseOutline: View {
    @Binding var selection: String
    let passed: String

    var body: some View {
        let completed = Set(passed.components(separatedBy: ","))
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ECU tuning course").font(.headline)
                let count = Course.lessons.filter { completed.contains($0.id) }.count
                Text("\(count) of \(Course.lessons.count) lessons complete").foregroundStyle(.secondary)
                ProgressView(value: Double(count), total: Double(Course.lessons.count))
            }
            .padding()
            List(selection: $selection) {
                ForEach(Course.modules, id: \.self) { module in
                    Section(module) {
                        ForEach(Course.lessons.filter { $0.module == module }) { item in
                            Label(item.title, systemImage: completed.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                .padding(.vertical, 3).tag(item.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

struct CourseReader: View {
    @Binding var selection: String
    @Binding var passed: String
    let worksheet: AppModel

    var body: some View {
        let index = Course.lessons.firstIndex { $0.id == selection } ?? 0
        let lesson = Course.lessons[index]
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("\(lesson.module)  ·  Lesson \(index + 1) of \(Course.lessons.count)")
                    .font(.headline).foregroundStyle(.secondary)
                Text(lesson.title).font(.largeTitle.bold())
                Text(lesson.concept).font(.system(size: 17)).lineSpacing(5).textSelection(.enabled)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Worked example", systemImage: "text.magnifyingglass").font(.headline)
                    Text(lesson.example).lineSpacing(4).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18).background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Practice").font(.title2.bold())
                    Text(lesson.practice).lineSpacing(4).textSelection(.enabled)
                    CourseLab(lesson: lesson, worksheet: worksheet)
                    LessonNotebook(lessonID: lesson.id)
                }
                if lesson.id == "fuel" {
                    Link("Read Link’s guide to fuel equations", destination: URL(string: "https://support.linkecu.com/learn/latest/get-started/getting-running/fuel-equations")!)
                }
                Divider()
                LessonCheck(lesson: lesson, passed: $passed)
                Divider()
                HStack {
                    Button("Previous lesson") { selection = Course.lessons[index - 1].id }
                        .disabled(index == 0)
                    Spacer()
                    if index + 1 < Course.lessons.count {
                        Button("Next lesson") { selection = Course.lessons[index + 1].id }.buttonStyle(.borderedProminent)
                    } else if Course.lessons.allSatisfy({ passed.components(separatedBy: ",").contains($0.id) }) {
                        Label("Course complete", systemImage: "checkmark.seal.fill").font(.headline)
                    } else if let next = Course.lessons.first(where: { !passed.components(separatedBy: ",").contains($0.id) }) {
                        Button("Review unfinished lessons") { selection = next.id }
                    }
                }
            }
            .font(.system(size: 15))
            .frame(maxWidth: 740, alignment: .leading).padding(32)
            .frame(maxWidth: .infinity)
        }
        .id(lesson.id)
    }
}

private struct LessonNotebook: View {
    @AppStorage private var notes: String
    init(lessonID: String) {
        _notes = AppStorage(wrappedValue: "", "course.notes." + lessonID)
    }

    var body: some View {
        TextField("Your practice notes", text: $notes, axis: .vertical)
            .textFieldStyle(.roundedBorder).lineLimit(2...10)
            .accessibilityLabel("Practice notes, saved on this Mac")
    }
}

private struct LessonCheck: View {
    let lesson: Lesson
    @Binding var passed: String
    @State private var attempt: Int?

    var body: some View {
        let complete = passed.components(separatedBy: ",").contains(lesson.id)
        VStack(alignment: .leading, spacing: 10) {
            Text("Knowledge check").font(.title2.bold())
            Text(lesson.question).font(.headline)
            ForEach(lesson.choices.indices, id: \.self) { index in
                Button {
                    attempt = index
                    if index == lesson.answer && !complete {
                        passed = (passed.split(separator: ",").map(String.init) + [lesson.id]).joined(separator: ",")
                    }
                } label: {
                    Label(lesson.choices[index], systemImage: complete && index == lesson.answer ? "checkmark.circle.fill" : "circle")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(7)
                }
                .disabled(complete)
            }
            if complete {
                Text("Correct. " + lesson.explanation)
            } else if attempt != nil {
                Text("Try again. " + lesson.explanation)
            }
        }
    }
}
