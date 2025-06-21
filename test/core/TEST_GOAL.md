Below is a **ready-to-paste prompt** for your in-house “CodingAI” (or any Foundry/Hardhat runner) that enumerates deterministic, high-value test cases for **CoreMath** (pure maths) and **Core** (state-transition façade).
Everything focuses strictly on the monetary formulas and invariants documented in PolynanceLend V2, so the AI can ignore UI, events, access control, etc.

---

## ☑️ Prompt for CodingAI

> **Context**
> You are writing Solidity/Foundry tests for the PolynanceLend V2 code-base.
> Only two contracts/libraries need to be covered here:
>
> 1. `CoreMath.sol` – pure library
> 2. `Core.sol` – abstract contract that mutates `PoolData`, `MarketData`, `UserPosition` using CoreMath results.
>
> **Test goals**
>
> 1. Validate *mathematical correctness* of CoreMath functions across edge-cases and fuzz ranges.
> 2. Validate *financial invariants* that Core must maintain after each state transition.
>
> **Reference behaviour** is defined in the repo’s README formulas:
>
> * User debt decomposition (principal vs spread)
> * Global invariants on LP supply and borrowing totals
>
> Implement the following numbered tests. Use **Wad/Ray math helpers** already present in the project.
> Fuzz with at least 50 randomised samples per test unless a value is fixed for clarity.

---

### 1️⃣ CoreMath — LP-token minting

| Id              | Purpose                                                                          | Inputs (fuzz)              | Expected                            |
| --------------- | -------------------------------------------------------------------------------- | -------------------------- | ----------------------------------- |
| **CM\_LP\_001** | `calculateLPTokensToMint` must return *exactly* the supplied amount (1 : 1 peg). | `deposit ∈ [1, 10^9 USDC]` | result == `deposit` (Wad precision) |

---

### 2️⃣ CoreMath — Utilisation → Spread curve

*Assume governance params:* `base = 1e16 (1%)`, `U* = 8e17 (80%)`, `slope1 = 5e16`, `slope2 = 2e17`.

| Id               | Purpose                   | Inputs           | Expected                                                             |
| ---------------- | ------------------------- | ---------------- | -------------------------------------------------------------------- |
| **CM\_SR\_010**  | Linear section below knee | `util = 0.40e18` | `rate = base + slope1 × util`                                        |
| **CM\_SR\_020**  | Exactly at knee           | `util = U*`      | `rate = base + slope1 × U*`                                          |
| **CM\_SR\_030**  | Steep section above knee  | `util = 0.95e18` | `rate = base + slope1×U* + slope2×(util-U*)`                         |
| **CM\_SR\_FUZZ** | Fuzz 0–1                  | random `util`    | match piece-wise formula; enforce monotonicity (`d rate/d util ≥ 0`) |

---

### 3️⃣ CoreMath — Debt allocation

Set up two markets **A** and **B** with arbitrary totals; verify the multi-level ratios in one pass.

| Id                 | Scenario                                                                                                                                                                   | Checks                                                                                                                                                                                |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **CM\_DEBT\_100**  | `protocolDebt = 1 000e18`<br>`totalBorrowedAllMarkets = 600e18 (A) + 400e18 (B)`<br>User u in market A: `borrowAmount_u = 60e18`, `scaledDebt_u = 80e18`, `index = 1.2e27` | *Step 1*: `marketDebt_A = 1000 × 600/1000 = 600`<br>*Step 2*: `principal_u = 600 × 60/600 = 60`<br>*Step 3*: `spread_u = (80 × 1.2) − 60 = 36` (Ray math)<br>*Step 4*: `total_u = 96` |
| **CM\_DEBT\_FUZZ** | Fuzz ≥ 5 random triplets `(protocolDebt, marketTotals[], userBorrow)`                                                                                                      | recompute with high-precision Python reference and assert ≤ 1 wei diff                                                                                                                |

---

### 4️⃣ Core — Process Supply invariants

| Id               | Steps                                                                 | Expected                                                     |
| ---------------- | --------------------------------------------------------------------- | ------------------------------------------------------------ |
| **CR\_SUP\_200** | Start with empty pool.<br>Call `_processSupply(pool, userBal, 500e6)` | `pool.totalSupplied == 500e6` and `lpBalance[user] == 500e6` |

---

### 5️⃣ Core — Borrow/Repay round-trip

| Id              | Flow                                                                                                                                                    | Assertions                                                                                                                                                                                     |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **CR\_BR\_300** | ① User supplies 1 000 USDC (done).<br>② Adds collateral worth 800 USDC.<br>③ `_processBorrow` for 400 USDC.<br>④ Immediately `_processRepay` full debt. | After step ③: `sum(market.totalBorrowed) == pool.totalBorrowedAllMarkets` (README invariant)<br>After step ④: borrower debt == 0, collateral released, pool and market borrowed sums restored. |

---

### 6️⃣ Core — Invariant fuzz suite

For **N = 30** fuzz iterations:

1. Randomly choose `numMarkets ∈ 1–5`; seed each with random collateral caps & spreads.
2. Random users perform sequences of Supply → Borrow → (optional) partial Repay.
3. After each state-changing call assert simultaneously:

   * `Σ market.totalBorrowed == pool.totalBorrowedAllMarkets`
   * `pool.totalBorrowedAllMarkets ≤ pool.totalSupplied`
   * `Σ lpBalances == pool.totalSupplied` (allow burn after withdrawals)
   * Each user’s computed debt by Core matches CoreMath reference within 1 wei.

---

### 7️⃣ CoreMath — Edge guards

| Id                 | Purpose                                         | Expect revert      |
| ------------------ | ----------------------------------------------- | ------------------ |
| **CM\_GUARD\_400** | `calculateSpreadRate` with `totalSupplied == 0` | `division by zero` |
| **CM\_GUARD\_410** | Debt formula with `market.totalBorrowed == 0`   | revert             |

---

### 8️⃣ Regression for rounding-loss

Reproduce historical rounding bug:

1. `indexPrev = 1e27`, `indexNow = 1e27 + 1` (≈ 1 wei growth)
2. `principal = any`
3. Ensure `accrue()` never returns 0 when `principal > 0`.

---
