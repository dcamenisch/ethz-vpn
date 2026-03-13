import SwiftUI

// MARK: - Profile list (root)

struct ProfilesView: View {
    @State private var store = ProfileStore.shared
    @State private var editingProfile: VPNProfile? = nil
    @State private var duplicatingProfile: VPNProfile? = nil
    @State private var isAdding = false
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Image(systemName: "shield.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                Text("ETHZ VPN — Profiles")
                    .font(.title2.bold())
                Text("Manage your VPN configurations.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            if store.profiles.isEmpty {
                Text("No profiles yet. Add one below.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .padding()
            } else {
                List {
                    ForEach(store.profiles) { profile in
                        ProfileRow(
                            profile: profile,
                            isActive: store.activeProfileID == profile.id,
                            onEdit: { editingProfile = profile },
                            onDuplicate: { duplicatingProfile = profile },
                            onDelete: { store.delete(profile) },
                            onSetActive: { store.activeProfileID = profile.id }
                        )
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 120, maxHeight: 260)
            }

            Divider()

            HStack {
                Button("Add Profile") { isAdding = true }
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480)
        .sheet(item: $editingProfile) { profile in
            ProfileEditView(profile: profile, onDone: { editingProfile = nil })
        }
        .sheet(item: $duplicatingProfile) { profile in
            ProfileEditView(profile: profile, isDuplicate: true, onDone: { duplicatingProfile = nil })
        }
        .sheet(isPresented: $isAdding) {
            ProfileEditView(profile: nil, onDone: { isAdding = false })
        }
    }
}

// MARK: - Single row

private struct ProfileRow: View {
    let profile: VPNProfile
    let isActive: Bool
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onSetActive: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.displayName).fontWeight(.medium)
                    if isActive {
                        Text("default")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(.tint)
                            .clipShape(Capsule())
                    }
                }
                Text("\(profile.username) · \(profile.realm)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isActive {
                Button("Set Default") { onSetActive() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .font(.caption)
            }
            Button(action: onDuplicate) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .help("Duplicate profile")
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Add / Edit sheet

struct ProfileEditView: View {
    let onDone: () -> Void
    @State private var vm: ProfileEditViewModel

    /// - Parameters:
    ///   - profile: nil → new, non-nil → edit (or duplicate when isDuplicate=true)
    ///   - isDuplicate: when true, copies data from profile but generates a fresh id
    init(profile: VPNProfile?, isDuplicate: Bool = false, onDone: @escaping () -> Void) {
        self.onDone = onDone
        _vm = State(initialValue: ProfileEditViewModel(profile: profile, isDuplicate: isDuplicate))
    }

    var body: some View {
        ProfileEditFormView(vm: vm, onDone: onDone)
    }
}

struct ProfileEditFormView: View {
    @Bindable var vm: ProfileEditViewModel
    let onDone: () -> Void

    private enum Field: Hashable { case name, username, password, otp, realm }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(spacing: 20) {
            Text(vm.title)
                .font(.title3.bold())

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("e.g. Student, Staff", text: $vm.displayName)
                        .focused($focus, equals: .name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Username").gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("without @ethz.ch", text: $vm.username)
                            .focused($focus, equals: .username)
                            .textFieldStyle(.roundedBorder)
                        Text("without @ethz.ch")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("WLAN Password").gridColumnAlignment(.trailing)
                    HStack(spacing: 4) {
                        Group {
                            if vm.showPassword {
                                TextField("Password", text: $vm.password)
                                    .focused($focus, equals: .password)
                            } else {
                                SecureField("Password", text: $vm.password)
                                    .focused($focus, equals: .password)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        Button { vm.showPassword.toggle() } label: {
                            Image(systemName: vm.showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("OTP Secret").gridColumnAlignment(.trailing)
                    HStack(spacing: 4) {
                        Group {
                            if vm.showOTP {
                                TextField("TOTP seed", text: $vm.otpSecret)
                                    .focused($focus, equals: .otp)
                            } else {
                                SecureField("TOTP seed", text: $vm.otpSecret)
                                    .focused($focus, equals: .otp)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        Button { vm.showOTP.toggle() } label: {
                            Image(systemName: vm.showOTP ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Realm").gridColumnAlignment(.trailing)
                    TextField(AppConstants.defaultRealm, text: $vm.realm)
                        .focused($focus, equals: .realm)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let status = vm.statusMessage {
                HStack(spacing: 6) {
                    if vm.isSaving { ProgressView().controlSize(.small) }
                    Text(status.text)
                        .font(.callout)
                        .foregroundStyle(status.isError ? Color.red : Color.secondary)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel") { onDone() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    vm.save(openconnectPath: VPNController.shared.resolvedOpenconnectPath()) {
                        onDone()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!vm.canSave)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { focus = .name }
    }
}

// MARK: - ViewModel

@Observable final class ProfileEditViewModel {
    var displayName: String
    var username: String
    var password: String
    var otpSecret: String
    var realm: String
    var showPassword = false
    var showOTP = false
    var isSaving = false
    var errorMessage: String? = nil

    // nil = new profile; non-nil = editing existing id
    private let profileID: String?
    let title: String

    var canSave: Bool { !isSaving }
    var statusMessage: (text: String, isError: Bool)? {
        if let err = errorMessage { return (err, true) }
        if isSaving { return ("Saving...", false) }
        return nil
    }

    init(profile: VPNProfile?, isDuplicate: Bool = false) {
        if isDuplicate {
            // New profile — no existing id, but pre-fill fields and suggest a new name
            profileID   = nil
            displayName = profile.map { "\($0.displayName) Copy" } ?? ""
            title       = "Duplicate Profile"
        } else {
            profileID   = profile?.id
            displayName = profile?.displayName ?? ""
            title       = profile == nil ? "Add Profile" : "Edit Profile"
        }
        username  = profile?.username ?? ""
        realm     = profile?.realm ?? AppConstants.defaultRealm
        if let p = profile {
            password  = ProfileStore.shared.password(for: p) ?? ""
            otpSecret = ProfileStore.shared.token(for: p) ?? ""
        } else {
            password  = ""
            otpSecret = ""
        }
    }

    func save(openconnectPath: String, completion: @escaping () -> Void) {
        let trimName     = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimOTP      = otpSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimRealm    = realm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppConstants.defaultRealm
                           : realm.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimName.isEmpty     else { errorMessage = "Name is required.";     return }
        guard !trimUsername.isEmpty else { errorMessage = "Username is required."; return }
        guard !password.isEmpty     else { errorMessage = "Password is required."; return }
        guard !trimOTP.isEmpty      else { errorMessage = "OTP Secret is required."; return }

        let id = profileID ?? trimName.lowercased().replacingOccurrences(of: " ", with: "-")
        let profile = VPNProfile(id: id, displayName: trimName, username: trimUsername, realm: trimRealm)

        isSaving = true
        ProfileStore.shared.upsert(profile, password: password, token: trimOTP)

        SudoersHelper.installIfNeeded(openconnectPath: openconnectPath) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isSaving = false
                completion()
            }
        }
    }
}
