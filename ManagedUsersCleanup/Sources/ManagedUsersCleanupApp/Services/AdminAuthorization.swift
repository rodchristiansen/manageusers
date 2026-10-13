//
//  AdminAuthorization.swift
//  Managed Users Cleanup
//
//  Asks an administrator to authenticate when Save is clicked and hands the
//  helper the resulting authorization reference, which it checks before any
//  preference write. The grant lives for one save only: it is destroyed as
//  soon as the writes finish, so nothing stays unlocked and the next Save
//  asks again.
//

import Foundation
import Security
import ManagedUsersCleanupXPC

/// One administrator authorization, valid until `release()`.
@MainActor
final class AdminGrant {
    private var authRef: AuthorizationRef?
    /// The AuthorizationExternalForm the helper accepts.
    let externalForm: Data

    init(authRef: AuthorizationRef?, externalForm: Data) {
        self.authRef = authRef
        self.externalForm = externalForm
    }

    /// Destroys the rights, so the external form no longer authorizes anything.
    func release() {
        if let authRef {
            AuthorizationFree(authRef, [.destroyRights])
        }
        authRef = nil
    }
}

/// Something that can ask for an administrator. Tests substitute their own.
@MainActor
protocol AdminAuthorizing {
    /// Shows the system administrator prompt. Nil when the user cancels or
    /// the credentials are refused.
    func authorize() -> AdminGrant?
}

@MainActor
struct AdminAuthorization: AdminAuthorizing {
    func authorize() -> AdminGrant? {
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return nil }

        let status = CleanupConstants.adminRight.withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(ref, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(ref, [])
            return nil
        }

        var form = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(ref, &form) == errAuthorizationSuccess else {
            AuthorizationFree(ref, [.destroyRights])
            return nil
        }
        return AdminGrant(authRef: ref, externalForm: withUnsafeBytes(of: &form) { Data($0) })
    }
}

/// Performs one preference write with an administrator's authorization.
@MainActor
protocol PreferenceWriting: AnyObject {
    func perform(_ write: PreferenceWrite, authorization: Data) async -> Bool
}
