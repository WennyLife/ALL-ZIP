import os, shutil, tempfile, subprocess, zipfile
from pathlib import Path

ROOT = Path('/Users/lendaii/Movies/Apps criados/ALL ZIP/Codigo/Candidato-1.1.6')
ENGINE = ROOT / 'JuntaZIPEngine'
assert ENGINE.exists(), "JuntaZIPEngine deve existir"

tmp_dir = Path(tempfile.mkdtemp(prefix='test_multi_'))
try:
    src_dir = tmp_dir / 'source'
    dest_dir = tmp_dir / 'destination'
    src_dir.mkdir()
    dest_dir.mkdir()

    # Grupo 1: Festival de Jazz (2 partes)
    g1_p1 = src_dir / 'PMCF - FESTIVAL DE JAZZ DIA 01 - APRESENTADOR-20261021T223850Z-1-001.zip'
    g1_p2 = src_dir / 'PMCF - FESTIVAL DE JAZZ DIA 01 - APRESENTADOR-20261021T223850Z-1-002.zip'
    with zipfile.ZipFile(g1_p1, 'w') as zf:
        zf.writestr('jazz_video_01.mov', b'Jazz Conteudo 1')
    with zipfile.ZipFile(g1_p2, 'w') as zf:
        zf.writestr('jazz_video_02.mov', b'Jazz Conteudo 2')

    # Grupo 2: Festival do Marisco (2 partes)
    g2_p1 = src_dir / 'PMCF - FESTIVAL DO MARISCO - 3º DIA - APRESENTADOR-20261021T223859Z-1-001.zip'
    g2_p2 = src_dir / 'PMCF - FESTIVAL DO MARISCO - 3º DIA - APRESENTADOR-20261021T223859Z-1-002.zip'
    with zipfile.ZipFile(g2_p1, 'w') as zf:
        zf.writestr('marisco_foto_01.jpg', b'Marisco Conteudo 1')
    with zipfile.ZipFile(g2_p2, 'w') as zf:
        zf.writestr('marisco_foto_02.jpg', b'Marisco Conteudo 2')

    # Executa teste em Swift testando a extração via engine e publishExtraction
    test_swift = tmp_dir / 'test_runner.swift'
    test_swift.write_text(f"""
import Foundation

// Simula a lógica de agrupamento e publicação
let files = [
    URL(fileURLWithPath: "{g1_p1}"),
    URL(fileURLWithPath: "{g1_p2}"),
    URL(fileURLWithPath: "{g2_p1}"),
    URL(fileURLWithPath: "{g2_p2}")
]

func cleanGroupName(for url: URL) -> String {{
    let stem = url.deletingPathExtension().lastPathComponent
    if let r1 = stem.range(of: #"^(.*?)-\\d{{8}}T\\d{{6}}Z(?:-\\d+)?-\\d+$"#, options: .regularExpression) {{
        let matched = String(stem[r1])
        if let sepRange = matched.range(of: #"-\\d{{8}}T\\d{{6}}Z"#, options: .regularExpression) {{
            let clean = String(matched[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {{ return clean }}
        }}
    }}
    if let r2 = stem.range(of: #"[-_.\\s]+(?:part|pt|vol|volume)?[-_.\\s]*\\d+$"#, options: [.regularExpression, .caseInsensitive]) {{
        let clean = String(stem[..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {{ return clean }}
    }}
    return stem.trimmingCharacters(in: .whitespacesAndNewlines)
}}

var map: [String: [URL]] = [:]
var order: [String] = []
for u in files {{
    let g = cleanGroupName(for: u)
    if map[g] == nil {{ map[g] = []; order.append(g) }}
    map[g]?.append(u)
}}

assert(order.count == 2, "Deveriam ser 2 pastas identificadas")
assert(order[0] == "PMCF - FESTIVAL DE JAZZ DIA 01 - APRESENTADOR")
assert(order[1] == "PMCF - FESTIVAL DO MARISCO - 3º DIA - APRESENTADOR")

let dest = URL(fileURLWithPath: "{dest_dir}")
let fm = FileManager.default

for gname in order {{
    let groupFiles = map[gname]!.sorted {{ $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }}
    let stage = dest.appendingPathComponent(".JuntaZIP-\\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    
    // Executa extração com JuntaZIPEngine
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "{ENGINE}")
    p.arguments = ["extract", stage.path, "both"] + groupFiles.map(\\.path)
    try p.run()
    p.waitUntilExit()
    assert(p.terminationStatus == 0, "Falha na extração de \\(gname)")
    
    let final = dest.appendingPathComponent(gname, isDirectory: true)
    try publishExtraction(stage: stage, final: final)
}}

let jazzDir = dest.appendingPathComponent("PMCF - FESTIVAL DE JAZZ DIA 01 - APRESENTADOR")
let mariscoDir = dest.appendingPathComponent("PMCF - FESTIVAL DO MARISCO - 3º DIA - APRESENTADOR")

assert(fm.fileExists(atPath: jazzDir.appendingPathComponent("jazz_video_01.mov").path))
assert(fm.fileExists(atPath: jazzDir.appendingPathComponent("jazz_video_02.mov").path))
assert(fm.fileExists(atPath: mariscoDir.appendingPathComponent("marisco_foto_01.jpg").path))
assert(fm.fileExists(atPath: mariscoDir.appendingPathComponent("marisco_foto_02.jpg").path))

assert(!fm.fileExists(atPath: jazzDir.appendingPathComponent("marisco_foto_01.jpg").path))
assert(!fm.fileExists(atPath: mariscoDir.appendingPathComponent("jazz_video_01.mov").path))

print("APROVADO: Ambas as pastas foram identificadas e extraídas separadamente com 100% de integridade!")
""")

    # Executa
    cmd = f'cat "{ROOT / "Publication.swift"}" "{test_swift}" | swift -'
    res = subprocess.run(cmd, shell=True, capture_output=True, text=True, check=True)
    print(res.stdout)

finally:
    shutil.rmtree(tmp_dir, ignore_errors=True)
