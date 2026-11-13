import Testing
@testable import LegatoMac

@Suite struct FieldWriteCapabilitiesTests {
    @Test func aNativeWholeValueSetterDoesNotPromiseScopedReplacement() {
        // WhatsApp's populated compose field: AXValue and selection are settable; AXSelectedText is not.
        let field = FieldWriteCapabilities(chromium: false, editable: true, selectedTextSettable: false, textOperation: false)
        #expect(!field.editsInPlace)
        #expect(field.typesKeys)
    }

    @Test func nativeScopedSettersAndWebKitMarkerOperationsStayLive() {
        for (setter, operation) in [(true, false), (false, true)] {
            let field = FieldWriteCapabilities(chromium: false, editable: true, selectedTextSettable: setter, textOperation: operation)
            #expect(field.editsInPlace)
            #expect(!field.typesKeys)
        }
    }

    @Test func chromiumNeverTrustsItsAdvertisedSetters() {
        let field = FieldWriteCapabilities(chromium: true, editable: true, selectedTextSettable: true, textOperation: true)
        #expect(!field.editsInPlace)
        #expect(field.typesKeys)
    }

    @Test func readablePagesNeverReceiveSyntheticKeys() {
        let field = FieldWriteCapabilities(chromium: true, editable: false, selectedTextSettable: true, textOperation: false)
        #expect(!field.editsInPlace)
        #expect(!field.typesKeys)
    }
    @Test func aVerifiedNoOpDisablesAnAdvertisedSetter() {
        for (setter, operation) in [(true, false), (false, true)] {
            let field = FieldWriteCapabilities(chromium: false, editable: true, selectedTextSettable: setter,
                                               textOperation: operation, scopedWriteFailed: true)
            #expect(!field.editsInPlace)
            #expect(field.typesKeys)
        }
    }

    @Test func aFailedSetterDoesNotAuthorizeKeysIntoAnUnidentifiedField() {
        let field = FieldWriteCapabilities(chromium: false, editable: false, selectedTextSettable: true,
                                           textOperation: false, scopedWriteFailed: true)
        #expect(!field.editsInPlace)
        #expect(!field.typesKeys)
    }

    @Test func onlyTextDestinationsAuthorizeBlindPanelTyping() {
        // WhatsApp's empty field is unreadable, but positively identifies an editable text area.
        #expect(FieldTypingDestination.accepts(role: "AXTextArea", textSettable: true))
        #expect(FieldTypingDestination.accepts(role: "AXSecureTextField", textSettable: false))
        #expect(FieldTypingDestination.accepts(role: "AXStaticText", textSettable: false, editableAncestorRole: "AXTextArea"))
        for role in [nil, "AXList", "AXOutline", "AXWebArea", "AXSlider", "AXGroup"] {
            #expect(!FieldTypingDestination.accepts(role: role, textSettable: true))
        }
        #expect(!FieldTypingDestination.accepts(role: "AXTextArea", textSettable: false))
        #expect(!FieldTypingDestination.accepts(role: "AXGroup", textSettable: false, editableAncestorRole: "AXWebArea"))
    }

}
