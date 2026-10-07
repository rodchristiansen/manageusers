import Testing
import Foundation
@testable import manageusers

@Suite("DeletionEvaluator")
struct DeletionEvaluatorTests {

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400
    let fourWeeks = DeletionPolicy(duration: 28 * 86_400, strategy: .loginAndCreation, forceTermDeletion: false)

    func account(
        _ name: String = "student1",
        createdDaysAgo: Double? = 60,
        loginDaysAgo: Double? = 60,
        admin: Bool = false,
        token: Bool = false,
        owner: Bool = false
    ) -> AccountFacts {
        AccountFacts(
            name: name,
            createdAt: createdDaysAgo.map { now.addingTimeInterval(-$0 * day) },
            lastLogin: loginDaysAgo.map { now.addingTimeInterval(-$0 * day) },
            isAdmin: admin,
            hasSecureToken: token,
            isVolumeOwner: owner
        )
    }

    func decide(_ facts: AccountFacts, policy: DeletionPolicy? = nil,
                protection: AccountProtection = AccountProtection(exclusions: []),
                owners: Int = 1) -> DeletionDecision {
        DeletionEvaluator.evaluate(facts, policy: policy ?? fourWeeks, protection: protection,
                                   adminVolumeOwnersRemaining: owners, now: now)
    }

    @Test("An old account that has not logged in recently is deleted")
    func oldAndIdle() {
        #expect(decide(account()).shouldDelete)
    }

    @Test("An old account that logged in yesterday is kept: both ages must pass the threshold")
    func oldButActive() {
        #expect(!decide(account(createdDaysAgo: 400, loginDaysAgo: 1)).shouldDelete)
    }

    @Test("A new account that never logged in is kept")
    func newNeverLoggedIn() {
        #expect(!decide(account(createdDaysAgo: 3, loginDaysAgo: nil)).shouldDelete)
    }

    @Test("No recorded login counts as never logged in")
    func missingLoginIsNever() {
        let decision = decide(account(createdDaysAgo: 60, loginDaysAgo: nil))
        #expect(decision.shouldDelete)
        #expect(decision.reason.contains("never"))
    }

    @Test("An unknown creation date keeps the account")
    func unknownCreation() {
        #expect(decide(account(createdDaysAgo: nil)) == .keep("creation date unknown"))
    }

    @Test("Creation-only ignores the login age")
    func creationOnly() {
        let policy = DeletionPolicy(duration: 2 * 86_400, strategy: .creationOnly, forceTermDeletion: false)
        #expect(decide(account(createdDaysAgo: 3, loginDaysAgo: 0), policy: policy).shouldDelete)
        #expect(!decide(account(createdDaysAgo: 1, loginDaysAgo: 30), policy: policy).shouldDelete)
    }

    @Test("Exclusions always win, case-insensitively")
    func exclusions() {
        let protection = AccountProtection(exclusions: ["Student1"], deleteAdmins: true, deletableAdmins: ["student1"])
        #expect(decide(account(admin: true), protection: protection) == .keep("excluded"))
    }

    @Test("Admins are kept unless DeleteAdmins is on")
    func adminGuard() {
        #expect(!decide(account(admin: true)).shouldDelete)
        #expect(decide(account(admin: true), protection: AccountProtection(exclusions: [], deleteAdmins: true)).shouldDelete)
    }

    @Test("A named admin in DeletableAdmins can be deleted while the guard is on")
    func deletableAdmins() {
        let protection = AccountProtection(exclusions: [], deleteAdmins: false, deletableAdmins: ["oldadmin"])
        #expect(decide(account("OldAdmin", admin: true), protection: protection).shouldDelete)
        #expect(!decide(account("otheradmin", admin: true), protection: protection).shouldDelete)
    }

    @Test("The last admin volume owner is never deleted, even with DeleteAdmins on")
    func lastVolumeOwner() {
        let protection = AccountProtection(exclusions: [], deleteAdmins: true)
        #expect(!decide(account(admin: true, token: true, owner: true), protection: protection, owners: 0).shouldDelete)
        #expect(decide(account(admin: true, token: true, owner: true), protection: protection, owners: 1).shouldDelete)
    }

    @Test("A non-admin SecureToken holder can be deleted while an admin owner remains")
    func tokenHolderNotLast() {
        #expect(decide(account(token: true, owner: true), owners: 1).shouldDelete)
        #expect(!decide(account(token: true, owner: true), owners: 0).shouldDelete)
    }

