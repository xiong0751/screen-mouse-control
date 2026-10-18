# Background automation engine for @local/screen-mouse-control.
# Read via UI Automation (element tree, no pixels); write via window messages
# (posted clicks / WM_SETTEXT / WM_KEYDOWN / WM_MOUSEWHEEL). Strict background:
# the cursor is never moved and no foreground input is injected.
# Dispatched by SM_ACTION; args via SM_* env vars.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$action = $env:SM_ACTION
if (-not $action) { $action = 'list' }

function Write-Result([hashtable]$obj) {
  ($obj | ConvertTo-Json -Compress -Depth 8) | Write-Output
}

$script:NativeLoaded = $false
function Load-Native {
  if ($script:NativeLoaded) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class BgWin32 {
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr hWnd, ref POINT pt);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, string lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
}
'@
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
  $script:NativeLoaded = $true
}

function Get-TopLevelWindows {
  Load-Native
  $procs = Get-Process | Where-Object { $_.MainWindowHandle -ne 0 }
  $out = @()
  foreach ($p in $procs) {
    $r = New-Object BgWin32+RECT
    [BgWin32]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
    $out += [pscustomobject]@{
      pid = $p.Id; name = $p.ProcessName; title = $p.MainWindowTitle
      x = $r.Left; y = $r.Top; w = ($r.Right - $r.Left); h = ($r.Bottom - $r.Top)
    }
  }
  return $out
}

function Resolve-Hwnd([string]$spec) {
  Load-Native
  $procs = Get-Process | Where-Object { $_.MainWindowHandle -ne 0 }
  if ($spec -match '^\d+$') {
    $p = $procs | Where-Object { $_.Id -eq [int]$spec } | Select-Object -First 1
    if ($p) { return [IntPtr]$p.MainWindowHandle }
  }
  $p = $procs | Where-Object { $_.MainWindowTitle -and $_.MainWindowTitle -like "*$spec*" } | Select-Object -First 1
  if ($p) { return [IntPtr]$p.MainWindowHandle }
  $p = $procs | Where-Object { $_.ProcessName -like "*$spec*" } | Select-Object -First 1
  if ($p) { return [IntPtr]$p.MainWindowHandle }
  return [IntPtr]::Zero
}

function Get-UiaAll([IntPtr]$hwnd) {
  Load-Native
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  if ($null -eq $root) { return @() }
  return @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
}

function Select-Elements($all, [string]$name, [string]$type, [string]$aid, [string]$cls) {
  $res = @()
  foreach ($el in $all) {
    try {
      $cur = $el.Current
      $r = $cur.BoundingRectangle
      if ($r.Width -le 0 -or $r.Height -le 0) { continue }
      if ($name -and -not ([string]$cur.Name -like "*$name*")) { continue }
      if ($type -and -not ([string]$cur.ControlType.ProgrammaticName -like "*$type*")) { continue }
      if ($aid -and -not ([string]$cur.AutomationId -like "*$aid*")) { continue }
      if ($cls -and -not ([string]$cur.ClassName -like "*$cls*")) { continue }
      $res += $el
    } catch { }
  }
  # An automation id is an identifier: when an exact match exists, prefer it over
  # loose substring hits (e.g. "area" must not also match "RootWebArea").
  if ($aid -and $res.Count -gt 1) {
    $exact = @($res | Where-Object { [string]$_.Current.AutomationId -eq $aid })
    if ($exact.Count -gt 0) { return $exact }
  }
  return $res
}

function ElemToObj($el, [int]$index) {
  $cur = $el.Current
  $r = $cur.BoundingRectangle
  return [pscustomobject]@{
    index = $index
    name = [string]$cur.Name
    type = ([string]$cur.ControlType.ProgrammaticName) -replace '^ControlType\.', ''
    automationId = [string]$cur.AutomationId
    className = [string]$cur.ClassName
    x = [int]$r.X; y = [int]$r.Y; w = [int]$r.Width; h = [int]$r.Height
    enabled = [bool]$cur.IsEnabled
  }
}

function Read-ElementText($el) {
  try {
    $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    return [string]$vp.Current.Value
  } catch { }
  try {
    $tp = $el.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
    return [string]$tp.DocumentRange.GetText(-1)
  } catch { }
  return [string]$el.Current.Name
}

