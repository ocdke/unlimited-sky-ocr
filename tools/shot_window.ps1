# 截取指定进程的主窗口
# 用法: powershell -File tools\shot_window.ps1 -Process dpg-setup -Out E:\dpg\docs\x.png [-Crop "x,y,w,h"] [-Scale 3]
param(
  [Parameter(Mandatory=$true)][string]$Process,
  [Parameter(Mandatory=$true)][string]$Out,
  [string]$Crop = '',
  [double]$Scale = 1
)

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class ShotWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
'@

$p = Get-Process -Name $Process -ErrorAction SilentlyContinue |
     Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Output "找不到带窗口的进程: $Process"; exit 1 }

$h = $p.MainWindowHandle
[ShotWin]::ShowWindow($h, 9) | Out-Null
[ShotWin]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 1200

$r = New-Object ShotWin+RECT
[ShotWin]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.R - $r.L; $ht = $r.B - $r.T
if ($w -le 0 -or $ht -le 0) { Write-Output "窗口尺寸异常: ${w}x${ht}"; exit 1 }

$bmp = New-Object System.Drawing.Bitmap($w, $ht)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
$g.Dispose()

if ($Crop -ne '') {
  $parts = $Crop.Split(',')
  $rect = New-Object System.Drawing.Rectangle([int]$parts[0], [int]$parts[1], [int]$parts[2], [int]$parts[3])
  $cropped = $bmp.Clone($rect, $bmp.PixelFormat)
  $bmp.Dispose()
  $bmp = $cropped
}

if ($Scale -ne 1) {
  $nw = [int]($bmp.Width * $Scale); $nh = [int]($bmp.Height * $Scale)
  $big = New-Object System.Drawing.Bitmap($nw, $nh)
  $g2 = [System.Drawing.Graphics]::FromImage($big)
  $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g2.DrawImage($bmp, 0, 0, $nw, $nh)
  $g2.Dispose(); $bmp.Dispose(); $bmp = $big
}

$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$sw = $bmp.Width; $sh = $bmp.Height
$bmp.Dispose()
Write-Output "已截图 $Out  ${sw}x${sh}  (窗口 ${w}x${ht} @ $($r.L),$($r.T))"
