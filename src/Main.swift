import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct JobFailure: LocalizedError { let message: String; var errorDescription: String? { message } }

struct ArchiveGroup: Identifiable, Equatable {
 var id: String { name }
 let name: String
 var files: [URL]
}

final class Model: ObservableObject {
 @Published var paneMode=0
 @Published var lockClosed=false
 @Published var knownTotal=false
 @Published var files: [URL] = []
 @Published var groups: [ArchiveGroup] = []
 @Published var folder = "Arquivos reunidos"
 @Published var destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
 @Published var policy = "ask"
 @Published var sounds = UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true
 @Published var busy = false
 @Published var status = "Selecione os ZIPs para reunir em uma pasta."
 @Published var progress: Double = 0
 @Published var speed: Double = 0
 @Published var processed: UInt64 = 0
 @Published var total: UInt64 = 0
 @Published var result: URL?
 let lock = NSLock()
 var process: Process?
 var cancelled = false
 var pending: [URL] = []
 var speedSamples: [(Double,UInt64)] = []
 var activity: NSObjectProtocol?
 func sound(_ name: String) { if sounds { NSSound(named: NSSound.Name(name))?.play() } }
 func pick() { let p=NSOpenPanel(); p.canChooseDirectories=lockClosed; p.allowsMultipleSelection=true; if !lockClosed{p.allowedContentTypes=[.zip]}; if p.runModal() == .OK { add(p.urls) } }
 static func cleanGroupName(for url: URL) -> String {
  let stem = url.deletingPathExtension().lastPathComponent
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
 static func groupURLs(_ urls: [URL]) -> [ArchiveGroup] {
  var groups: [ArchiveGroup] = []
  var map: [String: [URL]] = [:]
  var order: [String] = []
  for u in urls {
   let gname = cleanGroupName(for: u)
   if map[gname] == nil {
    map[gname] = []
    order.append(gname)
   }
   map[gname]?.append(u)
  }
  for gname in order {
   if let uList = map[gname] {
    let sortedList = uList.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    groups.append(ArchiveGroup(name: gname, files: sortedList))
   }
  }
  return groups
 }
 func add(_ urls:[URL]) {
  if busy { pending += urls; status="Operação em andamento. Novos arquivos aguardam a próxima operação."; return }
  for u in urls { if !files.contains(u) { files.append(u) } }
  result=nil
  if lockClosed {
   if let first=files.first { folder=first.deletingPathExtension().lastPathComponent }
   status="\(files.count) item(ns) selecionado(s)."
  } else {
   groups=Self.groupURLs(files)
   if groups.count == 1 {
    folder = groups[0].name
    status = "\(files.count) arquivo(s) selecionado(s) · 1 pasta identificada."
   } else if groups.count > 1 {
    status = "\(files.count) arquivo(s) selecionado(s) · \(groups.count) pastas identificadas."
   } else {
    status = "\(files.count) arquivo(s) selecionado(s)."
   }
  }
 }
 func chooseDestination() { let p=NSOpenPanel(); p.canChooseDirectories=true;p.canChooseFiles=false;p.canCreateDirectories=true;p.directoryURL=destination;if p.runModal() == .OK,let u=p.url{destination=u} }
 func cancel() { lock.lock();cancelled=true;process?.terminate();lock.unlock();status="Cancelando e removendo os arquivos temporários…" }
 func checkCancellation() throws {lock.lock();let c=cancelled;lock.unlock();if c{throw JobFailure(message:"Extração cancelada. Os ZIPs originais foram preservados.")}}
 func run(_ args:[String], line:@escaping(String)throws->Void) throws {
  try checkCancellation()
  let p=Process();p.executableURL=Bundle.main.url(forAuxiliaryExecutable:"JuntaZIPEngine");p.arguments=args
  let pipe=Pipe();p.standardOutput=pipe
  let err=FileManager.default.temporaryDirectory.appendingPathComponent("JuntaZIP-error-\(UUID().uuidString)")
  FileManager.default.createFile(atPath:err.path,contents:nil);let errorHandle=try FileHandle(forWritingTo:err);p.standardError=errorHandle
  defer {try? errorHandle.close();try? FileManager.default.removeItem(at:err);lock.lock();process=nil;lock.unlock()}
  lock.lock();if cancelled{lock.unlock();throw JobFailure(message:"Extração cancelada.")};process=p
  do{try p.run();lock.unlock()}catch{lock.unlock();throw error}
  var buffer=Data()
  do {
   while true {let data=pipe.fileHandleForReading.availableData;if data.isEmpty{break};buffer.append(data);while let end=buffer.firstIndex(of:10){let part=buffer[..<end];let text=String(decoding:part,as:UTF8.self);buffer.removeSubrange(...end);try line(text)};if buffer.count>32768{throw JobFailure(message:"Resposta inválida do motor de extração.")}}
  } catch {if p.isRunning{p.terminate()};p.waitUntilExit();throw error}
  p.waitUntilExit();try checkCancellation()
  if p.terminationStatus != 0 {let data=(try? Data(contentsOf:err)) ?? Data();let message=String(decoding:data.prefix(4096),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines);throw JobFailure(message:message.isEmpty ? "Não foi possível extrair este ZIP. Verifique se todas as partes estão presentes." : message)}
 }
 func begin() {
  guard !busy,!files.isEmpty else{return}
  let target=destination, chosenPolicy=policy
  let currentGroups = groups.isEmpty ? Self.groupURLs(files) : groups
  guard !currentGroups.isEmpty else{return}
  busy=true;result=nil;progress=0;speed=0;processed=0;total=0;knownTotal=false;speedSamples=[]
  status=currentGroups.count>1 ? "Iniciando extração de \(currentGroups.count) pastas…" : "Verificando os ZIPs e o espaço disponível…"
  lock.lock();cancelled=false;lock.unlock()
  activity=ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"Extração de arquivos ZIP")
  sound("Tink")
  DispatchQueue.global(qos:.userInitiated).async { [self] in
   let fm=FileManager.default
   var extractedFolders:[URL]=[]
   for (idx,group) in currentGroups.enumerated() {
    do {
     try checkCancellation()
     let groupName = (currentGroups.count==1 ? folder : group.name).trimmingCharacters(in:.whitespacesAndNewlines)
     guard !groupName.isEmpty,groupName != ".",groupName != "..",!groupName.contains("/"),!groupName.contains(":"),groupName.utf8.count<200 else {
      throw JobFailure(message:"Nome de pasta inválido: '\(groupName)'")
     }
     let stage=target.appendingPathComponent(".JuntaZIP-\(UUID().uuidString)",isDirectory:true)
     do {
      try fm.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
      var expected:UInt64=0;var entries:[String:Bool]=[:];var duplicates=0
      DispatchQueue.main.async {
       self.status = currentGroups.count>1 ? "Pasta \(idx+1) de \(currentGroups.count): \(groupName) · Verificando…" : "Verificando os ZIPs e o espaço disponível…"
       self.progress = 0
       self.knownTotal = false
      }
      try run(["scan",stage.path,"both"]+group.files.map(\.path)){text in
       if text.hasPrefix("ENTRY\t") {
        let parts=text.split(separator:"\t",maxSplits:3,omittingEmptySubsequences:false);guard parts.count==4,let size=UInt64(parts[2]),let type=Int(parts[1]) else{throw JobFailure(message:"Índice ZIP inválido.")}
        let hex=Array(parts[3].utf8);var data=Data();var i=0;while i+1<hex.count {guard let b=UInt8(String(decoding:hex[i...i+1],as:UTF8.self),radix:16) else{throw JobFailure(message:"Nome inválido no ZIP.")};data.append(b);i+=2}
        guard let path=String(data:data,encoding:.utf8) else{throw JobFailure(message:"O ZIP usa uma codificação de nomes não suportada nesta versão.")}
        let key=path.trimmingCharacters(in:CharacterSet(charactersIn:"/")).precomposedStringWithCanonicalMapping.lowercased();let isDirectory=type==16384
        if let old=entries[key] { if old != isDirectory {throw JobFailure(message:"Há um arquivo e uma pasta no mesmo caminho: \(path)")};if !isDirectory{duplicates+=1} }
        entries[key]=isDirectory
        let sum=expected.addingReportingOverflow(size);if sum.overflow{throw JobFailure(message:"Tamanho ZIP inválido.")};expected=sum.partialValue
       }
      }
      for key in entries.keys {var components=key.split(separator:"/");while components.count>1{components.removeLast();if entries[components.joined(separator:"/")]==false{throw JobFailure(message:"Há uma pasta dentro de um caminho ocupado por um arquivo.")}}}
      let attrs=try fm.attributesOfFileSystem(forPath:target.path);let free=(attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
      guard expected < free, free-expected > 64*1024*1024 else{
       let needed=Self.bytes(expected)
       let avail=Self.bytes(free)
       throw JobFailure(message:"Espaço insuficiente para '\(groupName)': necessário pelo menos \(needed), disponível \(avail). Escolha outro disco.")
      }
      var resolved=chosenPolicy
      if duplicates>0 && chosenPolicy=="ask" {
       DispatchQueue.main.sync {let alert=NSAlert();alert.messageText="\(duplicates) nome(s) repetido(s) em '\(groupName)'";alert.informativeText="As partes serão reunidas. Como deseja tratar os arquivos com nomes iguais?";alert.addButton(withTitle:"Manter os dois");alert.addButton(withTitle:"Preservar o primeiro");alert.addButton(withTitle:"Cancelar");let response=alert.runModal();resolved=response == .alertFirstButtonReturn ? "both" : response == .alertSecondButtonReturn ? "skip" : "cancel"}
       if resolved=="cancel"{throw JobFailure(message:"Extração cancelada. Os ZIPs originais foram preservados.")}
      }
      let transferStart=ProcessInfo.processInfo.systemUptime
      DispatchQueue.main.sync {
       self.total=expected
       self.processed=0
       self.knownTotal=true
       self.status = currentGroups.count>1 ? "Extraindo pasta \(idx+1) de \(currentGroups.count): \(groupName)…" : "Descompactando…"
       self.speedSamples=[(transferStart,0)]
      }
      try run(["extract",stage.path,resolved=="skip" ? "skip":"both"]+group.files.map(\.path)){text in
       if text.hasPrefix("PROGRESS\t"),let value=UInt64(text.dropFirst(9)) {let time=ProcessInfo.processInfo.systemUptime;DispatchQueue.main.async {self.processed=value;self.progress=expected>0 ? min(Double(value)/Double(expected),1):0;self.speedSamples.append((time,value));while self.speedSamples.count>2 && time-self.speedSamples[0].0>1.5{self.speedSamples.removeFirst()};if let first=self.speedSamples.first,time>first.0{self.speed=Double(value-first.1)/(time-first.0)}}}
      }
      try checkCancellation()
      var final=target.appendingPathComponent(groupName,isDirectory:true);var suffix=2
      while fm.fileExists(atPath:final.path){final=target.appendingPathComponent("\(groupName) (\(suffix))",isDirectory:true);suffix+=1}
      try publishExtraction(stage:stage,final:final)
      extractedFolders.append(final)
     } catch {
      try? fm.removeItem(at:stage)
      throw error
     }
    } catch {
     let message=error.localizedDescription
     DispatchQueue.main.async {
      self.status=message
      self.speed=0
      if !message.contains("cancelad"){self.sound("Basso")}
      self.finish()
     }
     return
    }
   }
   let firstResult = extractedFolders.first ?? target
   DispatchQueue.main.async {
    self.result=firstResult
    self.progress=1
    self.status=currentGroups.count>1 ? "Concluído! \(currentGroups.count) pastas extraídas com sucesso." : "Concluído. Todos os arquivos estão em uma pasta."
    self.sound("Glass")
    self.finish()
   }
  }
 }
 func finish(){busy=false;if let a=activity{ProcessInfo.processInfo.endActivity(a);activity=nil};if !pending.isEmpty{let next=pending;pending=[];files=[];groups=[];add(next)}}
 static func bytes(_ value:UInt64)->String{ByteCountFormatter.string(fromByteCount:Int64(min(value,UInt64(Int64.max))),countStyle:.file)}
}
final class Delegate:NSObject,NSApplicationDelegate {
 let model=Model();var window:NSWindow!;var layoutSubscription:AnyCancellable?
 func applicationDidFinishLaunching(_ notification:Notification){
  let view=NSHostingView(rootView:Content(model:model));window=NSWindow(contentRect:NSRect(x:0,y:0,width:580,height:560),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false);window.title="ALL ZIP";window.contentView=view;window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);NSApp.servicesProvider=self;NSUpdateDynamicServices()
  layoutSubscription=Publishers.CombineLatest3(model.$paneMode,DriveManager.shared.$jobs.map{$0.count},model.$groups.map{$0.count}).receive(on:DispatchQueue.main).sink{[weak self] mode,jobCount,groupCount in guard let window=self?.window else{return};let baseHeight:CGFloat = mode==0 ? (groupCount>1 ? 620:560) : (jobCount==0 ? 480:730);window.setContentSize(NSSize(width:580,height:min(baseHeight,(NSScreen.main?.visibleFrame.height ?? 900)-80)))}
  let menu=NSMenu();let appMenu=NSMenu();appMenu.addItem(withTitle:"Sobre ALL ZIP",action:#selector(about),keyEquivalent:"");appMenu.addItem(.separator());let services=NSMenu();let servicesItem=NSMenuItem(title:"Serviços",action:nil,keyEquivalent:"");servicesItem.submenu=services;appMenu.addItem(servicesItem);NSApp.servicesMenu=services;appMenu.addItem(.separator());appMenu.addItem(withTitle:"Sair do ALL ZIP",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");let item=NSMenuItem();item.submenu=appMenu;menu.addItem(item)
  let editMenu=NSMenu(title:"Editar")
  editMenu.addItem(withTitle:"Desfazer",action:Selector(("undo:")),keyEquivalent:"z")
  let redo=editMenu.addItem(withTitle:"Refazer",action:Selector(("redo:")),keyEquivalent:"z");redo.keyEquivalentModifierMask=[.command,.shift]
  editMenu.addItem(.separator())
  editMenu.addItem(withTitle:"Recortar",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
  editMenu.addItem(withTitle:"Copiar",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
  editMenu.addItem(withTitle:"Colar",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
  editMenu.addItem(withTitle:"Selecionar Tudo",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
  let editItem=NSMenuItem(title:"Editar",action:nil,keyEquivalent:"");editItem.submenu=editMenu;menu.addItem(editItem);NSApp.mainMenu=menu
 }
 func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);return true }
 @objc func about(){let a=NSAlert();a.messageText="ALL ZIP 1.1.6";a.informativeText="Compactação rápida e extração com libarchive do macOS. Downloads diretos do Google Drive com autorização própria, até dez transferências em paralelo e verificação de integridade.\n\nZIPs independentes são reunidos. Volumes divididos, arquivos com senha e links não têm suporte garantido nesta versão.\n\nVelocidade: bytes processados por segundo; não é uma medição de gravação física no disco.";a.runModal()}
 func application(_ app:NSApplication,open urls:[URL]){model.add(urls);window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
 @objc func extractTogether(_ pasteboard:NSPasteboard,userData:String?,error:AutoreleasingUnsafeMutablePointer<NSString?>){let urls=pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] ?? (pasteboard.propertyList(forType:NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] ?? []).map{URL(fileURLWithPath:$0)};if urls.isEmpty{error.pointee="Selecione os arquivos ZIP no Finder.";return};model.lockClosed=false;model.add(urls);window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
 func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {if DriveManager.shared.busy{let a=NSAlert();a.messageText="Downloads em andamento";a.informativeText="Conclua ou cancele a fila antes de sair. As pastas só são publicadas ao terminar.";a.runModal();return .terminateCancel};if model.busy{let a=NSAlert();a.messageText="Extração em andamento";a.informativeText="Cancele a extração antes de sair para permitir a limpeza dos arquivos temporários.";a.addButton(withTitle:"Continuar");a.addButton(withTitle:"Cancelar extração");if a.runModal() == .alertSecondButtonReturn{model.cancel()};return .terminateCancel};return .terminateNow}
}
@main
struct ALLZIPMain {
 static func main() {
  let app=NSApplication.shared
  let delegate=Delegate()
  app.delegate=delegate
  app.setActivationPolicy(.regular)
  withExtendedLifetime(delegate) { app.run() }
 }
}
