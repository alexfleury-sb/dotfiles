#!/usr/bin/env bash
#
# kitty-scratchpad-setup.sh
#
# Quake-style vim scratchpad on macOS: one global hotkey drops a kitty window
# with your scratch file already open in vim; the same hotkey hides it again.
# The window keeps running in the background, so vim state (buffer, cursor,
# undo, registers) survives between presses.
#
# Built entirely on things you already have:
#   * kitty's built-in `quick-access-terminal` kitten (kitty >= 0.42.0)
#   * macOS's built-in Services keyboard shortcuts
# No Hammerspoon, skhd, Karabiner or Automator required.
#
# Usage
#   ./kitty-scratchpad-setup.sh              install config + wrapper
#   ./kitty-scratchpad-setup.sh --autostart  also preload the pad (hidden) at login
#   ./kitty-scratchpad-setup.sh --uninstall  remove everything this script created
#
# Knobs (environment variables, read at install time and baked in)
#   SCRATCHPAD_FILE=~/notes/pad.md   which file to open   (default ~/Documents/scratchpad.md)
#   EDITOR_CMD=nvim                  which editor to run  (default vim)
#   PAD_LINES=28 PAD_COLUMNS=100     window size in cells
#   PAD_EDGE=center-sized            top | bottom | left | right | center | center-sized | none
#   PAD_OPACITY=0.90                 1.0 = solid, lower = more see-through
#   PAD_BLUR=32                      macOS blur radius behind the pad, 0 disables
#   PAD_PADDING=14                   inner padding, pts
#   PAD_RADIUS=10                    border corner radius (needs kitty 0.49+)
#   PAD_BORDER_COLOR='#E2A828'       border colour; 'inherit' (default) takes it
#                                    from your kitty.conf like every other colour
#   PAD_THEME=sandboxaq              opt in to a bundled palette; default is to
#                                    inherit all colours from your kitty.conf
#
set -euo pipefail

KITTY_CONFIG_DIR="${KITTY_CONFIG_DIRECTORY:-$HOME/.config/kitty}"
QAT_CONF="$KITTY_CONFIG_DIR/quick-access-terminal.conf"
BIN_DIR="$HOME/.local/bin"
WRAPPER="$BIN_DIR/kitty-scratchpad"
AGENT_LABEL="com.local.kitty-scratchpad"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

SCRATCH_FILE="${SCRATCHPAD_FILE:-$HOME/Work/scratchpad.md}"
EDITOR_CMD="${EDITOR_CMD:-vim}"
PAD_LINES="${PAD_LINES:-28}"
PAD_COLUMNS="${PAD_COLUMNS:-100}"
PAD_EDGE="${PAD_EDGE:-center-sized}"
PAD_OPACITY="${PAD_OPACITY:-0.90}"
PAD_BLUR="${PAD_BLUR:-32}"
PAD_PADDING="${PAD_PADDING:-14}"
PAD_RADIUS="${PAD_RADIUS:-10}"
PAD_BORDER_COLOR="${PAD_BORDER_COLOR:-inherit}"
PAD_THEME="${PAD_THEME:-none}"
BORDER_WARNING=no

MODE=install
for arg in "$@"; do
	case "$arg" in
	--autostart) MODE=autostart ;;
	--uninstall) MODE=uninstall ;;
	-h | --help)
		awk 'NR>1 { if (/^#/) print; else exit }' "$0"
		exit 0
		;;
	*)
		echo "unknown argument: $arg" >&2
		exit 2
		;;
	esac
done

say() { printf '  %s\n' "$*"; }
head2() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --------------------------------------------------------------------------
# locate the kitten binary
# --------------------------------------------------------------------------
find_kitten() {
	local c
	for c in \
		/Applications/kitty.app/Contents/MacOS/kitten \
		"$HOME/Applications/kitty.app/Contents/MacOS/kitten" \
		/opt/homebrew/bin/kitten \
		/usr/local/bin/kitten \
		"$(command -v kitten 2>/dev/null || true)"; do
		if [ -n "$c" ] && [ -x "$c" ]; then
			printf '%s\n' "$c"
			return 0
		fi
	done
	return 1
}

KITTEN="$(find_kitten || true)"

check_version() {
	[ -n "$KITTEN" ] || return 1
	local v major minor
	v="$("$KITTEN" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
	[ -n "$v" ] || return 1
	major="${v%%.*}"
	minor="$(printf '%s' "$v" | cut -d. -f2)"
	printf '%s\n' "$v"
	[ "$major" -gt 0 ] || [ "$minor" -ge 42 ]
}

