import Foundation
let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("ALLZIP-publication-tests-\(UUID().uuidString)")
try fm.createDirectory(at:base,withIntermediateDirectories:true)
defer {try? fm.removeItem(at:base)}
func stage(_ name:String) throws -> URL {
 let url=base.appendingPathComponent(name)
 try fm.createDirectory(at:url,withIntermediateDirectories:true)
 return url
}
func write(_ root:URL,_ path:String,_ content:String="integridade") throws {
 let url=root.appendingPathComponent(path)
 try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
 try Data(content.utf8).write(to:url)
}
func content(_ url:URL) throws -> String {try String(contentsOf:url,encoding:.utf8)}
let single=try stage("single")
try write(single,"Pacote/arquivo.txt")
try write(single,"Pacote/Texturas/área.png","textura")
try write(single,"Pacote/.oculto","oculto")
let final=base.appendingPathComponent("resultado")
try publishExtraction(stage:single,final:final)
assert(try! content(final.appendingPathComponent("arquivo.txt"))=="integridade")
assert(try! content(final.appendingPathComponent("Texturas/área.png"))=="textura")
assert(try! content(final.appendingPathComponent(".oculto"))=="oculto")
assert(!fm.fileExists(atPath:final.appendingPathComponent("Pacote").path))
assert(!fm.fileExists(atPath:single.path))
print("APROVADO: pasta externa removida, conteúdo e subpastas preservados")
let multi=try stage("multi")
try write(multi,"A/a.txt");try write(multi,"B/b.txt")
let multiFinal=base.appendingPathComponent("multi-final")
try publishExtraction(stage:multi,final:multiFinal)
assert(fm.fileExists(atPath:multiFinal.appendingPathComponent("A/a.txt").path))
assert(fm.fileExists(atPath:multiFinal.appendingPathComponent("B/b.txt").path))
print("APROVADO: múltiplas pastas principais preservadas")
let rootFile=try stage("root-file")
try write(rootFile,"Pacote/a.txt");try write(rootFile,".informacao","raiz")
let rootFinal=base.appendingPathComponent("root-final")
try publishExtraction(stage:rootFile,final:rootFinal)
assert(fm.fileExists(atPath:rootFinal.appendingPathComponent("Pacote/a.txt").path))
assert(try! content(rootFinal.appendingPathComponent(".informacao"))=="raiz")
print("APROVADO: arquivos ocultos na raiz não são descartados")
let nested=try stage("nested")
try write(nested,"Pacote/Arquivos/a.txt")
let nestedFinal=base.appendingPathComponent("nested-final")
try publishExtraction(stage:nested,final:nestedFinal)
assert(fm.fileExists(atPath:nestedFinal.appendingPathComponent("Arquivos/a.txt").path))
print("APROVADO: somente um nível externo removido")
let collision=try stage("collision")
try write(collision,"Pacote/a.txt","novo")
do {try publishExtraction(stage:collision,final:final);fatalError("Sobrescreveu o destino existente")}
catch {assert(try! content(final.appendingPathComponent("arquivo.txt"))=="integridade");assert(fm.fileExists(atPath:collision.appendingPathComponent("Pacote/a.txt").path))}
print("APROVADO: destino existente e temporários preservados em conflito")
