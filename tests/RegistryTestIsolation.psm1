Set-StrictMode -Version Latest

function Get-DagRegistryTreeSnapshot {
    param([Parameter(Mandatory)][string]$SubKeyPath)

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKeyPath)
    if ($null -eq $key) {
        return $null
    }

    try {
        $values = @(
            foreach ($name in $key.GetValueNames()) {
                [pscustomobject]@{
                    Name = $name
                    Kind = [int]$key.GetValueKind($name)
                    Value = $key.GetValue(
                        $name,
                        $null,
                        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                }
            })
        $children = @(
            foreach ($name in $key.GetSubKeyNames()) {
                [pscustomobject]@{
                    Name = $name
                    Snapshot = Get-DagRegistryTreeSnapshot `
                        -SubKeyPath "$SubKeyPath\$name"
                }
            })
        return [pscustomobject]@{
            Values = $values
            Children = $children
        }
    } finally {
        $key.Dispose()
    }
}

function Restore-DagRegistryTreeSnapshot {
    param(
        [Parameter(Mandatory)][string]$SubKeyPath,
        [AllowNull()][object]$Snapshot
    )

    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(
        $SubKeyPath,
        $false)
    if ($null -eq $Snapshot) {
        return
    }

    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey(
        $SubKeyPath,
        $true)
    try {
        foreach ($value in @($Snapshot.Values)) {
            $key.SetValue(
                [string]$value.Name,
                $value.Value,
                [Microsoft.Win32.RegistryValueKind]([int]$value.Kind))
        }
    } finally {
        $key.Dispose()
    }

    foreach ($child in @($Snapshot.Children)) {
        Restore-DagRegistryTreeSnapshot `
            -SubKeyPath "$SubKeyPath\$($child.Name)" `
            -Snapshot $child.Snapshot
    }
}

Export-ModuleMember `
    -Function Get-DagRegistryTreeSnapshot,Restore-DagRegistryTreeSnapshot
