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
    # Horario: dias (1=lunes..5=viernes) y horas de trabajo (HastaViernes = salida del viernes). Lo usado fuera
    # de horario se suma al ritmo de las horas de trabajo y la proyeccion solo avanza en horario.
    # Sin Horario todas las horas son iguales.
    @{ Label = "Trabajo";  CredPath = Join-Path $env:USERPROFILE ".claude-trabajo\.credentials.json"; Horario = @{ Dias = 1..5; Desde = 8; Hasta = 17.5; HastaViernes = 16 } }
)
# Historial local de % semanal (una fila por refresco y cuenta) para calcular el ritmo de las ultimas 24h.
# ponytail: crece ~1 MB/ano; borrar el archivo si molesta, solo se vuelve al promedio de la semana.
$LogPath = Join-Path $PSScriptRoot "historial.csv"
$ReportPath = Join-Path $PSScriptRoot "reporte.html"
$TemplatePath = Join-Path $PSScriptRoot "reporte.template.html"
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

function Get-HourCat {
    # "lab" = dentro del horario, "noche" = dia laboral fuera del horario, "finde" = dia no laboral
    param([datetimeoffset]$T, $Horario)
    if (-not $Horario) { return "lab" }
    $l = [System.TimeZoneInfo]::ConvertTime($T, $tz)
    if ($Horario.Dias -notcontains [int]$l.DayOfWeek) { return "finde" }
    $h = $l.Hour + $l.Minute / 60
    $fin = if ([int]$l.DayOfWeek -eq 5 -and $Horario.HastaViernes) { $Horario.HastaViernes } else { $Horario.Hasta }
    if ($h -ge $Horario.Desde -and $h -lt $fin) { "lab" } else { "noche" }
}

function Get-NextSlice {
    # Siguiente limite de 10 minutos (Chile cambia de hora en horas enteras, asi que coincide en UTC)
    param([datetimeoffset]$T)
    $u = $T.UtcDateTime
    [datetimeoffset]::new($u.Date.AddMinutes(10 * ([math]::Floor(($u.Hour * 60 + $u.Minute) / 10) + 1)), [timespan]::Zero)
}

function Get-Spread {
    # Reparte cada aumento de % en el tiempo que paso entre dos lecturas y lo suma por categoria de hora
    # y por dia local. Solo cuenta desde $Desde.
    param($Rows, [long]$Desde, $Horario)
    $r = @{ inc = @{ lab = 0.0; noche = 0.0; finde = 0.0 }; hrs = @{ lab = 0.0; noche = 0.0; finde = 0.0 }; dia = [ordered]@{}; dow = @{} }
    for ($i = 1; $i -lt $Rows.Count; $i++) {
        $p0 = $Rows[$i - 1]; $p1 = $Rows[$i]
        $b0 = [long]$p0.t; $v0 = [double]$p0.pct
        if ($p1.semana -ne $p0.semana) {
            # Primera lectura de una semana nueva: lo que marca se gasto desde que empezo esa semana
            $b0 = [math]::Max($b0, [datetimeoffset]::Parse($p1.semana + ":00:00Z").AddDays(-7).ToUnixTimeSeconds()); $v0 = 0
        }
        $t0 = [math]::Max($b0, $Desde); $t1 = [long]$p1.t
        if ($t1 -le $t0) { continue }
        # Hueco largo (Claude Watch cerrado o PC apagado): el aumento va al momento en que se dejo de medir,
        # que es cuando se estaba usando; el resto del hueco cuenta como horas sin uso.
        $total = [math]::Max(0, [double]$p1.pct - $v0)
        $largo = ($t1 - $b0) -gt 7200
        $perSec = if ($largo) { 0.0 } else { $total / ($t1 - $b0) }
        $t = [datetimeoffset]::FromUnixTimeSeconds($t0); $end = [datetimeoffset]::FromUnixTimeSeconds($t1)
        while ($t -lt $end) {
            $n = Get-NextSlice $t
            if ($n -gt $end) { $n = $end }
            $s = ($n - $t).TotalSeconds; $c = Get-HourCat $t $Horario
            $add = if ($largo -and $t.ToUnixTimeSeconds() -eq $b0) { $total } else { $perSec * $s }
            $r.hrs[$c] += $s / 3600; $r.inc[$c] += $add
            $l = [System.TimeZoneInfo]::ConvertTime($t, $tz); $dk = $l.ToString("ddd dd")
            $r.dia[$dk] = [double]$r.dia[$dk] + $add; $r.dow[$dk] = [int]$l.DayOfWeek
            $t = $n
        }
    }
    $r
}

