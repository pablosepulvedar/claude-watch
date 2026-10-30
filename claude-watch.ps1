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
    # Horario: dias (1=lunes..5=viernes) y horas en que se trabaja; fuera de eso la proyeccion no suma uso.
    # Sin Horario se asume que se puede usar a cualquier hora.
    @{ Label = "Trabajo";  CredPath = Join-Path $env:USERPROFILE ".claude-trabajo\.credentials.json"; Horario = @{ Dias = 1..5; Desde = 8; Hasta = 21 } }
)
# Historial local de % semanal (una fila por refresco y cuenta) para calcular el ritmo de las ultimas 24h.
# ponytail: crece ~1 MB/ano; borrar el archivo si molesta, solo se vuelve al promedio de la semana.
$LogPath = Join-Path $PSScriptRoot "historial.csv"
$ReportPath = Join-Path $PSScriptRoot "reporte.html"
$TemplatePath = Join-Path $PSScriptRoot "reporte.template.html"
# Consumo propio de este PC por hora, sesion y modelo, sacado de las conversaciones locales de Claude Code.
# Claude Code borra conversaciones viejas; consumo.csv queda como historial.
$UsoPath = Join-Path $PSScriptRoot "consumo.csv"
$UsoEstadoPath = Join-Path $PSScriptRoot "consumo.estado.csv"
$SesionesPath = Join-Path $PSScriptRoot "sesiones.csv"
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

function Test-UsableHour {
    param([datetimeoffset]$T, $Horario)
    if (-not $Horario) { return $true }
    $l = [System.TimeZoneInfo]::ConvertTime($T, $tz)
    return ($Horario.Dias -contains [int]$l.DayOfWeek) -and $l.Hour -ge $Horario.Desde -and $l.Hour -lt $Horario.Hasta
}

function Get-UsableHours {
    param([datetimeoffset]$From, [datetimeoffset]$To, $Horario)
    $h = 0.0; $t = $From
    while ($t -lt $To) {
        $n = [datetimeoffset]::new($t.UtcDateTime.Date.AddHours($t.UtcDateTime.Hour + 1), [timespan]::Zero)
        if ($n -gt $To) { $n = $To }
        if (Test-UsableHour $t $Horario) { $h += ($n - $t).TotalHours }
        $t = $n
    }
    return $h
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
    $week = @($all | Where-Object { $_.semana -eq $key })

    # Ritmo reciente por hora de uso posible (horario): mira hacia atras tanto como falta para el reset
    # (min 3h, max 24h); si el historial no alcanza, desde que empezo la semana
    $win  = [math]::Min(24, [math]::Max(3, $hRem))
    $ref  = $week | Where-Object { [long]$_.t -le $nowT - $win * 3600 } | Select-Object -Last 1
    if ($ref) {
        $rate = ($Pct - [double]$ref.pct) / [math]::Max(0.5, (Get-UsableHours ([datetimeoffset]::FromUnixTimeSeconds([long]$ref.t)) $Now $Horario))
        $base = "según el ritmo de las últimas {0:0}h" -f $win
    } else {
        $rate = $Pct / [math]::Max(0.5, (Get-UsableHours $start $Now $Horario))
        $base = "según el ritmo desde que empezó la semana"
    }
    if ($Horario) { $base += ", solo en horario laboral" }

    # Patron: % que subes en promedio cada (dia de semana, hora), aprendido de semanas anteriores.
    # ponytail: una hora observada solo en parte cuenta como entera; con varias semanas se diluye.
    $inc = @{}; $seen = @{}
    for ($i = 1; $i -lt $all.Count; $i++) {
        $p0 = $all[$i - 1]; $p1 = $all[$i]
        if ($p1.semana -ne $p0.semana -or $p1.semana -eq $key) { continue }
        if (([long]$p1.t - [long]$p0.t) -gt 1800) { continue }
        $b = [System.TimeZoneInfo]::ConvertTime([datetimeoffset]::FromUnixTimeSeconds([long]$p1.t), $tz).ToString("ddd-HH")
        $inc[$b] = [double]$inc[$b] + [math]::Max(0, [double]$p1.pct - [double]$p0.pct)
        if (-not $seen[$b]) { $seen[$b] = @{} }
        $seen[$b][$p1.semana] = 1
    }

    # Proyeccion hora a hora hasta el reset: patron si esa hora ya se vio otra semana, si no el ritmo reciente
    $proj = $Pct; $hit = $null; $hPat = 0.0
    $tcur = $Now
    while ($tcur -lt $reset) {
        $tnext = [datetimeoffset]::new($tcur.UtcDateTime.Date.AddHours($tcur.UtcDateTime.Hour + 1), [timespan]::Zero)
        if ($tnext -gt $reset) { $tnext = $reset }
        $f = ($tnext - $tcur).TotalHours
        $b = [System.TimeZoneInfo]::ConvertTime($tcur, $tz).ToString("ddd-HH")
        if ($seen[$b]) { $step = $inc[$b] / $seen[$b].Count * $f; $hPat += $f }
        elseif (Test-UsableHour $tcur $Horario) { $step = $rate * $f } else { $step = 0 }
        if (-not $hit -and $step -gt 0 -and $proj + $step -ge 100) { $hit = $tcur.AddHours((100 - $proj) / $step * $f) }
        $proj += $step
        $tcur = $tnext
    }
    if ($hPat -ge $hRem / 2) { $base = "según tu patrón de semanas anteriores" }

    Write-Host "  Tiempo    " -NoNewline
    Draw-Bar -pct ($hElap / 168 * 100) -color DarkCyan
    Write-Host "  Al reset  " -NoNewline
    Draw-Bar -pct ([math]::Min(100, $proj)) -color $(if ($proj -ge 100) { "Red" } else { "Green" })
    if ($hit) {
        $h = [System.TimeZoneInfo]::ConvertTime($hit, $tz)
        Write-Host ("  Si sigues así: se acaba el {0} a las {1}, antes del reset. Baja el ritmo." -f $h.ToString("ddd dd"), $h.ToString("HH:mm")) -ForegroundColor Red
    } else {
        Write-Host ("  Si sigues así: llegas al reset con ~{0:0}% (te sobra {1:0}%)" -f $proj, (100 - $proj)) -ForegroundColor Green
    }
    Write-Host ("  ({0})" -f $base) -ForegroundColor DarkGray

    # Uso por dia de esta semana (solo dias con historial)
    $days = [ordered]@{}
    foreach ($r in $week) {
        $dk = [System.TimeZoneInfo]::ConvertTime([datetimeoffset]::FromUnixTimeSeconds([long]$r.t), $tz).ToString("ddd dd")
        if (-not $days.Contains($dk)) { $days[$dk] = @([double]$r.pct, [double]$r.pct) }
        $days[$dk][1] = [double]$r.pct
    }
    if ($days.Count -gt 0) {
        $parts = @(); $prev = $null; $sum = 0.0; $n = 0
        $today = [System.TimeZoneInfo]::ConvertTime($Now, $tz).ToString("ddd dd")
        foreach ($dk in $days.Keys) {
            $first, $last = $days[$dk]
            $d = if ($null -ne $prev) { $last - $prev } else { $last - $first }
            $parts += ("{0} +{1:0}%" -f $dk.Substring(0, 3), $d)
            if ($null -ne $prev -and $dk -ne $today) { $sum += $d; $n++ }
            $prev = $last
        }
        Write-Host ("  Por día   " + ($parts -join "  ")) -ForegroundColor Gray
        if ($n -gt 0) { Write-Host ("  Promedio  {0:0.0}% por día completo" -f ($sum / $n)) -ForegroundColor Gray }
    }
}