# --------------------------------------------------------------------------
# uninstall
# --------------------------------------------------------------------------
if [ "$MODE" = uninstall ]; then
	head2 "Removing kitty scratchpad"
	if [ -f "$LAUNCH_AGENT" ]; then
		launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null ||
			launchctl unload -w "$LAUNCH_AGENT" 2>/dev/null || true
		rm -f "$LAUNCH_AGENT"
		say "removed $LAUNCH_AGENT"
	fi
	if [ -f "$WRAPPER" ]; then
		rm -f "$WRAPPER"
		say "removed $WRAPPER"
	fi
	if [ -f "$QAT_CONF" ]; then
		rm -f "$QAT_CONF"
		say "removed $QAT_CONF"
		if ls "$KITTY_CONFIG_DIR"/quick-access-terminal.conf.bak-* >/dev/null 2>&1; then
			say "backups of your previous conf are still in $KITTY_CONFIG_DIR"
		fi
	fi
	say "your scratch file ($SCRATCH_FILE) was left alone"
	say "clear the Services shortcut by hand in System Settings if you set one"
	exit 0
fi

# --------------------------------------------------------------------------
# preflight
# --------------------------------------------------------------------------
head2 "Checking kitty"
if VER="$(check_version)"; then
	say "kitten $VER at $KITTEN -- ok"
elif [ -n "$KITTEN" ]; then
	say "found $KITTEN but it looks older than 0.42.0 (reported: ${VER:-unknown})"
	say "the quick-access-terminal kitten was added in 0.42.0 -- please upgrade kitty"
else
	say "could not find the 'kitten' binary; writing config anyway"
	say "install kitty, then re-run with --autostart if you want login preloading"
	if [ "$MODE" = autostart ]; then
		say "--autostart needs the kitten binary; aborting"
		exit 1
	fi
fi

# --------------------------------------------------------------------------
# the scratchpad wrapper: keeps vim alive so the pad never dies on :q
# --------------------------------------------------------------------------
head2 "Installing the scratchpad wrapper"
mkdir -p "$BIN_DIR" "$(dirname "$SCRATCH_FILE")"
[ -e "$SCRATCH_FILE" ] || : >"$SCRATCH_FILE"

{
	printf '#!/bin/sh\n'
	printf '# Generated by kitty-scratchpad-setup.sh -- edit freely, or re-run the setup.\n'
	printf 'SCRATCH_FILE=%q\n' "$SCRATCH_FILE"
	printf 'EDITOR_CMD=%q\n' "$EDITOR_CMD"
	cat <<'WRAPPER_BODY'

UNDODIR="$HOME/.local/state/kitty-scratchpad/undo"
mkdir -p "$UNDODIR" "$(dirname "$SCRATCH_FILE")"
[ -e "$SCRATCH_FILE" ] || : > "$SCRATCH_FILE"

# :q should not kill the pad -- reopen instead, so the hotkey always has
# something to show. Press s for a real shell, q to close the pad for good.
while : ; do
	"$EDITOR_CMD" \
		-c "set undofile undodir=$UNDODIR" \
		-c 'silent! normal! g`"' \
		"$SCRATCH_FILE"
	printf '\n[scratchpad] editor exited.  enter = reopen   s = shell   q = close pad: '
	read -r reply || exit 0
	case "$reply" in
		s|S) exec "${SHELL:-/bin/sh}" -l ;;
		q|Q) exit 0 ;;
	esac
done
WRAPPER_BODY
} >"$WRAPPER"
chmod +x "$WRAPPER"
say "wrote $WRAPPER"
say "scratch file: $SCRATCH_FILE"

