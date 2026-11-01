import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "codesieb.omarchy-player"
  ipcTarget: "codesieb.omarchy-player"

  property string preferredKey: ""
  property var levels: []
  property bool spectrumMissing: false

  readonly property var players: {
    var all = Mpris.players ? Mpris.players.values : []
    var list = []
    for (var i = 0; i < all.length; i++) {
      // playerctld only mirrors the real players.
      if (all[i] && all[i].dbusName.indexOf("playerctld") < 0) list.push(all[i])
    }
    return list
  }

  // A source picked by hand wins; otherwise follow whatever is playing.
  readonly property var player: {
    var playing = null
    for (var i = 0; i < players.length; i++) {
      if (players[i].dbusName === preferredKey) return players[i]
      if (!playing && players[i].isPlaying) playing = players[i]
    }
    return playing || (players.length > 0 ? players[0] : null)
  }

  readonly property bool playing: player ? player.isPlaying : false
  // Spotify DJ's spoken links can arrive without track metadata.
  readonly property string title: shownTrack.title || (playing && player ? player.identity : "")
  readonly property string artist: shownTrack.artist
  readonly property string album: shownTrack.album
  readonly property real length: player && player.lengthSupported ? player.length : 0
  readonly property bool seekable: player !== null && player.canSeek && length > 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int maxTitleLength: setting("maxTitleLength", 32)
  readonly property bool visualizerEnabled: setting("visualizer", "on") === "on"

  readonly property string barLabel: {
    if (!title || maxTitleLength <= 0 || vertical) return ""
    var label = artist ? title + " - " + artist : title
    return label.length > maxTitleLength ? label.slice(0, maxTitleLength - 1) + "…" : label
  }
  readonly property bool vertical: bar ? bar.vertical : false

  // Spotify blanks its metadata, and can briefly drop off the bus, when the
  // context changes. Hold the last track and player so the panel doesn't jump.
  readonly property var liveTrack: ({
    title: player ? (player.trackTitle || "") : "",
    artist: player ? (player.trackArtist || "") : "",
    album: player ? (player.trackAlbum || "") : "",
    art: player ? (player.trackArtUrl || "") : ""
  })
  property var shownTrack: liveTrack
  property string sourceName: ""
  property bool idle: players.length === 0

  onLiveTrackChanged: {
    if (liveTrack.title) {
      trackHold.stop()
      shownTrack = liveTrack
    } else {
      trackHold.restart()
    }
  }
  onPlayerChanged: if (player) sourceName = player.identity
  onPlayersChanged: {
    if (players.length > 0) {
      idleHold.stop()
      idle = false
    } else {
      idleHold.restart()
    }
  }

  Timer {
    id: trackHold
    interval: 2500
    onTriggered: root.shownTrack = root.liveTrack
  }

  Timer {
    id: idleHold
    interval: 4000
    onTriggered: {
      root.idle = true
      root.sourceName = ""
    }
  }

  readonly property bool hidden: setting("hideWhenIdle", "on") === "on" && idle

  visible: !hidden
  onHiddenChanged: if (hidden) close()
  implicitWidth: hidden ? 0 : button.implicitWidth
  implicitHeight: button.implicitHeight

  function formatTime(seconds) {
    var total = Math.max(0, Math.floor(seconds || 0))
    var s = total % 60
    return Math.floor(total / 60) + ":" + (s < 10 ? "0" : "") + s
  }

  function togglePlaying() {
    if (player && player.canTogglePlaying) player.togglePlaying()
  }

  function next() {
    if (player && player.canGoNext) player.next()
  }

  function previous() {
    if (player && player.canGoPrevious) player.previous()
  }

  function seekBy(delta) {
    if (seekable) player.position = Math.max(0, Math.min(length, player.position + delta))
  }

  function nudgeVolume(delta) {
    if (player && player.volumeSupported && player.canControl)
      player.volume = Math.max(0, Math.min(1, player.volume + delta))
  }

  function toggleShuffle() {
    if (player && player.shuffleSupported && player.canControl) player.shuffle = !player.shuffle
  }

  function cycleLoop() {
    if (!player || !player.loopSupported || !player.canControl) return
    if (player.loopState === MprisLoopState.None) player.loopState = MprisLoopState.Playlist
    else if (player.loopState === MprisLoopState.Playlist) player.loopState = MprisLoopState.Track
    else player.loopState = MprisLoopState.None
  }

  readonly property bool canLike: player !== null && player.identity === "Spotify" && !!player.trackTitle
  // Without a Spotify login this only knows about tracks hearted here, kept
  // on disk across restarts. With one, the Web API reports the real state.
  property var likedTracks: ({})
  property bool apiLiked: false
  property bool apiAvailable: false
  property string likeTrack: ""
  property string likeSent: ""
  readonly property string trackId: player && player.metadata ? String(player.metadata["mpris:trackid"] || "") : ""
  readonly property string spotifyId: trackId.indexOf("/com/spotify/track/") === 0 ? trackId.split("/").pop() : ""
  readonly property string spotifyHelper: String(Qt.resolvedUrl("spotify.py")).replace("file://", "")
  readonly property bool liked: apiAvailable ? apiLiked : likedTracks[trackId] === true

  function checkLiked() {
    if (spotifyId) likeCheck.exec(["python3", "-I", spotifyHelper, "contains", spotifyId])
  }

  onSpotifyIdChanged: checkLiked()
  onOpenedChanged: if (opened) checkLiked()

  // Change signals skip the track already playing at load, and likes made in
  // Spotify itself send no signal at all, so keep checking.
  Timer {
    interval: 20000
    repeat: true
    running: root.spotifyId !== ""
    triggeredOnStart: true
    onTriggered: root.checkLiked()
  }

  Process {
    id: likeCheck
    stdout: SplitParser {
      onRead: function(line) {
        if (likeSet.running) return
        root.apiAvailable = line !== "unavailable"
        root.apiLiked = line === "true"
      }
    }
  }

  Process {
    id: likeSet
    // Restarting a running helper can lose the write, so send a quick change afterwards.
    onExited: {
      if (root.spotifyId === root.likeTrack && String(root.apiLiked) !== root.likeSent) root.sendLike()
      else root.checkLiked()
    }
  }

  function sendLike() {
    likeTrack = spotifyId
    likeSent = String(apiLiked)
    likeSet.exec(["python3", "-I", spotifyHelper, "set", likeTrack, likeSent])
  }

  // MPRIS has no like call, so press Spotify's own shortcut in its window.
  function toggleLike() {
    if (!canLike) return
    if (apiAvailable && spotifyId) {
      apiLiked = !apiLiked
      if (!likeSet.running) sendLike()
      return
    }
    Quickshell.execDetached(["hyprctl", "dispatch",
      'hl.dsp.send_shortcut({ mods = "ALT SHIFT", key = "B", window = "class:^(Spotify)$" })'])
    var next = Object.assign({}, likedTracks)
    if (liked) delete next[trackId]
    else next[trackId] = true
    likedTracks = next
    likedFile.setText(JSON.stringify(next))
  }

  function startDj() {
    Quickshell.execDetached(["python3", "-I", spotifyHelper, "dj"])
  }

  // Liked tracks are private, and plugin installs skip install.sh, so lock the folder here.
  Process {
    running: true
    command: ["sh", "-c", 'install -d -m 700 "$1" && chmod -f 600 "$1/liked.json" || true', "sh",
      Quickshell.env("HOME") + "/.local/state/omarchy-player"]
  }

  FileView {
    id: likedFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy-player/liked.json"
    printErrors: false
    onLoaded: {
      try { root.likedTracks = JSON.parse(text()) || {} } catch (e) {}
    }
  }

  // Window classes usually match the desktop entry, but case varies, so match both ways.
  function showPlayerWindow() {
    var name = player.desktopEntry || player.identity
    var pattern = "(?i)^(" + name.replace(/[^A-Za-z0-9_.-]/g, "") + ")$"
    Quickshell.execDetached(["hyprctl", "dispatch",
      'hl.dsp.focus({ window = "class:' + pattern + '" })'])
    close()
  }

  function selectSource(delta) {
    if (players.length < 2) return
    var index = Math.max(0, players.indexOf(player))
    preferredKey = players[(index + delta + players.length) % players.length].dbusName
  }

  // MPRIS doesn't push position updates, so ask for them while they're on show.
  Timer {
    interval: 500
    repeat: true
    running: root.opened && root.playing
    onTriggered: if (root.player) root.player.positionChanged()
  }

  Process {
    id: spectrum
    command: ["python3", "-I", String(Qt.resolvedUrl("visualizer.py")).replace("file://", "")]
    running: root.opened && root.playing && root.visualizerEnabled && !root.spectrumMissing
    stdout: SplitParser {
      onRead: function(line) {
        if (line === "missing-numpy") root.spectrumMissing = true
        else root.levels = line.split(" ").map(Number)
      }
    }
    onRunningChanged: if (!running) root.levels = []
  }

  TextMetrics {
    id: labelMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    text: "x".repeat(root.maxTitleLength + 3)
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: (root.playing ? "󰏤" : "󰝚") + (root.barLabel ? "  " + root.barLabel : "")
    dimmed: !root.title
    // A fixed width keeps the bar, and the panel centred under it, still when tracks change.
    fixedWidth: !root.idle && root.maxTitleLength > 0 && !root.vertical
      ? labelMetrics.advanceWidth + button.scaledHorizontalMargin * 2 : -1
    tooltipText: root.title ? "" : "Nothing playing"
    onPressed: function(pressedButton) {
      if (pressedButton === Qt.MiddleButton) root.togglePlaying()
      else if (pressedButton === Qt.RightButton) root.next()
      else root.toggle()
    }
    onWheelMoved: function(delta) { root.nudgeVolume(delta > 0 ? 0.05 : -0.05) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    Behavior on contentHeight {
      NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.seekBy(dx * 5)
        else root.nudgeVolume(dy * -0.05)
      }
      onActivateRequested: root.togglePlaying()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(key) {
        if (key === "n") root.next()
        else if (key === "p") root.previous()
        else if (key === "s") root.toggleShuffle()
        else if (key === "r") root.cycleLoop()
        else if (key === "c") root.selectSource(1)
        else if (key === "f") root.toggleLike()
        else if (key === "d") root.startDj()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(14)

        Row {
          width: parent.width
          spacing: Style.space(14)

          Rectangle {
            id: artFrame
            width: Style.space(128)
            height: width
            radius: Style.cornerRadius
            color: Qt.tint(Color.background, Util.alpha(root.foreground, 0.08))
            clip: true

            Text {
              anchors.centerIn: parent
              visible: art.status !== Image.Ready
              text: "󰝚"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.space(44)
            }

            Image {
              id: art
              anchors.fill: parent
              source: root.shownTrack.art
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              sourceSize.width: 256
              sourceSize.height: 256
            }
          }

          Column {
            width: parent.width - artFrame.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.sourceName ? root.sourceName.toUpperCase() : "NO PLAYER"
              color: root.accent
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.5

              MouseArea {
                anchors.left: parent.left
                width: Math.min(parent.width, parent.implicitWidth)
                height: parent.height
                enabled: root.player !== null
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showPlayerWindow()
              }
            }
            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                width: parent.width - (likeButton.visible ? likeButton.width + parent.spacing : 0)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.title || "Nothing playing"
                color: root.foreground
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: Math.round(Style.font.body * 1.4)
                font.bold: true
              }
              ControlButton {
                id: likeButton
                width: Style.space(30)
                height: Style.space(30)
                anchors.verticalCenter: parent.verticalCenter
                visible: root.canLike
                glyph: root.liked ? "󰋑" : "󰋕"
                hint: "Like or unlike in Spotify (f)"
                active: root.liked
                onClicked: root.toggleLike()
              }
            }
            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                width: parent.width - (djButton.visible ? djButton.width + parent.spacing : 0)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.artist
                color: root.foreground
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              ControlButton {
                id: djButton
                width: Style.space(30)
                height: Style.space(30)
                anchors.verticalCenter: parent.verticalCenter
                visible: root.sourceName === "Spotify"
                hint: "Start Spotify DJ (d)"
                djLogo: true
                onClicked: root.startDj()
              }
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.album
              color: root.dim
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Button {
              visible: root.players.length === 0
              text: "Open Spotify"
              onClicked: {
                Quickshell.execDetached(["spotify"])
                root.close()
              }
            }
          }
        }

        Canvas {
          id: visualizer
          width: parent.width
          height: visible ? Style.space(64) : 0
          visible: root.visualizerEnabled

          Text {
            anchors.centerIn: parent
            visible: root.spectrumMissing
            textFormat: Text.PlainText
            text: "Install python-numpy for the spectrum"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          readonly property var levels: root.levels
          readonly property color low: root.accent
          readonly property color high: root.foreground

          onLevelsChanged: requestPaint()
          onLowChanged: requestPaint()
          onHighChanged: requestPaint()
          onWidthChanged: requestPaint()

          onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            var bars = 40
            var cell = Math.max(3, Style.space(4))
            var rows = Math.floor(height / cell)
            var gap = 2
            var barWidth = (width - gap * (bars - 1)) / bars
            for (var i = 0; i < bars; i++) {
              // Always leave one lit block, so a quiet player still reads as a meter.
              var lit = Math.max(1, Math.round(((levels[i] || 0) / 100) * rows))
              for (var row = 0; row < lit; row++) {
                ctx.fillStyle = row > rows * 0.72 ? high : low
                ctx.globalAlpha = 0.35 + 0.65 * ((row + 1) / rows)
                ctx.fillRect(i * (barWidth + gap), height - (row + 1) * cell, barWidth, cell - 1)
              }
            }
          }
        }

        Item {
          width: parent.width
          height: seekSlider.implicitHeight
          // Fades rather than collapses, so the panel keeps its height.
          opacity: root.length > 0 ? 1 : 0

          Text {
            id: elapsed
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.formatTime(seekSlider.dragging ? seekSlider.liveValue : (root.player ? root.player.position : 0))
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          PanelSlider {
            id: seekSlider
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(44)
            anchors.rightMargin: Style.space(44)
            anchors.verticalCenter: parent.verticalCenter
            bar: root.bar
            enabled: root.seekable
            fillColor: root.accent
            maximum: Math.max(1, root.length)
            step: 5
            value: root.player ? root.player.position : 0
            onReleased: function(value) { if (root.seekable) root.player.position = value }
          }
          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.formatTime(root.length)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Item {
          width: parent.width
          height: transport.implicitHeight

          Row {
            anchors.centerIn: parent
            id: transport
            spacing: Style.space(10)

            ControlButton {
              glyph: "󰒝"
              hint: "Shuffle (s)"
              active: root.player ? root.player.shuffle : false
              available: root.player !== null && root.player.shuffleSupported && root.player.canControl
              onClicked: root.toggleShuffle()
            }
            ControlButton {
              glyph: "󰒮"
              hint: "Previous (p)"
              available: root.player !== null && root.player.canGoPrevious
              onClicked: root.previous()
            }
            ControlButton {
              glyph: root.playing ? "󰏤" : "󰐊"
              hint: "Play or pause (Enter)"
              primary: true
              available: root.player !== null && root.player.canTogglePlaying
              onClicked: root.togglePlaying()
            }
            ControlButton {
              glyph: "󰒭"
              hint: "Next (n)"
              available: root.player !== null && root.player.canGoNext
              onClicked: root.next()
            }
            ControlButton {
              glyph: root.player && root.player.loopState === MprisLoopState.Track ? "󰑘" : "󰑖"
              hint: "Repeat (r)"
              active: root.player ? root.player.loopState !== MprisLoopState.None : false
              available: root.player !== null && root.player.loopSupported && root.player.canControl
              onClicked: root.cycleLoop()
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(10)
          opacity: root.player !== null && root.player.volumeSupported && root.player.canControl ? 1 : 0

          Text {
            id: volumeIcon
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "󰕾"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          PanelSlider {
            width: parent.width - volumeIcon.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            bar: root.bar
            value: root.player ? root.player.volume : 0
            onMoved: function(value) { if (root.player) root.player.volume = value }
          }
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)
          visible: root.players.length > 1

          Repeater {
            model: root.players

            Rectangle {
              required property var modelData
              readonly property bool selected: modelData === root.player

              width: sourceLabel.implicitWidth + Style.space(16)
              height: sourceLabel.implicitHeight + Style.space(8)
              radius: Style.cornerRadius
              color: selected ? root.accent : "transparent"
              border.width: 1
              border.color: selected ? root.accent : root.dim

              Text {
                id: sourceLabel
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: parent.modelData.identity
                color: parent.selected ? Color.background : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.preferredKey = parent.modelData.dbusName
              }
            }
          }
        }
      }
    }
  }

  component ControlButton: Rectangle {
    id: control

    property string glyph: ""
    property string hint: ""
    property bool active: false
    property bool available: true
    property bool primary: false
    property bool djLogo: false

    signal clicked()

    width: Style.space(primary ? 52 : 40)
    height: Style.space(40)
    radius: Style.cornerRadius
    opacity: available ? 1 : 0.35
    color: primary ? root.accent : (mouse.containsMouse && available ? Util.alpha(root.foreground, 0.1) : "transparent")

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: control.glyph
      color: control.primary ? Color.background : (control.active ? root.accent : root.foreground)
      font.family: root.fontFamily
      font.pixelSize: Math.round(Style.font.body * 1.6)
    }
    Canvas {
      anchors.centerIn: parent
      width: Style.space(26)
      height: width
      visible: control.djLogo

      readonly property color logoFill: root.accent
      readonly property color logoRing: Color.background

      onLogoFillChanged: requestPaint()
      onLogoRingChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        var mid = width / 2
        ctx.clearRect(0, 0, width, height)
        ctx.fillStyle = logoFill
        ctx.beginPath()
        ctx.arc(mid, mid, mid, 0, Math.PI * 2)
        ctx.fill()
        ctx.strokeStyle = logoRing
        ctx.lineWidth = width * 0.13
        ctx.lineCap = "round"
        ctx.beginPath()
        ctx.arc(mid, mid, mid * 0.55, -Math.PI * 0.25, Math.PI * 1.4)
        ctx.stroke()
      }
    }
    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: control.available
      cursorShape: Qt.PointingHandCursor
      onClicked: control.clicked()
    }
  }
}
