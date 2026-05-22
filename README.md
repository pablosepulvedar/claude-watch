# Claude Watch

Monitor de uso de tokens de Claude Code en tiempo real para Windows.

Muestra en una ventana de PowerShell, actualizada cada 30 segundos:

- **Barra de tiempo** del bloque activo de 5h (cuánto llevás / cuánto queda)
- **Barra de tokens output** del bloque (estimado según plan Pro)
- Hora aproximada de restablecimiento (zona horaria Santiago, Chile)
- Tokens output y costo estimado de la sesión
- Proyección de tokens al final del bloque
- **Barra semanal** de tokens output de los últimos 7 días

```
  Claude Code Usage  [14:23:07]
============================================================

  Sesion actual (5h)
  Tiempo   [###############-------------------------] 34%
  Tokens   [########################################] 91%
  2h 50m usados  /  5h 10m restantes
  Restablece: ~19:30  (aprox, ver /usage)
  Output: 260,194  /  ~286,000   Costo: $0.00
  Proyect: 285,000 tokens  /  $0.00

  Semana actual (7 dias)
  Tokens   [##########------------------------------] 24%
  Output: 91,000  /  ~382,000   Costo: $0.00

============================================================
  Actualiza en 30s  (Ctrl+C para salir)
```

---

## Requisitos

- Windows con PowerShell 5.1+ (viene incluido en Windows 10/11)
- [Node.js](https://nodejs.org/) instalado (para `npx`)
- [Claude Code](https://claude.ai/code) instalado y haber iniciado al menos una sesión

---

## Instalación

### 1. Clonar o descargar

```powershell
git clone https://github.com/pablosepulvedar/claude-watch.git
cd claude-watch
```

O bien descargá solo el archivo `claude-watch.ps1` directamente.

### 2. Instalar ccusage (una sola vez)

```powershell
npm install -g ccusage
```

Verificá que funcione:

```powershell
npx ccusage blocks --active --json
```

Deberías ver un JSON. Si no hay sesión activa, `blocks` estará vacío — eso es normal.

### 3. Ejecutar

```powershell
powershell -ExecutionPolicy Bypass -File "C:\ruta\a\claude-watch.ps1"
```

O si ya estás en PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\claude-watch.ps1
```

Para salir: **Ctrl+C**

---

## Iniciar automáticamente con Windows

### Opción A — Acceso directo en Inicio (recomendada, sin admin)

1. Presioná `Win + R`, escribí `shell:startup`, Enter
2. Dentro de esa carpeta, creá un nuevo archivo de texto con extensión `.bat`:

```bat
@echo off
start "Claude Watch" powershell -WindowStyle Normal -ExecutionPolicy Bypass -File "C:\Users\TU_USUARIO\claude-watch.ps1"
```

Cambiá `TU_USUARIO` y la ruta al archivo `.ps1`. Al iniciar Windows, se abre la ventana automáticamente.

### Opción B — Tarea programada (más control)

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument '-WindowStyle Normal -ExecutionPolicy Bypass -File "C:\ruta\claude-watch.ps1"'
$trigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName "ClaudeWatch" -Action $action -Trigger $trigger -RunLevel Limited
```

---

## Ajustar los límites

Si tu plan tiene límites distintos, editá las dos primeras líneas del script:

```powershell
$SessionOutputLimit = 286000   # tokens output por bloque de 5h
$WeeklyOutputLimit  = 382000   # tokens output por semana
```

Para saber los tuyos: en Claude Code escribí `/usage` y fijate qué porcentaje aparece cuando tenés tokens conocidos. Dividí tokens / porcentaje × 100.

---

## Cómo iniciar en cualquier sesión de Claude

Cada vez que arrancás a trabajar con Claude Code, simplemente abrí una ventana de PowerShell aparte y ejecutá:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\TU_USUARIO\claude-watch.ps1"
```

Podés tenerlo minimizado o en un monitor secundario. Se actualiza solo cada 30 segundos.

**Nota:** la hora de restablecimiento es aproximada (ccusage usa bloques fijos de hora en hora). Para ver la hora exacta usá `/usage` dentro de Claude Code.

---

## Zona horaria

El script muestra la hora de restablecimiento en **hora de Santiago (Chile)**. Para cambiarla a tu zona editá esta línea:

```powershell
$tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Pacific SA Standard Time")
```

Reemplazá el ID por el de tu zona. Para ver todos los disponibles:

```powershell
[System.TimeZoneInfo]::GetSystemTimeZones() | Select-Object Id, DisplayName
```

---

## Dependencias

| Herramienta | Qué hace |
|------------|---------|
| `ccusage` | Lee los logs locales de Claude Code (`~/.claude/projects/`) y expone datos de bloques y semanas |
| PowerShell 5.1 | Viene con Windows 10/11, no necesita instalación extra |

---

Hecho para monitorear el plan **Pro** de Claude Code. Adaptable a cualquier plan ajustando los límites.
