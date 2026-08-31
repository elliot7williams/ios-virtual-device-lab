#!/usr/bin/env swift

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("coverage gate: \(message)\n".utf8))
    exit(2)
}

guard CommandLine.arguments.count >= 2 else {
    fail("usage: check_coverage.swift <llvm-cov.json> [minimum-overall-line-percent] [minimum-expansion-line-percent] [minimum-production-depth-line-percent]")
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let minimumOverall = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 25 : 25
let minimumExpansion = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 65 : 65
let minimumProductionDepth = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4]) ?? 60 : 60
guard let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
      let data = object["data"] as? [[String: Any]],
      let root = data.first,
      let totals = root["totals"] as? [String: Any],
      let lines = totals["lines"] as? [String: Any],
      let overall = (lines["percent"] as? NSNumber)?.doubleValue,
      overall.isFinite else {
    fail("report is not a supported LLVM coverage JSON document")
}

let files = root["files"] as? [[String: Any]] ?? []
let expansion = files.first { ($0["filename"] as? String)?.hasSuffix("/LabExpansion.swift") == true }
let productionDepth = files.first { ($0["filename"] as? String)?.hasSuffix("/ProductionDepth.swift") == true }
let expansionPercent = ((expansion?["summary"] as? [String: Any])?["lines"] as? [String: Any])?["percent"] as? NSNumber
let productionDepthPercent = ((productionDepth?["summary"] as? [String: Any])?["lines"] as? [String: Any])?["percent"] as? NSNumber
guard let expansionLinePercent = expansionPercent?.doubleValue, expansionLinePercent.isFinite else {
    fail("LabExpansion.swift is missing from the coverage report")
}
guard let productionDepthLinePercent = productionDepthPercent?.doubleValue, productionDepthLinePercent.isFinite else {
    fail("ProductionDepth.swift is missing from the coverage report")
}

print(String(format: "Overall line coverage %.2f%% (floor %.2f%%)", overall, minimumOverall))
print(String(format: "LabExpansion.swift line coverage %.2f%% (floor %.2f%%)", expansionLinePercent, minimumExpansion))
print(String(format: "ProductionDepth.swift line coverage %.2f%% (floor %.2f%%)", productionDepthLinePercent, minimumProductionDepth))
guard overall >= minimumOverall else { fail("overall line coverage regressed below its baseline floor") }
guard expansionLinePercent >= minimumExpansion else { fail("qualification-and-scale line coverage regressed below its floor") }
guard productionDepthLinePercent >= minimumProductionDepth else { fail("production-depth line coverage regressed below its floor") }
