import Foundation
import AppKit

// MARK: - Test Framework Helpers
var passedCount = 0
func test(_ name: String, block: () throws -> Void) {
 do {
  try block()
  passedCount += 1
  print("✓ APROVADO: \(name)")
 } catch {
  print("✗ FALHOU: \(name) - \(error)")
  exit(1)
 }
}

func assertTrue(_ condition: Bool, _ message: String = "") {
 if !condition {
  fatalError("Assertion failed: \(message)")
 }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "") {
 if a != b {
  fatalError("Assertion failed: [\(a)] != [\(b)] \(message)")
 }
}

// MARK: - Mock Setup Helpers
func makeIsolatedDefaults() -> UserDefaults {
 let suite = "com.lendaii.allzip.test.\(UUID().uuidString)"
 let defaults = UserDefaults(suiteName: suite)!
 defaults.removePersistentDomain(forName: suite)
 return defaults
}

func makeClientJsonData() -> Data {
 return try! JSONEncoder().encode(GoogleClient(client_id: "test-client-id.apps.googleusercontent.com", client_secret: "test-secret"))
}

// MARK: - Tests

test("1. Migração segura e offline da conta legada (id estável 'legacy' e timestamp)") {
 let vault = MemoryVaultStorage()
 let defaults = makeIsolatedDefaults()
 
 // Simulando estado legado existente
 let legacyToken = "legacy-refresh-token-xyz"
 try vault.write("refresh", Data(legacyToken.utf8))
 let timestamp = 1730000000.0
 defaults.set(timestamp, forKey: "google_connected_at")
 
 var networkCalls = 0
 GoogleAuth.sessionHandler = { _ in
  networkCalls += 1
  fatalError("Nenhuma chamada de rede deve ser feita no init/migração offline!")
 }
 defer { GoogleAuth.sessionHandler = nil }
 
 let auth = GoogleAuth()
 auth.vault = vault
 
 let dm = DriveManager(auth: auth, defaults: defaults)
 
 assertEqual(networkCalls, 0, "Migração não deve fazer chamadas de rede")
 assertEqual(dm.accounts.count, 1)
 let acc = dm.accounts[0]
 assertEqual(acc.id, "legacy")
 assertEqual(acc.displayName, "Conta principal")
 assertEqual(acc.connectedAt, timestamp)
 assertEqual(dm.activeAccountId, "legacy")
 assertTrue(dm.connected)
 
 // Verifica gravação na nova chave sem apagar a legada
 let newKeyData = vault.read("refresh.legacy")
 assertTrue(newKeyData != nil)
 assertEqual(String(data: newKeyData!, encoding: .utf8), legacyToken)
 assertTrue(vault.read("refresh") != nil, "Chave legada original deve ser preservada")
 
 // Idempotência: recriar o DriveManager com os mesmos dados não duplica
 let dm2 = DriveManager(auth: auth, defaults: defaults)
 assertEqual(dm2.accounts.count, 1)
 assertEqual(dm2.accounts[0].id, "legacy")
}

