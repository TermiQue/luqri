param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string[]]$Runtime = @('win-x64', 'win-arm64'),
    [string]$Compiler = 'ISCC.exe'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'Windows\Luqri.Windows.csproj'
$definition = Join-Path $root 'Windows\Luqri.iss'
$iscc = (Get-Command -Name $Compiler -CommandType Application).Source
$temp = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).ProviderPath.TrimEnd('\')
$staging = Join-Path $temp ('Luqri-Package-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null

try {
    foreach ($rid in $Runtime) {
        $payload = Join-Path $staging $rid
        dotnet publish $project -c Release -r $rid --self-contained -o $payload
        if ($LASTEXITCODE -ne 0) { throw "Luqri publish failed for $rid ($LASTEXITCODE)." }

        $output = Join-Path $root ".build\Luqri-$rid"
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $payload 'Luqri.exe'))
        $version = '{0}.{1}.{2}' -f $fileVersion.FileMajorPart, $fileVersion.FileMinorPart, $fileVersion.FileBuildPart
        $architecture = $rid.Substring(4)

        & $iscc /Qp "/DArchitecture=$architecture" "/DVersion=$version" "/DPublishDir=$payload" "/O$output" $definition
        if ($LASTEXITCODE -ne 0) { throw "Luqri installer build failed for $rid ($LASTEXITCODE)." }
        Write-Output (Join-Path $output "Luqri-Setup-$architecture.exe")
    }
}
finally {
    $resolved = (Resolve-Path -LiteralPath $staging).ProviderPath
    if ($resolved -eq $staging -and $resolved.StartsWith($temp + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