function Show-WeekForecast {
    param([string]$Label, [double]$Pct, [string]$ResetIso, [datetimeoffset]$Now, $Horario)
    $reset = [datetimeoffset]::Parse($ResetIso)
    $start = $reset.AddDays(-7)
    $key   = $reset.ToUniversalTime().AddMinutes(30).ToString("yyyy-MM-ddTHH")
    $nowT  = $Now.ToUnixTimeSeconds()
    try { "{0},{1},{2},{3}" -f $nowT, $Label, $key, $Pct.ToString([cultureinfo]::InvariantCulture) | Add-Content $LogPath } catch {}

    $hElap = ($Now - $start).TotalHours
    $hRem  = ($reset - $Now).TotalHours
    if ($hElap -lt 1 -or $hRem -le 0) { return }

    $all = @()
    if (Test-Path $LogPath) { $all = @(Import-Csv $LogPath -Header t, cuenta, semana, pct | Where-Object { $_.cuenta -eq $Label }) }

    # Ritmo de los ultimos 7 dias. Con horario, todo lo gastado (incluso fuera de horario) se reparte solo
    # en las horas de trabajo, y la proyeccion solo avanza dentro del horario.
    # ponytail: los 7 dias pesan igual; si cambias de ritmo de golpe tarda unos dias en notarse.
    $sp = Get-Spread $all ($nowT - 7 * 86400) $Horario
    $rate = @{ lab = 0.0; noche = 0.0; finde = 0.0 }
    if ($sp.hrs.lab -ge 1) { $rate.lab = ($sp.inc.lab + $sp.inc.noche + $sp.inc.finde) / $sp.hrs.lab } else { $rate.lab = $Pct / $hElap }
    $cov = $sp.hrs.lab + $sp.hrs.noche + $sp.hrs.finde
    $dias = [math]::Max(1, [math]::Round($cov / 24))
    $per = if ($dias -eq 1) { "del último día" } else { "de los últimos $dias días" }
    $base = "ritmo {0}: {1:0.0}%/h{2}" -f $per, $rate.lab, $(if ($Horario) { " en horario, con lo de fuera de horario" } else { "" })

    # Proyeccion por tramos de 10 minutos hasta el reset con el ritmo de cada tipo de hora
    $proj = $Pct; $hit = $null; $tcur = $Now
    while ($tcur -lt $reset) {
        $tnext = Get-NextSlice $tcur
        if ($tnext -gt $reset) { $tnext = $reset }
        $f = ($tnext - $tcur).TotalHours
        $step = $rate[(Get-HourCat $tcur $Horario)] * $f
        if (-not $hit -and $step -gt 0 -and $proj + $step -ge 100) { $hit = $tcur.AddHours((100 - $proj) / $step * $f) }
        $proj += $step
        $tcur = $tnext
    }

    Write-Host "  Tiempo    " -NoNewline
    Draw-Bar -pct ($hElap / 168 * 100) -color DarkCyan
    Write-Host "  Al reset  " -NoNewline
    Draw-Bar -pct ([math]::Min(100, $proj)) -color $(if ($proj -ge 100) { "Red" } else { "Green" })
    if ($hit) {
        $h = [System.TimeZoneInfo]::ConvertTime($hit, $tz)
        Write-Host ("  Si sigues así: se acaba el {0} a las {1}, antes del reset." -f $h.ToString("ddd dd"), $h.ToString("HH:mm")) -ForegroundColor Red
    } else {
        Write-Host ("  Si sigues así: llegas al reset con ~{0:0}% (te sobra {1:0}%)" -f $proj, (100 - $proj)) -ForegroundColor Green
    }
    Write-Host ("  ({0})" -f $base) -ForegroundColor DarkGray

    # Uso por dia de esta semana, fines de semana incluidos; el promedio solo cuenta dias laborales completos
    $sw = Get-Spread $all $start.ToUnixTimeSeconds() $Horario
    if ($sw.dia.Count -gt 0) {
        $today = [System.TimeZoneInfo]::ConvertTime($Now, $tz).ToString("ddd dd")
        $first = @($sw.dia.Keys)[0]
        $parts = @(); $sum = 0.0; $n = 0
        foreach ($dk in $sw.dia.Keys) {
            $v = $sw.dia[$dk]
            if ($v -ge 0.05) { $parts += ("{0} +{1}%" -f $dk.Substring(0, 3), $v.ToString($(if ($v -gt 0 -and $v -lt 1) { "0.0" } else { "0" }))) }
            if ($dk -ne $first -and $dk -ne $today -and (-not $Horario -or $Horario.Dias -contains $sw.dow[$dk])) { $sum += $v; $n++ }
        }
        if ($parts) { Write-Host ("  Por día   " + ($parts -join "  ")) -ForegroundColor Gray }
        if ($n -gt 0 -and $sum / $n -ge 0.05) { Write-Host ("  Promedio  {0:0.0}% por día {1}completo" -f ($sum / $n), $(if ($Horario) { "laboral " } else { "" })) -ForegroundColor Gray }
    }
}

