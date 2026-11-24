param(
    [string]$BaseDir = "D:\Device\Apps\Antigravity Multi-Profile"
)

$tag = ""
$tagFile = Join-Path $BaseDir "tags\$($env:USERNAME).txt"
if (Test-Path $tagFile) {
    $tag = (Get-Content -LiteralPath $tagFile -Raw -Encoding UTF8).Trim()
}

$hideActiveEditor = $false
$hubSettingsFile = Join-Path $BaseDir "hub_settings.json"
if (Test-Path $hubSettingsFile) {
    try {
        $hubParsed = Get-Content -LiteralPath $hubSettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $hubParsed.HideActiveEditor) {
            $hideActiveEditor = [bool]$hubParsed.HideActiveEditor
        }
    } catch {}
}

$userDir = Join-Path $env:APPDATA "Antigravity IDE\User"
if (-not (Test-Path $userDir)) {
    New-Item -ItemType Directory -Path $userDir -Force | Out-Null
}

$settingsFile = Join-Path $userDir "settings.json"
$obj = @{}
if (Test-Path $settingsFile) {
    try {
        $raw = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $parsed = $raw | ConvertFrom-Json
            foreach ($prop in $parsed.PSObject.Properties) {
                $obj[$prop.Name] = $prop.Value
            }
        }
    } catch {}
}

$baseTitle = if ($hideActiveEditor) {
    "`${rootName}`${separator}`${appName}"
} else {
    "`${dirty}`${activeEditorShort}`${separator}`${rootName}`${separator}`${appName}"
}
$obj["window.title"] = if ($tag) { "$tag $baseTitle" } else { $baseTitle }
$json = $obj | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($settingsFile, $json, [System.Text.UTF8Encoding]::new($false))