function Post-Click([IntPtr]$hwnd, [int]$cx, [int]$cy, [string]$button) {
  $lp = [IntPtr](($cy -shl 16) -bor ($cx -band 0xFFFF))
  if ($button -eq 'right') {
    [BgWin32]::PostMessage($hwnd, 0x0204, [IntPtr]0, $lp) | Out-Null
    [BgWin32]::PostMessage($hwnd, 0x0205, [IntPtr]0, $lp) | Out-Null
  } else {
    [BgWin32]::PostMessage($hwnd, 0x0201, [IntPtr]1, $lp) | Out-Null
    [BgWin32]::PostMessage($hwnd, 0x0202, [IntPtr]0, $lp) | Out-Null
  }
}

function Do-List {
  $wins = Get-TopLevelWindows
  $out = @()
  $i = 0
  foreach ($w in $wins) {
    $out += [pscustomobject]@{ index = $i; pid = $w.pid; name = $w.name; title = $w.title; x = $w.x; y = $w.y; w = $w.w; h = $w.h }
    $i++
  }
  Write-Result @{ ok = $true; windows = $out }
}

function Do-Find {
  $spec = $env:SM_WINDOW
  if (-not $spec) { throw 'SM_WINDOW required' }
  $hwnd = Resolve-Hwnd $spec
  if ($hwnd -eq [IntPtr]::Zero) { throw "Window not found: $spec" }
  $all = Get-UiaAll $hwnd
  $sel = Select-Elements $all $env:SM_NAME $env:SM_TYPE $env:SM_AUTOMATION_ID $env:SM_CLASS
  $limit = 50
  if ($env:SM_LIMIT) { $limit = [int]$env:SM_LIMIT }
  $list = @()
  $i = 0
  foreach ($el in $sel) {
    if ($i -ge $limit) { break }
    $list += ElemToObj $el $i
    $i++
  }
  Write-Result @{ ok = $true; window = $spec; total = $sel.Count; elements = $list }
}

function Do-Read {
  $spec = $env:SM_WINDOW
  if (-not $spec) { throw 'SM_WINDOW required' }
  $hwnd = Resolve-Hwnd $spec
  if ($hwnd -eq [IntPtr]::Zero) { throw "Window not found: $spec" }
  $all = Get-UiaAll $hwnd
  $sel = Select-Elements $all $env:SM_NAME $env:SM_TYPE $env:SM_AUTOMATION_ID $env:SM_CLASS
  $idx = 0
  if ($env:SM_INDEX) { $idx = [int]$env:SM_INDEX }
  if ($sel.Count -le $idx) { throw 'Element not found' }
  $el = $sel[$idx]
  $text = Read-ElementText $el
  Write-Result @{ ok = $true; name = [string]$el.Current.Name; type = ([string]$el.Current.ControlType.ProgrammaticName) -replace '^ControlType\.', ''; text = $text }
}

function Do-Click {
  $spec = $env:SM_WINDOW
  if (-not $spec) { throw 'SM_WINDOW required' }
  $hwnd = Resolve-Hwnd $spec
  if ($hwnd -eq [IntPtr]::Zero) { throw "Window not found: $spec" }
  $button = $env:SM_BUTTON; if (-not $button) { $button = 'left' }
  $all = Get-UiaAll $hwnd
  $sel = Select-Elements $all $env:SM_NAME $env:SM_TYPE $env:SM_AUTOMATION_ID $env:SM_CLASS
  if ($sel.Count -gt 0) {
    $idx = 0; if ($env:SM_INDEX) { $idx = [int]$env:SM_INDEX }
    $el = $sel[$idx]
    try {
      $ip = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
      $ip.Invoke()
      Write-Result @{ ok = $true; via = 'invoke'; element = [string]$el.Current.Name }
      return
    } catch { }
    $r = $el.Current.BoundingRectangle
    $pt = New-Object BgWin32+POINT
    $pt.X = [int]($r.X + $r.Width / 2)
    $pt.Y = [int]($r.Y + $r.Height / 2)
    [BgWin32]::ScreenToClient($hwnd, [ref]$pt) | Out-Null
    Post-Click $hwnd $pt.X $pt.Y $button
    Write-Result @{ ok = $true; via = 'post'; element = [string]$el.Current.Name; cx = $pt.X; cy = $pt.Y }
    return
  }
  if ($null -eq $env:SM_X -or $env:SM_X -eq '') { throw 'No element matched and no x,y given' }
  Post-Click $hwnd ([int]$env:SM_X) ([int]$env:SM_Y) $button
  Write-Result @{ ok = $true; via = 'post'; cx = [int]$env:SM_X; cy = [int]$env:SM_Y }
}

