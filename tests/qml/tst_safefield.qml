import QtQuick
import QtTest

TestCase {
  id: tc
  name: "SafeField"
  width: 300
  height: 100
  visible: true
  when: windowShown

  property int pastes: 0
  property bool lastPrimary: false

  Component {
    id: fieldC
    SafeField {
      width: 200
      maximumLength: 8
      onPasteRequested: function(primary) { tc.pastes += 1; tc.lastPrimary = primary }
    }
  }

  function make() {
    const f = createTemporaryObject(fieldC, tc)
    verify(f)
    return f
  }

  // a live field with the keyboard focus, as when the panel is open and clicked into
  function focused(f) {
    f.live = true
    f.forceActiveFocus()
    tryVerify(function() { return f.loaded && f.children[0].item.activeFocus })
  }

  function test_no_input_exists_while_not_live() {
    const f = make()
    compare(f.loaded, false)
    f.live = true
    compare(f.loaded, true)
    f.live = false
    compare(f.loaded, false)
  }

  function test_draft_is_dropped_when_it_stops_being_live() {
    const f = make()
    focused(f)
    keyClick("a"); keyClick("b")
    compare(f.text, "ab")
    f.live = false
    compare(f.text, "")
    f.live = true
    compare(f.text, "")
  }

  function test_typing_is_bounded() {
    const f = make()
    focused(f)
    for (let i = 0; i < 12; i++) keyClick("x")
    compare(f.text.length, 8)
  }

  function test_secret_masks_the_input() {
    const f = make()
    f.live = true
    f.secret = true
    compare(f.children[0].item.echoMode, TextInput.Password)
    f.secret = false
    compare(f.children[0].item.echoMode, TextInput.Normal)
  }

  function test_ctrl_v_asks_the_owner_instead_of_pasting() {
    const f = make()
    focused(f)
    pastes = 0
    keyClick(Qt.Key_V, Qt.ControlModifier)
    compare(pastes, 1)
    compare(lastPrimary, false)
    keyClick(Qt.Key_Insert, Qt.ShiftModifier)
    compare(pastes, 2)
    compare(f.text, "")
  }

  function test_inserted_text_is_cleaned_and_bounded() {
    const f = make()
    focused(f)
    keyClick("a")
    f.insertBounded("b\nc\u0007d" + "e".repeat(50))
    compare(f.text, "abcdeeee")
    f.insertBounded("zzz")
    compare(f.text, "abcdeeee")
  }

  function test_insert_does_nothing_when_not_live() {
    const f = make()
    f.insertBounded("abc")
    compare(f.text, "")
  }
}
