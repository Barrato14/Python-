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
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

settings = Settings()
app = FastAPI(title="Python Odyssey API", version="0.2.0")
app.add_middleware(CORSMiddleware, allow_origins=[settings.frontend_origin, "https://python-odyssey-web.onrender.com"], allow_credentials=True, allow_methods=["GET", "POST", "OPTIONS"], allow_headers=["Authorization", "Content-Type"])

mentor_calls = defaultdict(deque)

class MentorRequest(BaseModel):
    question: str = Field(min_length=2, max_length=1200)
    completed_lessons: list[str] = Field(default_factory=list, max_length=20)

@app.get("/health", tags=["system"])
async def health():
    return {"status": "ok", "service": "python-odyssey-api"}

@app.get("/api/v1", tags=["system"])
async def api_root():
    return {"name": "Python Odyssey", "phase": 6, "status": "community-and-mentor"}

@app.post("/api/v1/mentor", tags=["learning"])
async def mentor(payload: MentorRequest, authorization: str | None = Header(default=None)):
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Sign in to speak with the Sage.")
    token = authorization.split(" ", 1)[1].strip()
    if not settings.supabase_url or not settings.supabase_publishable_key:
        raise HTTPException(status_code=503, detail="Mentor authentication is not configured yet.")
    async with httpx.AsyncClient(timeout=12) as client:
        auth = await client.get(
            settings.supabase_url.rstrip("/") + "/auth/v1/user",
            headers={"apikey": settings.supabase_publishable_key, "Authorization": f"Bearer {token}"}
        )
    if auth.status_code != 200:
        raise HTTPException(status_code=401, detail="Your session expired. Sign in again.")
    user_id = auth.json().get("id")
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
                    {"role": "user", "content": f"Completed lessons: {context}\nLearner question: {payload.question}"}
                ]
            }
        )
    if response.status_code >= 400:
        raise HTTPException(status_code=502, detail="The Sage is unavailable right now. Try the built-in study hints.")
    data = response.json()
    reply = data.get("choices", [{}])[0].get("message", {}).get("content", "")
    if not reply:
        raise HTTPException(status_code=502, detail="The Sage could not form a reply. Please try again.")
    return {"mode": "ai", "reply": reply[:2500]}
