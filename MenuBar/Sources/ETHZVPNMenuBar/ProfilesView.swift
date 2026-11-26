import SwiftUI

struct ProfilesView: View {
    let onDone: () -> Void
    @State private var store = ProfileStore.shared
    @State private var editor: EditorRequest?
    @State private var pendingDelete: VPNProfile?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                Text("ETHZ VPN").font(.title2.bold())
                Text("One click to the ETH network, secured with Touch ID")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 20)

            if store.profiles.isEmpty {
                ContentUnavailableView("No profiles yet", systemImage: "person.crop.circle.badge.plus",
                                       description: Text("Add your ETH account to get started."))
                    .frame(height: 160)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.profiles) { profile in
                            if profile.id != store.profiles.first?.id { Divider().padding(.leading, 50) }
                            row(profile).padding(.horizontal, 14).padding(.vertical, 10)
                        }
                    }
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("Add Profile", systemImage: "plus") { editor = EditorRequest(profile: nil) }
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editor) { request in
            ProfileEditView(profile: request.profile, isDuplicate: request.isDuplicate) { editor = nil }
        }
        .confirmationDialog("Delete \(pendingDelete?.displayName ?? "")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let profile = pendingDelete { store.delete(profile) }
            }
        } message: {
            Text("The saved password and OTP secret are removed from the Keychain.")
        }
    }

    private func row(_ profile: VPNProfile) -> some View {
        let isDefault = store.activeProfile?.id == profile.id
        return HStack(spacing: 10) {
            Image(systemName: isDefault ? "star.circle.fill" : "person.circle")
                .font(.title2)
                .foregroundStyle(isDefault ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName).fontWeight(.medium)
                Text("\(profile.username)@\(profile.realm)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !isDefault {
                Button("Make Default") { store.activeProfileID = profile.id }
                    .controlSize(.small)
            }
            Menu {
                Button("Edit", systemImage: "pencil") { editor = EditorRequest(profile: profile) }
                Button("Duplicate", systemImage: "plus.square.on.square") { editor = EditorRequest(profile: profile, isDuplicate: true) }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = profile }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

private struct EditorRequest: Identifiable {
    let id = UUID()
    let profile: VPNProfile?
    var isDuplicate = false
}

// MARK: - Add / edit

struct ProfileEditView: View {
    @State private var vm: ProfileEditViewModel
    let onDone: () -> Void

    init(profile: VPNProfile?, isDuplicate: Bool = false, onDone: @escaping () -> Void) {
        _vm = State(initialValue: ProfileEditViewModel(profile: profile, isDuplicate: isDuplicate))
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $vm.displayName, prompt: Text("Student, Staff"))
                    TextField("Username", text: $vm.username, prompt: Text("ETH username, without @ethz.ch"))
                    SecretField(label: "WLAN Password", prompt: vm.secretPrompt("Network password"), text: $vm.password)
                    SecretField(label: "OTP Secret", prompt: vm.secretPrompt("Setup key or otpauth:// link"), text: $vm.otpSecret)
                } header: {
                    Text(vm.title).font(.headline)
                }
                Section("Advanced") {
                    TextField("Realm", text: $vm.realm, prompt: Text(AppConstants.defaultRealm))
                    TextField("Server", text: $vm.server, prompt: Text(AppConstants.defaultServer))
                }
            }
            .formStyle(.grouped)

            HStack {
                if vm.isSaving { ProgressView().controlSize(.small) }
                if let error = vm.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Save") { vm.save(completion: onDone) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(vm.isSaving)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
    }
}

private struct SecretField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 6) {
            if revealed {
                TextField(label, text: $text, prompt: Text(prompt))
            } else {
                SecureField(label, text: $text, prompt: Text(prompt))
            }
            Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }
}

@Observable final class ProfileEditViewModel {
    var displayName: String
    var username: String
    var password = ""
    var otpSecret = ""
    var realm: String
    var server: String
    var isSaving = false
    var errorMessage: String?
    let title: String

    /// nil when creating; secrets are never loaded, blank fields keep the saved ones.
    private let profileID: String?
    private let source: VPNProfile?

    init(profile: VPNProfile?, isDuplicate: Bool) {
        profileID   = isDuplicate ? nil : profile?.id
        source      = profile
        title       = isDuplicate ? "Duplicate Profile" : (profile == nil ? "New Profile" : "Edit Profile")
        displayName = profile.map { isDuplicate ? "\($0.displayName) Copy" : $0.displayName } ?? ""
        username    = profile?.username ?? ""
        realm       = profile?.realm ?? ""
        server      = profile?.server ?? ""
    }

    func secretPrompt(_ placeholder: String) -> String {
        source == nil ? placeholder : "Saved, leave blank to keep"
    }

    func save(completion: @escaping () -> Void) {
        errorMessage = nil
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = trim(displayName), user = trim(username)
        guard !name.isEmpty else { errorMessage = "Name is required."; return }
        guard !user.isEmpty else { errorMessage = "Username is required."; return }

        let store = ProfileStore.shared
        var newPassword = password.isEmpty ? nil : password
        var newToken: String?
        do {
            newToken = trim(otpSecret).isEmpty ? nil : try OTPSecret.normalize(otpSecret)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if profileID == nil {
            if let source {
                newPassword = newPassword ?? store.password(for: source)
                newToken = newToken ?? store.token(for: source)
            }
            guard newPassword != nil else { errorMessage = "Password is required."; return }
            guard newToken != nil else { errorMessage = "OTP secret is required."; return }
        }

        let id = profileID ?? ProfileStore.makeID(from: name)
        if profileID == nil, store.profiles.contains(where: { $0.id == id }) {
            errorMessage = "A profile with this name already exists."
            return
        }
        let profile = VPNProfile(id: id, displayName: name, username: user,
                                 realm: trim(realm).isEmpty ? AppConstants.defaultRealm : trim(realm),
                                 server: trim(server).isEmpty ? AppConstants.defaultServer : trim(server))
        do {
            try store.upsert(profile, password: newPassword, token: newToken)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        guard !PrivilegedHelper.isInstalled() else { completion(); return }
        isSaving = true
        PrivilegedHelper.install { [weak self] result in
            self?.isSaving = false
            switch result {
            case .success: completion()
            case .failure(let error): self?.errorMessage = error.localizedDescription
            }
        }
    }
}