function Get-JsonStr { param([string]$Line, [string]$Key, [switch]$Last)
    $k = '"' + $Key + '":"'
    $i = if ($Last) { $Line.LastIndexOf($k) } else { $Line.IndexOf($k) }
    if ($i -lt 0) { return $null }
    $s = $i + $k.Length
    $e = $Line.IndexOf('"', $s)
    if ($e -lt 0) { return $null }
    $Line.Substring($s, $e - $s).TrimEnd([char]92)
}

function Update-Consumo {
    # Lee solo lo nuevo de cada .jsonl (offset guardado) y suma tokens por hora, cuenta, sesion y modelo.
    # Cada respuesta aparece repetida en varias lineas con el mismo requestId: se cuenta una vez.
    $uso = @{}
    if (Test-Path $UsoPath) { foreach ($r in (Import-Csv $UsoPath -Header h, cuenta, sesion, modelo, i, cc, cr, o)) { $uso["$($r.h)|$($r.cuenta)|$($r.sesion)|$($r.modelo)"] = [long[]]@($r.i, $r.cc, $r.cr, $r.o) } }
    $estado = @{}
    if (Test-Path $UsoEstadoPath) { foreach ($r in (Import-Csv $UsoEstadoPath)) { $estado[$r.archivo] = $r } }
    $titulos = @{}
    if (Test-Path $SesionesPath) { foreach ($r in (Import-Csv $SesionesPath)) { $titulos[$r.sesion] = $r } }
    $cambio = $false
    foreach ($acc in $Accounts) {
        $dir = Join-Path (Split-Path $acc.CredPath) "projects"
        if (-not (Test-Path $dir)) { continue }
        foreach ($f in (Get-ChildItem $dir -Recurse -Filter *.jsonl -File)) {
            $e = $estado[$f.FullName]
            $off = if ($e) { [long]$e.offset } else { 0L }
            $prev = if ($e) { [string]$e.ultimo } else { "" }
            if ($f.Length -le $off) { continue }
            $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
            try {
                [void]$fs.Seek($off, 'Begin')
                $buf = New-Object byte[] ($f.Length - $off)
                $n = 0
                while ($n -lt $buf.Length) { $r = $fs.Read($buf, $n, $buf.Length - $n); if ($r -le 0) { break }; $n += $r }
            } finally { $fs.Close() }
            if ($n -le 0) { continue }
            $nl = [Array]::LastIndexOf($buf, [byte]10, $n - 1)
            if ($nl -lt 0) { continue }
            $off += $nl + 1
            $vistos = New-Object 'System.Collections.Generic.HashSet[string]'
            if ($prev) { [void]$vistos.Add($prev) }
            foreach ($l in [Text.Encoding]::UTF8.GetString($buf, 0, $nl).Split("`n")) {
                $custom = $l.StartsWith('{"type":"custom-title"')
                if ($custom -or $l.StartsWith('{"type":"ai-title"')) {
                    $sid = Get-JsonStr $l "sessionId"
                    $t = Get-JsonStr $l $(if ($custom) { "customTitle" } else { "aiTitle" })
                    $old = $titulos[$sid]
                    if ($sid -and $t -and ($custom -or -not $old -or $old.tipo -ne "custom")) {
                        $titulos[$sid] = [pscustomobject]@{ sesion = $sid; cuenta = $acc.Label; tipo = $(if ($custom) { "custom" } else { "ai" }); titulo = $t }
                    }
                    continue
                }
                $u = $l.LastIndexOf('"usage":{"input_tokens":')
                if ($u -lt 0) { continue }
                $ra = $l.IndexOf('"role":"assistant"')
                if ($ra -lt 0 -or $ra -gt 600) { continue }
                $req = Get-JsonStr $l "requestId" -Last
                if ($req -and -not $vistos.Add($req)) { continue }
                $m = [regex]::Match($l.Substring($u, [Math]::Min(300, $l.Length - $u)), '"input_tokens":(\d+),"cache_creation_input_tokens":(\d+),"cache_read_input_tokens":(\d+),"output_tokens":(\d+)')
                $ts = Get-JsonStr $l "timestamp" -Last
                if (-not $m.Success -or -not $ts -or $ts.Length -lt 13) { continue }
                $v = [long[]]@($m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value, $m.Groups[4].Value)
                if (($v | Measure-Object -Sum).Sum -eq 0) { continue }
                $h = [DateTimeOffset]::Parse($ts.Substring(0, 13) + ":00:00Z", [cultureinfo]::InvariantCulture).ToUnixTimeSeconds()
                $sid = Get-JsonStr $l "sessionId" -Last
                if (-not $sid) { $sid = $f.BaseName }
                $k = "$h|$($acc.Label)|$sid|$(Get-JsonStr $l 'model')"
                if (-not $uso.ContainsKey($k)) { $uso[$k] = [long[]]@(0, 0, 0, 0) }
                for ($j = 0; $j -lt 4; $j++) { $uso[$k][$j] += $v[$j] }
                if ($req) { $prev = $req }
            }
            $estado[$f.FullName] = [pscustomobject]@{ archivo = $f.FullName; offset = $off; ultimo = $prev }
            $cambio = $true
        }
    }
    if (-not $cambio) { return }
    [IO.File]::WriteAllLines($UsoPath, [string[]]($uso.GetEnumerator() | ForEach-Object { ($_.Key -replace '\|', ',') + "," + ($_.Value -join ",") }))
    $estado.Values | Export-Csv $UsoEstadoPath -NoTypeInformation -Encoding UTF8
    $titulos.Values | Export-Csv $SesionesPath -NoTypeInformation -Encoding UTF8
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
    $uso = if (Test-Path $UsoPath) { ([IO.File]::ReadAllLines($UsoPath) | ForEach-Object { $c = $_.Split(","); '[{0},"{1}","{2}","{3}",{4},{5},{6},{7}]' -f $c }) -join "," } else { "" }
    $ses = @{}
    if (Test-Path $SesionesPath) { foreach ($r in (Import-Csv $SesionesPath)) { $ses[$r.sesion] = $r.titulo } }
    $html = [IO.File]::ReadAllText($tpl).Replace("/*DATA*/[]", "[" + $sb.ToString() + "]").Replace("/*USO*/[]", "[" + $uso + "]").Replace("/*SES*/{}", ($ses | ConvertTo-Json -Compress)).Replace('/*GEN*/""', '"' + (Get-Date -Format "dd-MM-yyyy HH:mm") + '"')
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

    try { Update-Consumo } catch {}
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
                    if ($key.KeyChar -eq 'i' -or $key.KeyChar -eq 'I') { try { Update-Consumo; Write-Report; Start-Process $ReportPath } catch {} }
                }
                $KeyCheckSupported = $true
            } catch {
                $KeyCheckSupported = $false
            }
        }
    }
    Write-Host ""
}
