import Foundation

final class TransferControl {
 private let condition=NSCondition()
 private var tasks:[ObjectIdentifier:URLSessionTask]=[:]
 private var paused=false
 private var cancelled=false
 func check()throws {condition.lock();defer{condition.unlock()};while paused && !cancelled{condition.wait()};if cancelled{throw DriveError.message("Download cancelado.")}}
 func register(_ task:URLSessionTask)throws {condition.lock();defer{condition.unlock()};if cancelled{throw DriveError.message("Download cancelado.")};tasks[ObjectIdentifier(task)]=task;if !paused{task.resume()}}
 func remove(_ task:URLSessionTask){condition.lock();tasks.removeValue(forKey:ObjectIdentifier(task));condition.unlock()}
 func pause(_ value:Bool){condition.lock();paused=value;for task in tasks.values{if value && task.state == .running{task.suspend()}else if !value && task.state == .suspended{task.resume()}};condition.broadcast();condition.unlock()}
 func cancel(){condition.lock();cancelled=true;for task in tasks.values{task.cancel()};condition.broadcast();condition.unlock()}
}

// Streams response data to the target volume. Range retries reuse the partial file.
final class DownloadTransfer:NSObject,URLSessionDataDelegate {
 let output:URL
 let expected:UInt64?
 let control:TransferControl
 let progress:(UInt64,UInt64?)->Void
 var handle:FileHandle?
 var offset:UInt64=0
 var written:UInt64=0
 var failure:Error?
 var responseSeen=false
 var responseExpected:UInt64?
 var finished=DispatchSemaphore(value:0)
 init(output:URL,expected:UInt64?,control:TransferControl,progress:@escaping(UInt64,UInt64?)->Void){self.output=output;self.expected=expected;self.control=control;self.progress=progress}
 func download(_ request:URLRequest)throws {
  try control.check()
  let fm=FileManager.default
  if !fm.fileExists(atPath:output.path){guard fm.createFile(atPath:output.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw DriveError.message("Não foi possível criar o arquivo de download.")}}
  handle=try FileHandle(forWritingTo:output);offset=try handle!.seekToEnd();written=offset
  var request=request
  request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
  if offset>0{request.setValue("bytes=\(offset)-",forHTTPHeaderField:"Range")}
  let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=60;config.timeoutIntervalForResource=86400;config.httpMaximumConnectionsPerHost=4
  let queue=OperationQueue();queue.maxConcurrentOperationCount=1;queue.qualityOfService = .userInitiated
  let session=URLSession(configuration:config,delegate:self,delegateQueue:queue);let task=session.dataTask(with:request)
  defer{control.remove(task);if task.state != .completed{task.cancel()};session.finishTasksAndInvalidate();try? handle?.close()}
  try control.register(task)
  finished.wait()
  if let failure=failure{throw failure}
  guard responseSeen else{throw DriveError.message("O servidor não entregou o arquivo.")}
  if let expected=expected,expected != written{throw DriveError.message("Download incompleto ou arquivo alterado no Drive.")}
  if let expected=responseExpected,expected != written{throw DriveError.message("A transferência terminou antes de receber todos os bytes.")}
 }
 func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void){
  guard let http=response as? HTTPURLResponse else{failure=DriveError.message("Resposta inválida no download.");completionHandler(.cancel);return}
  guard http.statusCode==200 || http.statusCode==206 else{failure=DriveError.message("O Drive recusou o download (HTTP \(http.statusCode)). Confira acesso, limite de download e conexão.");completionHandler(.cancel);return}
  if http.statusCode==206 {
   guard let range=http.value(forHTTPHeaderField:"Content-Range"),range.hasPrefix("bytes \(offset)-") else{failure=DriveError.message("O servidor retornou uma faixa de bytes inesperada.");completionHandler(.cancel);return}
  } else if offset>0 {
   do{try handle?.truncate(atOffset:0);try handle?.seek(toOffset:0);offset=0;written=0}catch{failure=error;completionHandler(.cancel);return}
  }
  if response.expectedContentLength>=0 {responseExpected=offset+UInt64(response.expectedContentLength)}
  if let expected=expected,let actual=responseExpected,expected != actual{failure=DriveError.message("O tamanho do arquivo mudou no Drive. Adicione o link novamente.");completionHandler(.cancel);return}
  responseSeen=true;progress(written,expected ?? responseExpected);completionHandler(.allow)
 }
 func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data){
  do{if let expected=expected,written+UInt64(data.count)>expected{throw DriveError.message("O download ultrapassou o tamanho informado pelo Drive.")};try handle?.write(contentsOf:data);written+=UInt64(data.count);progress(written,expected ?? responseExpected)}catch{failure=error;dataTask.cancel()}
 }
 func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){if failure==nil{failure=error};finished.signal()}
 func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){
  guard let url=request.url,url.scheme=="https",let host=url.host,host=="www.googleapis.com" || host.hasSuffix(".googleusercontent.com") || host.hasSuffix(".usercontent.google.com") || host=="drive.google.com" else{failure=DriveError.message("O download tentou redirecionar para um endereço inesperado.");completionHandler(nil);return}
  completionHandler(request)
 }
}
