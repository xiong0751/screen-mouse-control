# Shortcuts engine for @local/screen-mouse-control.
# Pre-stored common Windows actions + keyboard + clipboard.
# Dispatched by SM_ACTION; args via SM_TARGET / SM_TEXT / SM_KEYS env vars.

$ErrorActionPreference = 'Stop'
$action = $env:SM_ACTION
if (-not $action) { $action = 'open' }

function Write-Result([hashtable]$obj) {
  ($obj | ConvertTo-Json -Compress -Depth 6) | Write-Output
}

$script:Win32Loaded = $false
function Add-Win32Key {
  if ($script:Win32Loaded) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class KWin32 {
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);
}
'@
  $script:Win32Loaded = $true
}

function Press-Vk([byte]$vk) {
  Add-Win32Key
  [KWin32]::keybd_event($vk, 0, 0, 0)
  [KWin32]::keybd_event($vk, 0, 2, 0)
}

function Send-Keys([string]$keys) {
  $ws = New-Object -ComObject WScript.Shell
  $ws.SendKeys($keys)
}

function Escape-SendKeys([string]$s) {
  return $s.Replace('+','{+}').Replace('^','{^}').Replace('%','{%}').Replace('~','{~}').Replace('(','{(}').Replace(')','{)}').Replace('{','{{}').Replace('}','{}}').Replace('[','{[}').Replace(']','{]}')
}

try {
  switch ($action) {
    'open' {
      $t = $env:SM_TARGET
      if (-not $t) { throw 'SM_TARGET required' }
      Start-Process $t
      Write-Result @{ ok = $true; action = 'open'; target = $t }
    }
    'open_explorer'    { Start-Process explorer.exe;     Write-Result @{ ok = $true } }
    'open_settings'    { Start-Process 'ms-settings:';   Write-Result @{ ok = $true } }
    'open_task_manager'{ Start-Process taskmgr.exe;      Write-Result @{ ok = $true } }
    'open_notepad'     { Start-Process notepad.exe;      Write-Result @{ ok = $true } }
    'open_calculator'  { Start-Process calc.exe;         Write-Result @{ ok = $true } }
    'open_cmd'         { Start-Process cmd.exe;          Write-Result @{ ok = $true } }
    'open_powershell'  { Start-Process powershell.exe;   Write-Result @{ ok = $true } }
    'lock'             { rundll32.exe 'user32.dll,LockWorkStation'; Write-Result @{ ok = $true } }
    'sleep'            { rundll32.exe 'powrprof.dll,SetSuspendState' '0,1,0'; Write-Result @{ ok = $true } }
    'hibernate'        { rundll32.exe 'powrprof.dll,SetSuspendState' '1,1,0'; Write-Result @{ ok = $true } }
    'restart'          { shutdown.exe /r /t 0; Write-Result @{ ok = $true } }
    'shutdown'         { shutdown.exe /s /t 0; Write-Result @{ ok = $true } }
    'volume_up'        { Press-Vk 0xAF; Write-Result @{ ok = $true } }
    'volume_down'      { Press-Vk 0x8E; Write-Result @{ ok = $true } }
    'volume_mute'      { Press-Vk 0xAD; Write-Result @{ ok = $true } }
    'show_desktop' {
      Add-Win32Key
      [KWin32]::keybd_event(0x5B, 0, 0, 0)
      [KWin32]::keybd_event(0x44, 0, 0, 0)
      [KWin32]::keybd_event(0x44, 0, 2, 0)
      [KWin32]::keybd_event(0x5B, 0, 2, 0)
      Write-Result @{ ok = $true }
    }
    'empty_recycle_bin' { Clear-RecycleBin -Force -ErrorAction SilentlyContinue; Write-Result @{ ok = $true } }
    'clipboard_set' {
      $t = $env:SM_TEXT
      Set-Clipboard -Value $t
      Write-Result @{ ok = $true; len = $t.Length }
    }
    'clipboard_get' {
      $c = Get-Clipboard -Raw
      Write-Result @{ ok = $true; text = $c }
    }
    'type_text' {
      $t = $env:SM_TEXT
      if ($null -eq $t) { throw 'SM_TEXT required' }
      Send-Keys (Escape-SendKeys $t)
      Write-Result @{ ok = $true; len = $t.Length }
    }
    'press_keys' {
      $k = $env:SM_KEYS
      if (-not $k) { throw 'SM_KEYS required' }
      Send-Keys $k
      Write-Result @{ ok = $true; keys = $k }
    }
    default { throw "Unknown action: $action" }
  }
} catch {
  Write-Result @{ ok = $false; error = $_.Exception.Message }
}
