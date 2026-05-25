# Claude Watch

Monitor de uso de Claude Code en tiempo real para Windows.

Muestra en una ventana de PowerShell, actualizada cada 30 segundos, **los mismos porcentajes que `/usage`** dentro de Claude Code — porque lee de la misma fuente oficial.

```
  Claude Code Usage  [13:58:22]
==============================================================

  Plan: max  (default_claude_max_20x)

  Sesion (5h)
  Uso       [###-------------------------------------] 7%
  Restablece: 18:19  (4h 21m restantes)

  Semana (7 dias)
  Todos     [###################---------------------] 47%
  Sonnet    [####################--------------------] 49%
  Restablece: vie 29 may. 07:00

--------------------------------------------------------------
  Volumen (ccusage, equivalente API - NO es tu factura)
  Sesion: 71.125 out  /  ~$18,52
  Semana: 71.125 out  /  ~$403,05

==============================================================
  Actualiza en 30s  (Ctrl+C para salir)
```

---

## Cómo funciona

A diferencia de herramientas que estiman el uso contando tokens, Claude Watch consulta el **endpoint real** que usa el comando `/usage`:

```
GET https://api.anthropic.com/api/oauth/usage
```

Se autentica con tu token OAuth, que Claude Code ya guarda localmente en `~/.claude/.credentials.json`. Por eso:

- **Los porcentajes coinciden exactamente con `/usage`.** No hay que adivinar ni calibrar límites.
- **Se adapta solo a tu plan.** Funciona igual en plan `max`, `pro`, etc. Muestra automáticamente los sub-límites que tu plan tenga (semana global, Sonnet, Opus); los que no apliquen simplemente no aparecen.
- **No cuesta nada ni gasta cupo.** Es un endpoint de solo lectura de estadísticas; consultarlo no consume tokens ni genera cargos (igual que mirar `/usage`).

La sección **"Volumen (ccusage)"** es opcional y solo informativa: muestra cuántos tokens moviste y su costo *equivalente en la API de pago por uso* — **no es tu factura** (estás en suscripción). Se puede desactivar.

> El endpoint no está documentado oficialmente; se descubrió inspeccionando Claude Code. Funciona hoy, pero podría cambiar en una actualización. Si eso pasa, el script lo maneja con gracia (muestra un aviso y sigue corriendo).

---

## Requisitos

- **Windows** con PowerShell 5.1+ (incluido en Windows 10/11).
- **Claude Code** instalado y con **sesión iniciada al menos una vez** (para que exista `~/.claude/.credentials.json`).
- **Node.js** — *solo* si querés la sección de volumen/costo (usa `npx ccusage`). El bloque de porcentajes reales funciona sin Node.

---

## Instalación (también en otro PC / otra cuenta)

El script lee las credenciales de **la máquina y cuenta donde se ejecuta**, así que mostrará automáticamente el uso de quien esté logueado en Claude Code en ese equipo — sin configurar nada.

### 1. Asegurate de estar logueado en Claude Code

En ese PC, abrí Claude Code al menos una vez (o corré `claude` y autenticá). Eso crea `~/.claude/.credentials.json`. Verificá:

```powershell
Test-Path "$env:USERPROFILE\.claude\.credentials.json"   # debe dar True
```

### 2. Clonar

```powershell
git clone https://github.com/pablosepulvedar/claude-watch.git
cd claude-watch
```

### 3. (Opcional) Instalar ccusage para la sección de volumen

```powershell
npm install -g ccusage
```

Si no querés esa sección, abrí `claude-watch.ps1` y poné `$ShowCcusage = $false` cerca del inicio. Así no necesita Node y carga más rápido.

### 4. Ejecutar

```powershell
powershell -ExecutionPolicy Bypass -File ".\claude-watch.ps1"
```

Para salir: **Ctrl+C**

---

## Configuración

Las opciones están al inicio de `claude-watch.ps1`:

```powershell
$CredPath    = Join-Path $env:USERPROFILE ".claude\.credentials.json"  # ruta a credenciales
$ShowCcusage = $true   # $false oculta la seccion de volumen/costo (no necesita Node)
```

### Zona horaria

Las horas de restablecimiento se muestran en **hora de Santiago (Chile)**. Para tu zona, editá:

```powershell
$tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Pacific SA Standard Time")
```

Para ver los IDs disponibles:

```powershell
[System.TimeZoneInfo]::GetSystemTimeZones() | Select-Object Id, DisplayName
```

---

## Iniciar automáticamente con Windows

### Opción A — Carpeta de Inicio (recomendada, sin admin)

1. `Win + R` → `shell:startup` → Enter.
2. Creá ahí un archivo `.bat`:

```bat
@echo off
start "Claude Watch" powershell -WindowStyle Normal -ExecutionPolicy Bypass -File "C:\Users\TU_USUARIO\claude-watch\claude-watch.ps1"
```

Ajustá la ruta. Al iniciar sesión en Windows, se abre la ventana sola.

### Opción B — Tarea programada

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument '-WindowStyle Normal -ExecutionPolicy Bypass -File "C:\Users\TU_USUARIO\claude-watch\claude-watch.ps1"'
$trigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName "ClaudeWatch" -Action $action -Trigger $trigger -RunLevel Limited
```

---

## Seguridad

El script lee tu token OAuth desde `~/.claude/.credentials.json` **solo para autenticar la consulta a Anthropic**. El token no sale de tu equipo más que hacia `api.anthropic.com` (lo mismo que hace Claude Code). **No subas ese archivo a ningún repositorio.** El token expira periódicamente; Claude Code lo refresca al usarse y el script vuelve a leerlo en el siguiente ciclo (si caduca, muestra un aviso y se recupera solo).

---

## Solución de problemas

| Síntoma | Causa / solución |
|---|---|
| `Token expirado` | Abrí Claude Code una vez para refrescar el token; el panel se recupera solo. |
| `Error leyendo /usage` | Verificá conexión y que exista `.credentials.json`. |
| No aparece la sección de volumen | Falta `ccusage`/Node, o `$ShowCcusage = $false`. Es opcional. |
| Error de TLS | El script fuerza TLS 1.2; asegurate de usar PowerShell 5.1+. |
| Horas de reset desfasadas | Cambiá la zona horaria (ver arriba). |

---

## Dependencias

| Herramienta | Rol |
|------------|-----|
| PowerShell 5.1 | Motor del script. Incluido en Windows 10/11. |
| Claude Code | Provee el token OAuth en `~/.claude/.credentials.json`. **Requerido.** |
| `ccusage` (Node) | Solo para la sección de volumen/costo. **Opcional.** |

---

Funciona en cualquier plan de Claude Code (Pro, Max, etc.) — los porcentajes y sub-límites se detectan automáticamente desde el endpoint oficial.
