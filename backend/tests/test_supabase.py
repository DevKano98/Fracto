import os
from supabase import create_client, Client

# ==============================
# CONFIG
# ==============================

SUPABASE_URL = "https://ylfctffhdvkambhpheff.supabase.co"
SUPABASE_KEY = "YOUR_SUPABASE_KEY"   # anon or service role


def test_supabase_connection():
    print("🔎 Testing Supabase connection...")

    try:
        supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

        # simple query
        response = supabase.table("claims").select("*").limit(1).execute()

        print("✅ Supabase connected successfully")

        if response.data:
            print("📦 Sample row from 'claims' table:")
            print(response.data[0])
        else:
            print("ℹ️ Table reachable but empty")

        return True

    except Exception as e:
        print("❌ Supabase connection failed")
        print("Error:", str(e))
        return False


if __name__ == "__main__":
    test_supabase_connection()