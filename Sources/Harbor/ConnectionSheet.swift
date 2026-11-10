import SwiftUI
import HarborCore

struct ConnectionSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let profile: ConnectionProfile?
    @State private var draft = ConnectionProfile()
    @State private var password = ""
    @State private var port = "3306"
    @State private var testing = false
    @State private var status = ""
    @State private var succeeded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "cylinder.split.1x2.fill").font(.system(size: 30)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) { Text(profile == nil ? "新建 MySQL 连接" : "编辑 MySQL 连接").font(.title3.weight(.semibold)); Text("保存连接，下次双击即可打开。").foregroundStyle(.secondary) }
            }
            Form {
                TextField("连接名称", text: $draft.name)
                TextField("主机地址", text: $draft.host)
                TextField("端口", text: $port)
                TextField("用户名", text: $draft.username)
                SecureField("密码", text: $password)
                TextField("默认数据库（可选）", text: $draft.database)
                Picker("TLS", selection: $draft.tls) { ForEach(TLSMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                Toggle("将密码保存到 macOS 钥匙串", isOn: $draft.rememberPassword)
            }.textFieldStyle(.roundedBorder).disabled(testing)
            HStack {
                if testing { ProgressView().controlSize(.small) }
                Text(status.isEmpty ? "TCP/IP · MySQL 5.7 / 8.x / 9.x" : status)
                    .font(.caption).foregroundStyle(status.isEmpty ? Color.secondary : succeeded ? Color.green : Color.red).textSelection(.enabled)
            }.frame(minHeight: 24)
            Divider()
            HStack {
                Button("测试连接") { test() }.disabled(testing)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.disabled(testing)
                Button("保存") { save(connect: false) }.disabled(testing)
                Button("保存并连接") { save(connect: true) }.buttonStyle(.borderedProminent).disabled(testing || model.busy)
            }
        }.padding(25).frame(width: 470).interactiveDismissDisabled(testing)
        .onAppear {
            if let profile { draft = profile; port = String(profile.port); do { password = try model.password(for: profile) } catch { status = error.localizedDescription } }
        }
    }
    private func validated() throws -> ConnectionProfile {
        var p = draft; p.host = p.host.trimmingCharacters(in: .whitespacesAndNewlines); p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(port) else { throw HarborError.message("端口必须是数字。") }
        p.port = number; try p.validate(); return p
    }
    private func save(connect: Bool) {
        do { let p = try validated(); try model.saveProfile(p, password: password); dismiss(); if connect { model.connect(p, password: password) } }
        catch { status = error.localizedDescription; succeeded = false }
    }
    private func test() {
        do {
            let p = try validated(), secret = password; testing = true; status = "正在连接…"; succeeded = false
            Task {
                let session = MySQLSession()
                do { let version = try await session.connect(p, password: secret); status = "连接成功 · MySQL \(version)"; succeeded = true }
                catch { status = error.localizedDescription; succeeded = false }
                await session.shutdown(); testing = false
            }
        } catch { status = error.localizedDescription; succeeded = false }
    }
}
