"""Self-calibrated usage budgets for the percent-of-quota gauge.

Anthropic doesn't publish a token quota for subscription plans — the 5h/weekly
limits are compute-based and relative to your tier. So these are budgets YOU
set: tune each number until the gauge reads ~100% right when you actually start
hitting that window's limit. The percentage on the display is (window cost /
budget), where "cost" is the compute-weighted token value from pricing.py —
a much better proxy for limit pressure than raw token counts (cache reads
dominate token totals but barely count toward real load).

Starting points below are seeded from observed heavy usage; adjust to taste.
"""

# Budget per rolling window, in the same USD-equivalent units pricing.py emits.
QUOTA_5H_USD = 120.0
QUOTA_WEEK_USD = 6000.0


def pct(cost_usd, budget):
    if budget <= 0:
        return 0.0
    return round(100.0 * cost_usd / budget, 1)
