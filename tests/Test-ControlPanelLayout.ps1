[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$layoutRepo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $layoutRepo 'scripts\Start-WindowsPrivacyGuard.ps1') -TestMode -PreviewOnly | Out-Null
$layoutReports = Join-Path $layoutRepo 'reports'
[void](New-Item -ItemType Directory -Path $layoutReports -Force)
if ($window.WindowStyle -ne 'SingleBorderWindow' -or $window.ResizeMode -ne 'CanResizeWithGrip' -or
    $window.SizeToContent -ne 'Manual' -or $window.WindowStartupLocation -ne 'Manual') {
    throw 'Native movable/resizable window configuration changed.'
}
$workAreas = @(
    [Windows.Rect]::new(0, 0, 1280, 672),
    [Windows.Rect]::new(0, 0, 960, 500),
    [Windows.Rect]::new(0, 0, 800, 432),
    [Windows.Rect]::new(-1280, 48, 1280, 672),
    [Windows.SystemParameters]::WorkArea
)
foreach ($area in $workAreas) {
    $bounds = Get-GuardWindowBounds -WorkArea $area
    if ($bounds.Left -lt $area.Left -or $bounds.Top -lt $area.Top -or
        $bounds.Left + $bounds.Width -gt $area.Right -or $bounds.Top + $bounds.Height -gt $area.Bottom -or
        $bounds.MinWidth -gt $bounds.Width -or $bounds.MinHeight -gt $bounds.Height) {
        throw "Startup window extends outside work area: $area"
    }
    if ($area.Width -ge 840 -and $bounds.MinWidth -gt $area.Width / 2) {
        throw 'Minimum width prevents a half-screen layout.'
    }
}
Write-Output 'Startup bounds PASS: actual work area, scaled/short screens, taskbar offset and negative origin'
# Render only this application's own WPF content. No desktop capture or microphone access.
$content = $window.Content
$window.Content = $null
$surface = [System.Windows.Controls.Border]::new()
$surface.Background = $window.Background
$surface.Child = $content
foreach ($size in @(@(848, 700, 'normal'), @(684, 500, 'small'), @(624, 600, 'half-screen'), @(464, 444, 'scaled-half-screen'), @(404, 380, 'minimum'))) {
    $width = [int]$size[0]
    $height = [int]$size[1]
    $surface.Width = $width
    $surface.Height = $height
    # Exercise wrapping with a real-length recovery path, not just the short idle text.
    $lastAction.Text = 'Privacy baseline applied. Restart Windows to refresh policies.' + [Environment]::NewLine +
        'Backup: C:\Users\Example\AppData\Local\WindowsPrivacyGuard\backups\privacy-baseline-20000101T000000Z-0123456789abcdef0123456789abcdef.json'
    $surface.Measure([System.Windows.Size]::new($width, $height))
    $surface.Arrange([System.Windows.Rect]::new(0, 0, $width, $height))
    $surface.UpdateLayout()
    if ($window.FindName('MainScroll').ActualHeight -lt 32) { throw "Scrollable content collapsed at $($size[2]) size." }
    foreach ($control in @($refresh, $apply, $debloat, $localOnly, $undoPrivacy, $undoNetwork, $lastAction)) {
        $point = $control.TransformToAncestor($surface).Transform([System.Windows.Point]::new(0, 0))
        if ($point.X -lt 0 -or $point.Y -lt 0 -or $point.X + $control.ActualWidth -gt $width -or $point.Y + $control.ActualHeight -gt $height) {
            throw "Control clipped at $($size[2]) size: $($control.Name)"
        }
    }
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($surface)
    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $path = Join-Path $layoutReports ("control-panel-preview-" + $size[2] + '.png')
    $stream = [IO.File]::Create($path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    Write-Output "Layout $($size[2]) PASS: $path"
}
$window.Close()
