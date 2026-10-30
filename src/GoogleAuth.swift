import Foundation
import AppKit
import Security
import CryptoKit
import Darwin

enum DriveError: LocalizedError {
 case message(String)
 var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

struct GoogleAccount: Codable, Identifiable, Equatable {
 let id: String
 var permissionId: String?
 var email: String
 var displayName: String
 var photoLink: String?
 var connectedAt: Double?
 
 var title: String {
  let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
  if !cleanName.isEmpty { return cleanName }
  let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
  if !cleanEmail.isEmpty { return cleanEmail }
  return "Conta Google"
 }
 
 var initial: String {
  let s = title
  return s.first.map { String($0).uppercased() } ?? "G"
 }
}

protocol GoogleAuthorizing: AnyObject {
 func accessToken(for account: GoogleAccount) throws -> String
 func disconnect(account: GoogleAccount)
}

protocol VaultStoring: AnyObject {
 func read(_ account: String) -> Data?
 func write(_ account: String, _ data: Data) throws
 func remove(_ account: String)
}

final class KeychainVaultStorage: VaultStoring {
 let service = "com.lendaii.allzip.google"
 func read(_ account: String) -> Data? {
  var result: CFTypeRef?
  let q: [String: Any] = [
   kSecClass as String: kSecClassGenericPassword,
   kSecAttrService as String: service,
   kSecAttrAccount as String: account,
   kSecReturnData as String: true,
   kSecMatchLimit as String: kSecMatchLimitOne
  ]
  guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
  return result as? Data
 }
 func write(_ account: String, _ data: Data) throws {
  let q: [String: Any] = [
   kSecClass as String: kSecClassGenericPassword,
   kSecAttrService as String: service,
   kSecAttrAccount as String: account
  ]
  let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
  if status == errSecItemNotFound {
   var add = q
   add[kSecValueData as String] = data
   add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
   guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
    throw DriveError.message("Não foi possível salvar a conexão no Chaves do macOS.")
   }
  } else if status != errSecSuccess {
   throw DriveError.message("Não foi possível atualizar a conexão no Chaves do macOS.")
  }
 }
 func remove(_ account: String) {
  let q: [String: Any] = [
   kSecClass as String: kSecClassGenericPassword,
   kSecAttrService as String: service,
   kSecAttrAccount as String: account
  ]
  SecItemDelete(q as CFDictionary)
 }
}

final class MemoryVaultStorage: VaultStoring {
 var storage: [String: Data] = [:]
 var throwOnWrite = false
 func read(_ account: String) -> Data? { storage[account] }
 func write(_ account: String, _ data: Data) throws {
  if throwOnWrite { throw DriveError.message("Falha simulada de gravação no Vault.") }
  storage[account] = data
 }
 func remove(_ account: String) { storage.removeValue(forKey: account) }
}

enum GoogleVault {
 static var current: VaultStoring { GoogleAuth.shared.vault }
 static func read(_ account: String) -> Data? { current.read(account) }
 static func write(_ account: String, _ data: Data) throws { try current.write(account, data) }
 static func remove(_ account: String) { current.remove(account) }
}

struct GoogleClient: Codable { let client_id: String; let client_secret: String? }
struct GoogleTokens: Codable { let access_token: String; let refresh_token: String?; let expires_in: Double? }

struct CachedToken {
 let token: String
 let expiry: Date
}

struct AuthExchangeError: Error {
 let isInvalidGrant: Bool
 let underlying: Error
}

struct DriveAboutUser: Decodable {
 struct User: Decodable {
  let displayName: String?
  let emailAddress: String?
  let permissionId: String?
  let photoLink: String?
 }
 let user: User?
}

struct ConnectedAccountResult {
 let account: GoogleAccount
 let refreshToken: String
}

final class GoogleAuth: GoogleAuthorizing {
 static let shared = GoogleAuth()
 var vault: VaultStoring = KeychainVaultStorage()
 static var sessionHandler: ((URLRequest) throws -> (Data, HTTPURLResponse))?
 
 let lock = NSLock()
 private var tokens: [String: CachedToken] = [:]
 private var refreshLocks: [String: NSLock] = [:]
 
 var onRevoke: (() -> Void)?
 var onRevokeAccount: ((GoogleAccount) -> Void)?
 
 let connectionLock = NSLock()
 var connectionCancelled = false
 func cancelConnection() {
  connectionLock.lock()
  connectionCancelled = true
  connectionLock.unlock()
 }
 
