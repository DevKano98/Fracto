"""
-- FULL SQL SCHEMA FOR FRACTA --

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE claims (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    raw_text TEXT NOT NULL,
    extracted_claim TEXT,
    source_type TEXT,         -- text | image | url | voice
    platform TEXT,            -- whatsapp | twitter | instagram | unknown
    language TEXT,
    ml_category TEXT,
    ml_confidence FLOAT,
    llm_verdict TEXT,         -- TRUE | FALSE | MISLEADING | UNVERIFIED
    llm_confidence FLOAT,
    evidence TEXT,
    sources TEXT[],
    reasoning_steps TEXT[],
    corrective_response TEXT,
    risk_score FLOAT,
    risk_level TEXT,          -- LOW | MEDIUM | HIGH
    visual_flags TEXT[],
    status TEXT DEFAULT 'PENDING',  -- PENDING | APPROVED | REJECTED | OVERRIDDEN
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    claim_id UUID REFERENCES claims(id),
    action TEXT,
    operator_note TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE blog_posts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    claim_id UUID REFERENCES claims(id),
    title TEXT,
    slug TEXT UNIQUE,
    summary TEXT,
    content TEXT,
    image_url TEXT,
    cloudinary_public_id TEXT,
    tags TEXT[],
    category TEXT,
    views INTEGER DEFAULT 0,
    published BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_claims_created_at ON claims(created_at DESC);
CREATE INDEX idx_claims_risk_score ON claims(risk_score DESC);
CREATE INDEX idx_claims_status ON claims(status);
CREATE INDEX idx_blog_slug ON blog_posts(slug);
CREATE INDEX idx_blog_created_at ON blog_posts(created_at DESC);
"""

from supabase import create_client
from app.config import settings

supabase = create_client(settings.SUPABASE_URL, settings.SUPABASE_ANON_KEY)