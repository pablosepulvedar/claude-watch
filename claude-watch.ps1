# Claude Code Usage Watch
# Lee los porcentajes REALES del plan desde el mismo endpoint que usa /usage
# (https://api.anthropic.com/api/oauth/usage). Los % coinciden exactamente con /usage.
# ccusage se usa solo como info de volumen/costo (equivalente API, NO es tu factura).

# TLS 1.2 (Windows PowerShell 5.1 lo necesita para api.anthropic.com)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Desactiva "QuickEdit Mode" de la consola: si se selecciona texto (click/drag sin
# querer) en la ventana, Windows pausa TODO el script hasta soltar/tocar una tecla,
# rompiendo el auto-refresco cada $RefreshSeconds sin avisar.
try {
    Add-Type -Name Console -Namespace Win32Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction Stop
    $STD_INPUT_HANDLE    = -10
    $ENABLE_QUICK_EDIT   = 0x0040
    $ENABLE_EXTENDED_FLAGS = 0x0080
    $h = [Win32Native.Console]::GetStdHandle($STD_INPUT_HANDLE)
    [uint32]$mode = 0
    if ([Win32Native.Console]::GetConsoleMode($h, [ref]$mode)) {
        $mode = ($mode -band (-bnot $ENABLE_QUICK_EDIT)) -bor $ENABLE_EXTENDED_FLAGS
        [Win32Native.Console]::SetConsoleMode($h, $mode) | Out-Null
    }
} catch {}

$Accounts = @(
    @{ Label = "Personal"; CredPath = Join-Path $env:USERPROFILE ".claude\.credentials.json" }
    @{ Label = "Trabajo";  CredPath = Join-Path $env:USERPROFILE ".claude-trabajo\.credentials.json" }
)
$UsageUrl  = "https://api.anthropic.com/api/oauth/usage"
$ShowCcusage = $false  # poner $true para mostrar seccion de volumen/costo (ccusage)
# Cada cuanto refrescar (segundos). El endpoint de /usage se bloquea si lo
# llamas muy seguido: 30s (=120/h) gatilla bloqueos. 300s (=12/h) es seguro.
# Minimo recomendado ~120s. A mas alto, mas seguro.
$RefreshSeconds = 300

$host.UI.RawUI.WindowTitle = "Claude Watch"
try { $host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size(64, 48) } catch {}

function Draw-Bar {
    param([double]$pct, [int]$width = 40, [string]$color = "Green")
    $filled = [math]::Min($width, [math]::Round($pct / 100 * $width))
    $empty  = $width - $filled
    $bar = "[" + ("#" * $filled) + ("-" * $empty) + "]"
    Write-Host $bar -ForegroundColor $color -NoNewline
    Write-Host (" {0:0}%" -f $pct) -ForegroundColor White
}

function Get-BarColor { param([double]$pct)
    if ($pct -gt 80) { "Red" } elseif ($pct -gt 60) { "Yellow" } else { "Green" }
}

# Zona horaria de Santiago, disponible en todo el script
$tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Pacific SA Standard Time")

function Get-SantiagoTime {
    param([string]$iso)
    if ([string]::IsNullOrWhiteSpace($iso)) { return $null }
    $dto = [datetimeoffset]::Parse($iso)
    return [System.TimeZoneInfo]::ConvertTime($dto, $tz)
}

function Get-Usage {
    param([string]$CredPath)
    $cred = Get-Content $CredPath -Raw | ConvertFrom-Json
    $tok  = $cred.claudeAiOauth.accessToken
    $headers = @{
        "Authorization"  = "Bearer $tok"
        "anthropic-beta" = "oauth-2025-04-20"
    }
    $data  = Invoke-RestMethod -Uri $UsageUrl -Headers $headers -Method Get -TimeoutSec 15
    return @{ data = $data; plan = $cred.claudeAiOauth.subscriptionType; tier = $cred.claudeAiOauth.rateLimitTier }
}

