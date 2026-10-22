import Foundation
import AppKit
extension Model {
 func beginOperation(){if lockClosed{beginCompression()}else{begin()}}
 func beginCompression(){
  guard !busy,!files.isEmpty else{return}
  let name=folder.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !name.isEmpty,name != ".",name != "..",!name.contains("/"),!name.contains(":"),name.utf8.count<200 else{status="Escolha um nome válido para o ZIP.";return}
  let selected=files,target=destination
  let names=selected.map{$0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()}
  guard Set(names).count==names.count else{status="Selecione itens com nomes principais diferentes para evitar caminhos repetidos no ZIP.";return}
  busy=true;result=nil;progress=0;speed=0;processed=0;total=0;knownTotal=false;speedSamples=[];status="Preparando a compactação…";lock.lock();cancelled=false;lock.unlock()
  activity=ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"Compactação de arquivos")
  sound("Tink")
  DispatchQueue.global(qos:.userInitiated).async { [self] in
   let fm=FileManager.default;let temporary=target.appendingPathComponent(".ALLZIP-compress-\(UUID().uuidString).zip")
   do {
    var expected:UInt64=0
    try run(["cscan",temporary.path,"fast"]+selected.map(\.path)){text in if text.hasPrefix("TOTAL\t"),let value=UInt64(text.dropFirst(6)){expected=value}}
    let attributes=try fm.attributesOfFileSystem(forPath:target.path);let free=(attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
    guard expected<free,free-expected>64*1024*1024 else{throw JobFailure(message:"Espaço insuficiente para criar o ZIP com segurança.")}
    let started=ProcessInfo.processInfo.systemUptime
    DispatchQueue.main.sync{self.total=expected;self.knownTotal=true;self.speedSamples=[(started,0)];self.status="Compactando no modo rápido…"}
    try run(["compress",temporary.path,"fast"]+selected.map(\.path)){text in
     if text.hasPrefix("PROGRESS\t"),let bytes=UInt64(text.dropFirst(9)){let time=ProcessInfo.processInfo.systemUptime;DispatchQueue.main.async{self.processed=bytes;self.progress=expected>0 ? min(Double(bytes)/Double(expected),1):0;self.speedSamples.append((time,bytes));while self.speedSamples.count>2 && time-self.speedSamples[0].0>1.5{self.speedSamples.removeFirst()};if let first=self.speedSamples.first,time>first.0{self.speed=Double(bytes-first.1)/(time-first.0)}}}
    }
    try checkCancellation()
    let stem=name.lowercased().hasSuffix(".zip") ? String(name.dropLast(4)):name
    var final=target.appendingPathComponent(stem+".zip");var suffix=2
    while fm.fileExists(atPath:final.path){final=target.appendingPathComponent(stem+" (\(suffix)).zip");suffix+=1}
    try fm.moveItem(at:temporary,to:final);let finalURL=final
    DispatchQueue.main.async{self.result=finalURL;self.progress=1;self.status="Concluído. ZIP criado; arquivos originais preservados.";self.sound("Glass");self.finish()}
   } catch {
    try? fm.removeItem(at:temporary);let message=error.localizedDescription
    DispatchQueue.main.async{self.status=message;self.speed=0;if !message.contains("cancelad"){self.sound("Basso")};self.finish()}
   }
  }
 }
}
