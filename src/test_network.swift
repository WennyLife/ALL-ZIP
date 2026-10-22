import Foundation
import AppKit
let fm=FileManager.default
let base=URL(fileURLWithPath:CommandLine.arguments[1])
let endpoint=CommandLine.arguments[2]
let expected=Data((0..<(256*1024)).map{UInt8($0%251)})
func perform(_ path:String,_ name:String,prefix:Int=0)throws {
 let output=base.appendingPathComponent(name)
 if prefix>0{try expected.prefix(prefix).write(to:output)}
 let transfer=DownloadTransfer(output:output,expected:UInt64(expected.count),control:TransferControl()){_,_ in}
 try transfer.download(URLRequest(url:URL(string:endpoint+path)!))
 assert(try! Data(contentsOf:output)==expected)
}
try perform("/file","normal")
print("APROVADO: download direto íntegro")
try perform("/file","resume",prefix:12345)
print("APROVADO: retomada por HTTP Range")
try perform("/ignore","restart",prefix:12345)
print("APROVADO: servidor ignora Range; arquivo reiniciado sem duplicar bytes")
for path in ["/forbidden","/short"] {
 do{try perform(path,String(path.dropFirst()));fatalError("Aceitou resposta inválida")}
 catch{print("APROVADO: resposta rejeitada \(path)")}
}
let control=TransferControl(),finished=DispatchSemaphore(value:0)
var pauseSucceeded=false
DispatchQueue.global().async {
 do{let t=DownloadTransfer(output:base.appendingPathComponent("pause"),expected:UInt64(expected.count),control:control){_,_ in};try t.download(URLRequest(url:URL(string:endpoint+"/slow")!));pauseSucceeded=true}catch{print(error)};finished.signal()
}
Thread.sleep(forTimeInterval:0.1);control.pause(true)
assert(finished.wait(timeout:.now()+0.3) == .timedOut)
control.pause(false);assert(finished.wait(timeout:.now()+5) == .success && pauseSucceeded)
assert(try! Data(contentsOf:base.appendingPathComponent("pause"))==expected)
print("APROVADO: pausa e retomada de transferência")
let cancel=TransferControl(),group=DispatchGroup(),mutex=NSLock()
var failures=0
for i in 0..<4{group.enter();DispatchQueue.global().async{defer{group.leave()};do{let t=DownloadTransfer(output:base.appendingPathComponent("cancel\(i)"),expected:UInt64(expected.count),control:cancel){_,_ in};try t.download(URLRequest(url:URL(string:endpoint+"/slow")!))}catch{mutex.lock();failures+=1;mutex.unlock()}}}
Thread.sleep(forTimeInterval:0.1);cancel.cancel();assert(group.wait(timeout:.now()+5) == .success && failures==4)
print("APROVADO: cancelamento simultâneo de quatro transferências")
for link in ["https://drive.google.com/drive/folders/Abc_123?usp=drive_link","https://drive.google.com/file/d/Abc_123/view","https://drive.google.com/open?id=Abc_123"]{assert(try! DriveLink.parse(link).id=="Abc_123")}
for link in ["http://drive.google.com/drive/folders/id","https://drive.google.com.evil.test/drive/folders/id","https://example.com/file/d/id"]{do{_ = try DriveLink.parse(link);fatalError("Aceitou host inválido")}catch{}}
assert(safeDriveName("../x") != "../x" && safeDriveName("..") != "..")
print("APROVADO: links e nomes seguros")
let client=try GoogleAuth.parseClient(Data("{\"installed\":{\"client_id\":\"example.apps.googleusercontent.com\"}}".utf8))
assert(client.client_id=="example.apps.googleusercontent.com")
do{_ = try GoogleAuth.parseClient(Data("{\"web\":{\"client_id\":\"x\"}}".utf8));fatalError("Aceitou OAuth web")}catch{}
print("APROVADO: validação da configuração OAuth Desktop")
final class FakeDrive:DriveReading {
 var files:[String:DriveFile]=[:]
 var contents:[String:[DriveFile]]=[:]
 var errors:[String:Error]=[:]
 func metadata(_ link:DriveLink)throws->DriveFile {
  if let err=errors[link.id]{throw err}
  guard let file=files[link.id] else{throw DriveError.message("O link não foi encontrado ou sua conta não tem acesso à pasta.")}
  return file
 }
 func children(_ parent:String,control:TransferControl)throws->[DriveFile]{
  try control.check()
  if let err=errors[parent]{throw err}
  return contents[parent] ?? []
 }
}
func file(_ id:String,_ name:String,_ mime:String="application/octet-stream",shortcut:String?=nil)throws->DriveFile {
 var data:[String:Any] = ["id":id,"name":name,"mimeType":mime,"size":"12","capabilities":["canDownload":true]]
 if let shortcut=shortcut{data["shortcutDetails"]=["targetId":shortcut]}
 return try JSONDecoder().decode(DriveFile.self,from:JSONSerialization.data(withJSONObject:data))
}
let api=FakeDrive();let folder=try file("root","Projeto","application/vnd.google-apps.folder")
api.files["root"]=folder;api.contents["root"]=[try file("a","clip.mov"),try file("b","clip.mov"),try file("sub","Brutos","application/vnd.google-apps.folder")];api.contents["sub"]=[try file("c","take.mov")]
let plan=try makeDrivePlan(api:api,link:DriveLink(id:"root",resourceKey:nil),control:TransferControl())
assert(plan.name=="Projeto" && plan.items.count==3 && plan.items.contains{$0.path=="Brutos/take.mov"} && Set(plan.items.map(\.path)).count==3)
print("APROVADO: estrutura do Drive e nomes repetidos preservados")
api.contents["sub"]=[try file("loop","Loop","application/vnd.google-apps.shortcut",shortcut:"root")]
do{_ = try makeDrivePlan(api:api,link:DriveLink(id:"root",resourceKey:nil),control:TransferControl());fatalError("Aceitou atalho circular")}catch{}
print("APROVADO: atalho circular bloqueado")

