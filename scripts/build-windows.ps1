param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string[]]$Runtime = @('win-x64', 'win-arm64')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'Windows\Luqri.Windows.csproj'
foreach ($rid in $Runtime) {
    $output = Join-Path $root ".build\Luqri-$rid"
    dotnet publish $project -c Release -r $rid --self-contained -o $output
    if ($LASTEXITCODE -ne 0) { throw "Luqri build failed for $rid ($LASTEXITCODE)." }
    Write-Output (Join-Path $output 'Luqri.exe')
}