 private func lockForAccount(_ id: String) -> NSLock {
  lock.lock()
  defer { lock.unlock() }
  if let existing = refreshLocks[id] { return existing }
  let newLock = NSLock()
  refreshLocks[id] = newLock
  return newLock
 }
 
 var configured: Bool { client() != nil }
 var connected: Bool {
  if vault.read("refresh") != nil || vault.read("refresh.legacy") != nil { return true }
  if let data = UserDefaults.standard.data(forKey: "google_accounts_list"),
     let accs = try? JSONDecoder().decode([GoogleAccount].self, from: data),
     !accs.isEmpty {
   return accs.contains { vault.read("refresh." + $0.id) != nil }
  }
  return false
 }
 
 func client() -> GoogleClient? {
  if let d = vault.read("client"), let c = try? JSONDecoder().decode(GoogleClient.self, from: d) { return c }
  if let u = Bundle.main.url(forResource: "GoogleOAuthClient", withExtension: "json"), let d = try? Data(contentsOf: u) {
   return try? Self.parseClient(d)
  }
  return nil
 }
 
 static func parseClient(_ data: Data) throws -> GoogleClient {
  guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let installed = json["installed"] as? [String: Any],
        let id = installed["client_id"] as? String,
        id.hasSuffix(".apps.googleusercontent.com") else {
   throw DriveError.message("Escolha o JSON OAuth do tipo Aplicativo para computador.")
  }
  return GoogleClient(client_id: id, client_secret: installed["client_secret"] as? String)
 }
 
 func importClient(_ url: URL) throws {
  let client = try Self.parseClient(Data(contentsOf: url))
  try vault.write("client", JSONEncoder().encode(client))
 }
 
 func readRefreshToken(for accountId: String) -> Data? {
  if let d = vault.read("refresh." + accountId) { return d }
  if accountId == "legacy", let d = vault.read("refresh") { return d }
  return nil
 }
 
 func disconnect(account: GoogleAccount) {
  lock.lock()
  tokens.removeValue(forKey: account.id)
  lock.unlock()
  vault.remove("refresh." + account.id)
  if account.id == "legacy" {
   vault.remove("refresh")
  }
 }
 
 func disconnect() {
  lock.lock()
  tokens.removeAll()
  lock.unlock()
  vault.remove("refresh")
  vault.remove("refresh.legacy")
  UserDefaults.standard.removeObject(forKey: "google_connected_at")
 }
 
 static func synchronous(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
  if let handler = sessionHandler {
   return try handler(request)
  }
  let sem = DispatchSemaphore(value: 0)
  var result: Result<(Data, HTTPURLResponse), Error>!
  let config = URLSessionConfiguration.ephemeral
  config.timeoutIntervalForRequest = 45
  config.timeoutIntervalForResource = 60
  let session = URLSession(configuration: config)
  let task = session.dataTask(with: request) { data, response, error in
   if let error = error { result = .failure(error) }
   else if let data = data, let response = response as? HTTPURLResponse { result = .success((data, response)) }
   else { result = .failure(DriveError.message("Resposta inválida do servidor.")) }
   sem.signal()
  }
  task.resume()
  guard sem.wait(timeout: .now() + 65) == .success else {
   task.cancel()
   session.invalidateAndCancel()
   throw DriveError.message("O servidor demorou para responder. Tente novamente.")
  }
  session.finishTasksAndInvalidate()
  return try result.get()
 }
 
 func exchange(_ fields: [String: String]) throws -> GoogleTokens {
  var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
  req.httpMethod = "POST"
  req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
  var components = URLComponents()
  components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
  req.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
  
  let data: Data
  let response: HTTPURLResponse
  do {
   let r = try Self.synchronous(req)
   data = r.0
   response = r.1
  } catch {
   throw AuthExchangeError(isInvalidGrant: false, underlying: error)
  }
  
  if response.statusCode == 200 {
   do {
    return try JSONDecoder().decode(GoogleTokens.self, from: data)
   } catch {
    throw AuthExchangeError(isInvalidGrant: false, underlying: DriveError.message("Resposta de autenticação inválida do Google."))
   }
  }
  
  var isInvalid = false
  if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
     let err = json["error"] as? String, err == "invalid_grant" {
   isInvalid = true
  }
  
  let msg = isInvalid ? "O Google revogou a autorização da conta." : "O Google não autorizou a conexão (HTTP \(response.statusCode))."
  throw AuthExchangeError(isInvalidGrant: isInvalid, underlying: DriveError.message(msg))
 }
 
