# Vision engine for @local/screen-mouse-control.
# Captures the screen AND OCRs it in ONE process; optionally clicks matched text.
# Dispatched by SM_ACTION. Emits exactly one JSON object on stdout.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$action = $env:SM_ACTION
if (-not $action) { $action = 'ocr' }

function Write-Result([hashtable]$obj) {
  ($obj | ConvertTo-Json -Compress -Depth 6) | Write-Output
}

# --- OCR engine (initialized once per process) ---
$script:OcrReady = $false
$script:OcrEngine = $null
function Ensure-Ocr {
  if ($script:OcrReady) { return }
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
  $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
  $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
  $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  if ($null -eq $script:OcrEngine) {
    $langs = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages
    if ($null -eq $langs -or $langs.Count -eq 0) { throw 'No OCR recognizer available' }
    $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($langs[0])
  }
  if ($null -eq $script:OcrEngine) { throw 'Cannot create OCR engine' }
  $script:OcrReady = $true
}

function Await([object]$WinRtTask, [Type]$ResultType) {
  $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
  })[0]
  $t = $asTask.MakeGenericMethod($ResultType).Invoke($null, @($WinRtTask))
  $t.Wait() | Out-Null
  $t.Result
}

# --- mouse (only loaded for click_text) ---
$script:MouseLoaded = $false
function Ensure-Mouse {
  if ($script:MouseLoaded) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class SMWin32 {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, int dwData, int dwExtraInfo);
}
'@
  $script:MouseLoaded = $true
}

function Invoke-ClickAt([int]$x, [int]$y, [string]$button, [bool]$doubleClick) {
  Ensure-Mouse
  [SMWin32]::SetCursorPos($x, $y) | Out-Null
  $map = @{
    'left'   = @{ down = 0x0002; up = 0x0004 }
    'right'  = @{ down = 0x0008; up = 0x0010 }
    'middle' = @{ down = 0x0020; up = 0x0040 }
  }
  if (-not $map.ContainsKey($button)) { throw "Unknown button: $button" }
  $down = $map[$button].down; $up = $map[$button].up
  $clicks = if ($doubleClick) { 2 } else { 1 }
  for ($i = 0; $i -lt $clicks; $i++) {
    [SMWin32]::mouse_event($down, 0, 0, 0, 0)
    Start-Sleep -Milliseconds 60
    [SMWin32]::mouse_event($up, 0, 0, 0, 0)
    if ($i -lt ($clicks - 1)) { Start-Sleep -Milliseconds 60 }
  }
}

# --- capture (returns coordinate mapping) ---
function Invoke-Capture([string]$outPath, [int]$maxDim, [bool]$all, [string]$regionJson) {
  Add-Type -AssemblyName System.Drawing
  Add-Type -AssemblyName System.Windows.Forms
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
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try { $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h)) } finally { $g.Dispose() }

  $scale = 1.0
  $outBmp = $bmp
  $resized = $false
  if ($maxDim -gt 0) {
    $longest = [Math]::Max($w, $h)
    if ($longest -gt $maxDim) {
      $scale = $maxDim / $longest
      $nw = [int][Math]::Round($w * $scale); $nh = [int][Math]::Round($h * $scale)
      $outBmp = New-Object System.Drawing.Bitmap $nw, $nh
      $resized = $true
      $g2 = [System.Drawing.Graphics]::FromImage($outBmp)
      try {
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g2.DrawImage($bmp, 0, 0, $nw, $nh)
      } finally { $g2.Dispose() }
    }
  }
  $outBmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
  if ($resized) { $outBmp.Dispose() }
  $bmp.Dispose()
  return @{ offX = $x; offY = $y; scale = $scale }
}

# --- OCR (returns text + words in screen coordinates) ---
function Invoke-Ocr([string]$imgPath, [double]$scale, [int]$offX, [int]$offY) {
  Ensure-Ocr
  $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($imgPath)) ([Windows.Storage.StorageFile])
  $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $result = Await ($script:OcrEngine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])

  $words = @()
  foreach ($line in $result.Lines) {
    foreach ($w in $line.Words) {
      $r = $w.BoundingRect
      $sx = [int][Math]::Round($offX + $r.X / $scale)
      $sy = [int][Math]::Round($offY + $r.Y / $scale)
      $sw = [int][Math]::Round($r.Width / $scale)
      $sh = [int][Math]::Round($r.Height / $scale)
      $cx = $sx + [int][Math]::Round($sw / 2)
      $cy = $sy + [int][Math]::Round($sh / 2)
      $words += [pscustomobject]@{ text = $w.Text; x = $sx; y = $sy; w = $sw; h = $sh; cx = $cx; cy = $cy }
    }
  }
  return [pscustomobject]@{ text = $result.Text; words = $words }
}

