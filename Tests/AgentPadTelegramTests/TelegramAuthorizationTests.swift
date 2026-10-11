import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramAuthorizationTests: XCTestCase {
    func testQRRefreshAndPasswordReplaceTheFormRevision() {
        var machine = TelegramAuthorizationMachine()
        _ = machine.transition(TDLibMessage("authorizationStateWaitOtherDeviceConfirmation", ["link": .string("tg://login?token=one")]), now: Date())
        let first = machine.snapshot.revision
        _ = machine.transition(TDLibMessage("authorizationStateWaitOtherDeviceConfirmation", ["link": .string("tg://login?token=two")]), now: Date())
        XCTAssertGreaterThan(machine.snapshot.revision, first)
        XCTAssertEqual(machine.snapshot.state, .qr(link: "tg://login?token=two"))
        _ = machine.transition(TDLibMessage("authorizationStateWaitPassword", ["password_hint": .string("hint")]), now: Date())
        XCTAssertEqual(machine.snapshot.state, .password(hint: "hint"))
        _ = machine.transition(TDLibMessage("authorizationStateReady"), now: Date())
        XCTAssertEqual(machine.snapshot.state, .verifyingAccount)
    }
    func testCodeDeliveryAndResendUseTDLibState() {
        let now = Date()
        var machine = TelegramAuthorizationMachine()
        _ = machine.transition(TDLibMessage("authorizationStateWaitCode", ["code_info": .object([
            "type": .object(["@type": .string("authenticationCodeTypeTelegramMessage")]),
            "next_type": .object(["@type": .string("authenticationCodeTypeSms")]), "timeout": .integer(30)
        ])]), now: now)
        XCTAssertEqual(machine.snapshot.state, .code(TelegramCodeInfo(delivery: "Enter the code sent in Telegram.", resendAvailableAt: now.addingTimeInterval(30))))
        _ = machine.transition(TDLibMessage("authorizationStateWaitEmailAddress"), now: now)
        XCTAssertEqual(machine.snapshot.state, .emailAddress)
        _ = machine.transition(TDLibMessage("authorizationStateWaitEmailCode", ["code_info": .object(["email_address_pattern": .string("t***@example.test")])]), now: now)
        XCTAssertEqual(machine.snapshot.state, .emailCode(pattern: "t***@example.test"))
    }
    func testRegistrationAndPremiumStepsAreExplicitlyUnsupported() {
        for type in ["authorizationStateWaitRegistration", "authorizationStateWaitPremiumPurchase"] {
            var machine = TelegramAuthorizationMachine()
            _ = machine.transition(TDLibMessage(type), now: Date())
            XCTAssertEqual(machine.snapshot.state, .unsupported)
        }
    }
    func testCleanupWinsOverLateAuthorizationAndErrorsAreSanitized() {
        var machine = TelegramAuthorizationMachine(); machine.cleanup = true
        _ = machine.transition(TDLibMessage("authorizationStateReady"), now: Date())
        XCTAssertEqual(machine.snapshot.state, .loggingOut)
        XCTAssertFalse(machine.authorizationReady)
        let error = TelegramFailure.rpc(TDLibMessage("error", ["code": .integer(406), "message": .string("private payload")]))
        XCTAssertEqual(error, .requestFailed)
        XCTAssertFalse(error.message.contains("private payload"))
    }
}
