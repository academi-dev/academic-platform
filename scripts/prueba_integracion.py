"""
Prueba de integración de punta a punta del ecosistema Academic.

Recorre el flujo completo contra servicios en ejecución (local o Docker):
  1. Salud de academic-api y academic-rag
  2. Registro, login, refresh y seguridad (rol forzado, 401 sin token)
  3. CRUD de materias y tareas con filtros
  4. Aislamiento entre usuarios
  5. Subida de un PDF al RAG, pregunta con citas y limpieza

Uso:
    pip install httpx
    python scripts/prueba_integracion.py
    python scripts/prueba_integracion.py --api http://localhost:8000 --rag http://localhost:8001
    python scripts/prueba_integracion.py --gateway http://localhost      # vía Nginx

Código de salida 0 si todas las verificaciones pasan, 1 en caso contrario.
"""

from __future__ import annotations

import argparse
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from io import BytesIO
from typing import Callable, List, Optional, Tuple

import httpx

RESULTADOS: List[Tuple[str, bool, str]] = []


def verificar(nombre: str, condicion: bool, detalle: str = "") -> bool:
    """Registra el resultado de una verificación y lo imprime en consola."""
    RESULTADOS.append((nombre, condicion, detalle))
    marca = "OK  " if condicion else "FALLA"
    linea = f"  [{marca}] {nombre}"
    if detalle and not condicion:
        linea += f"  ->  {detalle}"
    print(linea)
    return condicion


def seccion(titulo: str) -> None:
    """Imprime un encabezado de sección."""
    print(f"\n=== {titulo} ===")


