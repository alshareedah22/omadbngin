import QtQuick
import qs.Ui

// A text field that exists only while `live` is true.
//
// A Qt text input watches the system clipboard from the moment it is created: on Wayland a
// clipboard change makes every live input ask the clipboard's owner about its contents, and a
// slow or huge owner stalls the shell. So the input here is built only while the panel is
// open, is destroyed when it closes (taking its draft with it), and never pastes by itself:
// Ctrl+V, Shift+Insert, the Paste key and a middle click ask the owner of this component
// (pasteRequested) to fetch the clipboard in a separate, time- and size-limited process, and
// the owner hands the result to insertBounded().
FocusScope {
  id: root

  property bool live: false
  property string text: ""
  property string placeholderText: ""
  property color foreground: "white"
  property bool secret: false          // dots instead of characters
  property int maximumLength: 128      // typing and pasting both stop here
  property var validator: null
  readonly property bool loaded: loader.item !== null

  signal accepted()
  signal keyPressed(var event)
  signal pasteRequested(bool primary)

  implicitWidth: loader.item ? loader.item.implicitWidth : 120
  implicitHeight: loader.item ? loader.item.implicitHeight : 30

  // a draft never outlives the field
  onLiveChanged: if (!live) text = ""

  function blur() { if (loader.item) loader.item.focus = false }

  // Insert pasted text: one line, no control characters, no more than the field has room for.
  function insertBounded(s) {
    const f = loader.item
    if (!f) return
    let t = String(s).replace(/[\u0000-\u001f\u007f-\u009f]/g, "")
    const room = root.maximumLength - (f.length - Math.abs(f.selectionEnd - f.selectionStart))
    t = t.slice(0, Math.max(0, room))
    if (t === "") return
    f.remove(f.selectionStart, f.selectionEnd)
    f.insert(f.cursorPosition, t)
  }

  Loader {
    id: loader
    anchors.fill: parent
    focus: true // (a Loader is a focus scope of its own)
    active: root.live
    sourceComponent: TextField {
      focus: true
      foreground: root.foreground
      placeholderText: root.placeholderText
      password: root.secret
      maximumLength: root.maximumLength
      validator: root.validator
      inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
      text: root.text
      onTextChanged: if (root.text !== text) root.text = text
      onAccepted: root.accepted()
      Keys.onPressed: function(event) {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0
        if (event.key === Qt.Key_Paste || (ctrl && event.key === Qt.Key_V) || (shift && event.key === Qt.Key_Insert)) {
          root.pasteRequested(false)
          event.accepted = true
          return
        }
        root.keyPressed(event)
      }
    }
  }

  // a middle click would paste the primary selection: fetch it the bounded way instead
  MouseArea {
    anchors.fill: parent
    enabled: root.live
    acceptedButtons: Qt.MiddleButton
    onClicked: root.pasteRequested(true)
  }
}
