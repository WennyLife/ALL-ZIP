import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Content:View {
 @ObservedObject var model:Model
 @ObservedObject var drive=DriveManager.shared
 var body:some View {
  VStack(alignment:.leading,spacing:16){
   HStack{Text("ALL ZIP").font(.system(size:16,weight:.medium));Spacer();Toggle("Sons",isOn:$model.sounds).toggleStyle(.checkbox).font(.system(size:12)).onChange(of:model.sounds){_,value in UserDefaults.standard.set(value,forKey:"sounds")};Button{model.lockClosed.toggle();model.result=nil;model.files=[];model.groups=[];model.status=model.lockClosed ? "Arraste arquivos ou pastas para compactar.":"Arraste seus ZIPs para descompactar."}label:{Label(model.lockClosed ? "Compactar":"Descompactar",systemImage:model.lockClosed ? "lock.fill":"lock.open")}.disabled(model.busy).help(model.lockClosed ? "Cadeado fechado: compactar":"Cadeado aberto: descompactar")}
   Picker("Modo",selection:$model.paneMode){Text("Arquivos ZIP").tag(0);Text("Baixar do Drive").tag(1)}.pickerStyle(.segmented)
   if model.paneMode==0{ArchivePane(model:model)}else{DrivePane(model:model,drive:drive)}
  }.padding(24).frame(width:580).background(Color(nsColor:.windowBackgroundColor))
   .onDrop(of:[UTType.fileURL.identifier],isTargeted:nil){providers in
    guard !model.busy else{return false};let group=DispatchGroup(),mutex=NSLock();var urls:[URL]=[]
    for provider in providers{group.enter();provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil){item,_ in defer{group.leave()};let url=(item as? URL) ?? (item as? Data).flatMap{URL(dataRepresentation:$0,relativeTo:nil)};if let url=url{mutex.lock();urls.append(url);mutex.unlock()}}}
    group.notify(queue:.main){model.paneMode=0;model.add(urls.sorted{$0.lastPathComponent<$1.lastPathComponent});model.beginOperation()};return true
   }
 }
}
struct ArchivePane:View {
 @ObservedObject var model:Model
 var body:some View {
  VStack(alignment:.leading,spacing:16){
   Text(model.lockClosed ? "Compactar arquivos":"Extrair arquivos").font(.system(size:18,weight:.medium))
   if model.files.isEmpty {
    VStack(spacing:12){Image(systemName:model.lockClosed ? "doc.zipper":"folder.badge.plus").font(.system(size:32)).foregroundStyle(.secondary);Text(model.lockClosed ? "Arraste arquivos ou pastas aqui":"Arraste seus arquivos ZIP aqui");Text("A operação começa ao soltar os arquivos.").font(.system(size:11)).foregroundStyle(.secondary);Button("Selecionar arquivos…"){model.pick()}}
     .frame(maxWidth:.infinity,minHeight:130).background(Color(nsColor:.textBackgroundColor)).cornerRadius(7)
   } else {
    HStack{Image(systemName:"doc.zipper").foregroundStyle(.secondary);VStack(alignment:.leading,spacing:4){Text("\(model.files.count) item(ns) selecionado(s)" + (!model.lockClosed && model.groups.count > 1 ? " · \(model.groups.count) pastas identificadas" : ""));Text(model.files.prefix(2).map(\.lastPathComponent).joined(separator:"\n")).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(2)};Spacer();Button("Adicionar…"){model.pick()}.disabled(model.busy);Button{model.files=[];model.groups=[];model.result=nil;model.status="Selecione os arquivos."}label:{Image(systemName:"xmark")}.help("Limpar seleção").disabled(model.busy)}.padding(12).background(Color(nsColor:.textBackgroundColor)).cornerRadius(7)
   }
   if !model.lockClosed && model.groups.count > 1 {
    VStack(alignment:.leading,spacing:6){
     Text("Pastas identificadas:").font(.system(size:12,weight:.medium)).foregroundStyle(.secondary)
     ScrollView{
      VStack(spacing:6){
       ForEach(model.groups){g in
        HStack{
         Image(systemName:"folder.fill").foregroundStyle(Color.accentColor)
         VStack(alignment:.leading,spacing:2){
          Text(g.name).font(.system(size:12,weight:.medium)).lineLimit(1)
          Text("\(g.files.count) parte(s)").font(.system(size:10)).foregroundStyle(.secondary)
         }
         Spacer()
        }.padding(8).background(Color(nsColor:.controlBackgroundColor)).cornerRadius(6)
       }
      }
     }.frame(maxHeight:110)
    }
   } else {
    HStack{Text(model.lockClosed ? "Nome do ZIP:":"Pasta final:").frame(width:86,alignment:.trailing);TextField("Nome",text:$model.folder)}.disabled(model.busy)
   }
   HStack{Text("Salvar em:").frame(width:86,alignment:.trailing);Text(model.destination.lastPathComponent).lineLimit(1);Spacer();Button("Alterar…"){model.chooseDestination()}.disabled(model.busy)}
   if !model.lockClosed{HStack{Text("Repetidos:").frame(width:86,alignment:.trailing);Picker("",selection:$model.policy){Text("Perguntar antes").tag("ask");Text("Manter os dois").tag("both");Text("Preservar o primeiro").tag("skip")}.labelsHidden()}.disabled(model.busy)}
   VStack(alignment:.leading,spacing:7){
    if model.busy || model.result != nil {
     if model.knownTotal || model.result != nil{ShimmerProgress(value:model.progress,active:model.busy);HStack{Text("\(Int(model.progress*100))%").fontWeight(.medium);Text("\(Model.bytes(model.processed)) / \(Model.bytes(model.total))");Spacer();Text(String(format:"%.1f MB/s",model.speed/1_000_000)).monospacedDigit()}.font(.system(size:12))}
     else{ProgressView().progressViewStyle(.linear);Text("Preparando…").font(.system(size:12)).foregroundStyle(.secondary)}
    }
    Text(model.status).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
   }
   Divider()
   HStack{Text("Originais preservados").font(.system(size:11)).foregroundStyle(.secondary);Spacer();if model.busy{Button("Cancelar"){model.cancel()}}else if let result=model.result{Button("Mostrar no Finder"){NSWorkspace.shared.activateFileViewerSelecting([result])}.keyboardShortcut(.defaultAction)}else{Button(model.lockClosed ? "Compactar em ZIP" : (model.groups.count > 1 ? "Extrair as \(model.groups.count) pastas" : "Extrair em uma pasta")){model.beginOperation()}.keyboardShortcut(.defaultAction).disabled(model.files.isEmpty)}}
  }
 }
}
struct DrivePane:View {
 @ObservedObject var model:Model
 @ObservedObject var drive:DriveManager
 var body:some View {
  VStack(alignment:.leading,spacing:14){
   Text("Baixar do Google Drive").font(.system(size:18,weight:.medium))
   Text("Cole os links recebidos no WhatsApp. Um link por linha.").font(.system(size:12)).foregroundStyle(.secondary)
   TextEditor(text:$drive.links).font(.system(size:12)).frame(height:65).padding(5).scrollContentBackground(.hidden).background(Color(nsColor:.textBackgroundColor)).cornerRadius(5).overlay(alignment:.topLeading){if drive.links.isEmpty{Text("Cole aqui os links do Google Drive…").font(.system(size:12)).foregroundStyle(.secondary).padding(10).allowsHitTesting(false)}}.overlay(RoundedRectangle(cornerRadius:5).stroke(Color(nsColor:.separatorColor),lineWidth:1))
   HStack{Text(drive.connected ? "Conta Google conectada":"Conta Google não conectada").font(.system(size:12)).foregroundStyle(.secondary);Spacer();Button(drive.connecting ? "Cancelar conexão":drive.connected ? "Desconectar":"Conectar Google…"){if drive.connecting{drive.cancelConnection()}else if drive.connected{drive.disconnect()}else{drive.connect()}}}
   HStack{Text("Salvar em: \(model.destination.lastPathComponent)");Spacer();Button("Alterar…"){model.chooseDestination()}}
   HStack{Text("Transferências simultâneas");Spacer();Picker("Transferências simultâneas",selection:$drive.parallelDownloads){ForEach(1...10,id:\.self){count in Text("\(count)").tag(count)}}.labelsHidden().frame(width:65)}
   if !drive.jobs.isEmpty{HStack{Text("Downloads").font(.system(size:12,weight:.medium));Spacer();Button{drive.clearCompleted()}label:{Label("Limpar baixados",systemImage:"arrow.uturn.backward")}.help("Remove os downloads concluídos desta lista. Os arquivos são mantidos.").disabled(!drive.jobs.contains{$0.result != nil})};ScrollView{VStack(spacing:10){ForEach(drive.jobs){job in DriveJobRow(job:job,drive:drive)}}}.frame(maxHeight:max(80,min(230,(NSScreen.main?.visibleFrame.height ?? 900)-600)))}
   Text(drive.status).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
   Divider()
   HStack{Text("Download direto · sem ZIP intermediário").font(.system(size:11)).foregroundStyle(.secondary);Spacer();Button("Baixar"){drive.enqueue(destination:model.destination)}.keyboardShortcut(.defaultAction).disabled(drive.links.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !drive.connected)}
  }
 }
}
struct DriveJobRow:View {
 @ObservedObject var job:DriveJob
 let drive:DriveManager
 var body:some View {
  VStack(alignment:.leading,spacing:7){
   HStack{Image(systemName:job.result != nil ? "checkmark.circle":"folder").foregroundStyle(.secondary);Text(job.name).lineLimit(1);Spacer();if let result=job.result{Button("Mostrar"){NSWorkspace.shared.activateFileViewerSelecting([result])}}else if job.active{Button(job.paused ? "Retomar":"Pausar"){drive.pause(job)};Button{drive.cancel(job)}label:{Image(systemName:"xmark")}.help("Cancelar download")}else if job.status=="Na fila"{Button("Cancelar"){drive.cancel(job)}}}
   if job.total != nil || job.result != nil{ShimmerProgress(value:job.fraction,active:job.active && !job.paused)}else if job.active{ProgressView().progressViewStyle(.linear)}
   HStack{if job.total != nil{Text("\(Int(job.fraction*100))%").fontWeight(.medium)};Text(job.total.map{Model.bytes(job.processed)+" / "+Model.bytes($0)} ?? Model.bytes(job.processed));Spacer();if job.active && !job.paused{Text(String(format:"%.1f MB/s",job.speed/1_000_000)).monospacedDigit();if let total=job.total,job.speed>0,job.processed<total{let seconds=Double(total-job.processed)/job.speed;Text(seconds<60 ? "~\(Int(seconds)) s":"~\(Int(seconds/60)) min")}}}.font(.system(size:12)).foregroundStyle(.secondary)
   Text(job.status+(job.count>0 ? " · \(job.doneCount)/\(job.count) arquivos":"")).font(.system(size:11)).foregroundStyle(job.failed ? .red:.secondary).fixedSize(horizontal:false,vertical:true)
  }.padding(12).background(Color(nsColor:.textBackgroundColor)).cornerRadius(7)
 }
}