function Do-Type {
  $spec = $env:SM_WINDOW
  if (-not $spec) { throw 'SM_WINDOW required' }
  $hwnd = Resolve-Hwnd $spec
  if ($hwnd -eq [IntPtr]::Zero) { throw "Window not found: $spec" }
  $text = $env:SM_TEXT
  if ($null -eq $text) { throw 'SM_TEXT required' }
  $all = Get-UiaAll $hwnd
  $sel = Select-Elements $all $env:SM_NAME $env:SM_TYPE $env:SM_AUTOMATION_ID $env:SM_CLASS
  if ($sel.Count -eq 0) { throw 'Target element not found (run bg_find to locate an edit control)' }
  $idx = 0; if ($env:SM_INDEX) { $idx = [int]$env:SM_INDEX }
  $el = $sel[$idx]

  # 1) ValuePattern first (fast path, keeps the window untouched)
  try {
    $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if (-not $vp.Current.IsReadOnly) {
      $vp.SetValue($text)
      Write-Result @{ ok = $true; via = 'value'; element = [string]$el.Current.Name }
      return
    }
  } catch { }

  # 2) WM_SETTEXT to the element's own native window handle (classic Edit controls)
  $eh = [int]$el.Current.NativeWindowHandle
  if ($eh -ne 0) {
    [BgWin32]::SendMessage([IntPtr]$eh, 0x000C, [IntPtr]0, $text) | Out-Null
    Write-Result @{ ok = $true; via = 'wm_settext'; element = [string]$el.Current.Name }
    return
  }

  # 3) Renderer-hosted inputs (e.g. Chromium <textarea>): UIA-focus the element,
  #    then post WM_CHAR to the window under it. No foreground input is injected.
  try {
    $el.SetFocus()
    Start-Sleep -Milliseconds 100
    $r = $el.Current.BoundingRectangle
    $pt = New-Object BgWin32+POINT
    $pt.X = [int]($r.X + $r.Width / 2)
    $pt.Y = [int]($r.Y + $r.Height / 2)
    $wh = [BgWin32]::WindowFromPoint($pt)
    if ($wh -eq [IntPtr]::Zero) { throw 'No window under the element' }
    $norm = ($text -replace "`r`n", "`r") -replace "`n", "`r"
    foreach ($ch in $norm.ToCharArray()) {
      [BgWin32]::PostMessage($wh, 0x0102, [IntPtr][int]$ch, [IntPtr]0) | Out-Null
      Start-Sleep -Milliseconds 15
    }
    Write-Result @{ ok = $true; via = 'wm_char'; element = [string]$el.Current.Name; hwnd = [int]$wh; len = $text.Length }
    return
  } catch { }

  throw 'Cannot type into this element in background mode'
}