def construir_pdf(paginas: List[str]) -> bytes:
    """Genera un PDF mínimo válido (Helvetica) con una línea de texto por página."""
    objetos: List[bytes] = []
    n = len(paginas)
    ids_contenido = [4 + 2 * i for i in range(n)]
    ids_pagina = [5 + 2 * i for i in range(n)]
    kids = " ".join(f"{p} 0 R" for p in ids_pagina)
    objetos.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    objetos.append(f"<< /Type /Pages /Kids [ {kids} ] /Count {n} >>".encode())
    objetos.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for texto, c_id in zip(paginas, ids_contenido):
        seguro = texto.replace("(", "\\(").replace(")", "\\)")
        stream = f"BT\n/F1 11 Tf\n40 750 Td\n({seguro}) Tj\nET\n".encode("latin-1")
        objetos.append(f"<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"endstream")
        objetos.append(
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents {c_id} 0 R "
            f"/Resources << /Font << /F1 3 0 R >> >> >>".encode()
        )
    buf = BytesIO()
    buf.write(b"%PDF-1.4\n")
    offsets = []
    for i, obj in enumerate(objetos, start=1):
        offsets.append(buf.tell())
        buf.write(f"{i} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = buf.tell()
    buf.write(f"xref\n0 {len(objetos) + 1}\n0000000000 65535 f \n".encode())
    for off in offsets:
        buf.write(f"{off:010d} 00000 n \n".encode())
    buf.write(f"trailer\n<< /Size {len(objetos) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return buf.getvalue()


def esperar_servicio(cliente: httpx.Client, url: str, intentos: int = 30) -> Optional[httpx.Response]:
    """Reintenta una petición GET hasta que el servicio responda 200."""
    for _ in range(intentos):
        try:
            r = cliente.get(url)
            if r.status_code == 200:
                return r
        except httpx.HTTPError:
            pass
        time.sleep(1)
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Prueba de integración Academic")
    parser.add_argument("--api", default="http://localhost:8000", help="URL base de academic-api")
    parser.add_argument("--rag", default="http://localhost:8001", help="URL base de academic-rag")
    parser.add_argument("--gateway", default=None, help="URL del gateway Nginx (sustituye --api/--rag)")
    parser.add_argument("--sin-rag", action="store_true", help="Omitir las pruebas del servicio RAG")
    args = parser.parse_args()

    api = args.gateway.rstrip("/") if args.gateway else args.api.rstrip("/")
    rag = f"{args.gateway.rstrip('/')}/rag" if args.gateway else args.rag.rstrip("/")
    print(f"academic-api: {api}\nacademic-rag: {rag}")

    c = httpx.Client(timeout=120)
    sufijo = uuid.uuid4().hex[:8]

    # ------------------------------------------------------------------ 1
    seccion("1. Salud de los servicios")
    r = esperar_servicio(c, f"{api}/health")
    if not verificar("academic-api responde /health", r is not None):
        return resumen()
    if not args.sin_rag:
        r = esperar_servicio(c, f"{rag}/api/v1/health", intentos=60)
        verificar("academic-rag responde /api/v1/health", r is not None)

    # ------------------------------------------------------------------ 2
    seccion("2. Autenticación y seguridad")
    email = f"estudiante_{sufijo}@universidad.edu"
    password = "ClaveSegura123"
    r = c.post(f"{api}/api/v1/auth/registro",
               json={"email": email, "password": password, "nombre": "Estudiante Prueba", "rol": "admin"})
    verificar("Registro devuelve 201", r.status_code == 201, r.text[:200])
    verificar("Registro ignora 'rol: admin' (queda estudiante)",
              r.status_code == 201 and str(r.json().get("rol", "")).lower() != "admin", r.text[:200])

    r = c.post(f"{api}/api/v1/auth/registro", json={"email": email, "password": password, "nombre": "Duplicado"})
    verificar("Registro duplicado devuelve 409", r.status_code == 409, f"{r.status_code} {r.text[:150]}")

    r = c.post(f"{api}/api/v1/auth/login", json={"email": email, "password": "incorrecta"})
    verificar("Login con clave incorrecta devuelve 401", r.status_code == 401, str(r.status_code))
    verificar("Errores usan formato {error:{codigo,mensaje}}",
              isinstance(r.json().get("error"), dict) and "codigo" in r.json()["error"], r.text[:200])

    r = c.post(f"{api}/api/v1/auth/login", json={"email": email, "password": password})
    verificar("Login correcto devuelve 200", r.status_code == 200, r.text[:200])
    tokens = r.json()
    verificar("Login entrega access y refresh token", "access_token" in tokens and "refresh_token" in tokens)
    h = {"Authorization": f"Bearer {tokens.get('access_token')}"}

    r = c.post(f"{api}/api/v1/auth/refresh", json={"refresh_token": tokens.get("refresh_token")})
    verificar("Refresh token genera nuevo access token", r.status_code == 200 and "access_token" in r.json(), r.text[:200])

    r = c.get(f"{api}/api/v1/materias")
    verificar("Sin token /materias devuelve 401", r.status_code == 401, str(r.status_code))

    # ------------------------------------------------------------------ 3
    seccion("3. Materias")
    r = c.post(f"{api}/api/v1/materias", headers=h,
               json={"nombre": "Estructuras de Datos", "codigo": f"ED-{sufijo}", "semestre": "2026-2",
                     "descripcion": "Listas, árboles y grafos"})
    verificar("Crear materia devuelve 201", r.status_code == 201, r.text[:200])
    materia_id = r.json().get("id") if r.status_code == 201 else None

    r = c.get(f"{api}/api/v1/materias", headers=h, params={"limite": 10, "desplazamiento": 0})
    verificar("Listar materias incluye la creada",
              r.status_code == 200 and any(m["id"] == materia_id for m in r.json().get("items", [])), r.text[:200])

    r = c.put(f"{api}/api/v1/materias/{materia_id}", headers=h, json={"semestre": "2027-1"})
    verificar("Actualizar materia (PUT) funciona", r.status_code == 200 and r.json().get("semestre") == "2027-1", r.text[:200])

    # ------------------------------------------------------------------ 4
    seccion("4. Tareas")
    entrega = (datetime.now(timezone.utc) + timedelta(days=2)).replace(microsecond=0).isoformat()
    r = c.post(f"{api}/api/v1/tareas", headers=h,
               json={"titulo": "Implementar árbol AVL", "descripcion": "Con rotaciones", "fecha_entrega": entrega,
                     "prioridad": "alta", "materia_id": materia_id})
    verificar("Crear tarea devuelve 201", r.status_code == 201, r.text[:200])
    tarea_id = r.json().get("id") if r.status_code == 201 else None
    verificar("Tarea nueva queda 'pendiente'", r.status_code == 201 and r.json().get("estado") == "pendiente", r.text[:200])

    r = c.post(f"{api}/api/v1/tareas", headers=h,
               json={"titulo": "X", "materia_id": materia_id})
    verificar("Tarea con título inválido devuelve 422", r.status_code == 422, str(r.status_code))

    r = c.get(f"{api}/api/v1/tareas", headers=h, params={"materia_id": materia_id, "estado": "pendiente"})
    verificar("Filtrar tareas por materia y estado",
              r.status_code == 200 and r.json().get("total") == 1, r.text[:200])

    r = c.put(f"{api}/api/v1/tareas/{tarea_id}", headers=h, json={"estado": "completada"})
    verificar("Marcar tarea como completada", r.status_code == 200 and r.json().get("estado") == "completada", r.text[:200])

    # ------------------------------------------------------------------ 5
    seccion("5. Aislamiento entre usuarios")
    email2 = f"otro_{sufijo}@universidad.edu"
    c.post(f"{api}/api/v1/auth/registro", json={"email": email2, "password": password, "nombre": "Otro Usuario"})
    t2 = c.post(f"{api}/api/v1/auth/login", json={"email": email2, "password": password}).json()
    h2 = {"Authorization": f"Bearer {t2.get('access_token')}"}
    r = c.get(f"{api}/api/v1/materias/{materia_id}", headers=h2)
    verificar("Otro usuario NO puede ver la materia ajena", r.status_code in (403, 404), str(r.status_code))
    r = c.delete(f"{api}/api/v1/tareas/{tarea_id}", headers=h2)
    verificar("Otro usuario NO puede borrar la tarea ajena", r.status_code in (403, 404), str(r.status_code))

    # ------------------------------------------------------------------ 6
    if not args.sin_rag:
        seccion("6. Servicio RAG (PDF + preguntas)")
        pdf = construir_pdf([
            "Programacion Orientada a Objetos: los pilares son encapsulamiento, abstraccion, herencia y polimorfismo.",
            "Complejidad algoritmica: la busqueda binaria tiene complejidad O(log n) sobre listas ordenadas.",
        ])
        r = c.post(f"{rag}/api/v1/documentos", files={"file": (f"apuntes_{sufijo}.pdf", pdf, "application/pdf")})
        verificar("Subir PDF devuelve 201", r.status_code == 201, r.text[:300])
        doc_id = r.json().get("id") if r.status_code == 201 else None
        verificar("PDF procesado con 2 páginas", r.status_code == 201 and r.json().get("total_paginas") == 2, r.text[:200])

        r = c.post(f"{rag}/api/v1/documentos", files={"file": ("notas.txt", b"hola", "text/plain")})
        verificar("Archivo que no es PDF se rechaza (4xx)", 400 <= r.status_code < 500, str(r.status_code))

        r = c.post(f"{rag}/api/v1/preguntar",
                   json={"pregunta": "¿Qué complejidad tiene la búsqueda binaria?", "documento_id": doc_id, "top_k": 2})
        ok = r.status_code == 200
        verificar("Preguntar devuelve 200", ok, r.text[:300])
        if ok:
            data = r.json()
            citas = data.get("citas", [])
            verificar("La respuesta incluye citas", len(citas) > 0, str(data)[:200])
            verificar("Cita más relevante apunta a la página 2",
                      bool(citas) and citas[0].get("pagina") == 2, str(citas[:1])[:200])
            verificar("Respuesta menciona O(log n)", "log n" in (data.get("respuesta", "") + str(citas)), data.get("respuesta", "")[:200])
            print(f"\n  Respuesta RAG: {data.get('respuesta', '')[:220]}...")

        # ------------------------------------------------------------------ 6B
        seccion("7. Integración de academic-bot y academic-mobile con API + RAG en vivo")
        try:
            import asyncio
            from pathlib import Path as _Path

            raiz_proyectos = _Path(__file__).resolve().parents[3]
            bot_dir = raiz_proyectos / "proyecto 2" / "academic-bot"
            mobile_service = (
                raiz_proyectos
                / "proyecto 3"
                / "academic-mobile"
                / "app"
                / "src"
                / "main"
                / "java"
                / "com"
                / "academic"
                / "mobile"
                / "data"
                / "api"
                / "AcademicApiService.kt"
            )
            if str(bot_dir) not in sys.path:
                sys.path.insert(0, str(bot_dir))

            from bot.services.api_client import AcademicApiClient
            from bot.services.rag_client import AcademicRagClient
            from bot.utils.formatters import (
                format_materias,
                format_rag_response,
                format_tareas,
            )
            from bot.whatsapp.processor import WhatsAppMessageProcessor

            bot_api = AcademicApiClient(base_url=f"{api}/api/v1")
            bot_rag = AcademicRagClient(base_url=f"{rag}/api/v1")
            wsp_proc = WhatsAppMessageProcessor(api_client=bot_api, rag_client=bot_rag)

            async def _flujo_bot():
                tok_resp = await bot_api.login(email=email, password=password)
                tok = tok_resp["access_token"]
                mats = await bot_api.get_materias(token=tok)
                tars = await bot_api.get_tareas(token=tok, materia_id=materia_id)
                ans = await bot_rag.ask_question(
                    query="¿Cuáles son los pilares de la Programación Orientada a Objetos?",
                    token=tok,
                )
                # Flujo completo de WhatsApp QR (conversación multi-paso + filtro personal)
                jid = "573001234567@s.whatsapp.net"
                wsp_personal = await wsp_proc.process_message(jid, "Hola bro, nos vemos en la U")
                await wsp_proc.process_message(jid, "/login")
                await wsp_proc.process_message(jid, email)
                wsp_login = await wsp_proc.process_message(jid, password)
                wsp_mats = await wsp_proc.process_message(jid, "/materias")
                wsp_rag = await wsp_proc.process_message(
                    jid, "/preguntar ¿Qué complejidad tiene la búsqueda binaria?"
                )
                wsp_rem = await wsp_proc.process_message(
                    jid, "/recordar 15m Sustentar proyecto Academic"
                )
                return mats, tars, ans, wsp_personal, wsp_login, wsp_mats, wsp_rag, wsp_rem

            (
                mats_bot,
                tars_bot,
                ans_bot,
                wsp_personal,
                wsp_login,
                wsp_mats,
                wsp_rag,
                wsp_rem,
            ) = asyncio.run(_flujo_bot())
            verificar(
                "academic-bot autentica y lista materias desde academic-api",
                len(mats_bot) == 1 and mats_bot[0]["id"] == materia_id,
            )
            verificar(
                "academic-bot lista tareas desde academic-api",
                len(tars_bot) == 1 and tars_bot[0]["id"] == tarea_id,
            )
            msg_rag = format_rag_response(ans_bot, "¿Cuáles son los pilares de la POO?")
            verificar(
                "academic-bot consulta academic-rag y formatea respuesta con citas para Telegram",
                "encapsulamiento" in msg_rag.lower() and "Pág. 1" in msg_rag,
                msg_rag[:200],
            )
            msg_mats = format_materias(mats_bot)
            msg_tars = format_tareas(tars_bot)
            verificar(
                "academic-bot formatea mensajes de /materias y /tareas",
                "Estructuras de Datos" in msg_mats and "Implementar árbol AVL" in msg_tars,
            )
            verificar(
                "WhatsApp QR ignora mensajes personales sin comando ('/...')",
                wsp_personal.get("reply") is None,
                str(wsp_personal),
            )
            verificar(
                "WhatsApp QR completa login conversacional contra academic-api",
                "exitoso" in (wsp_login.get("reply") or "").lower()
                or "bienvenido" in (wsp_login.get("reply") or "").lower(),
                str(wsp_login)[:200],
            )
            verificar(
                "WhatsApp QR responde /materias y /preguntar con citas de página del PDF",
                "Estructuras de Datos" in (wsp_mats.get("reply") or "")
                and "Pág. 2" in (wsp_rag.get("reply") or ""),
                str(wsp_rag)[:200],
            )
            verificar(
                "WhatsApp QR agenda recordatorios (/recordar 15m) con delay_seconds=900",
                bool(wsp_rem.get("reminder"))
                and wsp_rem["reminder"].get("delay_seconds") == 900,
                str(wsp_rem),
            )

            if mobile_service.exists():
                kt_code = mobile_service.read_text(encoding="utf-8")
                rutas_esperadas = [
                    "api/v1/auth/login",
                    "api/v1/auth/registro",
                    "api/v1/auth/refresh",
                    "api/v1/materias",
                    "api/v1/tareas",
                ]
                verificar(
                    "academic-mobile (Retrofit) coincide con todos los endpoints de academic-api",
                    all(ruta in kt_code for ruta in rutas_esperadas),
                )
        except Exception as exc_bot:
            verificar("Integración de academic-bot y academic-mobile", False, str(exc_bot))

        if doc_id:
            r = c.delete(f"{rag}/api/v1/documentos/{doc_id}")
            verificar("Eliminar documento devuelve 204", r.status_code == 204, str(r.status_code))

    # ------------------------------------------------------------------ 8
    seccion("8. Limpieza")
    r = c.delete(f"{api}/api/v1/tareas/{tarea_id}", headers=h)
    verificar("Eliminar tarea devuelve 204", r.status_code == 204, str(r.status_code))
    r = c.delete(f"{api}/api/v1/materias/{materia_id}", headers=h)
    verificar("Eliminar materia devuelve 204", r.status_code == 204, str(r.status_code))
    r = c.get(f"{api}/api/v1/materias/{materia_id}", headers=h)
    verificar("Materia eliminada ya no existe (404)", r.status_code == 404, str(r.status_code))

    return resumen()


def resumen() -> int:
    """Imprime el resumen final y devuelve el código de salida."""
    total = len(RESULTADOS)
    fallas = [r for r in RESULTADOS if not r[1]]
    print("\n" + "=" * 60)
    print(f"RESULTADO: {total - len(fallas)}/{total} verificaciones correctas")
    if fallas:
        print("Fallas:")
        for nombre, _, detalle in fallas:
            print(f"  - {nombre}: {detalle}")
    print("=" * 60)
    return 0 if not fallas else 1


if __name__ == "__main__":
    sys.exit(main())
