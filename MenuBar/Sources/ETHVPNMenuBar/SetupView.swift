import SwiftUI

struct SetupView: View {
    @Bindable var vm: SetupViewModel
    let onDone: () -> Void

    private enum Field: Hashable {
        case username, password, otp, realm
    }
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 4) {
                Image(systemName: "shield.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                Text("ETH VPN Setup")
                    .font(.title2.bold())
                Text("Enter your WLAN credentials to connect to the ETH network.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Form rows
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                // Username
                GridRow {
                    Text("Username")
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("without @ethz.ch", text: $vm.username)
                            .focused($focusedField, equals: .username)
                            .textFieldStyle(.roundedBorder)
                        Text("without @ethz.ch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Password
                GridRow {
                    Text("WLAN Password")
                        .gridColumnAlignment(.trailing)
                    HStack(spacing: 4) {
                        Group {
                            if vm.showPassword {
                                TextField("Password", text: $vm.password)
                                    .focused($focusedField, equals: .password)
                            } else {
                                SecureField("Password", text: $vm.password)
                                    .focused($focusedField, equals: .password)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        Button {
                            vm.showPassword.toggle()
                        } label: {
                            Image(systemName: vm.showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }

                // OTP Secret
                GridRow {
                    Text("OTP Secret")
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Group {
                                if vm.showOTP {
                                    TextField("TOTP seed", text: $vm.otpSecret)
                                        .focused($focusedField, equals: .otp)
                                } else {
                                    SecureField("TOTP seed", text: $vm.otpSecret)
                                        .focused($focusedField, equals: .otp)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            Button {
                                vm.showOTP.toggle()
                            } label: {
                                Image(systemName: vm.showOTP ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        Text("Your TOTP seed from mylogin.ethz.ch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Realm
                GridRow {
                    Text("Realm")
                        .gridColumnAlignment(.trailing)
                    TextField("student-net", text: $vm.realm)
                        .focused($focusedField, equals: .realm)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Status area
            if let status = vm.statusMessage {
                HStack(spacing: 6) {
                    if vm.phase == .saving || vm.phase == .installingHelper {
                        ProgressView().controlSize(.small)
                    }
                    Text(status.text)
                        .font(.callout)
                        .foregroundStyle(status.isError ? Color.red : Color.secondary)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") { vm.requestCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    vm.save(openconnectPath: VPNController.shared.resolvedOpenconnectPath())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!vm.canSave)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { focusedField = .username }
        .onChange(of: vm.phase) { _, newValue in
            if newValue == .done { onDone() }
        }
    }
}
