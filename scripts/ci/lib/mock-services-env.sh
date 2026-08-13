# Source this to redirect Anthropic/OpenAI/Stripe/Supabase API calls to the
# local mock-services fixtures (tests/fixtures/mock-services, CP-009,
# INFRA-1841). Only valid while the mocks are up — see
# scripts/ci/test-mock-services.sh for the spin-up/health-wait/teardown
# pattern this env file assumes.
#
# Usage (opt-in per test, not a flag day):
#   if [ "${CHUMP_USE_MOCK_SERVICES:-0}" = "1" ]; then
#     source "$(dirname "$0")/lib/mock-services-env.sh"
#   fi

# Anthropic — anthropic-sdk and chump's worker.sh honor ANTHROPIC_BASE_URL.
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://localhost:4011}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-sk-ant-mock-key-for-tests}"

# OpenAI — openai-python and litellm honor OPENAI_BASE_URL / OPENAI_API_BASE.
export OPENAI_BASE_URL="${OPENAI_BASE_URL:-http://localhost:4010}"
export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:4010}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-sk-mock-key-for-tests}"

# Stripe — stripe-node honors STRIPE_API_BASE (less standardized; some
# clients need patching to respect it).
export STRIPE_API_BASE="${STRIPE_API_BASE:-http://localhost:4013}"
export STRIPE_SECRET_KEY="${STRIPE_SECRET_KEY:-sk_test_mock}"

# Supabase — supabase-js honors SUPABASE_URL.
export SUPABASE_URL="${SUPABASE_URL:-http://localhost:4012}"
export SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-mock_anon_key}"
