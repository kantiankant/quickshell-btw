import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.SystemTray
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

ShellRoot {
    id: root

    // ─── Design Tokens ────────────────────────────────────────────────────
    readonly property real squircleRadius: 12
    readonly property real panelRadius:    18
    readonly property real pillRadius:     8

    // ─── Settings State ───────────────────────────────────────────────────
    property string barEdge:         "bottom"
    property string weatherLocation: "Singapore"
    property string iconTheme:       ""
    property var    iconThemeList:   []

    // ── Read persisted settings ────────────────────────────────────────────
    Process {
        id: settingsReadProc
        command: ["bash", "-c", "cat ~/.config/mango/bar-settings.conf 2>/dev/null || true"]
        running: true
        stdout: SplitParser {
            onRead: (line) => {
                var kv  = line.trim().split("=")
                if (kv.length < 2) return
                var key = kv[0].trim()
                var val = kv.slice(1).join("=").trim()
                if (key === "barEdge"         && ["top","bottom"].indexOf(val) !== -1) root.barEdge         = val
                if (key === "weatherLocation" && val.length > 0)                       root.weatherLocation = val
                if (key === "iconTheme"       && val.length > 0)                       root.iconTheme       = val
            }
        }
    }

    // ── Enumerate icon themes ──────────────────────────────────────────────
    Process {
        id: iconThemeListProc
        command: [
            "bash", "-c",
            "for d in ~/.local/share/icons/*/; do " +
            "  name=$(basename \"$d\"); " +
            "  [ -f \"$d/index.theme\" ] && echo \"$name\"; " +
            "done 2>/dev/null || true"
        ]
        running: true
        stdout: SplitParser {
            onRead: (line) => {
                var name = line.trim()
                if (name.length === 0) return
                var list = root.iconThemeList.slice()
                list.push(name)
                root.iconThemeList = list
            }
        }
    }

    Process { id: settingsWriteProc;  running: false }
    Process { id: iconThemeApplyProc; running: false }

    property string homeDir: ""
    Process {
        command: ["bash", "-c", "echo $HOME"]
        running: true
        stdout: SplitParser {
            onRead: (line) => { if (line.trim().length > 0) root.homeDir = line.trim() }
        }
    }

    function themeIconPath(name, size) {
        if (root.iconTheme.length === 0 || root.homeDir.length === 0 || name.length === 0) return ""
        var base = "file://" + root.homeDir + "/.local/share/icons/" + root.iconTheme
        return [
            base + "/scalable/apps/" + name + ".svg",
            base + "/symbolic/apps/" + name + "-symbolic.svg",
            base + "/" + size + "x" + size + "/apps/" + name + ".png",
            base + "/48x48/apps/" + name + ".png",
            base + "/32x32/apps/" + name + ".png",
            base + "/24x24/apps/" + name + ".png",
        ]
    }

    function saveSettings() {
        var loc   = root.weatherLocation.replace(/['"\\]/g, "")
        var edge  = root.barEdge
        var theme = root.iconTheme.replace(/['"\\]/g, "")
        var cmd   = "mkdir -p ~/.config/mango && printf 'barEdge=%s\\nweatherLocation=%s\\niconTheme=%s\\n' "
                  + "'" + edge  + "' "
                  + "'" + loc   + "' "
                  + "'" + theme + "' "
                  + "> ~/.config/mango/bar-settings.conf"
        settingsWriteProc.command = ["bash", "-c", cmd]
        settingsWriteProc.running = true
    }

    function applyIconTheme(theme) {
        root.iconTheme = theme
        saveSettings()
        var t = theme.replace(/['\\]/g, "")
        var cmd = theme.length > 0
            ? "gsettings set org.gnome.desktop.interface icon-theme '" + t + "' 2>/dev/null || true; "
              + "echo 'export QT_QPA_ICON_THEME=" + t + "' > ~/.config/mango/env"
            : "gsettings set org.gnome.desktop.interface icon-theme hicolor 2>/dev/null || true; "
              + "rm -f ~/.config/mango/env"
        iconThemeApplyProc.command = ["bash", "-c", cmd]
        iconThemeApplyProc.running = true
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ─── Hyprland Workspace State ─────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════════════════

    function switchWorkspace(num) {
        Hyprland.dispatch("workspace " + num)
    }

    // ─── Weather State ────────────────────────────────────────────────────
    property string weatherTemp:     "--°C"
    property string weatherIcon:     "🌡️"
    property var    chartData:       []
    property string currentTemp:     "--°C"
    property string currentDesc:     "—"
    property string todayLow:        "--°"
    property string todayHigh:       "--°"
    property string currentEmoji:    "🌡️"
    property var    lastWeatherFetch: null
    property bool   weatherLoading:  false

    function codeToEmoji(code) {
        var c = parseInt(code)
        if (c === 113) return "☀️"
        if (c === 116) return "⛅"
        if (c === 119) return "🌥️"
        if (c === 122) return "☁️"
        if (c === 143 || c === 248 || c === 260) return "🌫️"
        if (c >= 263 && c <= 314) return "🌧️"
        if (c >= 317 && c <= 335) return "🌨️"
        if (c >= 386 && c <= 395) return "⛈️"
        return "🌤️"
    }

    function weatherNeedsRefresh() {
        if (root.lastWeatherFetch === null) return true
        return (new Date() - root.lastWeatherFetch) > 3600000
    }

    function fetchWeatherPill() {
        var loc = encodeURIComponent(root.weatherLocation)
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "https://wttr.in/" + loc + "?format=%c+%t&m", true)
        xhr.timeout = 8000
        xhr.setRequestHeader("Accept-Language", "en-GB")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== 4 || xhr.status !== 200) return
            var parts = xhr.responseText.trim().split(/\s+/)
            if (parts.length >= 2) {
                root.weatherIcon = parts[0]
                root.weatherTemp = parts[1]
            }
        }
        xhr.ontimeout = function() {}
        xhr.send()
    }

    function fetchWeatherFull() {
        if (root.weatherLoading) return
        root.weatherLoading = true
        root.chartData = []

        var loc = encodeURIComponent(root.weatherLocation)
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "https://wttr.in/" + loc + "?format=j1&m", true)
        xhr.timeout = 6000
        xhr.setRequestHeader("Accept-Language", "en-GB")

        xhr.ontimeout = function() {
            root.weatherLoading = false
            root.weatherTemp = "Timeout"
            root.weatherIcon = "⏱️"
            root.chartData = [{ label: "Timeout", emoji: "⏱️", temp: 0, tempLabel: "--°", normY: 0.5 }]
        }

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== 4) return
            root.weatherLoading = false

            if (xhr.status !== 200) {
                root.chartData = [{ label: "Error", emoji: "⚠️", temp: 0, tempLabel: "--°", normY: 0.5 }]
                return
            }

            try {
                var json = JSON.parse(xhr.responseText)
                var now  = new Date()
                var nowH = now.getHours()

                var cur = json.current_condition[0]
                root.currentTemp  = cur.temp_C + "°C"
                root.currentDesc  = cur.weatherDesc[0].value
                root.currentEmoji = root.codeToEmoji(cur.weatherCode)
                root.todayLow     = json.weather[0].mintempC + "°"
                root.todayHigh    = json.weather[0].maxtempC + "°"
                root.weatherIcon  = root.codeToEmoji(cur.weatherCode)
                root.weatherTemp  = cur.temp_C + "°C"

                var slots = []
                for (var d = 0; d < 2 && slots.length < 9; d++) {
                    var hourly = json.weather[d].hourly
                    for (var h = 0; h < hourly.length && slots.length < 9; h++) {
                        var entry    = hourly[h]
                        var slotHour = parseInt(entry.time) / 100
                        var slotDate = new Date(now)
                        slotDate.setDate(now.getDate() + d)
                        slotDate.setHours(slotHour, 0, 0, 0)

                        var isNow = (d === 0 && slotHour <= nowH && slotHour + 3 > nowH)
                        if (slotDate < now && !isNow) continue

                        slots.push({
                            label:     isNow ? "Now" : slotDate.getHours().toString().padStart(2,"0") + ":00",
                            emoji:     root.codeToEmoji(entry.weatherCode),
                            temp:      parseInt(entry.tempC),
                            tempLabel: entry.tempC + "°",
                            normY:     0
                        })
                    }
                }

                if (slots.length > 0) {
                    var temps = slots.map(function(s) { return s.temp })
                    var minT  = Math.min.apply(null, temps)
                    var maxT  = Math.max.apply(null, temps)
                    var rng   = maxT - minT || 1
                    for (var i = 0; i < slots.length; i++)
                        slots[i].normY = 1.0 - (slots[i].temp - minT) / rng
                }

                root.chartData = slots.length > 0 ? slots : [{ label: "No data", emoji: "🤷", temp: 0, tempLabel: "--°", normY: 0.5 }]
                root.lastWeatherFetch = new Date()

            } catch(e) {
                root.chartData = [{ label: "Parse error", emoji: "⚠️", temp: 0, tempLabel: "--°", normY: 0.5 }]
            }
        }
        xhr.send()
    }

    Timer {
        interval: 900000; running: true; repeat: true
        onTriggered: root.fetchWeatherFull()
    }
    Component.onCompleted: root.fetchWeatherFull()

    // ─── Clock & Battery ──────────────────────────────────────────────────
    property string clockTime: Qt.formatTime(new Date(), "HH:mm")
    property string clockDate: Qt.formatDate(new Date(), "ddd d MMM")

    SystemClock {
        precision: SystemClock.Minutes
        onDateChanged: {
            root.clockTime = Qt.formatTime(date, "HH:mm")
            root.clockDate = Qt.formatDate(date, "ddd d MMM")
        }
    }

    property int    batCapacity: 100
    property string batStatus:   "Unknown"
    property bool   batCharging: batStatus === "Charging" || batStatus === "Full"
    property color  batColor:    batCharging ? "#32d74b" : batCapacity <= 20 ? "#ff453a" : "#ffffff"

    Process {
        command: [
            "bash", "-c",
            "while true; do cat /sys/class/power_supply/BAT1/capacity 2>/dev/null || echo 0; " +
            "cat /sys/class/power_supply/BAT1/status 2>/dev/null || echo Unknown; sleep 30; done"
        ]
        running: true
        stdout: SplitParser {
            property bool nextIsStatus: false
            onRead: (line) => {
                if (!nextIsStatus) { root.batCapacity = parseInt(line.trim()); nextIsStatus = true }
                else               { root.batStatus   = line.trim();           nextIsStatus = false }
            }
        }
    }

    // ─── Calendar State ───────────────────────────────────────────────────
    property int calYear:  new Date().getFullYear()
    property int calMonth: new Date().getMonth()

    readonly property var monthNames: [
        "January","February","March","April","May","June",
        "July","August","September","October","November","December"
    ]
    readonly property var dayNames: ["Mo","Tu","We","Th","Fr","Sa","Su"]

    function calendarCells() {
        var today       = new Date()
        var firstDay    = new Date(root.calYear, root.calMonth, 1)
        var startDow    = (firstDay.getDay() + 6) % 7
        var daysInMonth = new Date(root.calYear, root.calMonth + 1, 0).getDate()
        var daysInPrev  = new Date(root.calYear, root.calMonth, 0).getDate()
        var cells       = []

        for (var p = startDow - 1; p >= 0; p--)
            cells.push({ day: daysInPrev - p, isCurrentMonth: false, isToday: false })

        for (var d = 1; d <= daysInMonth; d++) {
            cells.push({
                day: d,
                isCurrentMonth: true,
                isToday: (d === today.getDate() &&
                          root.calMonth === today.getMonth() &&
                          root.calYear  === today.getFullYear())
            })
        }

        var remaining = (7 - cells.length % 7) % 7
        for (var n = 1; n <= remaining; n++)
            cells.push({ day: n, isCurrentMonth: false, isToday: false })

        return cells
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ─── Music / MPRIS State ──────────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════════════════

    property string musicTitle:    "Nothing playing"
    property string musicArtist:   "—"
    property string musicAlbum:    ""
    property string musicArtUrl:   ""
    property string musicStatus:   "Stopped"
    property int    musicPosition: 0
    property int    musicLength:   0
    property real   musicProgress: 0.0
    property string musicPlayer:   ""

    property var cavaHeights: [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]

    Process {
        id: mprisProc
        command: [
            "bash", "-c",
            "while true; do " +
            "  if playerctl status >/dev/null 2>&1; then " +
            "    fmt='{{title}}\n{{artist}}\n{{album}}\n{{mpris:artUrl}}\n{{status}}\n{{position}}\n{{mpris:length}}\n{{playerName}}\n---END---'; " +
            "    playerctl metadata --format \"$fmt\" " +
            "      2>/dev/null || printf '\n\n\n\nStopped\n0\n0\n\n---END---\n'; " +
            "  else " +
            "    printf '\n\n\n\nStopped\n0\n0\n\n---END---\n'; " +
            "  fi; " +
            "  sleep 1; " +
            "done"
        ]
        running: true
        stdout: SplitParser {
            property var buf: []
            onRead: (line) => {
                if (line.trim() === "---END---") {
                    if (buf.length >= 8) {
                        var title  = buf[0].trim()
                        var artist = buf[1].trim()
                        var album  = buf[2].trim()
                        var artUrl = buf[3].trim()
                        var status = buf[4].trim()
                        var pos    = parseInt(buf[5]) || 0
                        var len    = parseInt(buf[6]) || 0
                        var player = buf[7].trim()

                        if (status === "Stopped" || title.length === 0) {
                            root.musicTitle    = "Nothing playing"
                            root.musicArtist   = "—"
                            root.musicAlbum    = ""
                            root.musicArtUrl   = ""
                            root.musicProgress = 0
                            root.musicStatus   = "Stopped"
                            root.musicPlayer   = player
                        } else {
                            root.musicTitle    = title.length  > 0 ? title  : "Unknown Title"
                            root.musicArtist   = artist.length > 0 ? artist : "Unknown Artist"
                            root.musicAlbum    = album
                            root.musicArtUrl   = artUrl
                            root.musicStatus   = status
                            root.musicPosition = pos
                            root.musicLength   = len
                            root.musicPlayer   = player
                            root.musicProgress = len > 0 ? Math.min(1.0, pos / len) : 0.0
                        }
                    }
                    buf = []
                } else {
                    buf.push(line)
                }
            }
        }
    }

    // ── Cava visualiser ───────────────────────────────────────────────────
    property string cavaConfigPath: ""
    property bool   cavaAvailable:  false

    Process {
        id: cavaCheckProc
        command: ["bash", "-c", "command -v cava && echo yes || echo no"]
        running: true
        stdout: SplitParser {
            onRead: (line) => {
                root.cavaAvailable = line.trim() === "yes" || line.trim().endsWith("cava")
                if (root.cavaAvailable) writeCavaConfig.running = true
            }
        }
    }

    Process {
        id: writeCavaConfig
        command: [
            "bash", "-c",
            "mkdir -p /tmp/mango-cava && cat > /tmp/mango-cava/config << 'EOF'\n" +
            "[general]\n" +
            "bars = 20\n" +
            "framerate = 30\n" +
            "[output]\n" +
            "method = raw\n" +
            "raw_target = /tmp/mango-cava/fifo\n" +
            "data_format = ascii\n" +
            "ascii_max_range = 100\n" +
            "bar_delimiter = 59\n" +
            "[input]\n" +
            "method = pulse\n" +
            "EOF\n" +
            "mkfifo /tmp/mango-cava/fifo 2>/dev/null || true\n" +
            "echo /tmp/mango-cava/config"
        ]
        running: false
        stdout: SplitParser {
            onRead: (line) => {
                root.cavaConfigPath = line.trim()
                if (root.cavaConfigPath.length > 0) cavaProc.running = true
            }
        }
    }

    Process {
        id: cavaProc
        command: ["bash", "-c",
            "cava -p /tmp/mango-cava/config 2>/dev/null & " +
            "cat /tmp/mango-cava/fifo"
        ]
        running: false
        stdout: SplitParser {
            onRead: (line) => {
                var parts = line.trim().replace(/;$/, "").split(";")
                if (parts.length < 1) return
                var bars = []
                for (var i = 0; i < 20; i++) {
                    var raw = i < parts.length ? parseInt(parts[i]) : 0
                    bars.push(Math.max(0, Math.min(1, (isNaN(raw) ? 0 : raw) / 100)))
                }
                root.cavaHeights = bars
            }
        }
    }

    Timer {
        id: fakeCavaTimer
        interval: 80; running: !root.cavaAvailable; repeat: true
        property real phase: 0
        onTriggered: {
            phase += 0.18
            var bars    = []
            var playing = root.musicStatus === "Playing"
            for (var i = 0; i < 20; i++) {
                if (!playing) {
                    bars.push(0)
                } else {
                    var v = 0.45 + 0.45 * Math.sin(phase + i * 0.55)
                          + 0.10 * Math.sin(phase * 1.7 + i * 1.1)
                    bars.push(Math.max(0, Math.min(1, v)))
                }
            }
            root.cavaHeights = bars
        }
    }

    property bool musicPopupVisible: false

    Process { id: musicPlayPause; running: false }
    Process { id: musicNext;      running: false }
    Process { id: musicPrev;      running: false }

    function musicTogglePlay() { musicPlayPause.command = ["playerctl", "play-pause"]; musicPlayPause.running = true }
    function musicNextTrack()  { musicNext.command      = ["playerctl", "next"];        musicNext.running      = true }
    function musicPrevTrack()  { musicPrev.command      = ["playerctl", "previous"];    musicPrev.running      = true }

    // ═══════════════════════════════════════════════════════════════════════
    // ─── WiFi State (iwctl backend — pure iwd) ────────────────────────────
    // ═══════════════════════════════════════════════════════════════════════
    property bool   wifiPopupVisible:   false
    property string wifiSsid:           ""
    property int    wifiSignal:         0
    property var    wifiNetworks:       []
    property bool   wifiScanning:       false
    property string wifiConnectMsg:     ""
    property string wifiExpandedSsid:   ""
    property string wifiPasswordInput:  ""

    // ── Live SSID + signal every 5s via iwctl ─────────────────────────────
    Process {
        id: wifiStatusProc
        command: [
            "bash", "-c",
            "while true; do " +
            "  info=$(iwctl station wlan0 show 2>/dev/null); " +
            "  ssid=$(echo \"$info\" | grep 'Connected network' | sed 's/.*Connected network\\s*//' | xargs); " +
            "  rssi=$(echo \"$info\" | grep 'RSSI' | grep -o '\\-[0-9]*' | head -1); " +
            "  echo \"${ssid:-}\"; " +
            "  if [ -n \"$rssi\" ]; then " +
            "    sig=$(awk \"BEGIN{v=($rssi+90)/40*100; if(v<0)v=0; if(v>100)v=100; print int(v)}\"); " +
            "    echo \"$sig\"; " +
            "  else " +
            "    echo '0'; " +
            "  fi; " +
            "  sleep 3; " +
            "done"
        ]
        running: true
        stdout: SplitParser {
            property bool nextIsSignal: false
            onRead: (line) => {
                if (!nextIsSignal) { root.wifiSsid   = line.trim();               nextIsSignal = true  }
                else               { root.wifiSignal = parseInt(line.trim()) || 0; nextIsSignal = false }
            }
        }
    }

    // ── Scan with iwctl ───────────────────────────────────────────────────
    Process {
        id: wifiScanProc
        running: false
        stdout: SplitParser {
            property var buf: []
            onRead: (line) => {
                var clean = line.replace(/\x1b\[[0-9;]*m/g, "").trim()
                if (clean.length === 0) return
                if (clean.indexOf("Network name") !== -1) return
                if (clean.indexOf("----") !== -1) return
                if (clean.indexOf("Available networks") !== -1) return

                var connected = clean.charAt(0) === ">"
                if (connected) clean = clean.substring(1).trim()

                var parts = clean.split(/\s{2,}/)
                if (parts.length < 3) return

                var ssid     = parts[0].trim()
                var security = parts[1].trim()
                var bars     = parts[2].trim()

                if (ssid.length === 0) return

                var sig = Math.round((bars.replace(/[^*]/g, "").length / 4) * 100)

                buf.push({
                    ssid:      ssid,
                    signal:    sig,
                    security:  security === "open" ? "" : "WPA2",
                    connected: connected,
                    icon:      "\uf1eb"
                })
            }
        }
        onRunningChanged: {
            if (!running) {
                if (stdout.buf.length > 0)
                    root.wifiNetworks = stdout.buf.slice()
                stdout.buf        = []
                root.wifiScanning = false
            }
        }
    }

    Timer {
        id: wifiAutoRefreshTimer
        interval: 15000; repeat: true
        running:  root.wifiPopupVisible && !wifiScanProc.running
        onTriggered: root.wifiStartScan()
    }

    function wifiStartScan() {
        root.wifiScanning      = true
        root.wifiConnectMsg    = ""
        root.wifiExpandedSsid  = ""
        root.wifiPasswordInput = ""

        wifiScanProc.command = [
            "bash", "-c",
            "iwctl station wlan0 scan 2>/dev/null; " +
            "sleep 3; " +
            "iwctl station wlan0 get-networks 2>/dev/null"
        ]
        wifiScanProc.running = true
    }

    // ── Connect via iwctl ─────────────────────────────────────────────────
    Process {
        id: wifiConnectProc
        property string pendingSsid: ""
        running: false

        stdout: SplitParser {
            onRead: (line) => {
                var clean = line.replace(/\x1b\[[0-9;]*m/g, "").trim()
                if (clean.length === 0) return
                var low = clean.toLowerCase()
                if (low.indexOf("connected") !== -1) {
                    root.wifiConnectMsg = "✓  Connected to " + wifiConnectProc.pendingSsid
                } else if (low.indexOf("error") !== -1 ||
                           low.indexOf("failed") !== -1 ||
                           low.indexOf("not found") !== -1 ||
                           low.indexOf("incorrect") !== -1) {
                    root.wifiConnectMsg = "✕  " + (
                        low.indexOf("incorrect") !== -1 || low.indexOf("psk") !== -1
                            ? "Wrong password"
                            : low.indexOf("not found") !== -1
                                ? "Network not found"
                                : "Connection failed"
                    )
                }
            }
        }

        stderr: SplitParser {
            onRead: (line) => {
                var clean = line.replace(/\x1b\[[0-9;]*m/g, "").trim()
                if (clean.length === 0) return
                var low = clean.toLowerCase()
                if (low.indexOf("error") !== -1 || low.indexOf("failed") !== -1)
                    root.wifiConnectMsg = "✕  Connection failed"
            }
        }

        onRunningChanged: {
            if (!running) {
                if (root.wifiConnectMsg.indexOf("Connecting") !== -1)
                    root.wifiConnectMsg = "✕  Connection timed out"
                wifiStatusProc.running = false
                wifiStatusProc.running = true
                root.wifiStartScan()
            }
        }
    }

    function wifiConnect(ssid, password) {
        wifiConnectProc.pendingSsid = ssid
        root.wifiConnectMsg         = "Connecting to " + ssid + "…"
        root.wifiExpandedSsid       = ""

        var s = ssid.replace(/'/g, "")
        var p = (password || "").replace(/'/g, "")
        var cmd = p.length > 0
            ? "iwctl --passphrase '" + p + "' station wlan0 connect '" + s + "' 2>&1"
            : "iwctl station wlan0 connect '" + s + "' 2>&1"

        wifiConnectProc.command = ["bash", "-c", cmd]
        wifiConnectProc.running = true
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ─── Main Bar ─────────────────────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════════════════
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: panelWindow
            property var modelData
            screen: modelData

            anchors.top:    root.barEdge !== "bottom"
            anchors.bottom: root.barEdge === "bottom"
            anchors.left:   true
            anchors.right:  true

            margins {
                top:    root.barEdge === "top"    ? 10 : 0
                bottom: root.barEdge === "bottom" ? 10 : 0
                left:   12
                right:  12
            }

            implicitHeight: 46
            color: "transparent"

            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.exclusiveZone: 56

            Rectangle {
                anchors.fill: parent; radius: root.panelRadius
                color: Qt.rgba(0.07, 0.08, 0.10, 0.35)
                border.color: Qt.rgba(1,1,1,0.09); border.width: 1
                Rectangle {
                    x: (parent.width - width) / 2
                    y: root.barEdge === "bottom" ? parent.height - 2 : 1
                    width: parent.width * 0.45; height: 1; radius: 1
                    color: Qt.rgba(1,1,1,0.18)
                }
            }

            // ── Centre clock ───────────────────────────────────────────────
            Item {
                anchors.centerIn: parent
                implicitWidth: clockCol.implicitWidth + 24; implicitHeight: 36

                Rectangle {
                    id: clockHoverBg; anchors.fill: parent; radius: root.squircleRadius
                    color: Qt.rgba(1,1,1,0.0)
                    Behavior on color { ColorAnimation { duration: 130 } }
                }
                Column {
                    id: clockCol; anchors.centerIn: parent; spacing: 1
                    Text {
                        text: root.clockTime; font.pixelSize: 13; font.family: "SF Pro Display"
                        font.weight: Font.Medium; color: "white"
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                    Text {
                        text: root.clockDate; font.pixelSize: 10; font.family: "SF Pro Display"
                        color: Qt.rgba(1,1,1,0.45)
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }
                MouseArea {
                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onEntered: clockHoverBg.color = Qt.rgba(1,1,1,0.07)
                    onExited:  clockHoverBg.color = Qt.rgba(1,1,1,0.0)
                    onClicked: {
                        if (!calendarPopupWindow.visible) {
                            root.calYear  = new Date().getFullYear()
                            root.calMonth = new Date().getMonth()
                        }
                        calendarPopupWindow.visible = !calendarPopupWindow.visible
                    }
                }
            }

            RowLayout {
                anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                spacing: 0

                // ── Left cluster ───────────────────────────────────────────
                RowLayout {
                    spacing: 8

                    // ── Hyprland logo → Settings ───────────────────────────
                    Item {
                        implicitWidth: 28; implicitHeight: 28
                        Rectangle {
                            id: logoHoverBg; anchors.fill: parent; radius: root.squircleRadius
                            color: Qt.rgba(1,1,1,0.0)
                            Behavior on color { ColorAnimation { duration: 130 } }
                        }
                        Text {
                            anchors.centerIn: parent
                            text: "\uf303"
                            font.family: "Symbols Nerd Font"; font.pixelSize: 18; color: "white"
                        }
                        MouseArea {
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onEntered: logoHoverBg.color = Qt.rgba(1,1,1,0.10)
                            onExited:  logoHoverBg.color = Qt.rgba(1,1,1,0.0)
                            onClicked: settingsPopupWindow.visible = !settingsPopupWindow.visible
                        }
                    }

                    Rectangle { width: 1; height: 16; color: Qt.rgba(1,1,1,0.10); radius: 1 }

                    // ── Workspaces 1–9 ─────────────────────────────────────
                    RowLayout {
                        spacing: 3
                        Repeater {
                            model: 9
                            delegate: Item {
                                implicitWidth: 26; implicitHeight: 30
                                property bool isFoc: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === (index + 1)
                                property bool isOcc: {
                                    for (var i = 0; i < Hyprland.workspaces.length; i++)
                                        if (Hyprland.workspaces[i].id === (index + 1)) return true
                                    return false
                                }

                                Rectangle {
                                    anchors.centerIn: parent
                                    width: isFoc ? 24 : 20; height: width
                                    radius: root.squircleRadius * (isFoc ? 1 : 0.8)
                                    color: isFoc ? Qt.rgba(1,1,1,0.14) : isOcc ? Qt.rgba(1,1,1,0.05) : "transparent"
                                    border.color: isOcc && !isFoc ? Qt.rgba(1,1,1,0.12) : "transparent"
                                    border.width: 1
                                    Behavior on width  { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                    Behavior on radius { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                    Behavior on color  { ColorAnimation  { duration: 180 } }
                                }
                                Text {
                                    anchors.centerIn: parent; text: index + 1
                                    font.pixelSize: 11; font.family: "SF Pro Display"
                                    color: isFoc ? "white" : isOcc ? Qt.rgba(1,1,1,0.75) : Qt.rgba(1,1,1,0.28)
                                    Behavior on color { ColorAnimation { duration: 180 } }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.switchWorkspace(index + 1)
                                }
                            }
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                // ── Right cluster ──────────────────────────────────────────
                RowLayout {
                    layoutDirection: Qt.RightToLeft; spacing: 12

                    RowLayout {
                        spacing: 5
                        Text { text: root.batCharging ? "\uf0e7" : "\uf240"; font.family: "Symbols Nerd Font"; font.pixelSize: 13; color: root.batColor }
                        Text { text: root.batCapacity + "%"; font.pixelSize: 12; font.family: "SF Pro Display"; color: root.batColor }
                    }

                    // ── WiFi Pill ──────────────────────────────────────────
                    Item {
                        id: wifiPill
                        implicitWidth: wifiPillRow.implicitWidth + 18; implicitHeight: 30

                        Rectangle {
                            id: wifiPillBg; anchors.fill: parent; radius: root.squircleRadius
                            color: Qt.rgba(1,1,1,0.0)
                            Behavior on color { ColorAnimation { duration: 130 } }
                        }
                        RowLayout {
                            id: wifiPillRow; anchors.centerIn: parent; spacing: 6

                            Row {
                                spacing: 2
                                Repeater {
                                    model: 4
                                    delegate: Rectangle {
                                        width: 3; height: 4 + index * 3; radius: 1
                                        anchors.bottom: parent ? parent.bottom : undefined
                                        color: {
                                            if (root.wifiSsid.length === 0) return Qt.rgba(1,1,1,0.15)
                                            return root.wifiSignal >= (index + 1) * 25
                                                ? "white"
                                                : Qt.rgba(1,1,1,0.20)
                                        }
                                        Behavior on color { ColorAnimation { duration: 200 } }
                                    }
                                }
                            }

                            Text {
                                text: root.wifiSsid.length > 0 ? root.wifiSsid : "No WiFi"
                                font.family: "SF Pro Display"; font.pixelSize: 12
                                color: root.wifiSsid.length > 0 ? "white" : Qt.rgba(1,1,1,0.35)
                                elide: Text.ElideRight
                                Layout.maximumWidth: 120
                            }
                        }
                        MouseArea {
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onEntered: wifiPillBg.color = Qt.rgba(1,1,1,0.08)
                            onExited:  wifiPillBg.color = Qt.rgba(1,1,1,0.0)
                            onClicked: {
                                root.wifiPopupVisible = !root.wifiPopupVisible
                                if (root.wifiPopupVisible) root.wifiStartScan()
                            }
                        }
                    }

                    // ── Weather Pill ───────────────────────────────────────
                    Item {
                        implicitWidth: weatherRow.implicitWidth + 18; implicitHeight: 30
                        Rectangle {
                            id: weatherHoverBg; anchors.fill: parent; radius: root.squircleRadius
                            color: Qt.rgba(1,1,1,0.0)
                            Behavior on color { ColorAnimation { duration: 130 } }
                        }
                        RowLayout {
                            id: weatherRow; anchors.centerIn: parent; spacing: 6
                            Text { text: root.weatherIcon; font.pixelSize: 16 }
                            Text { text: root.weatherTemp; font.pixelSize: 12; font.family: "SF Pro Display"; color: "white" }
                        }
                        MouseArea {
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onEntered: weatherHoverBg.color = Qt.rgba(1,1,1,0.08)
                            onExited:  weatherHoverBg.color = Qt.rgba(1,1,1,0.0)
                            onClicked: {
                                if (weatherPopupWindow.visible) {
                                    weatherPopupWindow.visible = false
                                } else {
                                    if (root.weatherNeedsRefresh()) root.fetchWeatherFull()
                                    weatherPopupWindow.visible = true
                                }
                            }
                        }
                    }

                    // ── Music Pill ─────────────────────────────────────────
                    Item {
                        id: musicPill
                        implicitWidth: musicPillRow.implicitWidth + 18
                        implicitHeight: 30
                        visible: true

                        Rectangle {
                            id: musicPillBg; anchors.fill: parent; radius: root.squircleRadius
                            color: Qt.rgba(1,1,1,0.0)
                            Behavior on color { ColorAnimation { duration: 130 } }
                        }

                        RowLayout {
                            id: musicPillRow; anchors.centerIn: parent; spacing: 7

                            Row {
                                spacing: 2
                                Repeater {
                                    model: 5
                                    delegate: Rectangle {
                                        width: 2; radius: 1
                                        color: root.musicStatus === "Playing"
                                            ? Qt.rgba(0.72, 0.88, 1.0, 0.85)
                                            : Qt.rgba(1,1,1,0.30)
                                        height: root.musicStatus === "Playing"
                                            ? Math.max(4, root.cavaHeights[index * 3] * 14)
                                            : 6
                                        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                                        Behavior on height { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }
                                        Behavior on color  { ColorAnimation  { duration: 150 } }
                                    }
                                }
                            }

                            Text {
                                text: root.musicTitle
                                font.pixelSize: 11; font.family: "SF Pro Display"
                                color: "white"
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                Layout.maximumWidth: 160
                            }
                        }

                        MouseArea {
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onEntered: musicPillBg.color = Qt.rgba(1,1,1,0.08)
                            onExited:  musicPillBg.color = Qt.rgba(1,1,1,0.0)
                            onClicked: root.musicPopupVisible = !root.musicPopupVisible
                        }
                    }

                    // ── System Tray ────────────────────────────────────────
                    Item {
                        implicitWidth: SystemTray.items.count > 0
                            ? SystemTray.items.count * 26 : 0
                        implicitHeight: 30

                        Row {
                            anchors.right:          parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8
                            layoutDirection: Qt.RightToLeft

                            Repeater {
                                model: SystemTray.items
                                delegate: Item {
                                    required property var modelData
                                    width: 18; height: 18

                                    property string rawIcon:    modelData ? (modelData.icon ?? "") : ""
                                    property bool   isBareName: rawIcon.length > 0
                                                                 && !rawIcon.includes("/")
                                                                 && !rawIcon.includes(":")

                                    Image {
                                        id: imgSvg; anchors.fill: parent
                                        fillMode: Image.PreserveAspectFit; opacity: 0.82
                                        visible: status === Image.Ready
                                        source: (isBareName && root.iconTheme.length > 0 && root.homeDir.length > 0)
                                            ? "file://" + root.homeDir + "/.local/share/icons/"
                                              + root.iconTheme + "/scalable/apps/" + rawIcon + ".svg"
                                            : ""
                                    }
                                    Image {
                                        id: imgSymbolic; anchors.fill: parent
                                        fillMode: Image.PreserveAspectFit; opacity: 0.82
                                        visible: imgSvg.status !== Image.Ready && status === Image.Ready
                                        source: (isBareName && imgSvg.status !== Image.Ready
                                                 && root.iconTheme.length > 0 && root.homeDir.length > 0)
                                            ? "file://" + root.homeDir + "/.local/share/icons/"
                                              + root.iconTheme + "/symbolic/apps/" + rawIcon + "-symbolic.svg"
                                            : ""
                                    }
                                    Image {
                                        id: imgPng48; anchors.fill: parent
                                        fillMode: Image.PreserveAspectFit; opacity: 0.82
                                        visible: imgSvg.status !== Image.Ready
                                              && imgSymbolic.status !== Image.Ready
                                              && status === Image.Ready
                                        source: (isBareName
                                                 && imgSvg.status !== Image.Ready
                                                 && imgSymbolic.status !== Image.Ready
                                                 && root.iconTheme.length > 0 && root.homeDir.length > 0)
                                            ? "file://" + root.homeDir + "/.local/share/icons/"
                                              + root.iconTheme + "/48x48/apps/" + rawIcon + ".png"
                                            : ""
                                    }
                                    Image {
                                        id: imgPng32; anchors.fill: parent
                                        fillMode: Image.PreserveAspectFit; opacity: 0.82
                                        property bool prevFailed: imgSvg.status !== Image.Ready
                                                                && imgSymbolic.status !== Image.Ready
                                                                && imgPng48.status !== Image.Ready
                                        visible: prevFailed && status === Image.Ready
                                        source: (isBareName && prevFailed
                                                 && root.iconTheme.length > 0 && root.homeDir.length > 0)
                                            ? "file://" + root.homeDir + "/.local/share/icons/"
                                              + root.iconTheme + "/32x32/apps/" + rawIcon + ".png"
                                            : ""
                                    }
                                    Image {
                                        id: imgQtTheme; anchors.fill: parent
                                        fillMode: Image.PreserveAspectFit; opacity: 0.82
                                        property bool prevFailed: imgSvg.status !== Image.Ready
                                                                && imgSymbolic.status !== Image.Ready
                                                                && imgPng48.status !== Image.Ready
                                                                && imgPng32.status !== Image.Ready
                                        visible: prevFailed && status === Image.Ready
                                        source: prevFailed ? (isBareName ? "image://icon/" + rawIcon : rawIcon) : ""
                                    }
                                    Image {
                                        id: imgDirect; anchors.fill: parent
                                        fillMode: Image.PreserveAspectFit; opacity: 0.82
                                        visible: !isBareName && status === Image.Ready
                                        source: !isBareName ? rawIcon : ""
                                    }

                                    property bool allFailed: imgSvg.status     !== Image.Ready
                                                          && imgSymbolic.status !== Image.Ready
                                                          && imgPng48.status    !== Image.Ready
                                                          && imgPng32.status    !== Image.Ready
                                                          && imgQtTheme.status  !== Image.Ready
                                                          && imgDirect.status   !== Image.Ready
                                    Rectangle {
                                        anchors.fill: parent; radius: 4
                                        visible: parent.allFailed
                                        color: {
                                            if (!modelData || !modelData.title) return Qt.rgba(0.3,0.3,0.4,0.7)
                                            var h = 5381
                                            for (var i = 0; i < modelData.title.length; i++)
                                                h = ((h << 5) + h) + modelData.title.charCodeAt(i)
                                            return Qt.hsla(((h >>> 0) % 360) / 360, 0.55, 0.42, 0.85)
                                        }
                                        Text {
                                            anchors.centerIn: parent
                                            text: (modelData && modelData.title) ? modelData.title.charAt(0).toUpperCase() : "?"
                                            font.family: "SF Pro Display"; font.pixelSize: 11
                                            font.weight: Font.SemiBold; color: "white"
                                        }
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        onClicked: (m) => {
                                            if (!modelData) return
                                            m.button === Qt.LeftButton
                                                ? modelData.activate(0, 0)
                                                : modelData.secondaryActivate(0, 0)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ── Settings Popup ─────────────────────────────────────────────
            PanelWindow {
                id: settingsPopupWindow
                screen: panelWindow.screen; visible: false
                anchors.top:    root.barEdge !== "bottom"
                anchors.bottom: root.barEdge === "bottom"
                anchors.left: true
                margins {
                    top:    root.barEdge !== "bottom" ? 66 : 0
                    bottom: root.barEdge === "bottom" ? 66 : 0
                    left: 12
                }
                onVisibleChanged: if (visible) locationField.text = root.weatherLocation
                implicitWidth: 360
                implicitHeight: Math.min(settingsCol.implicitHeight + 32,
                    (panelWindow.screen ? panelWindow.screen.height * 0.80 : 800))
                color: "transparent"
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.exclusiveZone: -1
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

                Rectangle {
                    anchors.fill: parent; radius: root.panelRadius
                    color: Qt.rgba(0.06, 0.07, 0.10, 0.3); border.color: Qt.rgba(1,1,1,0.09); border.width: 1
                    Rectangle {
                        anchors { top: parent.top; topMargin: 1; horizontalCenter: parent.horizontalCenter }
                        width: parent.width * 0.4; height: 1; color: Qt.rgba(1,1,1,0.15); radius: 1
                    }
                }

                Flickable {
                    anchors.fill: parent; anchors.margins: 16
                    contentHeight: settingsCol.implicitHeight; clip: true
                    ScrollBar.vertical: ScrollBar {
                        policy: parent.contentHeight > parent.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                        width: 3
                        contentItem: Rectangle { radius: 1.5; color: Qt.rgba(1,1,1,0.22) }
                        background: Rectangle { color: "transparent" }
                    }

                    Column {
                        id: settingsCol; width: parent.width; spacing: 0

                        RowLayout {
                            width: parent.width; height: 36
                            RowLayout {
                                spacing: 8
                                Text { text: "\uf013"; font.family: "Symbols Nerd Font"; font.pixelSize: 13; color: Qt.rgba(1,1,1,0.45) }
                                Text { text: "Bar Settings"; font.family: "SF Pro Display"; font.pixelSize: 13; font.weight: Font.SemiBold; color: "white" }
                            }
                            Item { Layout.fillWidth: true }
                            Item {
                                implicitWidth: 22; implicitHeight: 22
                                Rectangle { id: settingsCloseBg; anchors.fill: parent; radius: 11; color: Qt.rgba(1,1,1,0.0); Behavior on color { ColorAnimation { duration: 100 } } }
                                Text { anchors.centerIn: parent; text: "\u2715"; font.pixelSize: 9; color: Qt.rgba(1,1,1,0.35) }
                                MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: settingsCloseBg.color = Qt.rgba(1,1,1,0.10); onExited: settingsCloseBg.color = Qt.rgba(1,1,1,0.0); onClicked: settingsPopupWindow.visible = false }
                            }
                        }

                        Rectangle { width: parent.width; height: 1; color: Qt.rgba(1,1,1,0.07) }
                        Item { width: 1; height: 14 }

                        Text { text: "WEATHER LOCATION"; font.family: "SF Pro Display"; font.pixelSize: 9; font.weight: Font.SemiBold; color: Qt.rgba(1,1,1,0.30); font.letterSpacing: 0.8 }
                        Item { width: 1; height: 6 }

                        RowLayout {
                            width: parent.width; spacing: 8
                            Rectangle {
                                Layout.fillWidth: true; height: 32; radius: root.pillRadius
                                color: Qt.rgba(1,1,1,0.06)
                                border.color: locationField.activeFocus ? Qt.rgba(0.42,0.68,1.0,0.60) : Qt.rgba(1,1,1,0.10)
                                border.width: 1
                                Behavior on border.color { ColorAnimation { duration: 150 } }
                                TextInput {
                                    id: locationField
                                    anchors { fill: parent; leftMargin: 10; rightMargin: 10; topMargin: 2 }
                                    verticalAlignment: TextInput.AlignVCenter; focus: true
                                    font.family: "SF Pro Display"; font.pixelSize: 12; color: "white"
                                    selectionColor: Qt.rgba(0.42,0.68,1.0,0.35); clip: true
                                    Component.onCompleted: text = root.weatherLocation
                                    onAccepted: applyLocationBtn.applyLocation()
                                }
                            }
                            Item {
                                id: applyLocationBtn
                                implicitWidth: applyLabel.implicitWidth + 20; implicitHeight: 32
                                function applyLocation() {
                                    var loc = locationField.text.trim()
                                    if (loc.length === 0) return
                                    root.weatherLocation = loc
                                    root.lastWeatherFetch = null; root.chartData = []
                                    root.weatherTemp = "--°C"; root.weatherIcon = "🌡️"
                                    root.currentTemp = "--°C"; root.currentDesc = "—"
                                    root.todayLow = "--°"; root.todayHigh = "--°"; root.currentEmoji = "🌡️"
                                    root.fetchWeatherFull(); root.saveSettings()
                                }
                                Rectangle { id: applyBg; anchors.fill: parent; radius: root.pillRadius; color: Qt.rgba(0.42,0.68,1.0,0.22); border.color: Qt.rgba(0.42,0.68,1.0,0.35); border.width: 1; Behavior on color { ColorAnimation { duration: 120 } } }
                                Text { id: applyLabel; anchors.centerIn: parent; text: "Apply"; font.family: "SF Pro Display"; font.pixelSize: 11; color: Qt.rgba(0.72,0.88,1.0,0.90) }
                                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onEntered: applyBg.color = Qt.rgba(0.42,0.68,1.0,0.35); onExited: applyBg.color = Qt.rgba(0.42,0.68,1.0,0.22); onClicked: applyLocationBtn.applyLocation() }
                            }
                        }

                        Item { width: 1; height: 4 }
                        Text { text: "City name, lat,lon, or airport code — anything wttr.in understands"; font.family: "SF Pro Display"; font.pixelSize: 9; color: Qt.rgba(1,1,1,0.22); wrapMode: Text.WordWrap; width: parent.width }

                        Item { width: 1; height: 18 }
                        Text { text: "BAR POSITION"; font.family: "SF Pro Display"; font.pixelSize: 9; font.weight: Font.SemiBold; color: Qt.rgba(1,1,1,0.30); font.letterSpacing: 0.8 }
                        Item { width: 1; height: 8 }

                        RowLayout {
                            width: parent.width; spacing: 8
                            Repeater {
                                model: [{ edge: "top", icon: "\uf077", label: "Top" }, { edge: "bottom", icon: "\uf078", label: "Bottom" }]
                                delegate: Item {
                                    required property var modelData
                                    Layout.fillWidth: true; height: 36
                                    Rectangle {
                                        anchors.fill: parent; radius: root.pillRadius
                                        color: root.barEdge === modelData.edge ? Qt.rgba(0.42,0.68,1.0,0.22) : edgeOptHov.containsMouse ? Qt.rgba(1,1,1,0.08) : Qt.rgba(1,1,1,0.05)
                                        border.color: root.barEdge === modelData.edge ? Qt.rgba(0.42,0.68,1.0,0.3) : Qt.rgba(1,1,1,0.09); border.width: 1
                                        Behavior on color { ColorAnimation { duration: 130 } }
                                    }
                                    RowLayout { anchors.centerIn: parent; spacing: 7
                                        Text { text: modelData.icon; font.family: "Symbols Nerd Font"; font.pixelSize: 10; color: root.barEdge === modelData.edge ? Qt.rgba(0.72,0.88,1.0,0.90) : Qt.rgba(1,1,1,0.40) }
                                        Text { text: modelData.label; font.family: "SF Pro Display"; font.pixelSize: 12; color: root.barEdge === modelData.edge ? "white" : Qt.rgba(1,1,1,0.45) }
                                    }
                                    MouseArea { id: edgeOptHov; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.barEdge = modelData.edge; root.saveSettings() } }
                                }
                            }
                        }

                        Item { width: 1; height: 18 }
                        Text { text: "ICON THEME"; font.family: "SF Pro Display"; font.pixelSize: 9; font.weight: Font.SemiBold; color: Qt.rgba(1,1,1,0.30); font.letterSpacing: 0.8 }
                        Item { width: 1; height: 6 }

                        Item {
                            width: parent.width; height: 28
                            Rectangle { anchors.fill: parent; radius: root.pillRadius; color: Qt.rgba(1,1,1,0.06); border.color: root.iconTheme.length > 0 ? Qt.rgba(0.42,0.68,1.0,0.35) : Qt.rgba(1,1,1,0.10); border.width: 1 }
                            Text { anchors { left: parent.left; leftMargin: 10; right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                                text: root.iconTheme.length > 0 ? root.iconTheme : "System default"; font.family: "SF Pro Display"; font.pixelSize: 11; color: root.iconTheme.length > 0 ? "white" : Qt.rgba(1,1,1,0.35); elide: Text.ElideRight }
                        }
                        Item { width: 1; height: 6 }

                        Item {
                            width: parent.width
                            height: root.iconThemeList.length === 0 ? 28 : Math.min(root.iconThemeList.length * 34, 136)
                            clip: true
                            Text { anchors.centerIn: parent; visible: root.iconThemeList.length === 0; text: "No themes found in ~/.local/share/icons"; font.family: "SF Pro Display"; font.pixelSize: 10; color: Qt.rgba(1,1,1,0.22) }
                            ListView {
                                id: themeListView; anchors.fill: parent; visible: root.iconThemeList.length > 0; model: root.iconThemeList; spacing: 4; clip: true
                                ScrollBar.vertical: ScrollBar { policy: themeListView.contentHeight > themeListView.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff; width: 3; contentItem: Rectangle { radius: 1.5; color: Qt.rgba(1,1,1,0.25) }
                                    background: Rectangle { color: "transparent" } }
                                delegate: Item {
                                    required property string modelData; required property int index
                                    width: themeListView.width; height: 30
                                    property bool isActive: root.iconTheme === modelData
                                    Rectangle { anchors.fill: parent; radius: root.pillRadius; color: isActive ? Qt.rgba(0.42,0.68,1.0,0.20) : themeRowHov.containsMouse ? Qt.rgba(1,1,1,0.07) : "transparent"; border.color: isActive ? Qt.rgba(0.42,0.68,1.0,0.3) : "transparent"; border.width: 1; Behavior on color { ColorAnimation { duration: 110 } } }
                                    RowLayout { anchors { fill: parent; leftMargin: 10; rightMargin: 10 } spacing: 8
                                        Text { Layout.fillWidth: true; text: modelData; font.family: "SF Pro Display"; font.pixelSize: 11; color: isActive ? "white" : Qt.rgba(1,1,1,0.65); elide: Text.ElideRight }
                                        Text { visible: isActive; text: ""; font.family: "Symbols Nerd Font"; font.pixelSize: 10; color: Qt.rgba(0.72,0.88,1.0,0.90) }
                                    }
                                    MouseArea { id: themeRowHov; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.applyIconTheme(modelData) }
                                }
                            }
                        }

                        Item { width: 1; height: 6 }
                        Item {
                            width: parent.width; height: 24; visible: root.iconTheme.length > 0
                            Rectangle { id: clearThemeBg; anchors.fill: parent; radius: root.pillRadius; color: Qt.rgba(1,1,1,0.04); border.color: Qt.rgba(1,1,1,0.08); border.width: 1; Behavior on color { ColorAnimation { duration: 110 } } }
                            Text { anchors.centerIn: parent; text: "Use system default"; font.family: "SF Pro Display"; font.pixelSize: 10; color: Qt.rgba(1,1,1,0.35) }
                            MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onEntered: clearThemeBg.color = Qt.rgba(1,1,1,0.09); onExited: clearThemeBg.color = Qt.rgba(1,1,1,0.04); onClicked: root.applyIconTheme("") }
                        }

                        Item { width: 1; height: 4 }
                        Text { width: parent.width; text: "⚠  Restart Quickshell for icon changes to take full effect."; font.family: "SF Pro Display"; font.pixelSize: 9; color: Qt.rgba(1.0,0.75,0.30,0.3); wrapMode: Text.WordWrap }
                        Item { width: 1; height: 14 }
                        Rectangle { width: parent.width; height: 1; color: Qt.rgba(1,1,1,0.06) }
                        Item { width: 1; height: 10 }
                        Text { text: "mango-bar · Hyprland"; font.family: "SF Pro Display"; font.pixelSize: 9; color: Qt.rgba(1,1,1,0.16) }
                        Item { width: 1; height: 4 }
                    }
                }
            }

            // ── Calendar Popup ─────────────────────────────────────────────
            PanelWindow {
                id: calendarPopupWindow
                screen: panelWindow.screen; visible: false
                anchors.top:    root.barEdge !== "bottom"
                anchors.bottom: root.barEdge === "bottom"
                anchors.right: true
                margins {
                    top:    root.barEdge !== "bottom" ? 66 : 0
                    bottom: root.barEdge === "bottom" ? 66 : 0
                    right: { var screenW = panelWindow.screen ? panelWindow.screen.width : 1920; return Math.round((screenW - 280) / 2) }
                }
                implicitWidth: 280; implicitHeight: calendarContentCol.implicitHeight + 32
                color: "transparent"
                WlrLayershell.layer: WlrLayer.Overlay; WlrLayershell.exclusiveZone: -1

                Rectangle {
                    anchors.fill: parent; radius: root.panelRadius
                    color: Qt.rgba(0.06,0.07,0.10,0.3); border.color: Qt.rgba(1,1,1,0.09); border.width: 1
                    Rectangle { anchors { top: parent.top; topMargin: 1; horizontalCenter: parent.horizontalCenter } width: parent.width * 0.4; height: 1; color: Qt.rgba(1,1,1,0.15); radius: 1 }
                }

                Column {
                    id: calendarContentCol
                    anchors { top: parent.top; left: parent.left; right: parent.right; margins: 16 }
                    spacing: 0

                    RowLayout {
                        width: parent.width; height: 36
                        Item { implicitWidth: 26; implicitHeight: 26
                            Rectangle { id: prevBg; anchors.fill: parent; radius: root.pillRadius; color: Qt.rgba(1,1,1,0.0); Behavior on color { ColorAnimation { duration: 100 } } }
                            Text { anchors.centerIn: parent; text: "‹"; font.pixelSize: 16; color: Qt.rgba(1,1,1,0.55) }
                            MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: prevBg.color = Qt.rgba(1,1,1,0.09); onExited: prevBg.color = Qt.rgba(1,1,1,0.0); onClicked: { root.calMonth--; if (root.calMonth < 0) { root.calMonth = 11; root.calYear-- } } }
                        }
                        Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: root.monthNames[root.calMonth] + " " + root.calYear; font.family: "SF Pro Display"; font.pixelSize: 13; font.weight: Font.SemiBold; color: "white" }
                        Item { implicitWidth: 26; implicitHeight: 26
                            Rectangle { id: nextBg; anchors.fill: parent; radius: root.pillRadius; color: Qt.rgba(1,1,1,0.0); Behavior on color { ColorAnimation { duration: 100 } } }
                            Text { anchors.centerIn: parent; text: "›"; font.pixelSize: 16; color: Qt.rgba(1,1,1,0.55) }
                            MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: nextBg.color = Qt.rgba(1,1,1,0.09); onExited: nextBg.color = Qt.rgba(1,1,1,0.0); onClicked: { root.calMonth++; if (root.calMonth > 11) { root.calMonth = 0; root.calYear++ } } }
                        }
                        Item { implicitWidth: 22; implicitHeight: 22
                            Rectangle { id: calCloseBg; anchors.fill: parent; radius: 11; color: Qt.rgba(1,1,1,0.0); Behavior on color { ColorAnimation { duration: 100 } } }
                            Text { anchors.centerIn: parent; text: "\u2715"; font.pixelSize: 9; color: Qt.rgba(1,1,1,0.35) }
                            MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: calCloseBg.color = Qt.rgba(1,1,1,0.10); onExited: calCloseBg.color = Qt.rgba(1,1,1,0.0); onClicked: calendarPopupWindow.visible = false }
                        }
                    }

                    Item { width: 1; height: 6 }
                    Row { width: parent.width; spacing: 0
                        Repeater { model: root.dayNames
                            delegate: Item { width: Math.floor(calendarContentCol.width / 7); height: 24
                                Text { anchors.centerIn: parent; text: modelData; font.family: "SF Pro Display"; font.pixelSize: 10; font.weight: Font.Medium; color: index >= 5 ? Qt.rgba(1,1,1,0.28) : Qt.rgba(1,1,1,0.38) }
                            }
                        }
                    }
                    Rectangle { width: parent.width; height: 1; color: Qt.rgba(1,1,1,0.07) }
                    Item { width: 1; height: 4 }

                    Item {
                        width: parent.width; height: Math.ceil(root.calendarCells().length / 7) * 34
                        Repeater {
                            model: root.calendarCells()
                            delegate: Item {
                                required property var modelData; required property int index
                                property int cellW: Math.floor(calendarContentCol.width / 7)
                                x: (index % 7) * cellW; y: Math.floor(index / 7) * 34
                                width: cellW; height: 34
                                Rectangle { anchors.centerIn: parent; width: 28; height: 28; radius: root.squircleRadius; color: modelData.isToday ? Qt.rgba(0.42,0.68,1.0,0.88) : "transparent"; Behavior on color { ColorAnimation { duration: 120 } } }
                                Text { anchors.centerIn: parent; text: modelData ? modelData.day.toString() : ""; font.family: "SF Pro Display"; font.pixelSize: 12; font.weight: (modelData && modelData.isToday) ? Font.SemiBold : Font.Normal; color: !modelData ? "transparent" : modelData.isToday ? "white" : modelData.isCurrentMonth ? Qt.rgba(1,1,1,0.82) : Qt.rgba(1,1,1,0.22) }
                            }
                        }
                    }

                    Item { width: 1; height: 8 }
                    Item {
                        width: parent.width; height: 28
                        Rectangle { id: todayBtnBg; anchors.fill: parent; radius: root.pillRadius; color: Qt.rgba(1,1,1,0.06); border.color: Qt.rgba(1,1,1,0.08); border.width: 1; Behavior on color { ColorAnimation { duration: 110 } } }
                        Text { anchors.centerIn: parent; text: "Today"; font.family: "SF Pro Display"; font.pixelSize: 11; color: Qt.rgba(1,1,1,0.50) }
                        MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: todayBtnBg.color = Qt.rgba(1,1,1,0.12); onExited: todayBtnBg.color = Qt.rgba(1,1,1,0.06); onClicked: { root.calYear = new Date().getFullYear(); root.calMonth = new Date().getMonth() } }
                    }
                    Item { width: 1; height: 4 }
                }
            }

            // ── Weather Popup ──────────────────────────────────────────────
            PanelWindow {
                id: weatherPopupWindow
                screen: panelWindow.screen; visible: false
                anchors.top:    root.barEdge !== "bottom"
                anchors.bottom: root.barEdge === "bottom"
                anchors.right: true
                margins { top: root.barEdge !== "bottom" ? 66 : 0; bottom: root.barEdge === "bottom" ? 66 : 0; right: 12 }
                implicitWidth: 360; implicitHeight: 310
                color: "transparent"
                WlrLayershell.layer: WlrLayer.Overlay; WlrLayershell.exclusiveZone: -1

                Rectangle {
                    anchors.fill: parent; radius: root.panelRadius
                    color: Qt.rgba(0.06,0.07,0.10,0.5); border.color: Qt.rgba(1,1,1,0.09); border.width: 1
                    Rectangle { anchors { top: parent.top; topMargin: 1; horizontalCenter: parent.horizontalCenter } width: parent.width * 0.5; height: 1; color: Qt.rgba(1,1,1,0.15); radius: 1 }
                }

                Column {
                    anchors { fill: parent; margins: 16 } spacing: 0

                    RowLayout {
                        width: parent.width; height: 48
                        RowLayout { spacing: 10
                            Text { text: root.currentEmoji; font.pixelSize: 34 }
                            Column { spacing: 2
                                Text { text: root.currentTemp; font.family: "SF Pro Display"; font.pixelSize: 24; font.weight: Font.Light; color: "white" }
                                Text { text: root.currentDesc; font.family: "SF Pro Display"; font.pixelSize: 10; color: Qt.rgba(1,1,1,0.45); elide: Text.ElideRight }
                            }
                        }
                        Item { Layout.fillWidth: true }
                        Column { spacing: 3
                            Text { text: root.weatherLocation; font.family: "SF Pro Display"; font.pixelSize: 12; font.weight: Font.SemiBold; color: Qt.rgba(1,1,1,0.55); anchors.right: parent.right; elide: Text.ElideRight }
                            Text { text: "↓ " + root.todayLow + "  ↑ " + root.todayHigh; font.family: "SF Pro Display"; font.pixelSize: 10; color: Qt.rgba(1,1,1,0.35); anchors.right: parent.right }
                            Item { width: 22; height: 22; anchors.right: parent.right
                                Rectangle { id: wxCloseBg; anchors.fill: parent; radius: 11; color: Qt.rgba(1,1,1,0.0); Behavior on color { ColorAnimation { duration: 100 } } }
                                Text { anchors.centerIn: parent; text: "\u2715"; font.pixelSize: 10; color: Qt.rgba(1,1,1,0.35) }
                                MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: wxCloseBg.color = Qt.rgba(1,1,1,0.10); onExited: wxCloseBg.color = Qt.rgba(1,1,1,0.0); onClicked: weatherPopupWindow.visible = false }
                            }
                        }
                    }

                    Item { width: parent.width; height: 8 }
                    Rectangle { width: parent.width; height: 1; color: Qt.rgba(1,1,1,0.07) }
                    Item { width: parent.width; height: 10 }

                    Item { width: parent.width; height: 160; visible: root.chartData.length === 0
                        Column { anchors.centerIn: parent; spacing: 8
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.weatherLoading ? "⏳" : "⚠️"; font.pixelSize: 24 }
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.weatherLoading ? "Fetching forecast…" : "Tap Refresh to retry"; font.family: "SF Pro Display"; font.pixelSize: 12; color: Qt.rgba(1,1,1,0.30) }
                        }
                    }

                    Item {
                        id: chartContainer; width: parent.width; height: 160; visible: root.chartData.length > 0; clip: false
                        Canvas {
                            id: tempCurveCanvas; anchors.fill: parent
                            readonly property int curveTop: 44; readonly property int curveBot: 116
                            property int slotW: root.chartData.length > 0 ? Math.floor(chartContainer.width / root.chartData.length) : 40
                            onSlotWChanged: requestPaint()
                            Connections { target: root; function onChartDataChanged() { if (root.chartData.length > 0) tempCurveCanvas.requestPaint() } }
                            Component.onCompleted: Qt.callLater(requestPaint)
                            onPaint: {
                                var ctx = getContext("2d"); ctx.clearRect(0, 0, width, height)
                                var data = root.chartData; if (data.length < 2) return
                                var iW = slotW, cTop = curveTop, cBot = curveBot, cH = cBot - cTop
                                var pts = []
                                for (var i = 0; i < data.length; i++) pts.push({ x: i * iW + iW / 2, y: cTop + data[i].normY * cH })
                                ctx.beginPath(); ctx.moveTo(pts[0].x, pts[0].y)
                                for (var j = 1; j < pts.length; j++) { var mx = (pts[j-1].x + pts[j].x) / 2; ctx.bezierCurveTo(mx, pts[j-1].y, mx, pts[j].y, pts[j].x, pts[j].y) }
                                ctx.lineTo(pts[pts.length-1].x, cBot+20); ctx.lineTo(pts[0].x, cBot+20); ctx.closePath()
                                var grad = ctx.createLinearGradient(0, cTop, 0, cBot+20); grad.addColorStop(0.0, "rgba(110,195,255,0.30)"); grad.addColorStop(1.0, "rgba(110,195,255,0.0)")
                                ctx.fillStyle = grad; ctx.fill()
                                ctx.beginPath(); ctx.moveTo(pts[0].x, pts[0].y)
                                for (var k = 1; k < pts.length; k++) { var mx2 = (pts[k-1].x + pts[k].x) / 2; ctx.bezierCurveTo(mx2, pts[k-1].y, mx2, pts[k].y, pts[k].x, pts[k].y) }
                                ctx.strokeStyle = "rgba(130,210,255,0.90)"; ctx.lineWidth = 1.8; ctx.stroke()
                                for (var m = 0; m < pts.length; m++) {
                                    var isNow = data[m].label === "Now"
                                    ctx.beginPath(); ctx.arc(pts[m].x, pts[m].y, isNow ? 4 : 2.5, 0, Math.PI*2)
                                    ctx.fillStyle = isNow ? "rgba(255,255,255,0.5)" : "rgba(160,220,255,0.5)"; ctx.fill()
                                    if (isNow) { ctx.beginPath(); ctx.arc(pts[m].x, pts[m].y, 7, 0, Math.PI*2); ctx.strokeStyle = "rgba(255,255,255,0.22)"; ctx.lineWidth = 1.5; ctx.stroke() }
                                }
                            }
                        }
                        Row { anchors.fill: parent
                            Repeater { model: root.chartData
                                delegate: Item {
                                    required property var modelData; required property int index
                                    width: tempCurveCanvas.slotW; height: chartContainer.height
                                    property real dotY: tempCurveCanvas.curveTop + modelData.normY * (tempCurveCanvas.curveBot - tempCurveCanvas.curveTop)
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; y: 2; text: modelData ? modelData.label : ""; font.family: "SF Pro Display"; font.pixelSize: 10; font.weight: (modelData && modelData.label === "Now") ? Font.SemiBold : Font.Normal; color: (modelData && modelData.label === "Now") ? "white" : Qt.rgba(1,1,1,0.38) }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; y: 18; text: modelData ? modelData.emoji : ""; font.pixelSize: 18 }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; y: dotY - 16; text: modelData ? modelData.tempLabel : ""; font.family: "SF Pro Display"; font.pixelSize: 10; font.weight: Font.Medium; color: (modelData && modelData.label === "Now") ? "white" : Qt.rgba(1,1,1,0.70) }
                                }
                            }
                        }
                    }

                    Item { width: parent.width; height: 10 }
                    Rectangle { width: parent.width; height: 1; color: Qt.rgba(1,1,1,0.06) }
                    Item { width: parent.width; height: 8 }
                    RowLayout { width: parent.width
                        Text { text: "wttr.in · " + root.weatherLocation; font.family: "SF Pro Display"; font.pixelSize: 9; color: Qt.rgba(1,1,1,0.18) }
                        Item { Layout.fillWidth: true }
                        Item {
                            implicitWidth: refreshLabel.implicitWidth + 22; implicitHeight: 22
                            Rectangle { id: refreshBg; anchors.fill: parent; radius: root.pillRadius; color: Qt.rgba(1,1,1,0.07); border.color: Qt.rgba(1,1,1,0.08); border.width: 1; Behavior on color { ColorAnimation { duration: 110 } } }
                            RowLayout { anchors.centerIn: parent; spacing: 5
                                Text { text: "\uf021"; font.family: "Symbols Nerd Font"; font.pixelSize: 9; color: Qt.rgba(1,1,1,0.45); RotationAnimation on rotation { id: spinAnim; running: false; from: 0; to: 360; duration: 600; loops: 1; easing.type: Easing.OutCubic } }
                                Text { id: refreshLabel; text: "Refresh"; font.family: "SF Pro Display"; font.pixelSize: 10; color: Qt.rgba(1,1,1,0.45) }
                            }
                            MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: refreshBg.color = Qt.rgba(1,1,1,0.13); onExited: refreshBg.color = Qt.rgba(1,1,1,0.07); onClicked: { spinAnim.running = true; root.lastWeatherFetch = null; root.fetchWeatherFull() } }
                        }
                    }
                }
            }

        }  // PanelWindow (panelWindow)
    }  // Variants (main bar)

    // ═══════════════════════════════════════════════════════════════════════
    // ── Music Popup ────────────────────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════════════════
    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: musicPopupWindow
            property var modelData
            screen: modelData
            visible: root.musicPopupVisible
            anchors.top:    root.barEdge !== "bottom"
            anchors.bottom: root.barEdge === "bottom"
            anchors.right:  true
            margins { top: root.barEdge !== "bottom" ? 66 : 0; bottom: root.barEdge === "bottom" ? 66 : 0; right: 12 }
            implicitWidth: 340; implicitHeight: musicPopupCol.implicitHeight + 32
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay; WlrLayershell.exclusiveZone: -1

            Rectangle {
                anchors.fill: parent; radius: root.panelRadius
                color: Qt.rgba(0.06,0.07,0.10,0.55); border.color: Qt.rgba(1,1,1,0.09); border.width: 1
                Rectangle { anchors { top: parent.top; topMargin: 1; horizontalCenter: parent.horizontalCenter } width: parent.width * 0.5; height: 1; color: Qt.rgba(1,1,1,0.15); radius: 1 }
            }

            Column {
                id: musicPopupCol
                anchors { top: parent.top; left: parent.left; right: parent.right; margins: 16 }
                spacing: 0

                RowLayout {
                    width: parent.width; height: 30
                    RowLayout { spacing: 7
                        Text { text: "\uf001"; font.family: "Symbols Nerd Font"; font.pixelSize: 12; color: Qt.rgba(1,1,1,0.40) }
                        Text { text: "Now Playing"; font.family: "SF Pro Display"; font.pixelSize: 12; font.weight: Font.SemiBold; color: "white" }
                        Rectangle { visible: root.musicPlayer.length > 0; radius: root.pillRadius; height: 16; implicitWidth: playerBadgeText.implicitWidth + 12; color: Qt.rgba(1,1,1,0.07); border.color: Qt.rgba(1,1,1,0.09); border.width: 1
                            Text { id: playerBadgeText; anchors.centerIn: parent; text: root.musicPlayer; font.family: "SF Pro Display"; font.pixelSize: 9; color: Qt.rgba(1,1,1,0.35) }
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Item { implicitWidth: 22; implicitHeight: 22
                        Rectangle { id: musicCloseBg; anchors.fill: parent; radius: 11; color: Qt.rgba(1,1,1,0.0); Behavior on color { ColorAnimation { duration: 100 } } }
                        Text { anchors.centerIn: parent; text: "\u2715"; font.pixelSize: 9; color: Qt.rgba(1,1,1,0.35) }
                        MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: musicCloseBg.color = Qt.rgba(1,1,1,0.10); onExited: musicCloseBg.color = Qt.rgba(1,1,1,0.0); onClicked: root.musicPopupVisible = false }
                    }
                }

                Item { width: 1; height: 12 }
                Rectangle { width: parent.width; height: 1; color: Qt.rgba(1,1,1,0.07) }
                Item { width: 1; height: 12 }

                RowLayout { width: parent.width; height: 80; spacing: 14
                    Item { width: 80; height: 80
                        Rectangle { anchors.centerIn: parent; width: 84; height: 84; radius: root.squircleRadius+2; color: Qt.rgba(0.15,0.20,0.30,0.6); opacity: albumArtImage.status === Image.Ready ? 0.7 : 0; Behavior on opacity { NumberAnimation { duration: 300 } } }
                        Rectangle { anchors.fill: parent; radius: root.squircleRadius; color: Qt.rgba(0.10,0.12,0.18,1.0); clip: true
                            Image { id: albumArtImage; anchors.fill: parent; fillMode: Image.PreserveAspectCrop; source: root.musicArtUrl; smooth: true; opacity: status === Image.Ready ? 1.0 : 0.0; Behavior on opacity { NumberAnimation { duration: 200 } } }
                            Text { anchors.centerIn: parent; visible: albumArtImage.status !== Image.Ready; text: "\uf001"; font.family: "Symbols Nerd Font"; font.pixelSize: 28; color: Qt.rgba(1,1,1,0.18) }
                        }
                    }
                    Column { Layout.fillWidth: true; spacing: 5
                        Text { width: parent.width; text: root.musicTitle; font.family: "SF Pro Display"; font.pixelSize: 14; font.weight: Font.SemiBold; color: "white"; elide: Text.ElideRight; maximumLineCount: 1 }
                        Text { width: parent.width; text: root.musicArtist; font.family: "SF Pro Display"; font.pixelSize: 11; color: Qt.rgba(1,1,1,0.55); elide: Text.ElideRight; maximumLineCount: 1 }
                        Text { width: parent.width; visible: root.musicAlbum.length > 0; text: root.musicAlbum; font.family: "SF Pro Display"; font.pixelSize: 10; color: Qt.rgba(1,1,1,0.28); elide: Text.ElideRight; maximumLineCount: 1 }
                    }
                }

                Item { width: 1; height: 16 }
                Item { width: parent.width; height: 3
                    Rectangle { anchors.fill: parent; radius: 1.5; color: Qt.rgba(1,1,1,0.10) }
                    Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom } width: parent.width * root.musicProgress; radius: 1.5; color: Qt.rgba(0.72,0.88,1.0,0.85); Behavior on width { NumberAnimation { duration: 950; easing.type: Easing.Linear } } }
                }
                Item { width: 1; height: 4 }
                RowLayout { width: parent.width
                    Text { text: { var s = Math.floor(root.musicPosition/1000000); return Math.floor(s/60).toString().padStart(2,"0")+":"+( s%60).toString().padStart(2,"0") }
                        font.family: "SF Pro Display"; font.pixelSize: 9; color: Qt.rgba(1,1,1,0.28) }
                    Item { Layout.fillWidth: true }
                    Text { text: { var s = Math.floor(root.musicLength/1000000); return s > 0 ? Math.floor(s/60).toString().padStart(2,"0")+":"+(s%60).toString().padStart(2,"0") : "--:--" }
                        font.family: "SF Pro Display"; font.pixelSize: 9; color: Qt.rgba(1,1,1,0.28) }
                }

                Item { width: 1; height: 14 }
                RowLayout { width: parent.width; spacing: 0
                    Item { Layout.fillWidth: true }
                    Item { implicitWidth: 40; implicitHeight: 40
                        Rectangle { id: prevCtrlBg; anchors.fill: parent; radius: 20; color: Qt.rgba(1,1,1,0.0); Behavior on color { ColorAnimation { duration: 120 } } }
                        Text { anchors.centerIn: parent; text: "\uf048"; font.family: "Symbols Nerd Font"; font.pixelSize: 15; color: Qt.rgba(1,1,1,0.70) }
                        MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onEntered: prevCtrlBg.color = Qt.rgba(1,1,1,0.09); onExited: prevCtrlBg.color = Qt.rgba(1,1,1,0.0); onClicked: root.musicPrevTrack() }
                    }
                    Item { implicitWidth: 8 }
                    Item { implicitWidth: 56; implicitHeight: 40
                        Rectangle { id: playPauseBg; anchors.fill: parent; radius: root.squircleRadius; color: Qt.rgba(0.42,0.68,1.0,0.22); border.color: Qt.rgba(0.42,0.68,1.0,0.30); border.width: 1; Behavior on color { ColorAnimation { duration: 120 } } }
                        Text { anchors.centerIn: parent; text: root.musicStatus === "Playing" ? "\uf04c" : "\uf04b"; font.family: "Symbols Nerd Font"; font.pixelSize: 18; color: Qt.rgba(0.72,0.88,1.0,0.95) }
                        MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onEntered: playPauseBg.color = Qt.rgba(0.42,0.68,1.0,0.38); onExited: playPauseBg.color = Qt.rgba(0.42,0.68,1.0,0.22); onClicked: root.musicTogglePlay() }
                    }
                    Item { implicitWidth: 8 }
                    Item { implicitWidth: 40; implicitHeight: 40
                        Rectangle { id: nextCtrlBg; anchors.fill: parent; radius: 20; color: Qt.rgba(1,1,1,0.0); Behavior on color { ColorAnimation { duration: 120 } } }
                        Text { anchors.centerIn: parent; text: "\uf051"; font.family: "Symbols Nerd Font"; font.pixelSize: 15; color: Qt.rgba(1,1,1,0.70) }
                        MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onEntered: nextCtrlBg.color = Qt.rgba(1,1,1,0.09); onExited: nextCtrlBg.color = Qt.rgba(1,1,1,0.0); onClicked: root.musicNextTrack() }
                    }
                    Item { Layout.fillWidth: true }
                }

                Item { width: 1; height: 14 }
                Rectangle { width: parent.width; height: 1; color: Qt.rgba(1,1,1,0.07) }
                Item { width: 1; height: 12 }

                Item { width: parent.width; height: 64
                    Canvas {
                        id: cavaCanvas; anchors.fill: parent
                        Connections { target: root; function onCavaHeightsChanged() { cavaCanvas.requestPaint() } function onMusicStatusChanged() { cavaCanvas.requestPaint() } }
                        Component.onCompleted: Qt.callLater(requestPaint)
                        onPaint: {
                            var ctx = getContext("2d"); ctx.clearRect(0, 0, width, height)
                            var bars = root.cavaHeights, n = bars.length, bW = 7
                            var totalGap = width - n * bW, gap = totalGap / (n + 1)
                            var maxH = height - 2, playing = root.musicStatus === "Playing"
                            for (var i = 0; i < n; i++) {
                                var h = Math.max(3, bars[i] * maxH), x = gap + i * (bW + gap), y = height - h
                                var g = ctx.createLinearGradient(x, y, x, height)
                                if (playing) { g.addColorStop(0.0,"rgba(190,230,255,0.95)"); g.addColorStop(0.45,"rgba(100,180,255,0.65)"); g.addColorStop(1.0,"rgba(60,130,220,0.25)") }
                                else         { g.addColorStop(0.0,"rgba(100,110,130,0.35)"); g.addColorStop(1.0,"rgba(70,80,100,0.12)") }
                                ctx.fillStyle = g
                                var r = Math.min(bW/2, h/2, 3.5)
                                ctx.beginPath(); ctx.moveTo(x+r,y); ctx.lineTo(x+bW-r,y); ctx.quadraticCurveTo(x+bW,y,x+bW,y+r); ctx.lineTo(x+bW,height); ctx.lineTo(x,height); ctx.lineTo(x,y+r); ctx.quadraticCurveTo(x,y,x+r,y); ctx.closePath(); ctx.fill()
                            }
                        }
                    }
                    Text { anchors.centerIn: parent; visible: root.musicStatus !== "Playing"; text: root.musicStatus === "Paused" ? "⏸  paused" : "—  no signal"; font.family: "SF Pro Display"; font.pixelSize: 10; color: Qt.rgba(1,1,1,0.18) }
                }

                Item { width: 1; height: 6 }
                Text { text: root.cavaAvailable ? "cava · live audio" : "cava · simulated"; font.family: "SF Pro Display"; font.pixelSize: 9; color: Qt.rgba(1,1,1,0.16) }
                Item { width: 1; height: 4 }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ── WiFi Popup ─────────────────────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════════════════
    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: wifiPopupWindow
            property var modelData
            screen: modelData
            visible: root.wifiPopupVisible
            anchors.top:    root.barEdge !== "bottom"
            anchors.bottom: root.barEdge === "bottom"
            anchors.right:  true
            margins { top: root.barEdge !== "bottom" ? 66 : 0; bottom: root.barEdge === "bottom" ? 66 : 0; right: 12 }
            implicitWidth: 320; implicitHeight: Math.min(wifiPopupCol.implicitHeight + 32, screen ? screen.height * 0.75 : 600)
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay; WlrLayershell.exclusiveZone: -1
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

            Rectangle {
                anchors.fill: parent; radius: root.panelRadius
                color: Qt.rgba(0.06,0.07,0.10,0.55); border.color: Qt.rgba(1,1,1,0.09); border.width: 1
                Rectangle { anchors { top: parent.top; topMargin: 1; horizontalCenter: parent.horizontalCenter } width: parent.width * 0.5; height: 1; color: Qt.rgba(1,1,1,0.15); radius: 1 }
            }

            Flickable {
                anchors.fill: parent; anchors.margins: 16; contentHeight: wifiPopupCol.implicitHeight; clip: true
                ScrollBar.vertical: ScrollBar { policy: parent.contentHeight > parent.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff; width: 3; contentItem: Rectangle { radius: 1.5; color: Qt.rgba(1,1,1,0.22) }
                                    background: Rectangle { color: "transparent" } }

                Column {
                    id: wifiPopupCol; width: parent.width; spacing: 0

                    RowLayout { width: parent.width; height: 30
                        RowLayout { spacing: 7
                            Text { text: "\uf1eb"; font.family: "Symbols Nerd Font"; font.pixelSize: 13; color: Qt.rgba(1,1,1,0.40) }
                            Text { text: "WiFi"; font.family: "SF Pro Display"; font.pixelSize: 12; font.weight: Font.SemiBold; color: "white" }
                            Rectangle { visible: root.wifiSsid.length > 0; radius: root.pillRadius; height: 16; implicitWidth: connectedBadge.implicitWidth + 12; color: Qt.rgba(0.20,0.78,0.35,0.18); border.color: Qt.rgba(0.20,0.78,0.35,0.30); border.width: 1
                                Text { id: connectedBadge; anchors.centerIn: parent; text: root.wifiSsid; font.family: "SF Pro Display"; font.pixelSize: 9; color: Qt.rgba(0.50,1.0,0.60,0.90); elide: Text.ElideRight }
                            }
                        }
                        Item { Layout.fillWidth: true }
                        Item { implicitWidth: 22; implicitHeight: 22
                            Rectangle { id: wifiScanBg; anchors.fill: parent; radius: 11; color: Qt.rgba(1,1,1,0.0); Behavior on color { ColorAnimation { duration: 100 } } }
                            Text { anchors.centerIn: parent; text: "\uf021"; font.family: "Symbols Nerd Font"; font.pixelSize: 11; color: root.wifiScanning ? Qt.rgba(0.72,0.88,1.0,0.80) : Qt.rgba(1,1,1,0.40)
                                RotationAnimation on rotation { id: wifiSpinAnim; running: root.wifiScanning; from: 0; to: 360; duration: 900; loops: Animation.Infinite } }
                            MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onEntered: wifiScanBg.color = Qt.rgba(1,1,1,0.10); onExited: wifiScanBg.color = Qt.rgba(1,1,1,0.0); onClicked: root.wifiStartScan() }
                        }
                        Item { implicitWidth: 6 }
                        Item { implicitWidth: 22; implicitHeight: 22
                            Rectangle { id: wifiCloseBg; anchors.fill: parent; radius: 11; color: Qt.rgba(1,1,1,0.0); Behavior on color { ColorAnimation { duration: 100 } } }
                            Text { anchors.centerIn: parent; text: "\u2715"; font.pixelSize: 9; color: Qt.rgba(1,1,1,0.35) }
                            MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: wifiCloseBg.color = Qt.rgba(1,1,1,0.10); onExited: wifiCloseBg.color = Qt.rgba(1,1,1,0.0); onClicked: root.wifiPopupVisible = false }
                        }
                    }

                    Item { width: parent.width; height: root.wifiConnectMsg.length > 0 ? 28 : 0; visible: root.wifiConnectMsg.length > 0; Behavior on height { NumberAnimation { duration: 150 } }
                        Text { anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter } text: root.wifiConnectMsg; font.family: "SF Pro Display"; font.pixelSize: 10; color: Qt.rgba(0.72,0.88,1.0,0.70); elide: Text.ElideRight }
                    }

                    Item { width: 1; height: 8 }
                    Rectangle { width: parent.width; height: 1; color: Qt.rgba(1,1,1,0.07) }
                    Item { width: 1; height: 8 }

                    Item { width: parent.width; height: 48; visible: root.wifiScanning || root.wifiNetworks.length === 0
                        Column { anchors.centerIn: parent; spacing: 6
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.wifiScanning ? "\uf021" : "\uf204"; font.family: "Symbols Nerd Font"; font.pixelSize: 20; color: Qt.rgba(1,1,1,0.25)
                                RotationAnimation on rotation { running: root.wifiScanning; from: 0; to: 360; duration: 900; loops: Animation.Infinite } }
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.wifiScanning ? "Scanning…" : "No networks found"; font.family: "SF Pro Display"; font.pixelSize: 10; color: Qt.rgba(1,1,1,0.25) }
                        }
                    }

                    Column {
                        width: parent.width; spacing: 4; visible: !root.wifiScanning && root.wifiNetworks.length > 0
                        Repeater {
                            model: root.wifiNetworks
                            delegate: Item {
                                required property var modelData; required property int index
                                width: parent.width
                                property bool isConnected: modelData.connected || modelData.ssid === root.wifiSsid
                                property bool isSecured:   modelData.security.length > 0 && modelData.security !== "--"
                                property bool isExpanded:  root.wifiExpandedSsid === modelData.ssid
                                height: isExpanded ? 116 : 38
                                Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                clip: true

                                Rectangle {
                                    id: netRowBg; x: 0; y: 0; width: parent.width; height: 38; radius: root.pillRadius
                                    color: isConnected ? Qt.rgba(0.20,0.78,0.35,0.14) : netHover.containsMouse ? Qt.rgba(1,1,1,0.08) : Qt.rgba(1,1,1,0.04)
                                    border.color: isConnected ? Qt.rgba(0.20,0.78,0.35,0.28) : isExpanded ? Qt.rgba(0.42,0.68,1.0,0.30) : Qt.rgba(1,1,1,0.07); border.width: 1
                                    Behavior on color { ColorAnimation { duration: 110 } } Behavior on border.color { ColorAnimation { duration: 110 } }
                                }
                                RowLayout {
                                    x: 0; y: 0; width: parent.width; height: 38
                                    anchors { left: parent.left; right: parent.right; leftMargin: 10; rightMargin: 10 }
                                    spacing: 10
                                    Row { spacing: 2
                                        Repeater { model: 4
                                            delegate: Rectangle {
                                                width: 3; height: 4 + index * 3; radius: 1
                                                anchors.bottom: parent ? parent.bottom : undefined
                                                color: {
                                                    var lit = modelData.signal >= (index + 1) * 25
                                                    if (!lit) return Qt.rgba(1,1,1,0.15)
                                                    return isConnected ? Qt.rgba(0.30,0.90,0.45,0.90) : isExpanded ? Qt.rgba(0.72,0.88,1.0,0.85) : Qt.rgba(1,1,1,0.70)
                                                }
                                                Behavior on color { ColorAnimation { duration: 150 } }
                                            }
                                        }
                                    }
                                    Text { Layout.fillWidth: true; text: modelData.ssid; font.family: "SF Pro Display"; font.pixelSize: 12; font.weight: (isConnected || isExpanded) ? Font.SemiBold : Font.Normal; color: isConnected ? Qt.rgba(0.50,1.0,0.60,0.95) : isExpanded ? Qt.rgba(0.72,0.88,1.0,0.95) : "white"; elide: Text.ElideRight; Behavior on color { ColorAnimation { duration: 110 } } }
                                    Text { visible: isSecured; text: "\uf023"; font.family: "Symbols Nerd Font"; font.pixelSize: 10; color: isExpanded ? Qt.rgba(0.72,0.88,1.0,0.55) : Qt.rgba(1,1,1,0.28) }
                                    Text { visible: isConnected; text: "\uf00c"; font.family: "Symbols Nerd Font"; font.pixelSize: 10; color: Qt.rgba(0.30,0.90,0.45,0.90) }
                                    Text { visible: isExpanded && !isConnected; text: "\uf077"; font.family: "Symbols Nerd Font"; font.pixelSize: 9; color: Qt.rgba(0.72,0.88,1.0,0.50) }
                                }
                                MouseArea { id: netHover; x: 0; y: 0; width: parent.width; height: 38; propagateComposedEvents: true; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (isConnected) return
                                        if (isSecured) { root.wifiExpandedSsid = isExpanded ? "" : modelData.ssid; root.wifiPasswordInput = ""; root.wifiConnectMsg = "" }
                                        else           { root.wifiConnect(modelData.ssid, "") }
                                    }
                                }
                                Item { id: pwDrawer; x: 0; y: 44; width: parent.width; height: 68; opacity: isExpanded ? 1.0 : 0.0; Behavior on opacity { NumberAnimation { duration: 160 } }
                                    Rectangle { anchors.fill: parent; radius: root.pillRadius; color: Qt.rgba(0.08,0.10,0.16,1.0); border.color: Qt.rgba(0.42,0.68,1.0,0.22); border.width: 1 }
                                    Column { anchors { fill: parent; margins: 10 } spacing: 7
                                        RowLayout { width: parent.width; height: 28; spacing: 8
                                            Text { text: "\uf023"; font.family: "Symbols Nerd Font"; font.pixelSize: 11; color: Qt.rgba(0.72,0.88,1.0,0.50) }
                                            Rectangle { Layout.fillWidth: true; height: 28; radius: root.pillRadius; color: Qt.rgba(1,1,1,0.07); border.color: pwInput.activeFocus ? Qt.rgba(0.42,0.68,1.0,0.55) : Qt.rgba(1,1,1,0.10); border.width: 1; Behavior on border.color { ColorAnimation { duration: 130 } }
                                                TextInput { id: pwInput; anchors { fill: parent; leftMargin: 10; rightMargin: 10 } verticalAlignment: TextInput.AlignVCenter; echoMode: TextInput.Password; font.family: "SF Pro Display"; font.pixelSize: 12; color: "white"; selectionColor: Qt.rgba(0.42,0.68,1.0,0.35)
                                                    onTextChanged: root.wifiPasswordInput = text
                                                    onAccepted: { if (text.length > 0) { root.wifiConnect(modelData.ssid, text); root.wifiExpandedSsid = "" } }
                                                }
                                                Text { anchors { fill: parent; leftMargin: 10 } verticalAlignment: Text.AlignVCenter; visible: pwInput.text.length === 0 && !pwInput.activeFocus; text: "Password…"; font.family: "SF Pro Display"; font.pixelSize: 12; color: Qt.rgba(1,1,1,0.25) }
                                            }
                                            Item { implicitWidth: 32; implicitHeight: 28
                                                Rectangle { id: pwConnBg; anchors.fill: parent; radius: root.pillRadius; color: Qt.rgba(0.42,0.68,1.0,0.22); border.color: Qt.rgba(0.42,0.68,1.0,0.30); border.width: 1; Behavior on color { ColorAnimation { duration: 110 } } }
                                                Text { anchors.centerIn: parent; text: "\uf061"; font.family: "Symbols Nerd Font"; font.pixelSize: 12; color: Qt.rgba(0.72,0.88,1.0,0.90) }
                                                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onEntered: pwConnBg.color = Qt.rgba(0.42,0.68,1.0,0.38); onExited: pwConnBg.color = Qt.rgba(0.42,0.68,1.0,0.22)
                                                    onClicked: { if (root.wifiPasswordInput.length > 0) { root.wifiConnect(modelData.ssid, root.wifiPasswordInput); root.wifiExpandedSsid = "" } }
                                                }
                                            }
                                            Item { implicitWidth: 28; implicitHeight: 28
                                                Rectangle { id: pwCancelBg; anchors.fill: parent; radius: root.pillRadius; color: Qt.rgba(1,1,1,0.05); border.color: Qt.rgba(1,1,1,0.09); border.width: 1; Behavior on color { ColorAnimation { duration: 110 } } }
                                                Text { anchors.centerIn: parent; text: "\u2715"; font.pixelSize: 9; color: Qt.rgba(1,1,1,0.35) }
                                                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onEntered: pwCancelBg.color = Qt.rgba(1,1,1,0.10); onExited: pwCancelBg.color = Qt.rgba(1,1,1,0.05); onClicked: { root.wifiExpandedSsid = ""; root.wifiPasswordInput = "" } }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Item { width: 1; height: 10 }
                    Rectangle { width: parent.width; height: 1; color: Qt.rgba(1,1,1,0.06) }
                    Item { width: 1; height: 8 }
                    Text { text: "iwctl · click to connect"; font.family: "SF Pro Display"; font.pixelSize: 9; color: Qt.rgba(1,1,1,0.16) }
                    Item { width: 1; height: 4 }
                }
            }
        }
    }

}  // ShellRoot



