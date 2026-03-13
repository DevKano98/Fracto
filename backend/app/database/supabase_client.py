"""
-- ============================================
-- STEP 1: DROP EVERYTHING CLEAN
-- ============================================

DROP TABLE IF EXISTS operator_log    CASCADE;
DROP TABLE IF EXISTS user_reports    CASCADE;
DROP TABLE IF EXISTS audit_log       CASCADE;
DROP TABLE IF EXISTS blog_posts      CASCADE;
DROP TABLE IF EXISTS refresh_tokens  CASCADE;
DROP TABLE IF EXISTS claims          CASCADE;
DROP TABLE IF EXISTS users           CASCADE;

-- ============================================
-- STEP 2: EXTENSIONS
-- ============================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================
-- STEP 3: USERS (base table — everything refs this)
-- ============================================

CREATE TABLE users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT NOT NULL,
  email         TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  city          TEXT,
  role          TEXT DEFAULT 'user' CHECK (role IN ('user', 'operator', 'super_admin')),
  is_active     BOOLEAN DEFAULT TRUE,
  last_login    TIMESTAMPTZ,
  created_by    UUID,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- Self-referencing FK added after table exists
ALTER TABLE users
  ADD CONSTRAINT fk_users_created_by
  FOREIGN KEY (created_by) REFERENCES users(id);

-- ============================================
-- STEP 4: REFRESH TOKENS
-- ============================================

CREATE TABLE refresh_tokens (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash  TEXT NOT NULL UNIQUE,
  expires_at  TIMESTAMPTZ NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- STEP 5: CLAIMS (core table)
-- ============================================

CREATE TABLE claims (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_text             TEXT NOT NULL,
  extracted_claim      TEXT,
  source_type          TEXT,
  platform             TEXT,
  language             TEXT,
  ml_category          TEXT,
  ml_confidence        FLOAT,
  llm_verdict          TEXT,
  llm_confidence       FLOAT,
  evidence             TEXT,
  sources              TEXT[],
  reasoning_steps      TEXT[],
  corrective_response  TEXT,
  risk_score           FLOAT,
  risk_level           TEXT,
  visual_flags         TEXT[],
  status               TEXT DEFAULT 'PENDING'
                         CHECK (status IN ('PENDING','APPROVED','REJECTED','OVERRIDDEN')),
  submitted_by         UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at           TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- STEP 6: AUDIT LOG
-- ============================================

CREATE TABLE audit_log (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id      UUID REFERENCES claims(id) ON DELETE CASCADE,
  action        TEXT NOT NULL,
  operator_note TEXT,
  reviewed_by   UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- STEP 7: OPERATOR LOG
-- ============================================

CREATE TABLE operator_log (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id  UUID REFERENCES users(id) ON DELETE SET NULL,
  action       TEXT NOT NULL,
  target_type  TEXT,
  target_id    UUID,
  detail       TEXT,
  ip_address   TEXT,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- STEP 8: USER REPORTS
-- ============================================

CREATE TABLE user_reports (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id     UUID REFERENCES claims(id) ON DELETE CASCADE,
  reported_by  UUID REFERENCES users(id) ON DELETE SET NULL,
  report_type  TEXT,
  user_note    TEXT,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- STEP 9: BLOG POSTS
-- ============================================

CREATE TABLE blog_posts (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id             UUID REFERENCES claims(id) ON DELETE SET NULL,
  title                TEXT NOT NULL,
  slug                 TEXT UNIQUE NOT NULL,
  summary              TEXT,
  content              TEXT,
  cover_image          TEXT,
  cloudinary_public_id TEXT,
  verdict              TEXT,
  category             TEXT,
  risk_score           FLOAT,
  sources              TEXT[],
  tags                 TEXT[],
  views                INT DEFAULT 0,
  published            BOOLEAN DEFAULT TRUE,
  auto_generated       BOOLEAN DEFAULT TRUE,
  created_at           TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- STEP 10: INDEXES
-- ============================================

CREATE INDEX idx_users_email            ON users(email);
CREATE INDEX idx_users_role             ON users(role);
CREATE INDEX idx_refresh_tokens_user    ON refresh_tokens(user_id);
CREATE INDEX idx_refresh_tokens_expiry  ON refresh_tokens(expires_at);
CREATE INDEX idx_claims_created         ON claims(created_at DESC);
CREATE INDEX idx_claims_risk            ON claims(risk_score DESC);
CREATE INDEX idx_claims_status          ON claims(status);
CREATE INDEX idx_claims_platform        ON claims(platform);
CREATE INDEX idx_claims_category        ON claims(ml_category);
CREATE INDEX idx_audit_log_claim        ON audit_log(claim_id);
CREATE INDEX idx_operator_log_operator  ON operator_log(operator_id);
CREATE INDEX idx_operator_log_created   ON operator_log(created_at DESC);
CREATE INDEX idx_blog_slug              ON blog_posts(slug);
CREATE INDEX idx_blog_created           ON blog_posts(created_at DESC);
CREATE INDEX idx_blog_published         ON blog_posts(published);

-- ============================================
-- STEP 11: REALTIME
-- ============================================

ALTER PUBLICATION supabase_realtime ADD TABLE claims;
ALTER PUBLICATION supabase_realtime ADD TABLE blog_posts;

-- ============================================
-- STEP 12: VERIFY — run this to confirm
-- ============================================

SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public'
ORDER BY table_name;
"""

from supabase import create_client
from app.config import settings

supabase = create_client(settings.SUPABASE_URL, settings.SUPABASE_ANON_KEY)