function Do-Keys {
  $spec = $env:SM_WINDOW
  if (-not $spec) { throw 'SM_WINDOW required' }
  $hwnd = Resolve-Hwnd $spec
  if ($hwnd -eq [IntPtr]::Zero) { throw "Window not found: $spec" }
  $keys = $env:SM_KEYS
  if (-not $keys) { throw 'SM_KEYS required' }
  $target = $hwnd
  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($focused) {
      $fh = [int]$focused.Current.NativeWindowHandle
      if ($fh -ne 0) { $target = [IntPtr]$fh }
    }
  } catch { }
  $vk = @{ ctrl = 0x11; alt = 0x12; shift = 0x10; win = 0x5B; enter = 0x0D; tab = 0x09; esc = 0x1B; space = 0x20; backspace = 0x08; delete = 0x2E; insert = 0x2D; up = 0x26; down = 0x28; left = 0x25; right = 0x27; home = 0x24; end = 0x23; pageup = 0x21; pagedown = 0x22; minus = 0xBD; equal = 0xBB; comma = 0xBC; period = 0xBE; slash = 0xBF }
  $parts = $keys.ToLower() -split '\+'
  $codes = @()
  foreach ($p in $parts) {
    if ($vk.ContainsKey($p)) { $codes += $vk[$p] }
    elseif ($p -match '^f([1-9]|1[0-2])$') { $codes += (0x70 + [int]$Matches[1] - 1) }
    elseif ($p -match '^[a-z0-9]$') { $codes += [int][char]$p.ToUpper() }
    else { throw "Unknown key: $p" }
  }
  foreach ($c in $codes) { [BgWin32]::PostMessage($target, 0x0100, [IntPtr]$c, [IntPtr]0) | Out-Null }
  for ($i = $codes.Count - 1; $i -ge 0; $i--) { [BgWin32]::PostMessage($target, 0x0101, [IntPtr]$codes[$i], [IntPtr]0) | Out-Null }
  Write-Result @{ ok = $true; keys = $keys; target = [int]$target }
}

function Do-Scroll {
  $spec = $env:SM_WINDOW
  if (-not $spec) { throw 'SM_WINDOW required' }
  $hwnd = Resolve-Hwnd $spec
  if ($hwnd -eq [IntPtr]::Zero) { throw "Window not found: $spec" }
  $amount = 0
  if ($env:SM_AMOUNT) { $amount = [int]$env:SM_AMOUNT }
  $delta = $amount * 120
  $r = New-Object BgWin32+RECT
  [BgWin32]::GetWindowRect($hwnd, [ref]$r) | Out-Null
  $sx = [int](($r.Left + $r.Right) / 2)
  $sy = [int](($r.Top + $r.Bottom) / 2)
  $wparam = [IntPtr](($delta -band 0xFFFF) -shl 16)
  $lparam = [IntPtr](($sy -shl 16) -bor ($sx -band 0xFFFF))
  [BgWin32]::PostMessage($hwnd, 0x020A, $wparam, $lparam) | Out-Null
  Write-Result @{ ok = $true; amount = $amount }
}

function Do-Window {
  $spec = $env:SM_WINDOW
  if (-not $spec) { throw 'SM_WINDOW required' }
  $hwnd = Resolve-Hwnd $spec
  if ($hwnd -eq [IntPtr]::Zero) { throw "Window not found: $spec" }
  $op = $env:SM_OP
  if (-not $op) { throw 'SM_OP required' }
  switch ($op) {
    'minimize' { [BgWin32]::ShowWindow($hwnd, 6) | Out-Null }
    'maximize' { [BgWin32]::ShowWindow($hwnd, 3) | Out-Null }
    'restore'  { [BgWin32]::ShowWindow($hwnd, 9) | Out-Null }
    'close'    { [BgWin32]::PostMessage($hwnd, 0x0010, [IntPtr]0, [IntPtr]0) | Out-Null }
    'topmost' {
      $on = ($env:SM_ON -ne '0')
      $insert = [IntPtr](-1)
      if (-not $on) { $insert = [IntPtr](-2) }
      [BgWin32]::SetWindowPos($hwnd, $insert, 0, 0, 0, 0, 0x0003) | Out-Null
    }
    'move' {
      $x = [int]$env:SM_X; $y = [int]$env:SM_Y
      [BgWin32]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, 0, 0, 0x0001) | Out-Null
    }
    'resize' {
      $w = [int]$env:SM_WIDTH; $h = [int]$env:SM_HEIGHT
      [BgWin32]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, $w, $h, 0x0002) | Out-Null
    }
    default { throw "Unknown window op: $op" }
  }
  Write-Result @{ ok = $true; op = $op; window = $spec }
}

try {
  switch ($action) {
    'list'   { Do-List }
    'find'   { Do-Find }
    'read'   { Do-Read }
    'click'  { Do-Click }
    'type'   { Do-Type }
    'keys'   { Do-Keys }
    'scroll' { Do-Scroll }
    'window' { Do-Window }
    default  { throw "Unknown action: $action" }
  }
} catch {
  Write-Result @{ ok = $false; error = $_.Exception.Message }
}
