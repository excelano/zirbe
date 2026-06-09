// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The system contact picker, wrapped for SwiftUI. The picker runs out of
// process: iOS shows the address book, the user taps one contact (or one email
// on a contact with several), and only that selection is handed back. The app
// never reads the address book, so this needs no Contacts permission, no
// usage-description string, and no entitlement, and nothing leaves the device.
//
// It presents from an invisible host controller rather than a SwiftUI sheet,
// because CNContactPickerViewController dismisses itself on selection and that
// self-dismissal desyncs a sheet's presentation binding. The host lets the
// picker manage its own lifetime; we only mirror the binding back to false.

import SwiftUI
import ContactsUI

struct ContactPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    /// Called with a composed recipient token for the chosen email, e.g.
    /// `"Pat Lee <pat@x.com>"`, or the bare address when the contact is unnamed.
    let onPick: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onClose = { isPresented = false }

        guard isPresented, host.presentedViewController == nil, !context.coordinator.isPresenting else { return }
        context.coordinator.isPresenting = true

        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        // Show and select only emails: a one-email contact is picked directly, a
        // multi-email contact drills into its detail so the user taps which one.
        picker.displayedPropertyKeys = [CNContactEmailAddressesKey]
        picker.predicateForSelectionOfContact = NSPredicate(format: "emailAddresses.@count == 1")
        picker.predicateForSelectionOfProperty = NSPredicate(format: "key == 'emailAddresses'")
        host.present(picker, animated: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var onPick: (String) -> Void = { _ in }
        var onClose: () -> Void = {}
        /// Guards against re-presenting in the window between presenting the
        /// picker and the binding settling back to false.
        var isPresenting = false

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            finish()
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            if let email = contact.emailAddresses.first?.value as String? {
                onPick(Self.token(name: Self.name(of: contact), email: email))
            }
            finish()
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            if let email = contactProperty.value as? String {
                onPick(Self.token(name: Self.name(of: contactProperty.contact), email: email))
            }
            finish()
        }

        private func finish() {
            isPresenting = false
            onClose()
        }

        private static func name(of contact: CNContact) -> String? {
            CNContactFormatter.string(from: contact, style: .fullName)
        }

        private static func token(name: String?, email: String) -> String {
            if let name, !name.isEmpty { return "\(name) <\(email)>" }
            return email
        }
    }
}
