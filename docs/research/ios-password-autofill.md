# iOS Password AutoFill and the Legato keyboard

Legato can offer a keyboard handoff for Password AutoFill, but cannot embed Apple's native AutoFill bar or read the Apple Passwords vault through public keyboard-extension APIs. Secure password fields already cause iOS to replace Legato with the system keyboard automatically.

## Supported behavior

For fields marked as username, password, new password, or one-time code, Legato offers **Switch keyboard for AutoFill** in the word row of both the full keyboard and compact strip. A tap advances to the next enabled keyboard; a long press opens the system keyboard picker. The action does not open Passwords directly. With multiple third-party keyboards enabled, the next keyboard may be another third-party keyboard.

**Automatically switch for AutoFill** in Settings > Typing enables an automatic handoff for marked credential fields. It defaults to off. Returning to Legato on the same field must remain possible without an automatic switching loop. Ordinary text, email-address and URL fields retain their existing behavior; email addresses marked specifically as usernames qualify.

The host app supplies field semantics through `textContentType`. Legato cannot reliably recognize an unmarked login field or change the host's AutoFill configuration. Native credential suggestions also depend on the user's saved credentials, AutoFill settings, and the host app's website associations.

## API boundaries

`UIInputViewController.advanceToNextInputMode()` advances through enabled keyboards. `handleInputModeList(from:with:)`, wired to all touch events on a native control, supports a tap to switch and a long press to choose. Apple provides no public API to select a particular keyboard.

`requestSupplementaryLexicon` supplies contact names, text replacements, and common words, not saved credentials. AuthenticationServices credential-provider extensions publish a password manager's own credentials; they do not grant access to Apple's Passwords database. App sign-in APIs are not a universal credential picker for arbitrary host apps.

## Sources

Researched October 28, 2026 against Apple's documentation and the installed iOS SDK headers:

- [Configuring a custom keyboard interface](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface): secure-field replacement and lexicon contents.
- [UIInputViewController](https://developer.apple.com/documentation/uikit/uiinputviewcontroller): public keyboard controller APIs.
- [Custom Keyboard programming guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html): keyboard-switching restrictions.
- [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard): native switch control wiring.
- [Enabling Password AutoFill on a text input view](https://developer.apple.com/documentation/security/enabling-password-autofill-on-a-text-input-view): content types and host-app responsibilities.
- [About the Password AutoFill workflow](https://developer.apple.com/documentation/security/about-the-password-autofill-workflow): saved credentials, settings, associations, and authentication.
- [Credential provider extensions](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller): supplying a password manager's own credentials.

## Verification scope

Regression checks cover credential classification and automatic-switch suppression. Simulator checks exercise the real keyboard extension, action, picker, persisted setting, field transitions, and secure-field system replacement. Keyboard handoff proof does not by itself establish saved-credential filling, iCloud synchronization, or device Face ID behavior; these require separate verification with a saved test credential and an appropriate device configuration.

## Implementation validation (October 28, 2026)

The iPhone 17 Pro simulator running iOS 26.5 exercised the real keyboard extension. Speech and readiness used the existing DEBUG fakes; the keyboard, UIKit input-mode picker, App Group preferences, and text fields were real. The simulator build used the repository's CI stubs for heavy model dependencies and ad-hoc signing to retain App Group entitlements.

| Check | Result |
| --- | --- |
| Keyboard-core affected suite | 540 tests in 56 suites passed; new policy and privacy regressions were observed failing before implementation. |
| Full keyboard action on a verification-code field | Visible; short tap switched to an enabled Apple keyboard; picker selection also completed the handoff. |
| Compact keyboard action | Visible with complete label; native picker opened and allowed selection. |
| Automatic setting | Default off; toggled in Settings; saved in the shared App Group; extension automatically handed off on a verification-code field. |
| Return after automatic handoff | Selecting Legato again on the same field left it visible without another automatic handoff. |
| Ordinary email field with automatic switching on | Legato remained visible; no AutoFill action. |
| Secure password field | iOS showed its own keyboard. The tested username login form also selected the native keyboard. |
| Saved-password filling and device authentication | Unverified: the isolated simulator's Passwords app remained locked. |

A direct simulator probe confirmed UIKit uses `new-password` and `one-time-code` as raw values, rather than their Swift property names. The UI boundary now compares typed UIKit constants. Regression coverage also excludes these actual raw values from suggestions and vocabulary learning.

Automatic repeat suppression retains only a field identifier and credential type for the extension process lifetime. If iOS terminates that process, the next process may hand off again. Field semantics remain host-provided; unmarked fields cannot be detected reliably.

Reproduce the focused package check with `LEGATO_STUB_DEPS=1 swift test --filter LegatoKeyboardCoreTests`. The DEBUG app's real-extension field is available with `-LegatoKeyboardHarness YES -LegatoHarnessSystemField YES -LegatoHarnessContentType oneTimeCode -LegatoHarnessSingleField YES`. Tap **Release keyboard pin** before interacting with the switch action; the pin is a harness-only mechanism to select Legato initially.
