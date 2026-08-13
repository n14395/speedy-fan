import Foundation
import SMCCore

// fanctl — tiny CLI over SMCCore. Reading works as any user; `set`/`auto`
// need root, so the SpeedyFan app installs this binary setuid-root under
// /Library/PrivilegedHelperTools. It only touches fan keys and clamps every
// requested speed to the fan's own [min, max] range.

let usage = """
usage:
  fanctl list             print fan status as JSON
  fanctl set <fan> <rpm>  force fan <fan> to <rpm> (root)
  fanctl auto <fan>       return fan <fan> to automatic (root)
  fanctl auto-all         return all fans to automatic (root)
  fanctl key <name>       print one SMC key as a number (e.g. F0Md, TC0P)
  fanctl version          print the command-set version
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func requireRoot() {
    // When installed setuid-root we run with euid 0; promote ruid too so
    // IOKit sees a fully-root process.
    if geteuid() == 0 { setuid(0) }
    guard geteuid() == 0 else {
        fail("fanctl: this command requires root (install the SpeedyFan helper or use sudo)")
    }
}

func parseFanIndex(_ s: String) -> Int {
    guard let id = Int(s), id >= 0, id < Fans.count() else {
        fail("fanctl: invalid fan index \(s) (have \(Fans.count()) fans)")
    }
    return id
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "list":
    let fans = Fans.all()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(fans) else { fail("fanctl: encode failed") }
    print(String(data: data, encoding: .utf8)!)

case "set":
    guard args.count == 3, let rpm = Double(args[2]), rpm >= 0, rpm <= 20000 else {
        fail(usage)
    }
    requireRoot()
    let id = parseFanIndex(args[1])
    do { try Fans.setSpeed(id, rpm: rpm) } catch { fail("fanctl: \(error)") }

case "auto":
    guard args.count == 2 else { fail(usage) }
    requireRoot()
    let id = parseFanIndex(args[1])
    do { try Fans.setAuto(id) } catch { fail("fanctl: \(error)") }

case "auto-all":
    requireRoot()
    do { try Fans.setAllAuto() } catch { fail("fanctl: \(error)") }

case "key":
    // Read-only debug probe (no root): raw SMC values settle questions the
    // fan-level API rounds away — e.g. F0Md=3 exposed the firmware's
    // parked-fan mode.
    guard args.count == 2 else { fail(usage) }
    do { print(try SMC.shared.readNumber(args[1])) }
    catch { fail("fanctl: \(error)") }

case "version":
    print(FanctlProtocol.version)

default:
    fail(usage)
}
