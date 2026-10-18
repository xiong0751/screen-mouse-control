# Screen & mouse control engine for the @local/screen-mouse-control plugin.
# Invoked by the plugin as:
#   powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File control.ps1
# Action and parameters are passed through SM_* environment variables.
# Emits exactly one JSON object on stdout.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$SM_ACTION = $env:SM_ACTION
if (-not $SM_ACTION) { $SM_ACTION = 'info' }

function Write-Result([hashtable]$obj) {
  ($obj | ConvertTo-Json -Compress -Depth 6) | Write-Output
}

$script:Win32Loaded = $false
function Add-Win32 {
  if ($script:Win32Loaded) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class SMWin32 {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, int dwData, int dwExtraInfo);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
}
'@
  $script:Win32Loaded = $true
}

function Get-CursorPoint {
  Add-Win32
  $p = New-Object SMWin32+POINT
  [SMWin32]::GetCursorPos([ref]$p) | Out-Null
  return @{ x = $p.X; y = $p.Y }
}

function Set-CursorPoint([int]$x, [int]$y) {
  Add-Win32
  [SMWin32]::SetCursorPos($x, $y) | Out-Null
}

function Invoke-MouseFlags([uint32]$flags, [int]$data = 0) {
  Add-Win32
  [SMWin32]::mouse_event($flags, 0, 0, $data, 0)
}

function Move-Smooth([int]$x, [int]$y, [int]$durationMs) {
  if ($durationMs -le 0) { Set-CursorPoint $x $y; return }
  $start = Get-CursorPoint
  $steps = [Math]::Max(1, [int]($durationMs / 10))
  for ($i = 1; $i -le $steps; $i++) {
    $t = $i / $steps
    $cx = [int][Math]::Round($start.x + ($x - $start.x) * $t)
    $cy = [int][Math]::Round($start.y + ($y - $start.y) * $t)
    Set-CursorPoint $cx $cy
    Start-Sleep -Milliseconds 10
  }
  Set-CursorPoint $x $y
}

function Get-ButtonFlags([string]$button, [string]$direction) {
  $map = @{
    'left'   = @{ down = 0x0002; up = 0x0004 }
    'right'  = @{ down = 0x0008; up = 0x0010 }
    'middle' = @{ down = 0x0020; up = 0x0040 }
  }
  if (-not $map.ContainsKey($button)) { throw "Unknown button: $button" }
  return $map[$button][$direction]
}

function Invoke-Capture {
  Add-Type -AssemblyName System.Drawing
  Add-Type -AssemblyName System.Windows.Forms

  $regionJson = $env:SM_REGION
  $all = ($env:SM_ALL -eq '1')
  $maxDim = 0
  if ($env:SM_MAX_DIM) { $maxDim = [int]$env:SM_MAX_DIM }
  $format = $env:SM_FORMAT
  if (-not $format) { $format = 'png' }
  $jpegQuality = 85
  if ($env:SM_JPEG_QUALITY) { $jpegQuality = [int]$env:SM_JPEG_QUALITY }
  $out = $env:SM_OUT
  if (-not $out) { throw 'SM_OUT is required' }

  $x = 0; $y = 0; $w = 0; $h = 0
  if ($regionJson) {
    $r = $regionJson | ConvertFrom-Json
    $x = [int]$r.x; $y = [int]$r.y; $w = [int]$r.width; $h = [int]$r.height
  } elseif ($all) {
    $v = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $x = $v.X; $y = $v.Y; $w = $v.Width; $h = $v.Height
  } else {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $x = $b.X; $y = $b.Y; $w = $b.Width; $h = $b.Height
  }
  if ($w -le 0 -or $h -le 0) { throw 'Invalid capture bounds' }

  $bmp = New-Object System.Drawing.Bitmap $w, $h
  try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
      $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
    } finally {
      $g.Dispose()
    }

    $outBmp = $bmp
    $resized = $false
    if ($maxDim -gt 0) {
      $longest = [Math]::Max($w, $h)
      if ($longest -gt $maxDim) {
        $scale = $maxDim / $longest
        $nw = [int][Math]::Round($w * $scale)
        $nh = [int][Math]::Round($h * $scale)
        $outBmp = New-Object System.Drawing.Bitmap $nw, $nh
        $resized = $true
        $g2 = [System.Drawing.Graphics]::FromImage($outBmp)
        try {
          $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
          $g2.DrawImage($bmp, 0, 0, $nw, $nh)
        } finally {
          $g2.Dispose()
        }
      }
    }

    if ($format -eq 'jpeg') {
      $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
      $ep = New-Object System.Drawing.Imaging.EncoderParameters 1
      $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality, [long]$jpegQuality)
      $outBmp.Save($out, $codec, $ep)
      $ep.Dispose()
    } else {
      $outBmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    }

    $finalW = $outBmp.Width
    $finalH = $outBmp.Height
    if ($resized) { $outBmp.Dispose() }
    $bytes = (Get-Item $out).Length
    Write-Result @{ ok = $true; path = $out; width = $finalW; height = $finalH; bytes = $bytes; format = $format }
  } finally {
    $bmp.Dispose()
  }
}

