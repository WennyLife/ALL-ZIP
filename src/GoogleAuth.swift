import Foundation
import AppKit
import Security
import CryptoKit
import Darwin

enum DriveError: LocalizedError {
 case message(String)
 var errorDescription:String? {if case .message(let s)=self{return s};return nil}
}
enum GoogleVault {
 static let service="com.lendaii.allzip.google"
 static func read(_ account:String)->Data? {
  var result:CFTypeRef?
  let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
  guard SecItemCopyMatching(q as CFDictionary,&result)==errSecSuccess else{return nil};return result as? Data
 }
 static func write(_ account:String,_ data:Data) throws {
  let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
  let status=SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
  if status==errSecItemNotFound {var add=q;add[kSecValueData as String]=data;add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;guard SecItemAdd(add as CFDictionary,nil)==errSecSuccess else{throw DriveError.message("Não foi possível salvar a conexão no Chaves do macOS.")}}
  else if status != errSecSuccess {throw DriveError.message("Não foi possível atualizar a conexão no Chaves do macOS.")}
 }
 static func remove(_ account:String){let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account];SecItemDelete(q as CFDictionary)}
}
struct GoogleClient:Codable {let client_id:String;let client_secret:String?}
struct GoogleTokens:Codable {let access_token:String;let refresh_token:String?;let expires_in:Double?}
final class GoogleAuth {
 static let shared=GoogleAuth()
 let lock=NSLock()
 var token:String?;var expiry=Date.distantPast
 let connectionLock=NSLock();var connectionCancelled=false
 func cancelConnection(){connectionLock.lock();connectionCancelled=true;connectionLock.unlock()}
 var configured:Bool {client() != nil}
 var connected:Bool {GoogleVault.read("refresh") != nil}
 func client()->GoogleClient? {
  if let d=GoogleVault.read("client"),let c=try? JSONDecoder().decode(GoogleClient.self,from:d){return c}
  if let u=Bundle.main.url(forResource:"GoogleOAuthClient",withExtension:"json"),let d=try? Data(contentsOf:u){return try? Self.parseClient(d)}
  return nil
 }
 static func parseClient(_ data:Data)throws->GoogleClient {
  guard let json=try JSONSerialization.jsonObject(with:data) as? [String:Any],let installed=json["installed"] as? [String:Any],let id=installed["client_id"] as? String,id.hasSuffix(".apps.googleusercontent.com") else{throw DriveError.message("Escolha o JSON OAuth do tipo Aplicativo para computador.")}
  return GoogleClient(client_id:id,client_secret:installed["client_secret"] as? String)
 }
 func importClient(_ url:URL)throws {let client=try Self.parseClient(Data(contentsOf:url));try GoogleVault.write("client",JSONEncoder().encode(client))}
 func disconnect(){lock.lock();defer{lock.unlock()};token=nil;expiry = .distantPast;GoogleVault.remove("refresh")}
 static func synchronous(_ request:URLRequest)throws->(Data,HTTPURLResponse) {
  let sem=DispatchSemaphore(value:0);var result:Result<(Data,HTTPURLResponse),Error>!
  let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=45;config.timeoutIntervalForResource=60
  let session=URLSession(configuration:config)
  let task=session.dataTask(with:request){data,response,error in
   if let error=error{result = .failure(error)}else if let data=data,let response=response as? HTTPURLResponse{result = .success((data,response))}else{result = .failure(DriveError.message("Resposta inválida do servidor."))};sem.signal()
  };task.resume()
  guard sem.wait(timeout:.now()+65) == .success else{task.cancel();session.invalidateAndCancel();throw DriveError.message("O servidor demorou para responder. Tente novamente.")}
  session.finishTasksAndInvalidate();return try result.get()
 }
 func exchange(_ fields:[String:String])throws->GoogleTokens {
  var req=URLRequest(url:URL(string:"https://oauth2.googleapis.com/token")!);req.httpMethod="POST";req.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
  var components=URLComponents();components.queryItems=fields.map{URLQueryItem(name:$0.key,value:$0.value)};req.httpBody=components.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B").data(using:.utf8)
  let (data,response)=try Self.synchronous(req)
  guard response.statusCode==200 else{throw DriveError.message("O Google não autorizou a conexão. Verifique a configuração OAuth e conecte novamente.")}
  return try JSONDecoder().decode(GoogleTokens.self,from:data)
 }
 func accessToken()throws->String {
  lock.lock();defer{lock.unlock()}
  if let token=token,expiry.timeIntervalSinceNow>60{return token}
  guard let client=client(),let data=GoogleVault.read("refresh"),let refresh=String(data:data,encoding:.utf8) else{throw DriveError.message("Conecte sua conta Google antes de adicionar links.")}
  var fields=["client_id":client.client_id,"refresh_token":refresh,"grant_type":"refresh_token"];fields["client_secret"]=client.client_secret
  let reply=try exchange(fields);token=reply.access_token;expiry=Date().addingTimeInterval(reply.expires_in ?? 3600);return reply.access_token
 }
 func connect()throws {
  connectionLock.lock();connectionCancelled=false;connectionLock.unlock()
  guard let client=client() else{throw DriveError.message("A conexão Google do ALL ZIP ainda precisa ser configurada pelo desenvolvedor.")}
  let socketFD=socket(AF_INET,SOCK_STREAM,0);guard socketFD>=0 else{throw DriveError.message("Não foi possível abrir a conexão local.")};defer{close(socketFD)}
  var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_port=0;address.sin_addr=in_addr(s_addr:inet_addr("127.0.0.1"))
  let bound=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){bind(socketFD,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
  guard bound==0,listen(socketFD,4)==0 else{throw DriveError.message("Não foi possível iniciar a autorização local.")}
  var len=socklen_t(MemoryLayout<sockaddr_in>.size);_ = withUnsafeMutablePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(socketFD,$0,&len)}}
  let redirect="http://127.0.0.1:\(UInt16(bigEndian:address.sin_port))/oauth2callback"
  func random()->String{var bytes=[UInt8](repeating:0,count:32);guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else{return UUID().uuidString+UUID().uuidString};return Data(bytes).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")}
  let verifier=random(),state=random();let challenge=Data(SHA256.hash(data:Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
  var url=URLComponents(string:"https://accounts.google.com/o/oauth2/v2/auth")!;url.queryItems=[URLQueryItem(name:"client_id",value:client.client_id),URLQueryItem(name:"redirect_uri",value:redirect),URLQueryItem(name:"response_type",value:"code"),URLQueryItem(name:"scope",value:"https://www.googleapis.com/auth/drive.readonly"),URLQueryItem(name:"access_type",value:"offline"),URLQueryItem(name:"prompt",value:"consent"),URLQueryItem(name:"code_challenge",value:challenge),URLQueryItem(name:"code_challenge_method",value:"S256"),URLQueryItem(name:"state",value:state)]
  DispatchQueue.main.async {NSWorkspace.shared.open(url.url!)}
  let deadline=Date().addingTimeInterval(180)
  while Date()<deadline {
   connectionLock.lock();let cancelled=connectionCancelled;connectionLock.unlock();if cancelled{throw DriveError.message("Conexão Google cancelada.")}
   var pollFD=pollfd(fd:socketFD,events:Int16(POLLIN),revents:0);if poll(&pollFD,1,1000)<=0{continue}
   let connection=accept(socketFD,nil,nil);if connection<0{continue};defer{close(connection)};var noPipe:Int32=1;setsockopt(connection,SOL_SOCKET,SO_NOSIGPIPE,&noPipe,socklen_t(MemoryLayout<Int32>.size))
   var timeout=timeval(tv_sec:5,tv_usec:0);setsockopt(connection,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
   var buffer=[UInt8](repeating:0,count:8192);let count=read(connection,&buffer,buffer.count);if count<=0{continue}
   let request=String(decoding:buffer.prefix(count),as:UTF8.self);let target=request.split(separator:" ").dropFirst().first.map(String.init) ?? ""
   guard let received=URLComponents(string:"http://127.0.0.1"+target),received.path=="/oauth2callback",received.queryItems?.first(where:{$0.name=="state"})?.value==state else{let text="HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";_ = text.withCString{Darwin.write(connection,$0,strlen($0))};continue}
   let html="<html><meta charset='utf-8'><title>ALL ZIP</title><p>Você pode voltar ao ALL ZIP para conferir a conexão.</p></html>";let reply="HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n"+html;_ = reply.withCString{Darwin.write(connection,$0,strlen($0))}
   guard let code=received.queryItems?.first(where:{$0.name=="code"})?.value else{throw DriveError.message("Autorização cancelada no Google.")}
   var fields=["client_id":client.client_id,"code":code,"code_verifier":verifier,"redirect_uri":redirect,"grant_type":"authorization_code"];fields["client_secret"]=client.client_secret
   let tokens=try exchange(fields);guard let refresh=tokens.refresh_token else{throw DriveError.message("O Google não entregou a autorização persistente. Conecte novamente.")}
   try GoogleVault.write("refresh",Data(refresh.utf8));lock.lock();token=tokens.access_token;expiry=Date().addingTimeInterval(tokens.expires_in ?? 3600);lock.unlock();return
  }
  throw DriveError.message("A conexão Google expirou. Clique em Conectar Google para tentar novamente.")
 }
}