 func accessToken(for account: GoogleAccount) throws -> String {
  // Fast path: check in-memory cache
  lock.lock()
  if let cached = tokens[account.id], cached.expiry.timeIntervalSinceNow > 60 {
   lock.unlock()
   return cached.token
  }
  lock.unlock()
  
  // Coalesce and serialize refreshes per account
  let accountLock = lockForAccount(account.id)
  accountLock.lock()
  defer { accountLock.unlock() }
  
  // Double-check cache in case another thread refreshed while waiting
  lock.lock()
  if let cached = tokens[account.id], cached.expiry.timeIntervalSinceNow > 60 {
   lock.unlock()
   return cached.token
  }
  lock.unlock()
  
  guard let client = client() else {
   throw DriveError.message("A conexão Google do ALL ZIP ainda precisa ser configurada pelo desenvolvedor.")
  }
  
  guard let data = readRefreshToken(for: account.id), let refresh = String(data: data, encoding: .utf8) else {
   throw DriveError.message("Conecte sua conta Google antes de adicionar links.")
  }
  
  var fields = [
   "client_id": client.client_id,
   "refresh_token": refresh,
   "grant_type": "refresh_token"
  ]
  fields["client_secret"] = client.client_secret
  
  do {
   let reply = try exchange(fields)
   lock.lock()
   tokens[account.id] = CachedToken(token: reply.access_token, expiry: Date().addingTimeInterval(reply.expires_in ?? 3600))
   lock.unlock()
   return reply.access_token
  } catch let error as AuthExchangeError {
   if error.isInvalidGrant {
    // Only remove refresh token if current token in vault is STILL the token that failed!
    let currentInVault = readRefreshToken(for: account.id).flatMap { String(data: $0, encoding: .utf8) }
    if currentInVault == refresh {
     lock.lock()
     tokens.removeValue(forKey: account.id)
     lock.unlock()
     vault.remove("refresh." + account.id)
     if account.id == "legacy" {
      vault.remove("refresh")
     }
     DispatchQueue.main.async {
      self.onRevokeAccount?(account)
      self.onRevoke?()
     }
    }
    throw DriveError.message("A autorização da conta '\(account.title)' expirou ou foi cancelada no Google. Conecte novamente.")
   }
   // Transient error (5xx, timeout, etc.) -> DO NOT delete refresh token!
   throw error.underlying
  } catch {
   throw error
  }
 }
 
 func accessToken() throws -> String {
  let fallback = GoogleAccount(id: "legacy", permissionId: nil, email: "", displayName: "")
  return try accessToken(for: fallback)
 }
 
 func fetchUserInfo(accessToken: String) throws -> DriveAboutUser.User? {
  var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(displayName,emailAddress,permissionId,photoLink)")!)
  req.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
  let (data, response) = try Self.synchronous(req)
  guard response.statusCode == 200 else {
   throw DriveError.message("Não foi possível obter dados do perfil Google (HTTP \(response.statusCode)).")
  }
  let res = try JSONDecoder().decode(DriveAboutUser.self, from: data)
  return res.user
 }
 
