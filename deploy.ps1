# Copies the SasCraneOperator Lua mod into the game's UE4SS Mods folder.
# In game, Ctrl+R reloads UE4SS Lua mods without a restart.
param(
    [string]$GameDir = "D:\SteamLibrary\steamapps\common\Ships At Sea"
)

$mods = Join-Path $GameDir "SAS\Binaries\Win64\ue4ss\Mods"
if (-not (Test-Path $mods)) { throw "UE4SS Mods folder not found: $mods" }

$target = Join-Path $mods "SasCraneOperator"
New-Item -ItemType Directory -Force (Join-Path $target "Scripts") | Out-Null
Copy-Item (Join-Path $PSScriptRoot "SasCraneOperator\Scripts\main.lua") (Join-Path $target "Scripts\main.lua") -Force
Copy-Item (Join-Path $PSScriptRoot "SasCraneOperator\enabled.txt") (Join-Path $target "enabled.txt") -Force
Copy-Item (Join-Path $PSScriptRoot "LICENSE") (Join-Path $target "LICENSE") -Force
"Deployed SasCraneOperator to $target"
