import Foundation

func cleanGroupName(for filename: String) -> String {
 let stem = (filename as NSString).deletingPathExtension
 if let r1 = stem.range(of: #"^(.*?)-\d{8}T\d{6}Z(?:-\d+)?-\d+$"#, options: .regularExpression) {
  let matched = String(stem[r1])
  if let sepRange = matched.range(of: #"-\d{8}T\d{6}Z"#, options: .regularExpression) {
   let clean = String(matched[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
   if !clean.isEmpty { return clean }
  }
 }
 if let r2 = stem.range(of: #"[-_.\s]+(?:part|pt|vol|volume)?[-_.\s]*\d+$"#, options: [.regularExpression, .caseInsensitive]) {
  let clean = String(stem[..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
  if !clean.isEmpty { return clean }
 }
 if let r3 = stem.range(of: #"\s*\(\d+\)$"#, options: .regularExpression) {
  let clean = String(stem[..<r3.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
  if !clean.isEmpty { return clean }
 }
 return stem.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct ArchiveGroup {
 let name: String
 let files: [String]
}

func groupFilenames(_ names: [String]) -> [ArchiveGroup] {
 var map: [String: [String]] = [:]
 var order: [String] = []
 for name in names {
  let g = cleanGroupName(for: name)
  if map[g] == nil {
   map[g] = []
   order.append(g)
  }
  map[g]?.append(name)
 }
 return order.map { g in
  let files = map[g]!.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  return ArchiveGroup(name: g, files: files)
 }
}

// Test 1: Google Drive split parts
let drive1 = "PMCF - FESTIVAL DE JAZZ DIA 01 - APRESENTADOR-20261021T223850Z-1-001.zip"
let drive2 = "PMCF - FESTIVAL DE JAZZ DIA 01 - APRESENTADOR-20261021T223850Z-1-027.zip"
assert(cleanGroupName(for: drive1) == "PMCF - FESTIVAL DE JAZZ DIA 01 - APRESENTADOR")
assert(cleanGroupName(for: drive2) == "PMCF - FESTIVAL DE JAZZ DIA 01 - APRESENTADOR")

// Test 2: Google Drive second folder
let driveMarisco = "PMCF - FESTIVAL DO MARISCO - 3º DIA - APRESENTADOR-20261021T223859Z-1-004.zip"
assert(cleanGroupName(for: driveMarisco) == "PMCF - FESTIVAL DO MARISCO - 3º DIA - APRESENTADOR")

// Test 3: Standard multi-part patterns
assert(cleanGroupName(for: "Backup-001.zip") == "Backup")
assert(cleanGroupName(for: "Fotos.part02.zip") == "Fotos")
assert(cleanGroupName(for: "Video_pt3.zip") == "Video")
assert(cleanGroupName(for: "Musica (2).zip") == "Musica")
assert(cleanGroupName(for: "Simples.zip") == "Simples")

// Test 4: Grouping mixed files
let mixed = [
 "PMCF - FESTIVAL DO MARISCO - 3º DIA - APRESENTADOR-20261021T223859Z-1-002.zip",
 "PMCF - FESTIVAL DE JAZZ DIA 01 - APRESENTADOR-20261021T223850Z-1-002.zip",
 "PMCF - FESTIVAL DE JAZZ DIA 01 - APRESENTADOR-20261021T223850Z-1-001.zip",
 "PMCF - FESTIVAL DO MARISCO - 3º DIA - APRESENTADOR-20261021T223859Z-1-001.zip"
]
let groups = groupFilenames(mixed)
assert(groups.count == 2)
assert(groups[0].name == "PMCF - FESTIVAL DO MARISCO - 3º DIA - APRESENTADOR")
assert(groups[0].files.count == 2)
assert(groups[0].files[0].hasSuffix("-001.zip"))
assert(groups[0].files[1].hasSuffix("-002.zip"))

assert(groups[1].name == "PMCF - FESTIVAL DE JAZZ DIA 01 - APRESENTADOR")
assert(groups[1].files.count == 2)
assert(groups[1].files[0].hasSuffix("-001.zip"))
assert(groups[1].files[1].hasSuffix("-002.zip"))

print("TODOS OS TESTES DE IDENTIFICAÇÃO E AGRUPAMENTO PASSARAM COM SUCESSO!")