function Invoke-Info {
  Add-Type -AssemblyName System.Windows.Forms
  $p = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $v = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $cursor = Get-CursorPoint
  Write-Result @{
    ok = $true
    primary = @{ x = $p.X; y = $p.Y; width = $p.Width; height = $p.Height }
    virtual = @{ x = $v.X; y = $v.Y; width = $v.Width; height = $v.Height }
    cursor  = $cursor
  }
}

function Invoke-Move {
  $x = [int]$env:SM_X
  $y = [int]$env:SM_Y
  $dur = 0
  if ($env:SM_DURATION_MS) { $dur = [int]$env:SM_DURATION_MS }
  Move-Smooth $x $y $dur
  Write-Result @{ ok = $true; x = $x; y = $y }
}

function Invoke-Click {
  $button = $env:SM_BUTTON
  if (-not $button) { $button = 'left' }
  $clicks = 1
  if ($env:SM_CLICKS) { $clicks = [int]$env:SM_CLICKS }
  $delay = 50
  if ($env:SM_DELAY_MS) { $delay = [int]$env:SM_DELAY_MS }
  if ($env:SM_X -ne $null -and $env:SM_X -ne '') { Set-CursorPoint ([int]$env:SM_X) ([int]$env:SM_Y) }

  $down = Get-ButtonFlags $button 'down'
  $up = Get-ButtonFlags $button 'up'
  for ($i = 0; $i -lt $clicks; $i++) {
    Invoke-MouseFlags $down
    Start-Sleep -Milliseconds $delay
    Invoke-MouseFlags $up
    if ($i -lt ($clicks - 1)) { Start-Sleep -Milliseconds $delay }
  }
  $pos = Get-CursorPoint
  Write-Result @{ ok = $true; button = $button; clicks = $clicks; x = $pos.x; y = $pos.y }
}

function Invoke-Drag {
  $x1 = [int]$env:SM_X1; $y1 = [int]$env:SM_Y1
  $x2 = [int]$env:SM_X2; $y2 = [int]$env:SM_Y2
  $button = $env:SM_BUTTON
  if (-not $button) { $button = 'left' }
  $dur = 200
  if ($env:SM_DURATION_MS) { $dur = [int]$env:SM_DURATION_MS }

  Move-Smooth $x1 $y1 0
  $down = Get-ButtonFlags $button 'down'
  $up = Get-ButtonFlags $button 'up'
  Invoke-MouseFlags $down
  Start-Sleep -Milliseconds 30
  Move-Smooth $x2 $y2 $dur
  Start-Sleep -Milliseconds 30
  Invoke-MouseFlags $up
  Write-Result @{ ok = $true; from = @{ x = $x1; y = $y1 }; to = @{ x = $x2; y = $y2 } }
}

function Invoke-Scroll {
  $amount = [int]$env:SM_AMOUNT
  $horizontal = ($env:SM_HORIZONTAL -eq '1')
  if ($env:SM_X -ne $null -and $env:SM_X -ne '') { Set-CursorPoint ([int]$env:SM_X) ([int]$env:SM_Y) }
  $flag = 0x0800
  if ($horizontal) { $flag = 0x1000 }
  Invoke-MouseFlags $flag ($amount * 120)
  $pos = Get-CursorPoint
  Write-Result @{ ok = $true; amount = $amount; horizontal = $horizontal; x = $pos.x; y = $pos.y }
}

try {
  switch ($SM_ACTION) {
    'capture' { Invoke-Capture }
    'info'    { Invoke-Info }
    'move'    { Invoke-Move }
    'click'   { Invoke-Click }
    'drag'    { Invoke-Drag }
    'scroll'  { Invoke-Scroll }
    default   { throw "Unknown action: $SM_ACTION" }
  }
} catch {
  Write-Result @{ ok = $false; error = $_.Exception.Message }
}
