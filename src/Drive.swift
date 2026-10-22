import Foundation
import Combine
import AppKit
import CryptoKit
import UniformTypeIdentifiers

struct DriveLink:Equatable {
 let id:String;let resourceKey:String?
 static func parse(_ text:String)throws->DriveLink {
  guard let url=URLComponents(string:text),url.scheme=="https",url.host=="drive.google.com" || url.host=="docs.google.com" else{throw DriveError.message("Cole um link HTTPS de arquivo ou pasta do Google Drive.")}
  let parts=url.path.split(separator:"/").map(String.init);var id:String?
  if let i=parts.firstIndex(of:"folders"),i+1<parts.count{id=parts[i+1]}
  else if let i=parts.firstIndex(of:"d"),i+1<parts.count{id=parts[i+1]}
  else{id=url.queryItems?.first(where:{$0.name=="id"})?.value}
  guard let fileID=id,!fileID.isEmpty,fileID.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil else{throw DriveError.message("O link não contém um arquivo ou pasta identificável do Drive.")}
  return DriveLink(id:fileID,resourceKey:url.queryItems?.first(where:{$0.name.lowercased()=="resourcekey"})?.value)
 }
}
struct DriveFile:Decodable {
 let id:String;let name:String;let mimeType:String
 let size:String?;let md5Checksum:String?;let resourceKey:String?
 struct Capabilities:Decodable{let canDownload:Bool?}
 struct Shortcut:Decodable{let targetId:String;let targetMimeType:String?;let targetResourceKey:String?}
 let capabilities:Capabilities?;let shortcutDetails:Shortcut?
 var isFolder:Bool{mimeType=="application/vnd.google-apps.folder"}
 var bytes:UInt64?{size.flatMap(UInt64.init)}
}
struct DrivePage:Decodable{let files:[DriveFile];let nextPageToken:String?;let incompleteSearch:Bool?}
protocol DriveReading {
 func metadata(_ link:DriveLink)throws->DriveFile
 func children(_ parent:String,control:TransferControl)throws->[DriveFile]
}
final class DriveAPI:DriveReading {
 static let fields="id,name,mimeType,size,md5Checksum,resourceKey,capabilities(canDownload),shortcutDetails(targetId,targetMimeType,targetResourceKey)"
 private var keys:[String:String]=[:]
 func remember(_ file:DriveFile){if let key=file.resourceKey{keys[file.id]=key}}
 func request(_ path:String,query:[String:String]=[:],keyIDs:[String]=[])throws->URLRequest {
  var url=URLComponents(string:"https://www.googleapis.com/drive/v3/"+path)!;url.queryItems=query.map{URLQueryItem(name:$0.key,value:$0.value)}
  var request=URLRequest(url:url.url!);request.setValue("Bearer "+(try GoogleAuth.shared.accessToken()),forHTTPHeaderField:"Authorization")
  let resources=keyIDs.compactMap{id in keys[id].map{id+"/"+$0}}.joined(separator:",");if !resources.isEmpty{request.setValue(resources,forHTTPHeaderField:"X-Goog-Drive-Resource-Keys")};return request
 }
 func json<T:Decodable>(_ type:T.Type,_ path:String,query:[String:String],keyIDs:[String])throws->T {
  for attempt in 0..<3 {
   let req=try request(path,query:query,keyIDs:keyIDs);let (data,response)=try GoogleAuth.synchronous(req)
   if response.statusCode==200{return try JSONDecoder().decode(type,from:data)}
   if [429,500,502,503,504].contains(response.statusCode),attempt<2{Thread.sleep(forTimeInterval:Double(attempt+1));continue}
   throw DriveError.message(response.statusCode==404 ? "O link não foi encontrado ou sua conta não tem acesso à pasta." : response.statusCode==403 ? "O Google bloqueou esta operação. Confira permissão de download, Drive API ativada e cotas." : "O Drive respondeu com erro HTTP \(response.statusCode). Conecte novamente se a sessão expirou.")
  }
  throw DriveError.message("Não foi possível consultar o Drive.")
 }
 func metadata(_ link:DriveLink)throws->DriveFile {
  if let key=link.resourceKey{keys[link.id]=key}
  let file=try json(DriveFile.self,"files/"+link.id,query:["fields":Self.fields,"supportsAllDrives":"true"],keyIDs:[link.id]);remember(file);return file
 }
 func children(_ parent:String,control:TransferControl)throws->[DriveFile] {
  var files:[DriveFile]=[],page:String?;var pages=Set<String>()
  repeat {
   try control.check();var query=["q":"'\(parent)' in parents and trashed = false","fields":"nextPageToken,incompleteSearch,files(\(Self.fields))","pageSize":"1000","supportsAllDrives":"true","includeItemsFromAllDrives":"true"]
   query["pageToken"]=page
   let result=try json(DrivePage.self,"files",query:query,keyIDs:[parent]);if result.incompleteSearch==true{throw DriveError.message("O Drive retornou uma listagem incompleta. Não será publicado um download parcial.")}
   files+=result.files;for file in result.files{remember(file)};if files.count>100000{throw DriveError.message("A pasta ultrapassa 100 mil itens nesta versão.")}
   page=result.nextPageToken;if let next=page,!pages.insert(next).inserted{throw DriveError.message("O Drive repetiu uma página de resultados.")}
  } while page != nil
  return files.sorted {if $0.name==$1.name{return $0.id<$1.id};return $0.name.localizedStandardCompare($1.name) == .orderedAscending}
 }
 static func export(_ file:DriveFile)throws->(mime:String,ext:String)? {
  switch file.mimeType {
  case "application/vnd.google-apps.document":return("application/vnd.openxmlformats-officedocument.wordprocessingml.document","docx")
  case "application/vnd.google-apps.spreadsheet":return("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet","xlsx")
  case "application/vnd.google-apps.presentation":return("application/vnd.openxmlformats-officedocument.presentationml.presentation","pptx")
  case "application/vnd.google-apps.drawing":return("image/png","png")
  default:if file.mimeType.hasPrefix("application/vnd.google-apps."){throw DriveError.message("A pasta contém um formato nativo do Google sem exportação suportada: \(file.name)")};return nil
  }
 }
 func downloadRequest(_ file:DriveFile)throws->URLRequest {
  if let export=try Self.export(file){return try request("files/\(file.id)/export",query:["mimeType":export.mime],keyIDs:[file.id])}
  return try request("files/\(file.id)",query:["alt":"media","supportsAllDrives":"true"],keyIDs:[file.id])
 }
}
struct DriveItem {let file:DriveFile;let path:String;let exported:Bool}
struct DrivePlan {let name:String;let folder:Bool;let items:[DriveItem];let directories:[String]}
struct DriveScanProgress:Equatable {
 let name:String
 let folderCount:Int
 let fileCount:Int
 let knownBytes:UInt64
}
func formatBytes(_ value:UInt64)->String {
 ByteCountFormatter.string(fromByteCount:Int64(min(value,UInt64(Int64.max))),countStyle:.file)
}
func spaceErrorMessage(needed:UInt64,available:UInt64,partial:Bool)->String {
 let neededStr=partial ? "pelo menos \(formatBytes(needed))" : formatBytes(needed)
 return "Espaço insuficiente no destino: necessário \(neededStr), disponível \(formatBytes(available)). Clique em Alterar para escolher outro disco."
}
func formatScanStatus(_ prog:DriveScanProgress)->String {
 if prog.folderCount>0 {
  return "Preparando… \(prog.fileCount) arquivo(s), \(prog.folderCount) pasta(s) · \(formatBytes(prog.knownBytes))"
 } else if prog.fileCount>0 {
  return "Preparando… \(prog.fileCount) arquivo(s) · \(formatBytes(prog.knownBytes))"
 } else {
  return "Preparando…"
 }
}
func safeDriveName(_ name:String)->String {
 let cleaned=name.replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:":",with:"_").replacingOccurrences(of:"\\",with:"_").replacingOccurrences(of:"\0",with:"")
 if cleaned.isEmpty || cleaned=="." || cleaned==".."{return "Sem nome"}
 // Preserve UTF-8 boundaries and leave room for conflict suffixes on APFS.
 var result="";for c in cleaned{if (result+String(c)).utf8.count>220{break};result.append(c)};return result.isEmpty ? "Sem nome":result
}
func makeDrivePlan(api:DriveReading,link:DriveLink,control:TransferControl,availableBytes:UInt64?=nil,onProgress:((DriveScanProgress)->Void)?=nil)throws->DrivePlan {
 var root=try api.metadata(link);if let shortcut=root.shortcutDetails{root=try api.metadata(DriveLink(id:shortcut.targetId,resourceKey:shortcut.targetResourceKey))}
 let rootName=root.isFolder ? safeDriveName(root.name):safeDriveName(root.name)
 var lastProgress=ProcessInfo.processInfo.systemUptime
 onProgress?(DriveScanProgress(name:rootName,folderCount:0,fileCount:0,knownBytes:0))
 var items:[DriveItem]=[],directories:[String]=[],used=Set<String>()
 var knownBytes:UInt64=0
 func reportProgress(force:Bool=false){
  guard let onProgress=onProgress else{return}
  let now=ProcessInfo.processInfo.systemUptime
  if force || now-lastProgress>=0.15 {
   lastProgress=now
   onProgress(DriveScanProgress(name:rootName,folderCount:directories.count,fileCount:items.count,knownBytes:knownBytes))
  }
 }
 func unique(_ path:String)->String {var result=path;var n=2;while !used.insert(result.precomposedStringWithCanonicalMapping.lowercased()).inserted{let url=URL(fileURLWithPath:path);let ext=url.pathExtension;let stem=ext.isEmpty ? path:String(path.dropLast(ext.count+1));result=stem+" (\(n))"+(ext.isEmpty ? "":"."+ext);n+=1};return result}
 func add(_ file:DriveFile,parent:String,ancestors:Set<String>,depth:Int)throws {
  try control.check();guard depth<64,items.count+directories.count<100000 else{throw DriveError.message("A estrutura da pasta ultrapassa o limite desta versão.")}
  var source=file;let label=file.name;let itemPath=parent+safeDriveName(label)
  if let shortcut=file.shortcutDetails {
   do {
    source=try api.metadata(DriveLink(id:shortcut.targetId,resourceKey:shortcut.targetResourceKey))
   } catch {
    throw DriveError.message("O atalho '\(itemPath)' aponta para um item não encontrado ou sem permissão de acesso.")
   }
  }
  if source.isFolder {
   guard !ancestors.contains(source.id) else{throw DriveError.message("A pasta contém um atalho circular: \(itemPath)")}
   let path=unique(itemPath);directories.append(path)
   reportProgress()
   let childrenList:[DriveFile]
   do {
    childrenList=try api.children(source.id,control:control)
   } catch let err as DriveError {
    if case .message(let msg)=err,msg.contains("subpasta '") || msg.contains("atalho '") || msg.contains("Espaço insuficiente") {throw err}
    if err.localizedDescription.contains("não foi encontrado") || err.localizedDescription.contains("acesso") {
     throw DriveError.message("A subpasta '\(path)' não foi encontrada ou sua conta não tem permissão de acesso.")
    }
    throw DriveError.message("Não foi possível acessar a subpasta '\(path)': \(err.localizedDescription)")
   } catch {
    throw DriveError.message("Não foi possível acessar a subpasta '\(path)': \(error.localizedDescription)")
   }
   for child in childrenList{try add(child,parent:path+"/",ancestors:ancestors.union([source.id]),depth:depth+1)}
  } else {
   if source.capabilities?.canDownload==false{throw DriveError.message("O proprietário não permite baixar: \(itemPath)")}
   let export=try DriveAPI.export(source);let name=safeDriveName(label)+(export.map{"."+$0.ext} ?? "")
   let path=unique(parent+name)
   let item=DriveItem(file:source,path:path,exported:export != nil)
   items.append(item)
   if !item.exported,let bytes=item.file.bytes {
    let sum=knownBytes.addingReportingOverflow(bytes)
    if sum.overflow{throw DriveError.message("Tamanho total inválido.")}
    knownBytes=sum.partialValue
    if let available=availableBytes {
     let reserve:UInt64=64*1024*1024
     let (needed,overflow)=knownBytes.addingReportingOverflow(reserve)
     if overflow || needed>available {
      reportProgress(force:true)
      throw DriveError.message(spaceErrorMessage(needed:overflow ? UInt64.max:needed,available:available,partial:true))
     }
    }
   }
   reportProgress()
  }
 }
 if root.isFolder {
  let rootChildren:[DriveFile]
  do {
   rootChildren=try api.children(root.id,control:control)
  } catch let err as DriveError {
   if case .message(let msg)=err,msg.contains("subpasta '") || msg.contains("atalho '") || msg.contains("Espaço insuficiente") {throw err}
   throw err
  }
  for child in rootChildren{try add(child,parent:"",ancestors:[root.id],depth:0)}
 } else {
  try add(root,parent:"",ancestors:[],depth:0)
 }
 reportProgress(force:true)
 let name=root.isFolder ? safeDriveName(root.name):(items.first?.path ?? safeDriveName(root.name))
 return DrivePlan(name:name,folder:root.isFolder,items:items,directories:directories)
}
final class DriveJob:ObservableObject,Identifiable {
 let id=UUID();let link:DriveLink;let destination:URL;let control=TransferControl()
 @Published var name="Pasta do Drive"
 @Published var status="Na fila"
 @Published var processed:UInt64=0
 @Published var total:UInt64?
 @Published var speed:Double=0
 @Published var count=0
 @Published var doneCount=0
 @Published var active=false
 @Published var paused=false
 @Published var result:URL?
 @Published var failed=false
 init(link:DriveLink,destination:URL){self.link=link;self.destination=destination}
 var fraction:Double{if result != nil{return 1};guard let total=total,total>0 else{return 0};return min(Double(processed)/Double(total),1)}
}
final class DriveManager:ObservableObject {
 static let shared=DriveManager()
 @Published var parallelDownloads:Int=max(1,min(10,UserDefaults.standard.object(forKey:"parallelDownloads") as? Int ?? 10)){didSet{UserDefaults.standard.set(max(1,min(10,parallelDownloads)),forKey:"parallelDownloads")}}
 @Published var links=""
 @Published var jobs:[DriveJob]=[]
 @Published var status="Cole um ou mais links do Drive."
 @Published var connecting=false
 @Published var connected=GoogleAuth.shared.connected
 private let serial=DispatchQueue(label:"ALLZIP.drive.queue",qos:.userInitiated)
 var busy:Bool{jobs.contains{$0.active} || jobs.contains{$0.status=="Na fila"} || connecting}
 func connect(){
  guard !connecting else{return}
  if !GoogleAuth.shared.configured {
   let alert=NSAlert();alert.messageText="Configurar conexão Google";alert.informativeText="Esta instalação ainda não recebeu a credencial OAuth do ALL ZIP. Importe o JSON de Aplicativo para computador. No pacote distribuído, essa configuração ficará incluída pelo desenvolvedor.";alert.addButton(withTitle:"Importar JSON…");alert.addButton(withTitle:"Abrir Google Cloud");alert.addButton(withTitle:"Cancelar")
   switch alert.runModal(){case .alertFirstButtonReturn:let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.canChooseDirectories=false;if panel.runModal() == .OK,let url=panel.url{do{try GoogleAuth.shared.importClient(url)}catch{status=error.localizedDescription;return}}else{return};case .alertSecondButtonReturn:NSWorkspace.shared.open(URL(string:"https://console.cloud.google.com/apis/credentials")!);status="Configuração do desenvolvedor pendente no Google Cloud.";return;default:return}
  }
  connecting=true;status="Autorize a conexão no navegador…"
  DispatchQueue.global(qos:.userInitiated).async {do{try GoogleAuth.shared.connect();DispatchQueue.main.async {self.connecting=false;self.connected=true;self.status="Conta Google conectada."}}catch{DispatchQueue.main.async{self.connecting=false;self.status=error.localizedDescription}}}
 }
 func cancelConnection(){GoogleAuth.shared.cancelConnection();status="Cancelando conexão…"}
 func disconnect(){guard !busy else{status="Finalize ou cancele os downloads antes de desconectar.";return};GoogleAuth.shared.disconnect();connected=false;status="Conta desconectada deste Mac."}
 func enqueue(destination:URL){
  guard connected else{status="Conecte sua conta Google antes de adicionar links.";return}
  do {
   let parsed=try links.split(whereSeparator:{$0.isWhitespace}).map{try DriveLink.parse(String($0))};guard !parsed.isEmpty else{throw DriveError.message("Cole pelo menos um link do Drive.")}
   var unique:[DriveLink]=[];for link in parsed{if !unique.contains(link){unique.append(link)}}
   for link in unique {let job=DriveJob(link:link,destination:destination);jobs.append(job);let parallel=max(1,min(10,parallelDownloads));serial.async{self.run(job,parallel:parallel)}}
   links="";status="Downloads adicionados."
  }catch{status=error.localizedDescription}
 }
 func clearCompleted(){jobs.removeAll{$0.result != nil}}
 func pause(_ job:DriveJob){job.paused.toggle();job.control.pause(job.paused);job.status=job.paused ? "Pausado":"Baixando…"}
 func cancel(_ job:DriveJob){job.control.cancel();job.paused=false;job.status="Cancelando…"}
 private func run(_ job:DriveJob,parallel:Int){
  let fm=FileManager.default;let stage=job.destination.appendingPathComponent(".ALLZIP-download-\(UUID().uuidString)")
  let activity=ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"Download do Drive")
  defer{ProcessInfo.processInfo.endActivity(activity)}
  DispatchQueue.main.async{job.active=true;job.status="Preparando…"}
  var stageCreated=false
  var resolvedName:String?
  do {
   try job.control.check()
   let initialAttrs=try fm.attributesOfFileSystem(forPath:job.destination.path)
   let initialFree=(initialAttrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
   let api=DriveAPI()
   let plan=try makeDrivePlan(api:api,link:job.link,control:job.control,availableBytes:initialFree,onProgress:{prog in
    resolvedName=prog.name
    DispatchQueue.main.async{
     job.name=prog.name
     job.status=formatScanStatus(prog)
    }
   })
   resolvedName=plan.name
   let allKnown=plan.items.allSatisfy{!$0.exported && $0.file.bytes != nil}
   var known:UInt64=0
   for item in plan.items{
    let add=known.addingReportingOverflow(item.exported ? 0:(item.file.bytes ?? 0))
    if add.overflow{throw DriveError.message("Tamanho total inválido.")}
    known=add.partialValue
   }
   let attrs=try fm.attributesOfFileSystem(forPath:job.destination.path)
   let free=(attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
   let reserve:UInt64=64*1024*1024
   let (needed,overflow)=known.addingReportingOverflow(reserve)
   guard !overflow,free>known,free-known>reserve else{
    let partial = !allKnown
    let neededBytes=overflow ? UInt64.max:needed
    throw DriveError.message(spaceErrorMessage(needed:neededBytes,available:free,partial:partial))
   }
   try fm.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
   stageCreated=true
   for directory in plan.directories{try fm.createDirectory(at:stage.appendingPathComponent(directory),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
   DispatchQueue.main.async{job.name=plan.name;job.count=plan.items.count;job.total=allKnown ? known:nil;job.status="Baixando…"}
   let group=DispatchGroup(),slots=DispatchSemaphore(value:parallel),stateLock=NSLock()
   var failureState:Error?,values=[Int:UInt64](),sizes=[Int:UInt64](),completed=0,last=ProcessInfo.processInfo.systemUptime
   var samples:[(Double,UInt64)]=[(last,0)]
   for (index,item) in plan.items.enumerated(){
    do{try job.control.check()}catch{stateLock.lock();if failureState==nil{failureState=error};stateLock.unlock();break}
    slots.wait();stateLock.lock();let failed=failureState != nil;stateLock.unlock();if failed{slots.signal();break}
    // API access/refresh is prepared serially; file bodies transfer in parallel.
    let request:URLRequest
    do{request=try api.downloadRequest(item.file)}catch{slots.signal();stateLock.lock();if failureState==nil{failureState=error};stateLock.unlock();job.control.cancel();break}
    group.enter()
    DispatchQueue.global(qos:.userInitiated).async {
     defer{slots.signal();group.leave()}
     do {
      let output=stage.appendingPathComponent(item.path);try fm.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
      var succeeded=false
      for attempt in 0..<3 {
       try job.control.check()
       let transfer=DownloadTransfer(output:output,expected:item.exported ? nil:item.file.bytes,control:job.control){value,size in
        stateLock.lock();values[index]=value;if let size=size{sizes[index]=size};let now=ProcessInfo.processInfo.systemUptime
        if now-last > 0.15 {
         let bytes=values.values.reduce(0,+);samples.append((now,bytes));while samples.count>2&&now-samples[0].0>1.5{samples.removeFirst()};let first=samples[0];let rate=bytes>=first.1 ? Double(bytes-first.1)/max(now-first.0,0.001):0;last=now;let total:UInt64?=allKnown ? known:sizes.count==plan.items.count ? sizes.values.reduce(0,+):nil
         DispatchQueue.main.async{job.processed=bytes;job.total=total;job.speed=rate}
        };stateLock.unlock()
       }
       do{var retryRequest=request;retryRequest.setValue("Bearer "+(try GoogleAuth.shared.accessToken()),forHTTPHeaderField:"Authorization");try transfer.download(retryRequest);succeeded=true;break}catch{try job.control.check();if attempt==2{throw error};Thread.sleep(forTimeInterval:Double(attempt+1))}
      }
      guard succeeded else{throw DriveError.message("Não foi possível concluir a transferência.")}
      if !item.exported,let expectedMD5=item.file.md5Checksum {
       let file=try FileHandle(forReadingFrom:output);defer{try? file.close()};var hash=Insecure.MD5()
       while let data=try file.read(upToCount:1024*1024),!data.isEmpty{try job.control.check();hash.update(data:data)}
       let digest=hash.finalize().map{String(format:"%02x",$0)}.joined();guard digest==expectedMD5.lowercased() else{throw DriveError.message("A verificação de integridade falhou: \(item.file.name)")}
      }
      stateLock.lock();completed+=1;let count=completed;stateLock.unlock();DispatchQueue.main.async{job.doneCount=count}
     }catch{stateLock.lock();if failureState==nil{failureState=error};stateLock.unlock();job.control.cancel()}
    }
   }
   group.wait();stateLock.lock();let failure=failureState;let bytes=values.values.reduce(0,+);stateLock.unlock();if let failure=failure{throw failure};try job.control.check()
   var final=job.destination.appendingPathComponent(plan.name);var suffix=2
   while fm.fileExists(atPath:final.path){let url=URL(fileURLWithPath:plan.name);let ext=plan.folder ? "":url.pathExtension;let stem=ext.isEmpty ? plan.name:String(plan.name.dropLast(ext.count+1));final=job.destination.appendingPathComponent(stem+" (\(suffix))"+(ext.isEmpty ? "":"."+ext));suffix+=1}
   // A Drive folder's internal hierarchy is meaningful and is never flattened.
   if plan.folder{try fm.moveItem(at:stage,to:final)}else if let item=plan.items.first{try fm.moveItem(at:stage.appendingPathComponent(item.path),to:final);try? fm.removeItem(at:stage)}else{throw DriveError.message("O link não contém um item para baixar.")}
   let result=final
   DispatchQueue.main.async{job.processed=bytes;job.total=bytes;job.result=result;job.active=false;job.status="Concluído";if UserDefaults.standard.object(forKey:"sounds") as? Bool ?? true{NSSound(named:"Glass")?.play()}}
  }catch{
   if stageCreated{try? fm.removeItem(at:stage)}
   DispatchQueue.main.async{
    if let name=resolvedName{job.name=name}
    job.active=false
    job.failed=true
    job.status=error.localizedDescription
    job.speed=0
   }
  }
 }
}