function Show-AccountUsage {
    param([string]$Label, [string]$CredPath, [datetimeoffset]$Now)

    Write-Host ("  Cuenta: {0}" -f $Label) -ForegroundColor Magenta

    if (-not (Test-Path $CredPath)) {
        Write-Host "  (no configurada en esta maquina)" -ForegroundColor DarkGray
        Write-Host ""
        return
    }

    try {
        $u = Get-Usage -CredPath $CredPath
        $d = $u.data

        Write-Host ("  Plan: {0}  ({1})" -f $u.plan, $u.tier) -ForegroundColor DarkCyan
        Write-Host ""

        # Sesion (5h)
        if ($d.five_hour) {
            $p5   = [double]$d.five_hour.utilization
            $rst5 = Get-SantiagoTime $d.five_hour.resets_at
            Write-Host "  Sesion (5h)" -ForegroundColor Cyan
            Write-Host "  Uso       " -NoNewline
            Draw-Bar -pct $p5 -color (Get-BarColor $p5)
            if ($rst5) {
                $remMin = ([datetimeoffset]::Parse($d.five_hour.resets_at) - $Now).TotalMinutes
                if ($remMin -lt 0) {
                    $nowSantiago = [System.TimeZoneInfo]::ConvertTime($Now, $tz)
                    $candidate   = $nowSantiago.DateTime.Date.Add($rst5.TimeOfDay)
                    if ($candidate -le $nowSantiago.DateTime) { $candidate = $candidate.AddDays(1) }
                    $remMin = ($candidate - $nowSantiago.DateTime).TotalMinutes
                }
                if ($remMin -le 0) {
                    Write-Host ("  Restablece: {0}  (en curso)" -f $rst5.ToString("HH:mm")) -ForegroundColor Gray
                } else {
                    $rh = [math]::Floor($remMin / 60); $rm = [math]::Floor($remMin % 60)
                    Write-Host ("  Restablece: {0}  ({1}h {2}m restantes)" -f $rst5.ToString("HH:mm"), $rh, $rm) -ForegroundColor Gray
                }
            } else {
                Write-Host "  Sin sesion activa" -ForegroundColor Gray
            }
            Write-Host ""
        }

        # Semana (7 dias) - todos los modelos
        if ($d.seven_day) {
            $p7   = [double]$d.seven_day.utilization
            $rst7 = Get-SantiagoTime $d.seven_day.resets_at
            Write-Host "  Semana (7 dias)" -ForegroundColor Cyan
            Write-Host "  Todos     " -NoNewline
            Draw-Bar -pct $p7 -color (Get-BarColor $p7)
            if ($d.seven_day_sonnet) {
                $ps = [double]$d.seven_day_sonnet.utilization
                Write-Host "  Sonnet    " -NoNewline
                Draw-Bar -pct $ps -color (Get-BarColor $ps)
            }
            if ($d.seven_day_opus) {
                $po = [double]$d.seven_day_opus.utilization
                Write-Host "  Opus      " -NoNewline
                Draw-Bar -pct $po -color (Get-BarColor $po)
            }
            if ($rst7) {
                Write-Host ("  Restablece: {0}" -f $rst7.ToString("ddd dd MMM HH:mm")) -ForegroundColor Gray
            }
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match "401|Unauthorized") {
            Write-Host "  Token expirado. Abre esta cuenta en Claude Code una vez para refrescarlo." -ForegroundColor Yellow
        } else {
            Write-Host ("  Error leyendo /usage: {0}" -f $msg) -ForegroundColor Red
        }
    }
    Write-Host ""
}

while ($true) {
    Clear-Host
    Write-Host ("  Claude Code Usage  [" + (Get-Date -Format "HH:mm:ss") + "]") -ForegroundColor Yellow
    Write-Host ("=" * 62) -ForegroundColor DarkGray
    Write-Host ""

    # ----- Porcentajes REALES del plan (coinciden con /usage), por cuenta -----
    $now = [datetimeoffset]::UtcNow
    for ($i = 0; $i -lt $Accounts.Count; $i++) {
        Show-AccountUsage -Label $Accounts[$i].Label -CredPath $Accounts[$i].CredPath -Now $now
        if ($i -lt $Accounts.Count - 1) {
            Write-Host ("  " + ("-" * 60)) -ForegroundColor DarkGray
            Write-Host ""
        }
    }

    # ----- Volumen / costo (ccusage) - SOLO informativo, equivalente API -----
    if ($ShowCcusage) {
        Write-Host ""
        Write-Host ("-" * 62) -ForegroundColor DarkGray
        Write-Host "  Volumen (ccusage, equivalente API - NO es tu factura)" -ForegroundColor DarkGray
        try {
            $jb    = (npx ccusage blocks --active --json 2>$null) | ConvertFrom-Json
            $block = $jb.blocks | Where-Object { $_.isActive } | Select-Object -First 1
            if ($block) {
                Write-Host ("  Sesion: {0:N0} out  /  ~`${1:N2}" -f $block.tokenCounts.outputTokens, $block.costUSD) -ForegroundColor DarkGray
            }
            $jw   = (npx ccusage weekly --json 2>$null) | ConvertFrom-Json
            $week = $jw.weekly | Select-Object -Last 1
            if ($week) {
                Write-Host ("  Semana: {0:N0} out  /  ~`${1:N2}" -f $week.outputTokens, $jw.totals.totalCost) -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "  (ccusage no disponible)" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host ("=" * 62) -ForegroundColor DarkGray

    $deadline = (Get-Date).AddSeconds($RefreshSeconds)
    # Primera línea del countdown (sin newline para poder sobreescribir con \r)
    Write-Host ("  Actualiza en {0,3}s  (Ctrl+C salir  ·  R recargar)" -f $RefreshSeconds) -ForegroundColor DarkGray -NoNewline

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $secs = [math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        # \r vuelve al inicio de la línea y sobreescribe sin bajar
        Write-Host ("`r  Actualiza en {0,3}s  (Ctrl+C salir  ·  R recargar)" -f $secs) -ForegroundColor DarkGray -NoNewline

        # $host.UI.RawUI.KeyAvailable/ReadKey se cuelga bajo Windows Terminal (ConPTY) en
        # algunos casos, congelando TODO el script. [Console]::KeyAvailable es mas
        # confiable; si tambien falla, se deja de intentar leer teclas (el refresco por
        # tiempo sigue funcionando igual, solo se pierde el atajo de "R para recargar").
        if ($KeyCheckSupported -ne $false) {
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.KeyChar -eq 'r' -or $key.KeyChar -eq 'R') { break }
                }
                $KeyCheckSupported = $true
            } catch {
                $KeyCheckSupported = $false
            }
        }
    }
    Write-Host ""
}
