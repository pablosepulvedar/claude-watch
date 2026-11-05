# Junta los tokens de Claude Code por hora (UTC) y modelo, de este PC y de servidores por SSH.
# Lee las conversaciones guardadas (~/.claude*/projects/**/*.jsonl) y devuelve solo totales.
# Fuentes en tokens_fuentes.json (no se sube a git). Salida: tokens.json, que lee el reporte.
import json, os, subprocess, sys, time

AQUI = os.path.dirname(os.path.abspath(__file__))

# Se ejecuta igual en local (python 3) y en el servidor (python 2): no usar f-strings.
AGREGADOR = r'''
import io, json, os, sys
def main(raiz):
    vistos = set(); horas = {}
    for base, _, archivos in os.walk(os.path.expanduser(raiz)):
        for a in archivos:
            if not a.endswith(".jsonl"): continue
            try: f = io.open(os.path.join(base, a), encoding="utf-8", errors="replace")
            except Exception: continue
            for linea in f:
                if '"usage"' not in linea: continue
                try: d = json.loads(linea)
                except Exception: continue
                m = d.get("message") or {}
                u = m.get("usage")
                if not isinstance(u, dict) or d.get("type") != "assistant": continue
                clave = (m.get("id") or "") + "|" + (d.get("requestId") or "")
                if clave == "|" or clave in vistos: continue
                vistos.add(clave)
                h = (d.get("timestamp") or "")[:13]
                if len(h) != 13: continue
                mod = m.get("model") or "?"
                if mod == "<synthetic>": continue
                fila = horas.setdefault(h, {}).setdefault(mod, [0, 0, 0, 0, 0])
                fila[0] += int(u.get("input_tokens") or 0)
                fila[1] += int(u.get("cache_creation_input_tokens") or 0)
                fila[2] += int(u.get("cache_read_input_tokens") or 0)
                fila[3] += int(u.get("output_tokens") or 0)
                fila[4] += 1
            f.close()
    sys.stdout.write(json.dumps(horas))
main(sys.argv[1])
'''


def correr(fuente):
    if fuente.get("host"):
        env = dict(os.environ, SSH_ASKPASS=fuente["askpass"], SSH_ASKPASS_REQUIRE="force", DISPLAY="x")
        cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10", "-o", "PubkeyAuthentication=no",
               fuente["host"], "python - " + fuente["dir"]]
        p = subprocess.run(cmd, input=AGREGADOR.encode(), capture_output=True, env=env, timeout=300)
    else:
        p = subprocess.run([sys.executable, "-", os.path.expanduser(fuente["dir"])], input=AGREGADOR.encode(), capture_output=True, timeout=300)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode(errors="replace").strip().splitlines()[-1][:200] if p.stderr else "sin salida")
    return json.loads(p.stdout.decode())


def main():
    fuentes = json.load(open(os.path.join(AQUI, "tokens_fuentes.json"), encoding="utf-8"))
    salida = {"gen": int(time.time()), "fuentes": []}
    for f in fuentes:
        r = {"cuenta": f["cuenta"], "nombre": f["nombre"]}
        try:
            r["horas"] = correr(f); r["ok"] = True
        except Exception as e:
            r["ok"] = False; r["error"] = str(e)[:200]; r["horas"] = {}
        salida["fuentes"].append(r)
    tmp = os.path.join(AQUI, "tokens.json.tmp")
    json.dump(salida, open(tmp, "w", encoding="utf-8"))
    os.replace(tmp, os.path.join(AQUI, "tokens.json"))


if __name__ == "__main__":
    main()