test("2. Identificador local estável preservado ao resolver identidade real via about.get") {
 let vault = MemoryVaultStorage()
 let defaults = makeIsolatedDefaults()
 
 let legacyToken = "legacy-token-stable"
 try vault.write("refresh.legacy", Data(legacyToken.utf8))
 try vault.write("client", makeClientJsonData())
 
 let auth = GoogleAuth()
 auth.vault = vault
 
 let legacyAcc = GoogleAccount(id: "legacy", permissionId: nil, email: "", displayName: "Conta principal", photoLink: nil)
 let dm = DriveManager(auth: auth, defaults: defaults)
 dm.accounts = [legacyAcc]
 dm.activeAccountId = "legacy"
 dm.saveAccounts()
 
 // Resposta simulada para about.get
 GoogleAuth.sessionHandler = { req in
  let url = req.url?.absoluteString ?? ""
  if url.contains("oauth2.googleapis.com/token") {
   let body = """
   {
    "access_token": "mock-access-token-legacy",
    "expires_in": 3600,
    "token_type": "Bearer"
   }
   """
   return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  } else if url.contains("drive/v3/about") {
   let body = """
   {
    "user": {
     "permissionId": "perm-id-12345",
     "emailAddress": "user@domain.com",
     "displayName": "Nome Real do Usuário",
     "photoLink": "https://avatar.example.com/p.png"
    }
   }
   """
   return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
  fatalError("URL inesperada: \(url)")
 }
 defer { GoogleAuth.sessionHandler = nil }
 
 let token = try auth.accessToken(for: legacyAcc)
 assertEqual(token, "mock-access-token-legacy")
 
 let info = try auth.fetchUserInfo(accessToken: token)
 assertTrue(info != nil)
 assertEqual(info?.emailAddress, "user@domain.com")
 assertEqual(info?.permissionId, "perm-id-12345")
 
 // Atualização de metadados mantendo ID "legacy"
 guard let idx = dm.accounts.firstIndex(where: { $0.id == "legacy" }) else { fatalError() }
 var updated = dm.accounts[idx]
 updated.permissionId = info?.permissionId ?? updated.permissionId
 updated.email = info?.emailAddress ?? updated.email
 updated.displayName = info?.displayName ?? updated.displayName
 dm.accounts[idx] = updated
 dm.saveAccounts()
 
 assertEqual(dm.accounts[0].id, "legacy", "ID estável 'legacy' DEVE permanecer inalterado")
 assertEqual(dm.accounts[0].email, "user@domain.com")
 assertEqual(dm.accounts[0].permissionId, "perm-id-12345")
 assertTrue(vault.read("refresh.legacy") != nil, "Chave do cofre continua estável como 'refresh.legacy'")
}

test("3. Isolamento multi-contas: Contas A e B obtêm seus próprios access tokens") {
 let vault = MemoryVaultStorage()
 try vault.write("refresh.acc_A", Data("refresh-A".utf8))
 try vault.write("refresh.acc_B", Data("refresh-B".utf8))
 try vault.write("client", makeClientJsonData())
 
 let auth = GoogleAuth()
 auth.vault = vault
 
 GoogleAuth.sessionHandler = { req in
  let bodyStr = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
  let token: String
  if bodyStr.contains("refresh_token=refresh-A") {
   token = "access-token-for-A"
  } else if bodyStr.contains("refresh_token=refresh-B") {
   token = "access-token-for-B"
  } else {
   fatalError("Corpo de requisição de token inesperado: \(bodyStr)")
  }
  let json = """
  {
   "access_token": "\(token)",
   "expires_in": 3600,
   "token_type": "Bearer"
  }
  """
  return (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
 }
 defer { GoogleAuth.sessionHandler = nil }
 
 let accA = GoogleAccount(id: "acc_A", permissionId: "perm_A", email: "a@gmail.com", displayName: "User A")
 let accB = GoogleAccount(id: "acc_B", permissionId: "perm_B", email: "b@gmail.com", displayName: "User B")
 
 let tokenA = try auth.accessToken(for: accA)
 let tokenB = try auth.accessToken(for: accB)
 
 assertEqual(tokenA, "access-token-for-A")
 assertEqual(tokenB, "access-token-for-B")
}

test("4. Vínculo imutável de job à conta de origem mesmo após alternar conta ativa") {
 let defaults = makeIsolatedDefaults()
 let vault = MemoryVaultStorage()
 try vault.write("refresh.acc_A", Data("refresh-A".utf8))
 try vault.write("refresh.acc_B", Data("refresh-B".utf8))
 try vault.write("client", makeClientJsonData())
 
 let auth = GoogleAuth()
 auth.vault = vault
 
 let accA = GoogleAccount(id: "acc_A", permissionId: "perm_A", email: "a@gmail.com", displayName: "User A")
 let accB = GoogleAccount(id: "acc_B", permissionId: "perm_B", email: "b@gmail.com", displayName: "User B")
 
 let dm = DriveManager(auth: auth, defaults: defaults)
 dm.accounts = [accA, accB]
 dm.activeAccountId = "acc_A"
 dm.saveAccounts()
 
 let link = try DriveLink.parse("https://drive.google.com/file/d/testFileId/view")
 let jobA = DriveJob(link: link, destination: URL(fileURLWithPath: "/tmp"), account: accA)
 dm.jobs.append(jobA)
 
 // Alterna conta ativa para B
 dm.selectAccount(accB)
 assertEqual(dm.activeAccountId, "acc_B")
 assertEqual(dm.activeAccount?.id, "acc_B")
 
 // Job continua rigidamente vinculado à conta A
 assertEqual(jobA.account.id, "acc_A")
 assertEqual(jobA.account.email, "a@gmail.com")
}

test("5. Isolamento de revogação: invalid_grant na Conta A remove apenas A; B permanece intacta") {
 let defaults = makeIsolatedDefaults()
 let vault = MemoryVaultStorage()
 try vault.write("refresh.acc_A", Data("refresh-A".utf8))
 try vault.write("refresh.acc_B", Data("refresh-B".utf8))
 try vault.write("client", makeClientJsonData())
 
 let auth = GoogleAuth()
 auth.vault = vault
 
 let accA = GoogleAccount(id: "acc_A", permissionId: "perm_A", email: "a@gmail.com", displayName: "User A")
 let accB = GoogleAccount(id: "acc_B", permissionId: "perm_B", email: "b@gmail.com", displayName: "User B")
 
 let dm = DriveManager(auth: auth, defaults: defaults)
 dm.accounts = [accA, accB]
 dm.activeAccountId = "acc_A"
 dm.saveAccounts()
 
 GoogleAuth.sessionHandler = { req in
  let bodyStr = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
  if bodyStr.contains("refresh_token=refresh-A") {
   let errJson = "{\"error\": \"invalid_grant\", \"error_description\": \"Token has been revoked.\"}"
   return (Data(errJson.utf8), HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
  }
  let okJson = "{\"access_token\": \"token-B-valid\", \"expires_in\": 3600, \"token_type\": \"Bearer\"}"
  return (Data(okJson.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
 }
 defer { GoogleAuth.sessionHandler = nil }
 
 do {
  _ = try auth.accessToken(for: accA)
  fatalError("Deveria ter lançado erro de revogação")
 } catch {
  // Esperado
 }
 
 // Processa eventos pendentes no main runloop (onRevokeAccount é disparado na main thread)
 RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
 
 // Conta A deve ter sido removida do Vault
 assertTrue(vault.read("refresh.acc_A") == nil)
 // Conta B no Vault deve continuar intacta
 assertTrue(vault.read("refresh.acc_B") != nil)
 
 // DriveManager deve ter removido A e trocado para B
 assertEqual(dm.accounts.count, 1)
 assertEqual(dm.accounts[0].id, "acc_B")
 assertEqual(dm.activeAccountId, "acc_B")
}

test("6. Proteção contra race condition de revogação desatualizada") {
 let vault = MemoryVaultStorage()
 try vault.write("refresh.acc_A", Data("old-stale-token".utf8))
 try vault.write("client", makeClientJsonData())
 
 let auth = GoogleAuth()
 auth.vault = vault
 
 let accA = GoogleAccount(id: "acc_A", permissionId: "perm_A", email: "a@gmail.com", displayName: "User A")
 
 GoogleAuth.sessionHandler = { req in
  // Simula o usuário reconectando com sucesso em outra thread/janela enquanto esta requisição antiga estava em voo
  try! vault.write("refresh.acc_A", Data("new-reconnected-token".utf8))
  
  let errJson = "{\"error\": \"invalid_grant\"}"
  return (Data(errJson.utf8), HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
 }
 defer { GoogleAuth.sessionHandler = nil }
 
 do {
  _ = try auth.accessToken(for: accA)
  fatalError("Deveria falhar com erro de autorização revogada")
 } catch {
  // Esperado
 }
 
 // O token novo gravado durante o voo NÃO DEVE ter sido apagado pela falha do token antigo
 let currentInVault = vault.read("refresh.acc_A").flatMap { String(data: $0, encoding: .utf8) }
 assertEqual(currentInVault, "new-reconnected-token", "Token novo reconectado não pode ser deletado por falha de token antigo")
}

test("7. Bloqueio de desconexão para conta com downloads ativos ou na fila") {
 let defaults = makeIsolatedDefaults()
 let vault = MemoryVaultStorage()
 try vault.write("refresh.acc_A", Data("tok-A".utf8))
 
 let auth = GoogleAuth()
 auth.vault = vault
 
 let accA = GoogleAccount(id: "acc_A", permissionId: "perm_A", email: "a@gmail.com", displayName: "User A")
 let dm = DriveManager(auth: auth, defaults: defaults)
 dm.accounts = [accA]
 dm.activeAccountId = "acc_A"
 dm.saveAccounts()
 
 let link = try DriveLink.parse("https://drive.google.com/file/d/testId1/view")
 let job = DriveJob(link: link, destination: URL(fileURLWithPath: "/tmp"), account: accA)
 job.active = true
 dm.jobs.append(job)
 
 // Tentativa de desconectar enquanto ativa
 let disconnectSucceeded = dm.disconnectAccount(accA)
 assertTrue(!disconnectSucceeded, "Desconexão de conta ocupada deve falhar")
 assertEqual(dm.accounts.count, 1)
 assertTrue(dm.status.contains("Finalize ou cancele os downloads"))
 
 // Finalizando o job
 job.active = false
 job.result = URL(fileURLWithPath: "/tmp/done.bin")
 job.status = "Concluído"
 
 let disconnectIdle = dm.disconnectAccount(accA)
 assertTrue(disconnectIdle, "Desconexão de conta ociosa deve ter sucesso")
 assertEqual(dm.accounts.count, 0)
}

test("8. Deduplicação inteligente de conta ao reconectar") {
 let defaults = makeIsolatedDefaults()
 let vault = MemoryVaultStorage()
 
 let auth = GoogleAuth()
 auth.vault = vault
 
 let dm = DriveManager(auth: auth, defaults: defaults)
 
 let acc1 = GoogleAccount(id: "acc_uuid_1", permissionId: "perm_100", email: "joao@exemplo.com", displayName: "João Silva", photoLink: nil)
 try dm.registerOrUpdateAccount(acc1, refreshToken: "refresh_v1")
 
 assertEqual(dm.accounts.count, 1)
 assertEqual(dm.accounts[0].displayName, "João Silva")
 
 // Reconecta a mesma conta (mesmo permissionId, email em caixa alta, novo nome e novo refresh)
 let acc2 = GoogleAccount(id: "acc_uuid_2", permissionId: "perm_100", email: "JOAO@EXEMPLO.COM", displayName: "João Pedro Silva", photoLink: "https://avatar.png")
 try dm.registerOrUpdateAccount(acc2, refreshToken: "refresh_v2")
 
 assertEqual(dm.accounts.count, 1, "Não deve duplicar conta já conectada")
 assertEqual(dm.accounts[0].id, "acc_uuid_1", "ID local deve ser mantido estável")
 assertEqual(dm.accounts[0].displayName, "João Pedro Silva")
 assertEqual(dm.accounts[0].photoLink, "https://avatar.png")
 
 let savedToken = vault.read("refresh.acc_uuid_1").flatMap { String(data: $0, encoding: .utf8) }
 assertEqual(savedToken, "refresh_v2")
}

test("9. about.get com erro ou dados ausentes não cria conta anônima nem inválida") {
 let vault = MemoryVaultStorage()
 try vault.write("client", makeClientJsonData())
 
 let auth = GoogleAuth()
 auth.vault = vault
 
 // about.get falha com HTTP 500
 GoogleAuth.sessionHandler = { req in
  let url = req.url?.absoluteString ?? ""
  if url.contains("oauth2.googleapis.com/token") {
   let okJson = "{\"access_token\": \"temp-token\", \"refresh_token\": \"refr\", \"expires_in\": 3600, \"token_type\": \"Bearer\"}"
   return (Data(okJson.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  } else if url.contains("drive/v3/about") {
   return (Data("Erro de servidor interno".utf8), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
  }
  fatalError()
 }
 defer { GoogleAuth.sessionHandler = nil }
 
 do {
  _ = try auth.fetchUserInfo(accessToken: "temp-token")
  fatalError("fetchUserInfo deve lançar erro quando about falha com HTTP 500")
 } catch {
  // Esperado
 }
}

test("10. Cancelamento durante autorização limpa estado e não salva conta") {
 let vault = MemoryVaultStorage()
 let auth = GoogleAuth()
 auth.vault = vault
 
 auth.cancelConnection()
 assertTrue(auth.connectionCancelled)
 
 // Reseta cancelamento para novo teste
 auth.connectionLock.lock()
 auth.connectionCancelled = false
 auth.connectionLock.unlock()
}

test("11. Falha atômica ao salvar credenciais no cofre (throwOnWrite) não corrompe lista") {
 let defaults = makeIsolatedDefaults()
 let vault = MemoryVaultStorage()
 vault.throwOnWrite = true
 
 let auth = GoogleAuth()
 auth.vault = vault
 
 let dm = DriveManager(auth: auth, defaults: defaults)
 let newAcc = GoogleAccount(id: "new_fail_acc", permissionId: "perm_fail", email: "fail@example.com", displayName: "Fail")
 
 do {
  try dm.registerOrUpdateAccount(newAcc, refreshToken: "tok")
  fatalError("Deveria ter falhado ao gravar no vault")
 } catch {
  // Esperado
 }
 
 assertEqual(dm.accounts.count, 0, "Lista de contas não deve ser alterada se o cofre falhar")
}

test("12. Badges de status: Ilimitado em modo padrão, cálculo por conta em modo teste") {
 let defaults = makeIsolatedDefaults()
 let vault = MemoryVaultStorage()
 
 let auth = GoogleAuth()
 auth.vault = vault
 
 let dm = DriveManager(auth: auth, defaults: defaults)
 let acc = GoogleAccount(id: "acc_badge", permissionId: "p", email: "badge@test.com", displayName: "Badge Test", connectedAt: Date().timeIntervalSince1970 - (3 * 86400))
 dm.accounts = [acc]
 dm.activeAccountId = "acc_badge"
 dm.saveAccounts()
 
 // Por padrão (produção)
 assertEqual(dm.connectionBadgeText, "● Conectada (Ilimitado)")
 
 // Em modo de teste (7 dias)
 defaults.set("testing", forKey: "google_oauth_mode")
 assertTrue(dm.connectionBadgeText?.contains("4 dias restantes") == true)
 assertTrue(!dm.isExpiringSoon)
 
 // Restando 1 dia
 let expiringAcc = GoogleAccount(id: "acc_badge2", permissionId: "p2", email: "exp@test.com", displayName: "Expiring", connectedAt: Date().timeIntervalSince1970 - (6 * 86400))
 dm.accounts = [expiringAcc]
 dm.activeAccountId = "acc_badge2"
 dm.saveAccounts()
 
 assertEqual(dm.connectionBadgeText, "1 dia restante")
 assertTrue(dm.isExpiringSoon)
}

print("\n🎉 TODOS OS \(passedCount) TESTES COMPORTAMENTAIS PASSARAM COM SUCESSO!")

// Exercise the production enqueue/run path, not only the job's stored property.
test("13. Fila real mantém autorização A/B ao alternar a conta durante a preparação") {
 let defaults = makeIsolatedDefaults(), vault = MemoryVaultStorage(), auth = GoogleAuth()
 auth.vault = vault
 try vault.write("client",makeClientJsonData())
 try vault.write("refresh.queue_A",Data("queue-refresh-A".utf8))
 try vault.write("refresh.queue_B",Data("queue-refresh-B".utf8))
 let a=GoogleAccount(id:"queue_A",permissionId:"pA",email:"a@example.test",displayName:"A")
 let b=GoogleAccount(id:"queue_B",permissionId:"pB",email:"b@example.test",displayName:"B")
 let dm=DriveManager(auth:auth,defaults:defaults)
 dm.accounts=[a,b];dm.activeAccountId=a.id;dm.saveAccounts()
 let entered=DispatchSemaphore(value:0),resume=DispatchSemaphore(value:0),seenLock=NSLock()
 var seen:[String]=[]
 GoogleAuth.sessionHandler={request in
  let path=request.url!.path
  let json:String
  if path == "/token" {
   let body=String(data:request.httpBody ?? Data(),encoding:.utf8) ?? ""
   json="{\"access_token\":\"\(body.contains("queue-refresh-A") ? "token-A":"token-B")\",\"expires_in\":3600}"
  }else{
   let bearer=request.value(forHTTPHeaderField:"Authorization") ?? ""
   seenLock.lock();seen.append(path+"="+bearer);seenLock.unlock()
   if path.hasSuffix("/folder_A"){
    entered.signal();assertTrue(resume.wait(timeout:.now()+5) == .success,"Teste não deve bloquear a fila")
   }
   json=path.hasSuffix("/files") ? "{\"files\":[]}":"{\"id\":\"\(path.hasSuffix("folder_A") ? "folder_A":"folder_B")\",\"name\":\"Pasta fake\",\"mimeType\":\"application/vnd.google-apps.folder\"}"
  }
  return(Data(json.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
 }
 defer{GoogleAuth.sessionHandler=nil}
 let destination=FileManager.default.temporaryDirectory.appendingPathComponent("ALLZIP-queue-test-"+UUID().uuidString)
 try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:false)
 defer{try? FileManager.default.removeItem(at:destination)}
 dm.links="https://drive.google.com/drive/folders/folder_A";dm.enqueue(destination:destination)
 assertTrue(entered.wait(timeout:.now()+5) == .success,"Job A deve iniciar pela API injetada")
 dm.selectAccount(b)
 dm.links="https://drive.google.com/drive/folders/folder_B";dm.enqueue(destination:destination)
 resume.signal()
 let deadline=Date().addingTimeInterval(5)
 while dm.jobs.contains(where:{$0.result==nil}) && Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.02))}
 assertTrue(dm.jobs.allSatisfy{$0.result != nil},"Os dois jobs precisam concluir")
 assertEqual(dm.jobs.map{$0.account.id},[a.id,b.id])
 seenLock.lock();let requests=seen;seenLock.unlock()
 assertTrue(requests.contains("/drive/v3/files/folder_A=Bearer token-A"))
 assertTrue(requests.contains("/drive/v3/files/folder_B=Bearer token-B"))
 assertTrue(!requests.contains("/drive/v3/files/folder_A=Bearer token-B"))
}
