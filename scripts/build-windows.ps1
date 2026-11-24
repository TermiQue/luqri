param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string]$Runtime = 'win-x64',
    [switch]$Package
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'Windows\Luqri.Windows.csproj'
$output = Join-Path $root ".build\Luqri-$Runtime"

dotnet publish $project -c Release -r $Runtime --self-contained -o $output
if ($LASTEXITCODE -ne 0) { throw "Luqri build failed ($LASTEXITCODE)." }

if ($Package) {
    $archive = "$output.zip"
    Compress-Archive -Path $output -DestinationPath $archive -Force
    $hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$archive.sha256" -Value "$hash  $(Split-Path -Leaf $archive)" -Encoding ascii
    Write-Output $archive
}
Write-Output (Join-Path $output 'Luqri.exe')
