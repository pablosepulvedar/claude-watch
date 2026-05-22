# Claude Code Usage Watch
# Limites estimados del plan Pro (ajustar si /usage muestra porcentaje diferente)
$SessionOutputLimit = 286000   # tokens output por bloque de 5h
$WeeklyOutputLimit  = 382000   # tokens output por semana

$host.UI.RawUI.WindowTitle = "Claude Watch"
try { $host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size(62, 30) } catch {}

function Draw-Bar {
    param([double]$pct, [int]$width = 44, [string]$color = "Green")
    $filled = [math]::Min($width, [math]::Round($pct / 100 * $width))
    $empty  = $width - $filled
    $bar = "[" + ("#" * $filled) + ("-" * $empty) + "]"
    Write-Host $bar -ForegroundColor $color -NoNewline
    Write-Host (" {0:0}%" -f $pct) -ForegroundColor White
}

function Get-BarColor { param([double]$pct)
    if ($pct -gt 80) { "Red" } elseif ($pct -gt 60) { "Yellow" } else { "Green" }
}

function Get-SantiagoTime {
    param([string]$utcIso)
    $utc = [datetime]::Parse($utcIso).ToUniversalTime()
    $tz  = [System.TimeZoneInfo]::FindSystemTimeZoneById("Pacific SA Standard Time")
    return [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, $tz)
}

while ($true) {
    Clear-Host
    Write-Host ("  Claude Code Usage  [" + (Get-Date -Format "HH:mm:ss") + "]") -ForegroundColor Yellow
    Write-Host ("=" * 60) -ForegroundColor DarkGray
    Write-Host ""

    try {
        # --- Bloque de sesion (5h) ---
        $raw   = npx ccusage blocks --active --json 2>$null
        $jb    = $raw | ConvertFrom-Json
        $block = $jb.blocks | Where-Object { $_.isActive } | Select-Object -First 1

        if ($block) {
            $nowUtc     = [datetime]::UtcNow
            $blockStart = [datetime]::Parse($block.startTime).ToUniversalTime()
            $blockEnd   = [datetime]::Parse($block.endTime).ToUniversalTime()

            # Tiempo del bloque
            $totalMin   = ($blockEnd - $blockStart).TotalMinutes
            $elapsedMin = ($nowUtc - $blockStart).TotalMinutes
            $remainMin  = ($blockEnd - $nowUtc).TotalMinutes
            $timePct    = [math]::Min(100, $elapsedMin / $totalMin * 100)
            $elapsedH   = [math]::Floor($elapsedMin / 60)
            $elapsedM   = [math]::Floor($elapsedMin % 60)
            $remainH    = [math]::Floor($remainMin / 60)
            $remainM    = [math]::Floor($remainMin % 60)

            # Hora reset aprox (start real desde JSONL + 5h seria mas exacto, esta es aprox)
            $resetLocal = Get-SantiagoTime $block.endTime

            # Tokens sesion
            $outTok  = $block.tokenCounts.outputTokens
            $total   = $block.totalTokens
            $cost    = $block.costUSD
            $tokPct  = [math]::Min(100, $outTok / $SessionOutputLimit * 100)

            Write-Host "  Sesion actual (5h)" -ForegroundColor Cyan
            Write-Host "  Tiempo   " -NoNewline
            Draw-Bar -pct $timePct  -width 40 -color (Get-BarColor $timePct)
            Write-Host "  Tokens   " -NoNewline
            Draw-Bar -pct $tokPct   -width 40 -color (Get-BarColor $tokPct)
            Write-Host ("  {0}h {1}m usados  /  {2}h {3}m restantes" -f $elapsedH, $elapsedM, $remainH, $remainM) -ForegroundColor Gray
            Write-Host ("  Restablece: ~{0}  (aprox, ver /usage)" -f $resetLocal.ToString("HH:mm")) -ForegroundColor DarkGray
            Write-Host ("  Output: {0:N0}  /  ~{1:N0}   Costo: `${2:N2}" -f $outTok, $SessionOutputLimit, $cost) -ForegroundColor White

            # Proyeccion
            if ($block.projection) {
                Write-Host ("  Proyect: {0:N0} tokens  /  `${1:N2}" -f $block.projection.totalTokens, $block.projection.totalCost) -ForegroundColor DarkYellow
            }
        } else {
            Write-Host "  Sin bloque activo." -ForegroundColor DarkGray
        }

        # --- Semana actual ---
        Write-Host ""
        $rawW  = npx ccusage weekly --json 2>$null
        $jw    = $rawW | ConvertFrom-Json
        $week  = $jw.weekly | Select-Object -First 1

        if ($week) {
            $wOut    = $week.outputTokens
            $wTotal  = $week.totalTokens
            $wCost   = $jw.totals.totalCost
            $wPct    = [math]::Min(100, $wOut / $WeeklyOutputLimit * 100)

            Write-Host "  Semana actual (7 dias)" -ForegroundColor Cyan
            Write-Host "  Tokens   " -NoNewline
            Draw-Bar -pct $wPct -width 40 -color (Get-BarColor $wPct)
            Write-Host ("  Output: {0:N0}  /  ~{1:N0}   Costo: `${2:N2}" -f $wOut, $WeeklyOutputLimit, $wCost) -ForegroundColor White
        }

    } catch {
        Write-Host "  Error: $_" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkGray
    Write-Host "  Actualiza en 30s  (Ctrl+C para salir)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 30
}