# --- find a substring's bounding span across words ---
function Find-TextSpan([array]$words, [string]$target) {
  $t = $target.ToLower()
  $combined = ''
  $charToWord = @()
  $wi = 0
  foreach ($w in $words) {
    foreach ($ch in $w.text.ToLower().ToCharArray()) {
      $combined += $ch
      $charToWord += $wi
    }
    $wi++
  }
  $idx = $combined.IndexOf($t)
  if ($idx -lt 0) { return $null }
  $endIdx = $idx + $t.Length - 1
  $minX = 2147483647; $minY = 2147483647; $maxX = -1; $maxY = -1
  $seen = @{}
  for ($p = $idx; $p -le $endIdx; $p++) {
    $wordIdx = $charToWord[$p]
    if (-not $seen.ContainsKey($wordIdx)) {
      $seen[$wordIdx] = $true
      $r = $words[$wordIdx]
      if ($r.x -lt $minX) { $minX = $r.x }
      if ($r.y -lt $minY) { $minY = $r.y }
      $rx = $r.x + $r.w; $ry = $r.y + $r.h
      if ($rx -gt $maxX) { $maxX = $rx }
      if ($ry -gt $maxY) { $maxY = $ry }
    }
  }
  $cw = $maxX - $minX; $ch = $maxY - $minY
  return @{ text = $target; x = $minX; y = $minY; w = $cw; h = $ch; cx = ($minX + [int]($cw / 2)); cy = ($minY + [int]($ch / 2)) }
}

function Get-CaptureParams {
  $maxDim = 0
  if ($env:SM_MAX_DIM) { $maxDim = [int]$env:SM_MAX_DIM }
  return @{ maxDim = $maxDim; all = ($env:SM_ALL -eq '1'); region = $env:SM_REGION }
}

function Do-OcrAction {
  $p = Get-CaptureParams
  $tmp = Join-Path $env:TEMP ('smocr-' + [guid]::NewGuid().ToString('N') + '.png')
  $cap = Invoke-Capture $tmp $p.maxDim $p.all $p.region
  $r = Invoke-Ocr $tmp $cap.scale $cap.offX $cap.offY
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  Write-Result @{ ok = $true; text = $r.text; words = $r.words }
}

function Do-ClickTextAction {
  $target = $env:SM_TARGET
  if (-not $target) { throw 'SM_TARGET required' }
  $offsetX = 0; if ($env:SM_OFFSET_X) { $offsetX = [int]$env:SM_OFFSET_X }
  $offsetY = 0; if ($env:SM_OFFSET_Y) { $offsetY = [int]$env:SM_OFFSET_Y }
  $button = $env:SM_BUTTON; if (-not $button) { $button = 'left' }
  $double = ($env:SM_DOUBLE -eq '1')

  $p = Get-CaptureParams
  $tmp = Join-Path $env:TEMP ('smocr-' + [guid]::NewGuid().ToString('N') + '.png')
  $cap = Invoke-Capture $tmp $p.maxDim $p.all $p.region
  $r = Invoke-Ocr $tmp $cap.scale $cap.offX $cap.offY
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue

  $span = Find-TextSpan $r.words $target
  if ($null -eq $span) {
    Write-Result @{ ok = $false; error = "Text not found: $target"; text = $r.text }
    return
  }
  $cx = $span.cx + $offsetX
  $cy = $span.cy + $offsetY
  Invoke-ClickAt $cx $cy $button $double
  Write-Result @{ ok = $true; matched = $span.text; x = $cx; y = $cy; button = $button; double = $double }
}

try {
  switch ($action) {
    'ocr'        { Do-OcrAction }
    'click_text' { Do-ClickTextAction }
    default      { throw "Unknown action: $action" }
  }
} catch {
  Write-Result @{ ok = $false; error = $_.Exception.Message }
}