// Teste 1: Progresso real de varredura
let progressAPI=FakeDrive()
let pRoot=try file("pRoot","PastaRaiz","application/vnd.google-apps.folder")
progressAPI.files["pRoot"]=pRoot
progressAPI.contents["pRoot"]=[try file("p1","file1.bin"),try file("sub1","SubPasta","application/vnd.google-apps.folder")]
progressAPI.contents["sub1"]=[try file("p2","file2.bin")]
var scanEvents:[DriveScanProgress]=[]
let pPlan=try makeDrivePlan(api:progressAPI,link:DriveLink(id:"pRoot",resourceKey:nil),control:TransferControl(),onProgress:{prog in
 scanEvents.append(prog)
})
assert(pPlan.name=="PastaRaiz")
assert(!scanEvents.isEmpty)
assert(scanEvents.first?.name=="PastaRaiz")
assert(scanEvents.last?.fileCount==2 && scanEvents.last?.folderCount==1 && scanEvents.last?.knownBytes==24)
print("APROVADO: progresso real de varredura sem porcentagem inventada")

// Teste 2: Cancelamento durante a varredura
let cancelCtrl=TransferControl()
cancelCtrl.cancel()
do {
 _=try makeDrivePlan(api:progressAPI,link:DriveLink(id:"pRoot",resourceKey:nil),control:cancelCtrl)
 fatalError("Deveria ter cancelado varredura")
} catch let err as DriveError {
 assert(err.localizedDescription=="Download cancelado.")
 print("APROVADO: cancelamento durante a varredura")
}

// Teste 3: Abortar varredura cedo se total conhecido excede disponível (com reserva de 64MB)
let spaceAPI=FakeDrive()
let sRoot=try file("sRoot","PastaGrande","application/vnd.google-apps.folder")
spaceAPI.files["sRoot"]=sRoot
var bigFiles:[DriveFile]=[]
for i in 0..<2 {
 let data:[String:Any]=["id":"f\(i)","name":"big\(i).bin","mimeType":"application/octet-stream","size":"\(50*1024*1024)","capabilities":["canDownload":true]]
 bigFiles.append(try JSONDecoder().decode(DriveFile.self,from:JSONSerialization.data(withJSONObject:data)))
}
spaceAPI.contents["sRoot"]=bigFiles
do {
 _=try makeDrivePlan(api:spaceAPI,link:DriveLink(id:"sRoot",resourceKey:nil),control:TransferControl(),availableBytes:80*1024*1024)
 fatalError("Deveria ter abortado varredura cedo por falta de espaço")
} catch let err as DriveError {
 let msg=err.localizedDescription
 assert(msg.contains("Espaço insuficiente no destino"))
 assert(msg.contains("pelo menos"))
 assert(msg.contains("necessário"))
 assert(msg.contains("disponível"))
 assert(msg.contains("Alterar"))
 print("APROVADO: abortar varredura cedo se total conhecido excede disponível com reserva")
}

