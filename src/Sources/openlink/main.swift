import Foundation
import OpenLinkKit

let usage = """
usage:
  openlink info    <tune.pclx>
  openlink decrypt <tune.pclx> <out.xml>          raw decrypted XML
  openlink encrypt <in.xml>    <out.pclx>
  openlink export  <tune.pclx> <out.md|out.json>  AI-readable export (names, units, axes)
  openlink diff    <a.pclx> <b.pclx> [out.md]     comparison report
"""

func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

let args = CommandLine.arguments
guard args.count >= 3 else { die(usage) }
let cmd = args[1]
let inURL = URL(fileURLWithPath: args[2])
let catalog = Catalog.bundled()
func title(_ u: URL) -> String { u.deletingPathExtension().lastPathComponent }

do {
    switch cmd {
    case "decrypt":
        guard args.count >= 4 else { die(usage) }
        let pt = try TuneCrypt.decrypt(try Data(contentsOf: inURL))
        try pt.write(to: URL(fileURLWithPath: args[3]))
        print("decrypted \(pt.count) bytes")
    case "encrypt":
        guard args.count >= 4 else { die(usage) }
        let enc = TuneCrypt.encrypt(try Data(contentsOf: inURL))
        try enc.write(to: URL(fileURLWithPath: args[3]))
        print("encrypted \(enc.count) bytes")
    case "info":
        let tune = try TuneFile(fileURL: inURL)
        print("Firmware:     \(tune.memory.firmware)")
        print("Bootcode:     \(tune.memory.bootcode)")
        print("HW revision:  \(tune.memory.hwRevision)")
        print("ECU min spec: \(tune.memory.ecuMinSpec)")
        print("Link ID:      \(tune.memory.linkID)")
        print("Serial:       \(tune.memory.serialNumber)")
        print("Parameters:   \(tune.parameters.count) (\(tune.parameters.filter{$0.isTable}.count) tables)")
        print("Catalog:      \(catalog == nil ? "not found (names unavailable)" : "loaded")")
    case "export":
        guard args.count >= 4 else { die(usage) }
        let tune = try TuneFile(fileURL: inURL)
        let out = URL(fileURLWithPath: args[3])
        if out.pathExtension.lowercased() == "json" {
            try TuneExport.json(tune, catalog: catalog, title: title(inURL)).write(to: out)
        } else {
            try TuneExport.markdown(tune, catalog: catalog, title: title(inURL)).write(to: out, atomically: true, encoding: .utf8)
        }
        print("exported \(out.path)")
    case "diff":
        guard args.count >= 4 else { die(usage) }
        let bURL = URL(fileURLWithPath: args[3])
        let a = try TuneFile(fileURL: inURL), b = try TuneFile(fileURL: bURL)
        let items = TuneDiff.compare(a, b)
        let md = TuneExport.comparisonMarkdown(a: a, b: b, nameA: title(inURL), nameB: title(bURL), catalog: catalog, items: items)
        if args.count >= 5 {
            try md.write(to: URL(fileURLWithPath: args[4]), atomically: true, encoding: .utf8)
            print("\(items.count) differences → \(args[4])")
        } else { print(md) }
    default:
        die(usage)
    }
} catch {
    die("error: \(error.localizedDescription)")
}