    @Test("Force mode zeroes the threshold but keeps the admin guard and exclusions")
    func forceMode() {
        let force = DeletionPolicy(duration: 0, strategy: .loginAndCreation, forceTermDeletion: true)
        #expect(decide(account(createdDaysAgo: 0.5, loginDaysAgo: 0.1), policy: force).shouldDelete)
        #expect(!decide(account(admin: true), policy: force).shouldDelete)
        #expect(!decide(account(), policy: force, protection: AccountProtection(exclusions: ["student1"])).shouldDelete)
        #expect(!decide(account(createdDaysAgo: nil), policy: force).shouldDelete)
    }

    @Test("A negative duration never deletes")
    func neverDelete() {
        let never = DeletionPolicy(duration: -1, strategy: .loginAndCreation, forceTermDeletion: false)
        #expect(decide(account(createdDaysAgo: 999, loginDaysAgo: nil), policy: never) == .keep("policy never deletes"))
    }
}

@Suite("AccountInspector parsing")
struct AccountInspectorParsingTests {

    @Test("Single attributes on one line or the next")
    func attributes() {
        #expect(AccountInspector.parseSingleAttribute("UniqueID: 502\n", key: "UniqueID") == "502")
        #expect(AccountInspector.parseSingleAttribute("NFSHomeDirectory:\n /Users/a b\n", key: "NFSHomeDirectory") == "/Users/a b")
        #expect(AccountInspector.parseSingleAttribute("No such key: UniqueID", key: "UniqueID") == nil)
    }

    @Test("accountPolicyData creationTime")
    func creationTime() {
        let output = """
        accountPolicyData:
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>creationTime</key>
        \t<real>1700000000.5</real>
        </dict>
        </plist>
        """
        #expect(AccountInspector.parseCreationTime(fromAccountPolicyData: output) == Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(AccountInspector.parseCreationTime(fromAccountPolicyData: "accountPolicyData:") == nil)
    }

    @Test("Volume users and owners from diskutil")
    func volumeUsers() throws {
        let plist: [String: Any] = ["Users": [
            ["APFSCryptoUserUUID": "AAAA", "VolumeOwner": true],
            ["APFSCryptoUserUUID": "BBBB", "VolumeOwner": false],
            ["APFSCryptoUserType": "PersonalRecovery"]
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(AccountInspector.parseVolumeUsers(data) == [
            .init(uuid: "AAAA", isVolumeOwner: true),
            .init(uuid: "BBBB", isVolumeOwner: false)
        ])
    }

    @Test("Only a real /Users/<name> folder is ever removed")
    func removableHome() {
        #expect(UserDeleter.removableHome("/Users/s1", for: "s1") == "/Users/s1")
        #expect(UserDeleter.removableHome(nil, for: "s1") == "/Users/s1")
        #expect(UserDeleter.removableHome("/var/root", for: "s1") == nil)
        #expect(UserDeleter.removableHome(nil, for: "Shared") == nil)
        #expect(UserDeleter.removableHome(nil, for: "../etc") == nil)
    }

    @Test("Admin guard settings parse booleans and lists")
    func settings() {
        #expect(AdminGuardSettings.parseBool(NSNumber(value: 1)) == true)
        #expect(AdminGuardSettings.parseBool("no") == false)
        #expect(AdminGuardSettings.parseBool(nil) == nil)
        #expect(AdminGuardSettings.parseList(["a", " b ", ""]) == ["a", "b"])
        #expect(AdminGuardSettings.parseList("a, b\nc") == ["a", "b", "c"])
    }
}

@Suite("Deletion plan")
struct DeletionPlanTests {
    @Test("The plan line is one parseable JSON object")
    func planLine() throws {
        let line = UserManager.planLine([("s1", "created 40d ago"), ("s2", "last login never")])
        #expect(line.hasPrefix("MANAGEUSERS_PLAN "))
        let json = try #require(line.dropFirst("MANAGEUSERS_PLAN ".count).data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let accounts = try #require(object["accounts"] as? [[String: String]])
        #expect(accounts.map { $0["name"] } == ["s1", "s2"])
        #expect(UserManager.planLine([]) == "MANAGEUSERS_PLAN {\"accounts\":[]}")
    }
}