# --------------------------------------------------------------------------
# version-gated styling
#
# kitty only draws window borders to separate adjacent windows, so a panel
# with a single window has none by default. Two newer options fix that, and
# both degrade gracefully on older kitty.
# --------------------------------------------------------------------------
ver_num() {
	local a b c
	IFS=. read -r a b c <<<"${1:-0.0.0}"
	printf '%d\n' $((10#${a:-0} * 1000000 + 10#${b:-0} * 1000 + 10#${c:-0}))
}
ver_ge() { [ "$(ver_num "$1")" -ge "$(ver_num "$2")" ]; }

# If we could not detect a version, assume a current kitty.
STYLE_VER="${VER:-99.0.0}"

if ver_ge "$STYLE_VER" 0.44.0; then
	BORDER_BLOCK="# Force a full border even though only one window is visible (kitty 0.44+).
kitty_override draw_window_borders_for_single_window=yes"
else
	BORDER_BLOCK="# Your kitty predates draw_window_borders_for_single_window (0.44+), so this
# leans on the documented side effect that a non-zero window_margin_width
# forces all borders to be drawn. Upgrade kitty for the reliable version.
kitty_override window_margin_width=4"
fi

if ver_ge "$STYLE_VER" 0.49.0; then
	RADIUS_BLOCK="# Rounded border corners (kitty 0.49+). Only applies to full borders.
kitty_override window_border_radius=$PAD_RADIUS"
else
	RADIUS_BLOCK="# window_border_radius needs kitty 0.49+, so the border stays square.
# kitty_override window_border_radius=$PAD_RADIUS"
fi

# Border colour. 'inherit' emits nothing, so kitty.conf decides. If the theme
# is on and no colour was asked for, pair it with the theme's gold.
if [ "$PAD_BORDER_COLOR" = inherit ] && [ "$PAD_THEME" != none ]; then
	PAD_BORDER_COLOR='#E2A828'
fi

if [ "$PAD_BORDER_COLOR" = inherit ]; then
	BORDER_COLOR_BLOCK="# Border colours are left to your kitty.conf.
# Set one just for the pad with: PAD_BORDER_COLOR='#RRGGBB' ./$(basename "$0")"
	# kitty's stock active_border_color is bright green; warn if they have not
	# overridden it, since the pad will inherit that. Shallow grep -- it does
	# not follow 'include' directives.
	if ! grep -qE '^[[:space:]]*active_border_color[[:space:]]' \
		"$KITTY_CONFIG_DIR/kitty.conf" 2>/dev/null; then
		BORDER_WARNING=yes
	fi
else
	BORDER_COLOR_BLOCK="kitty_override active_border_color=$PAD_BORDER_COLOR"
fi

if [ "$PAD_THEME" = none ]; then
	COLOR_BLOCK="# PAD_THEME is unset, so the pad uses the colours from your kitty.conf.
# Opt in to the bundled palette with: PAD_THEME=sandboxaq ./$(basename "$0")"
else
	COLOR_BLOCK="kitty_override background=#060203
kitty_override foreground=#D9D9D9
kitty_override cursor=#E2A828
kitty_override cursor_text_color=#060203
kitty_override selection_background=#2AA1BC
kitty_override selection_foreground=#060203
kitty_override url_color=#2AA1BC

kitty_override color0=#2A2326
kitty_override color8=#5A5055
kitty_override color1=#CB222D
kitty_override color9=#E05560
kitty_override color2=#5D9D6F
kitty_override color10=#7FBF90
kitty_override color3=#E2A828
kitty_override color11=#F0C45E
kitty_override color4=#2AA1BC
kitty_override color12=#55BBD4
kitty_override color5=#9373B1
kitty_override color13=#B197CC
kitty_override color6=#6FC9D6
kitty_override color14=#96DCE6
kitty_override color7=#D9D9D9
kitty_override color15=#FFFFFF"
fi

if [ "${PAD_BLUR}" = 0 ]; then
	BLUR_LINE="# PAD_BLUR=0 -- no background blur."
else
	BLUR_LINE="# On macOS this value is the blur radius. Up to 64 is usually safe.
kitty_override background_blur=$PAD_BLUR"
fi

# --------------------------------------------------------------------------
# quick-access-terminal.conf
# --------------------------------------------------------------------------
head2 "Installing quick-access-terminal.conf"
mkdir -p "$KITTY_CONFIG_DIR"
if [ -f "$QAT_CONF" ]; then
	BACKUP="$QAT_CONF.bak-$(date +%Y%m%d%H%M%S)"
	cp "$QAT_CONF" "$BACKUP"
	say "backed up existing conf to $BACKUP"
fi

cat >"$QAT_CONF" <<CONF
# Generated by kitty-scratchpad-setup.sh
# Full reference: https://sw.kovidgoyal.net/kitty/kittens/quick-access-terminal/

# --- geometry -------------------------------------------------------------
# edge: top | bottom | left | right | center | center-sized | none
#   top          = classic Quake drop-down, full width, 'lines' tall
#   center-sized = floating window centred on screen, lines x columns
lines              $PAD_LINES
columns            $PAD_COLUMNS
edge               $PAD_EDGE

# Set to yes if you want the pad to vanish the moment you click elsewhere.
hide_on_focus_loss no

# --- translucency ---------------------------------------------------------
# background_opacity belongs to the kitten (its default differs from
# kitty's); blur is a kitty option, so it goes through kitty_override.
background_opacity $PAD_OPACITY
$BLUR_LINE
# Lets you nudge opacity live without editing this file.
kitty_override dynamic_background_opacity=yes

# --- border ---------------------------------------------------------------
$BORDER_BLOCK
kitty_override window_border_width=2pt
$RADIUS_BLOCK
$BORDER_COLOR_BLOCK

# --- chrome ---------------------------------------------------------------
# Padding keeps text clear of the border, which is drawn over corner cells.
# Deliberately NOT window_margin_width: a non-zero margin overrides
# draw_minimal_borders and changes how borders are drawn.
kitty_override window_padding_width=$PAD_PADDING
kitty_override placement_strategy=center
kitty_override tab_bar_style=hidden

# --- colours --------------------------------------------------------------
$COLOR_BLOCK

# --- what runs inside it --------------------------------------------------
# The macOS "Quick access to kitty" Service invokes the kitten with no
# arguments, so the program is pinned here rather than on the command line.
kitty_override shell=$WRAPPER

# Don't nag on close, and keep kitty resident so the pad survives in the
# background between hotkey presses.
kitty_override confirm_os_window_close=0
kitty_override macos_quit_when_last_window_closed=no

# --- optional polish ------------------------------------------------------
# kitty_override font_size=15
# kitty_override cursor_blink_interval=0

# If 'shell=' ever stops taking effect, the alternative is a session file:
#   kitty_override startup_session=scratchpad.session
# with ~/.config/kitty/scratchpad.session containing:
#   launch --type=window $WRAPPER
CONF
say "wrote $QAT_CONF"
if [ "$BORDER_WARNING" = yes ]; then
	say ""
	say "heads up: your kitty.conf does not set active_border_color, so the pad"
	say "will inherit kitty's stock value, which is bright green (#00ff00)."
	say "If you'd rather not have that, either set active_border_color in"
	say "kitty.conf, or re-run with e.g. PAD_BORDER_COLOR='#808080'."
fi

# --------------------------------------------------------------------------
# optional: preload the pad, hidden, at login
# --------------------------------------------------------------------------
if [ "$MODE" = autostart ]; then
	head2 "Installing login agent"
	mkdir -p "$(dirname "$LAUNCH_AGENT")"
	cat >"$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$AGENT_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$KITTEN</string>
		<string>quick-access-terminal</string>
		<string>-o</string>
		<string>start_as_hidden=yes</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>/tmp/$AGENT_LABEL.log</string>
</dict>
</plist>
PLIST
	launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
	launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT" 2>/dev/null ||
		launchctl load -w "$LAUNCH_AGENT" 2>/dev/null ||
		say "could not load the agent now; it will start at your next login"
	say "wrote $LAUNCH_AGENT (first hotkey press will be instant)"
fi

# --------------------------------------------------------------------------
# what's left for you to do by hand
# --------------------------------------------------------------------------
head2 "Two manual steps left"
cat <<NEXT
  1. Register the Service. Open kitty normally and run:

         kitten quick-access-terminal --detach --detached-log /dev/null

     The pad appears with your scratch file in $EDITOR_CMD. Run the same command
     again (from anywhere) to hide it -- that toggle is the whole trick.

     --detach keeps the pad's log off your screen. Without it you will see
     lines like "[PARSE ERROR] Unknown terminfo property: K1" and an OpenGL
     glCopyImageSubData warning in the shell you launched from. Both are
     normal: the first is vim probing the terminal for capabilities kitty
     does not implement, the second is Apple capping OpenGL at 4.1. Neither
     affects the pad. See kovidgoyal/kitty#10453.

  2. Bind the hotkey. System Settings -> Keyboard -> Keyboard Shortcuts ->
     Services -> General, find "Quick access to kitty", click the right-hand
     column and press your combo.

     Pick something no app claims: ctrl-opt-cmd-Space, or F13 if you have it.
     Avoid cmd-Space and ctrl-Space.

  If the Service entry doesn't appear in that list, nudge Launch Services and
  log out and back in:

         /System/Library/CoreServices/pbs -flush

NEXT

head2 "Afterwards"
cat <<TIPS
  Hotkey          show / hide the pad (vim state is preserved)
  :q inside vim   reopens the file; press s there for a shell, q to close
  Resize          edit lines/columns/edge in $QAT_CONF
  Second pad      kitten quick-access-terminal --instance-group notes
  Undo me         $(basename "$0") --uninstall

TIPS
