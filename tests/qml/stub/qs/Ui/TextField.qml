import QtQuick
import QtQuick.Controls

// Stand-in for the shell's kit TextField (same extra properties), so SafeField can be tested
// without the shell.
TextField {
  property color foreground: "white"
  property bool password: false
  echoMode: password ? TextInput.Password : TextInput.Normal
}