// Teste 4: Consideração estrita da reserva de 64MB
let reserveAPI=FakeDrive()
let rRoot=try file("rRoot","PastaReserva","application/vnd.google-apps.folder")
reserveAPI.files["rRoot"]=rRoot
var rData:[String:Any]=["id":"rf1","name":"reserva.bin","mimeType":"application/octet-stream","size":"\(10*1024*1024)","capabilities":["canDownload":true]]
reserveAPI.contents["rRoot"]=[try JSONDecoder().decode(DriveFile.self,from:JSONSerialization.data(withJSONObject:rData))]
do {
 _=try makeDrivePlan(api:reserveAPI,link:DriveLink(id:"rRoot",resourceKey:nil),control:TransferControl(),availableBytes:50*1024*1024)
 fatalError("Deveria ter rejeitado por causa da reserva de 64MB")
} catch let err as DriveError {
 let msg=err.localizedDescription
 assert(msg.contains("Espaço insuficiente no destino"))
 assert(msg.contains("necessário"))
 assert(msg.contains("disponível"))
 assert(msg.contains("Alterar"))
 print("APROVADO: consideração estrita da reserva de 64MB")
}

// Teste 5: Descendente inacessível identificado sem culpar a raiz e raiz preservada
let failDescAPI=FakeDrive()
let fdRoot=try file("fdRoot","Campanha2026","application/vnd.google-apps.folder")
failDescAPI.files["fdRoot"]=fdRoot
let subFolder=try file("subBrutos","Brutos","application/vnd.google-apps.folder")
failDescAPI.contents["fdRoot"]=[subFolder]
failDescAPI.errors["subBrutos"]=DriveError.message("O link não foi encontrado ou sua conta não tem acesso à pasta.")
var fdProgressName=""
do {
 _=try makeDrivePlan(api:failDescAPI,link:DriveLink(id:"fdRoot",resourceKey:nil),control:TransferControl(),onProgress:{prog in
  fdProgressName=prog.name
 })
 fatalError("Deveria ter falhado no descendente")
} catch let err as DriveError {
 let msg=err.localizedDescription
 assert(msg.contains("subpasta 'Brutos'"))
 assert(!msg.hasPrefix("O link não foi encontrado"))
 assert(fdProgressName=="Campanha2026")
 print("APROVADO: descendente inacessível identificado sem culpar a raiz e raiz preservada")
}

// Teste 6: Atalho quebrado identificado com caminho
let shortcutAPI=FakeDrive()
let scRoot=try file("scRoot","AtalhosRaiz","application/vnd.google-apps.folder")
shortcutAPI.files["scRoot"]=scRoot
shortcutAPI.contents["scRoot"]=[try file("sc1","AtalhoQuebrado","application/vnd.google-apps.shortcut",shortcut:"alvoInexistente")]
do {
 _=try makeDrivePlan(api:shortcutAPI,link:DriveLink(id:"scRoot",resourceKey:nil),control:TransferControl())
 fatalError("Deveria ter falhado no atalho quebrado")
} catch let err as DriveError {
 let msg=err.localizedDescription
 assert(msg.contains("O atalho 'AtalhoQuebrado' aponta para um item não encontrado"))
 print("APROVADO: atalho quebrado identificado com caminho")
}

// Teste 7: Arquivos exportados preservados sem inventar tamanhos desconhecidos
let exportAPI=FakeDrive()
let exRoot=try file("exRoot","DocsRaiz","application/vnd.google-apps.folder")
exportAPI.files["exRoot"]=exRoot
var docData:[String:Any]=["id":"doc1","name":"Anotações","mimeType":"application/vnd.google-apps.document","capabilities":["canDownload":true]]
let gDoc=try JSONDecoder().decode(DriveFile.self,from:JSONSerialization.data(withJSONObject:docData))
exportAPI.contents["exRoot"]=[gDoc]
var exProgressBytes:UInt64=999
let exPlan=try makeDrivePlan(api:exportAPI,link:DriveLink(id:"exRoot",resourceKey:nil),control:TransferControl(),onProgress:{prog in
 exProgressBytes=prog.knownBytes
})
assert(exPlan.items.count==1)
assert(exPlan.items[0].exported==true)
assert(exPlan.items[0].path=="Anotações.docx")
assert(exProgressBytes==0)
print("APROVADO: arquivos exportados preservados sem inventar tamanhos desconhecidos")