function Write-Report {
    # Genera reporte.html (graficos semanal/mensual/historico) desde historial.csv; se abre con la tecla I
    $tpl = $TemplatePath
    if (-not (Test-Path $tpl) -or -not (Test-Path $LogPath)) { return }
    $last = @{}; $sb = New-Object System.Text.StringBuilder
    foreach ($r in (Import-Csv $LogPath -Header t, cuenta, semana, pct)) {
        $sig = $r.semana + "|" + $r.pct
        if ($last[$r.cuenta] -eq $sig) { continue }
        $last[$r.cuenta] = $sig
        if ($sb.Length) { [void]$sb.Append(",") }
        [void]$sb.AppendFormat('[{0},"{1}","{2}",{3}]', $r.t, $r.cuenta, $r.semana, $r.pct)
    }
    $html = [IO.File]::ReadAllText($tpl).Replace("/*DATA*/[]", "[" + $sb.ToString() + "]").Replace('/*GEN*/""', '"' + (Get-Date -Format "dd-MM-yyyy HH:mm") + '"')
    [IO.File]::WriteAllText($ReportPath, $html, (New-Object System.Text.UTF8Encoding $false))
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
    param([string]$Label, [string]$CredPath, [datetimeoffset]$Now, $Horario)

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
                Show-WeekForecast -Label $Label -Pct $p7 -ResetIso $d.seven_day.resets_at -Now $Now -Horario $Horario
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
        # Pausa entre cuentas para no disparar 2 requests casi simultaneos al
        # mismo endpoint (algunos rate limits cortan por rafaga corta, no solo
        # por promedio por hora).
        if ($i -gt 0) { Start-Sleep -Seconds 5 }
        Show-AccountUsage -Label $Accounts[$i].Label -CredPath $Accounts[$i].CredPath -Now $now -Horario $Accounts[$i].Horario
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

    try { Write-Report } catch {}
    # Enlace clickeable (Ctrl+clic en Windows Terminal) al informe con graficos
    $esc = [char]27
    $st  = $esc + "\"
    $url = "file:///" + $ReportPath.Replace([string][char]92, "/")
    Write-Host ""
    Write-Host ("  Informe con gráficos: tecla I  o  Ctrl+clic en {0}]8;;{1}{2}abrir informe{0}]8;;{2}" -f $esc, $url, $st) -ForegroundColor Cyan
    Write-Host ("=" * 62) -ForegroundColor DarkGray

    $deadline = (Get-Date).AddSeconds($RefreshSeconds)
    # Primera línea del countdown (sin newline para poder sobreescribir con \r)
    Write-Host ("  Actualiza en {0,3}s  (Ctrl+C salir · R recargar · I informe)" -f $RefreshSeconds) -ForegroundColor DarkGray -NoNewline

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $secs = [math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        # \r vuelve al inicio de la línea y sobreescribe sin bajar
        Write-Host ("`r  Actualiza en {0,3}s  (Ctrl+C salir · R recargar · I informe)" -f $secs) -ForegroundColor DarkGray -NoNewline

        # $host.UI.RawUI.KeyAvailable/ReadKey se cuelga bajo Windows Terminal (ConPTY) en
        # algunos casos, congelando TODO el script. [Console]::KeyAvailable es mas
        # confiable; si tambien falla, se deja de intentar leer teclas (el refresco por
        # tiempo sigue funcionando igual, solo se pierde el atajo de "R para recargar").
        if ($KeyCheckSupported -ne $false) {
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.KeyChar -eq 'r' -or $key.KeyChar -eq 'R') { break }
                    if ($key.KeyChar -eq 'i' -or $key.KeyChar -eq 'I') { try { Write-Report; Start-Process $ReportPath } catch {} }
                }
                $KeyCheckSupported = $true
            } catch {
                $KeyCheckSupported = $false
            }
        }
    }
    Write-Host ""
}
