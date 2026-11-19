from collections import defaultdict, deque
from time import monotonic
import httpx
from fastapi import FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    frontend_origin: str = "http://localhost:5173"
    supabase_url: str = ""
    supabase_publishable_key: str = ""
    openai_api_key: str = ""
    openai_model: str = "gpt-4.1-mini"
    brevo_api_key: str = ""
    brevo_sender_email: str = "barratobien@gmail.com"
    brevo_sender_name: str = "Python Odyssey"
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

settings = Settings()
app = FastAPI(title="Python Odyssey API", version="0.3.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[settings.frontend_origin, "https://python-odyssey-web.onrender.com"],
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)

mentor_calls = defaultdict(deque)
email_test_calls = defaultdict(deque)

class MentorRequest(BaseModel):
    question: str = Field(min_length=2, max_length=1200)
    completed_lessons: list[str] = Field(default_factory=list, max_length=20)

async def authenticated_user(authorization: str | None) -> dict:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Sign in to use this feature.")
    token = authorization.split(" ", 1)[1].strip()
    if not settings.supabase_url or not settings.supabase_publishable_key:
        raise HTTPException(status_code=503, detail="Authentication is not configured.")
    try:
        async with httpx.AsyncClient(timeout=12) as client:
            auth = await client.get(
                settings.supabase_url.rstrip("/") + "/auth/v1/user",
                headers={"apikey": settings.supabase_publishable_key, "Authorization": f"Bearer {token}"},
            )
    except httpx.HTTPError:
        raise HTTPException(status_code=503, detail="Could not verify your session right now.")
    if auth.status_code != 200:
        raise HTTPException(status_code=401, detail="Your session expired. Sign in again.")
    return auth.json()

async def brevo_request(method: str, path: str, payload: dict | None = None):
    if not settings.brevo_api_key:
        raise HTTPException(status_code=503, detail="Brevo email is not configured on the server.")
    headers = {"api-key": settings.brevo_api_key, "accept": "application/json", "content-type": "application/json"}
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.request(method, "https://api.brevo.com/v3/" + path.lstrip("/"), headers=headers, json=payload)
    except httpx.TimeoutException:
        raise HTTPException(status_code=504, detail="Brevo did not respond in time.")
    except httpx.HTTPError:
        raise HTTPException(status_code=502, detail="Could not reach the Brevo email service.")
    if response.status_code >= 400:
        # Do not return provider response bodies: they may contain account details.
        if response.status_code in (401, 403):
            raise HTTPException(status_code=502, detail="Brevo rejected the server API key. Check BREVO_API_KEY in Render.")
        raise HTTPException(status_code=502, detail=f"Brevo email request failed (HTTP {response.status_code}).")
    return response.json() if response.content else {}

@app.get("/health", tags=["system"])
async def health():
    return {
        "status": "ok",
        "service": "python-odyssey-api",
        "email_configured": bool(settings.brevo_api_key),
    }

@app.get("/api/v1", tags=["system"])
async def api_root():
    return {"name": "Python Odyssey", "phase": 6, "status": "community-and-mentor"}

@app.post("/api/v1/mentor", tags=["learning"])
async def mentor(payload: MentorRequest, authorization: str | None = Header(default=None)):
    user = await authenticated_user(authorization)
    user_id = user.get("id", "")
    now = monotonic()
    bucket = mentor_calls[user_id]
    while bucket and now - bucket[0] > 60:
        bucket.popleft()
    if len(bucket) >= 6:
        raise HTTPException(status_code=429, detail="The Sage needs a short rest. Try again in a minute.")
    bucket.append(now)
    if not settings.openai_api_key:
        return {"mode": "fallback", "reply": "The Sage's crystal is offline, but your quest continues. Break the problem into one small step, predict the result, then test it in the Code Lab. Ask about a specific Python topic and I can guide you with the built-in study hints."}
    system = (
        "You are the Sage, a patient, encouraging Python tutor inside a pixel-art RPG learning game. "
        "Teach beginners. Give hints before full solutions; explain errors kindly; use short runnable Python examples. "
        "Never claim code was executed. Do not ask for passwords, secrets, or personal data. "
        "If asked for harmful, credential-stealing, or destructive code, refuse and redirect to safe learning. "
        "Keep answers under 180 words and end with one small practice step."
    )
    context = ", ".join(payload.completed_lessons[:20]) or "No completed lessons recorded."
    async with httpx.AsyncClient(timeout=25) as client:
        response = await client.post(
            "https://api.openai.com/v1/chat/completions",
            headers={"Authorization": f"Bearer {settings.openai_api_key}", "Content-Type": "application/json"},
            json={
                "model": settings.openai_model,
                "temperature": 0.4,
                "max_tokens": 260,
                "messages": [
                    {"role": "system", "content": system},
                    {"role": "user", "content": f"Completed lessons: {context}\nLearner question: {payload.question}"},
                ],
            },
        )
    if response.status_code >= 400:
        raise HTTPException(status_code=502, detail="The Sage is unavailable right now. Try the built-in study hints.")
    data = response.json()
    reply = data.get("choices", [{}])[0].get("message", {}).get("content", "")
    if not reply:
        raise HTTPException(status_code=502, detail="The Sage could not form a reply. Please try again.")
    return {"mode": "ai", "reply": reply[:2500]}

@app.get("/api/v1/email/status", tags=["email"])
async def email_status(authorization: str | None = Header(default=None)):
    await authenticated_user(authorization)
    account = await brevo_request("GET", "account")
    return {
        "configured": True,
        "authenticated": bool(account.get("email")),
        "sender": settings.brevo_sender_email,
        "transactional_email": bool(account.get("relay", {}).get("enabled")),
    }

@app.post("/api/v1/email/test", tags=["email"])
async def send_test_email(authorization: str | None = Header(default=None)):
    user = await authenticated_user(authorization)
    recipient = user.get("email")
    if not recipient:
        raise HTTPException(status_code=400, detail="Your account does not have an email address.")
    user_id = user.get("id", "")
    now = monotonic()
    bucket = email_test_calls[user_id]
    while bucket and now - bucket[0] > 600:
        bucket.popleft()
    if bucket:
        raise HTTPException(status_code=429, detail="A test email was already sent recently. Try again in 10 minutes.")
    bucket.append(now)
    result = await brevo_request("POST", "smtp/email", {
        "sender": {"name": settings.brevo_sender_name, "email": settings.brevo_sender_email},
        "to": [{"email": recipient}],
        "subject": "Your Python Odyssey email connection is working!",
        "textContent": "The Sage has a message for you: Brevo is now connected to Python Odyssey. Your transactional email setup is working.",
        "htmlContent": "<!doctype html><html><body style='font-family:Arial,sans-serif;background:#10091c;color:#eee;padding:32px'><div style='max-width:560px;margin:auto;background:#211532;padding:28px;border-radius:12px'><p style='color:#c77dff;font-weight:bold;letter-spacing:2px'>PYTHON ODYSSEY</p><h1>Your email link is alive!</h1><p>Adventurer, Brevo is now connected to your Python Odyssey backend.</p><p>Your transactional email delivery test succeeded. The Sage awaits your next quest.</p></div></body></html>",
        "tags": ["python-odyssey", "connection-test"],
    })
    return {"sent": True, "message_id": result.get("messageId"), "recipient": recipient}