 func connect() throws -> ConnectedAccountResult {
  connectionLock.lock(); connectionCancelled = false; connectionLock.unlock()
  guard let client = client() else {
   throw DriveError.message("A conexão Google do ALL ZIP ainda precisa ser configurada pelo desenvolvedor.")
  }
  
  let socketFD = socket(AF_INET, SOCK_STREAM, 0)
  guard socketFD >= 0 else { throw DriveError.message("Não foi possível abrir a conexão local.") }
  defer { close(socketFD) }
  
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = 0
  address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
  let bound = withUnsafePointer(to: &address) {
   $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
  }
  guard bound == 0, listen(socketFD, 4) == 0 else { throw DriveError.message("Não foi possível iniciar a autorização local.") }
  
  var len = socklen_t(MemoryLayout<sockaddr_in>.size)
  _ = withUnsafeMutablePointer(to: &address) {
   $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &len) }
  }
  
  let redirect = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/oauth2callback"
  
  func random() -> String {
   var bytes = [UInt8](repeating: 0, count: 32)
   guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
    return UUID().uuidString + UUID().uuidString
   }
   return Data(bytes).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  }
  
  let verifier = random(), state = random()
  let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
   .replacingOccurrences(of: "+", with: "-")
   .replacingOccurrences(of: "/", with: "_")
   .replacingOccurrences(of: "=", with: "")
  
  var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
  url.queryItems = [
   URLQueryItem(name: "client_id", value: client.client_id),
   URLQueryItem(name: "redirect_uri", value: redirect),
   URLQueryItem(name: "response_type", value: "code"),
   URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.readonly"),
   URLQueryItem(name: "access_type", value: "offline"),
   URLQueryItem(name: "prompt", value: "select_account consent"),
   URLQueryItem(name: "code_challenge", value: challenge),
   URLQueryItem(name: "code_challenge_method", value: "S256"),
   URLQueryItem(name: "state", value: state)
  ]
  
  DispatchQueue.main.async { NSWorkspace.shared.open(url.url!) }
  let deadline = Date().addingTimeInterval(180)
  
  while Date() < deadline {
   connectionLock.lock(); let cancelled = connectionCancelled; connectionLock.unlock()
   if cancelled { throw DriveError.message("Conexão Google cancelada.") }
   var pollFD = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
   if poll(&pollFD, 1, 1000) <= 0 { continue }
   let connection = accept(socketFD, nil, nil)
   if connection < 0 { continue }
   defer { close(connection) }
   var noPipe: Int32 = 1
   setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
   var timeout = timeval(tv_sec: 5, tv_usec: 0)
   setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
   var buffer = [UInt8](repeating: 0, count: 8192)
   let count = read(connection, &buffer, buffer.count)
   if count <= 0 { continue }
   let request = String(decoding: buffer.prefix(count), as: UTF8.self)
   let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
   guard let received = URLComponents(string: "http://127.0.0.1" + target),
         received.path == "/oauth2callback",
         received.queryItems?.first(where: { $0.name == "state" })?.value == state else {
    let text = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
    _ = text.withCString { Darwin.write(connection, $0, strlen($0)) }
    continue
   }
   let html = "<html><meta charset='utf-8'><title>ALL ZIP</title><p>Você pode voltar ao ALL ZIP para conferir a conexão.</p></html>"
   let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
   _ = reply.withCString { Darwin.write(connection, $0, strlen($0)) }
   
   guard let code = received.queryItems?.first(where: { $0.name == "code" })?.value else {
    throw DriveError.message("Autorização cancelada no Google.")
   }
   
   // Check cancellation before exchange
   connectionLock.lock(); let cancelledBeforeExchange = connectionCancelled; connectionLock.unlock()
   if cancelledBeforeExchange { throw DriveError.message("Conexão Google cancelada.") }
   
   var fields = [
    "client_id": client.client_id,
    "code": code,
    "code_verifier": verifier,
    "redirect_uri": redirect,
    "grant_type": "authorization_code"
   ]
   fields["client_secret"] = client.client_secret
   
   let tokens = try exchange(fields)
   guard let refresh = tokens.refresh_token else {
    throw DriveError.message("O Google não entregou a autorização persistente. Conecte novamente.")
   }
   
   // Check cancellation after exchange
   connectionLock.lock(); let cancelledAfterExchange = connectionCancelled; connectionLock.unlock()
   if cancelledAfterExchange { throw DriveError.message("Conexão Google cancelada.") }
   
   // Verifiable identity REQUIRED for new authorization
   guard let userInfo = try? fetchUserInfo(accessToken: tokens.access_token),
         (userInfo.permissionId != nil || (userInfo.emailAddress != nil && !userInfo.emailAddress!.isEmpty)) else {
    throw DriveError.message("Não foi possível verificar a identidade da conta no Google. Tente novamente.")
   }
   
   // Check cancellation after fetchUserInfo
   connectionLock.lock(); let cancelledAfterInfo = connectionCancelled; connectionLock.unlock()
   if cancelledAfterInfo { throw DriveError.message("Conexão Google cancelada.") }
   
   let email = userInfo.emailAddress ?? ""
   let name = userInfo.displayName ?? email
   let permissionId = userInfo.permissionId
   let photoLink = userInfo.photoLink
   
   let tempAccount = GoogleAccount(
    id: UUID().uuidString,
    permissionId: permissionId,
    email: email,
    displayName: name,
    photoLink: photoLink,
    connectedAt: Date().timeIntervalSince1970
   )
   return ConnectedAccountResult(account: tempAccount, refreshToken: refresh)
  }
  throw DriveError.message("A conexão Google expirou. Clique em Conectar Google para tentar novamente.")
 }
}
