# PolynanceLend V2 Smart Contract Security Audit Report

**Date:** 2026-02-16
**Auditor:** Claude (Automated Audit)
**Scope:** All Solidity source files under `src/`
**Commit:** HEAD on `main` branch

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Findings Overview](#2-findings-overview)
3. [Critical Findings](#3-critical-findings)
4. [High Findings](#4-high-findings)
5. [Medium Findings](#5-medium-findings)
6. [Low / Informational Findings](#6-low--informational-findings)
7. [Architecture Review](#7-architecture-review)
8. [Recommendations](#8-recommendations)

---

## 1. Executive Summary

PolynanceLend V2 is a prediction-market lending protocol built on Aave V3. LPs deposit stablecoins, which are supplied to Aave. Borrowers post prediction-market position tokens as collateral and borrow stablecoins. The protocol earns a "spread" on top of Aave's variable borrow rate.

The codebase follows a **Functional-Core / Imperative-Shell** architecture: `CoreMath` (pure math) → `Core` (stateless state-transitions on memory structs) → Logic libraries (storage I/O, token transfers) → `Pool` (entry-point with access control and reentrancy guards). This design is sound in principle, but the implementation contains **4 Critical**, **4 High**, **7 Medium**, and **4 Low** severity findings that must be addressed before any mainnet deployment.

### Severity Summary

| Severity | Count |
|----------|-------|
| Critical | 4     |
| High     | 4     |
| Medium   | 7     |
| Low      | 4     |

---

## 2. Findings Overview

| ID | Severity | Title | Location |
|----|----------|-------|----------|
| C-01 | Critical | `_ensureMarketInitialized` is completely disabled | `Pool.sol:264-269` |
| C-02 | Critical | `claimProtocolRevenue` can be called repeatedly (double-spend) | `MarketResolveLogic.sol:249` |
| C-03 | Critical | Resolution ID mismatch — LP claims and protocol revenue claims always revert | `MarketResolveLogic.sol:185-186,245-246` vs `resolve():100` |
| C-04 | Critical | `processRepay` overcharges users on partial repayment | `Core.sol:198-204` |
| H-01 | High | No available-liquidity check in `processBorrow` — can over-lend | `Core.sol:107-160` |
| H-02 | High | Liquidation bonus is never applied | `Core.sol:245-304`, `RiskParams.liquidationBonus` |
| H-03 | High | 1:1 LP token minting causes yield dilution for earlier depositors | `CoreMath.sol:246-251`, `Pool.sol:90` |
| H-04 | High | Market maturity not enforced on borrow | `BorrowLogic.sol:48-129` |
| M-01 | Medium | `StorageShell.getResolutionData` reverts on empty data (no default) | `StorageShell.sol:109-113` |
| M-02 | Medium | `getDebtBalance` ignores `rateMode` parameter | `AaveModule.sol:195-197` |
| M-03 | Medium | Hardcoded Aave V3 addresses — not portable to other chains | `AaveModule.sol:33-34` |
| M-04 | Medium | Global `RiskParams` shared across all markets | `DataStruct.sol:57-73` |
| M-05 | Medium | Scaled-debt underflow can block full repayment | `Core.sol:213` |
| M-06 | Medium | No LP withdrawal mechanism before market resolution | `Pool.sol` |
| M-07 | Medium | Inconsistent Aave integration paths (AaveModule vs AaveLibrary) | `MarketResolveLogic.sol:208` vs `BorrowLogic.sol:110` |
| L-01 | Low | Misleading event emitted on market initialization | `Pool.sol:255` |
| L-02 | Low | Typo in parameter name `curremtTimestamp` | `CoreMath.sol:97` |
| L-03 | Low | Zero-borrow-amount execution wastes gas | `Core.sol:136` |
| L-04 | Low | Single-oracle price feed with no sanity checks | `BorrowLogic.sol:72` |

---

## 3. Critical Findings

### C-01: `_ensureMarketInitialized` Is Completely Disabled

**Location:** `src/Pool.sol:264-269`

```solidity
function _ensureMarketInitialized(address predictionAsset) internal view {
    RiskParams memory params = StorageShell.getRiskParams();
    // bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
    // if (!isMarketActive[marketId]) revert PolynanceEE.MarketNotActive();
}
```

**Description:**
The entire body of `_ensureMarketInitialized` is commented out. This function is the only guard called before `borrow()`. With it disabled, any arbitrary address can be passed as `predictionAsset` to `borrow()`, even if no market was ever initialized for that asset. This leads to:

- Borrowing against non-existent markets.
- Writing data to storage slots for uninitialized markets (variableBorrowIndex = 0 → division by zero in `calculateScaledDebt` when `rayDiv` divides by zero index).
- Potential storage-collision attacks if a crafted `predictionAsset` address produces a `marketId` that overlaps with a legitimate market.

**Impact:** Protocol is fully exploitable. Any user can create arbitrary debt positions.

**Recommendation:** Uncomment the check and restore the guard:

```solidity
function _ensureMarketInitialized(address predictionAsset) internal view {
    RiskParams memory params = StorageShell.getRiskParams();
    bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
    if (!isMarketActive[marketId]) revert PolynanceEE.MarketNotActive();
}
```

---

### C-02: `claimProtocolRevenue` Can Be Called Repeatedly (Double-Spend)

**Location:** `src/libraries/logic/MarketResolveLogic.sol:249`

```solidity
// if (resolution.protocolClaimed) revert PolynanceEE.AlreadyClaimed();
```

**Description:**
The check that prevents repeated claims of protocol revenue is commented out. The curator can call `claimProtocolRevenue()` multiple times, each time receiving `resolution.protocolPool` tokens. While the function does set `resolution.protocolClaimed = true` and writes to storage, the check on read is disabled, so the boolean flag is never enforced.

**Impact:** The curator (or a compromised curator key) can drain the Pool contract of all supplyAsset balance by calling this function repeatedly.

**Recommendation:** Uncomment the guard. Define the `AlreadyClaimed` error in `PolynanceEE` and enable the check:

```solidity
if (resolution.protocolClaimed) revert PolynanceEE.PositionAlreadyRedeemed();
```

---

### C-03: Resolution ID Mismatch — LP Claims and Protocol Revenue Always Revert

**Location:**
- `MarketResolveLogic.resolve()` stores at `marketId` — line 100
- `MarketResolveLogic.claimLPPosition()` reads from `ZERO_ID` — line 185-186
- `MarketResolveLogic.claimProtocolRevenue()` reads from `ZERO_ID` — line 245-246

```solidity
// In resolve():
StorageShell.next(DataType.RESOLUTION_DATA, abi.encode(newResolution), marketId);

// In claimLPPosition():
bytes32 resolutionId = ZERO_ID; // Pool-wide resolution
ResolutionData memory resolution = StorageShell.getResolutionData(resolutionId);

// In claimProtocolRevenue():
bytes32 resolutionId = ZERO_ID;
ResolutionData memory resolution = StorageShell.getResolutionData(resolutionId);
```

**Description:**
`resolve()` writes resolution data keyed by `marketId`, but `claimLPPosition()` and `claimProtocolRevenue()` read from `ZERO_ID` (bytes32(0)). Since no resolution data is ever stored at `ZERO_ID`, the `getResolutionData` call attempts to `abi.decode` empty bytes, which **reverts**.

This means **LP token redemption and protocol revenue claims are permanently broken** — even after a market is properly resolved, neither LPs nor the protocol can ever receive their payouts.

Combined with finding M-01 (`getResolutionData` has no empty-data fallback), this is a guaranteed revert path.

**Impact:** All post-resolution fund distribution is completely non-functional. Funds are locked forever.

**Recommendation:** Choose one consistent approach:
- **Option A (Per-market resolution):** Change `claimLPPosition` and `claimProtocolRevenue` to accept a `predictionAsset` parameter and use the same `marketId`.
- **Option B (Pool-wide resolution):** Change `resolve()` to also store (or aggregate) resolution data at `ZERO_ID`.

---

### C-04: `processRepay` Overcharges Users on Partial Repayment

**Location:** `src/core/Core.sol:190-204`

```solidity
uint256 userPrincipalDebt = _calculateUserPrincipalDebt(
    actualRepayAmount,           // <-- Uses repay amount instead of position.borrowAmount
    newMarket.totalBorrowed,
    newPool.totalBorrowedAllMarkets,
    input.protocolTotalDebt
);

(uint256 totalDebt, uint256 principalDebt,) = CoreMath.calculateUserTotalDebt(
    input.repayAmount,           // <-- Uses repay amount instead of position.borrowAmount
    newMarket.totalBorrowed,
    userPrincipalDebt,
    newPosition.scaledDebtBalance,  // <-- Full scaled debt, not proportional
    newMarket.variableBorrowIndex
);
```

**Description:**
`CoreMath.calculateUserTotalDebt` computes spread as:

```
spreadDebt = (scaledDebtBalance × borrowIndex) − userBorrowAmount
```

The first parameter (`userBorrowAmount`) is set to `input.repayAmount` rather than `position.borrowAmount`. For partial repayments, this causes a massive overcharge.

**Proof-of-Concept (numeric example):**
- User borrows 100 USDC at index 1.0 → `scaledDebtBalance = 100`
- Time passes, index = 1.05 → true spread = `100 × 1.05 - 100 = 5`
- User does partial repay of 50:
  - `spreadDebt = 100 × 1.05 - 50 = 55` (should be ~2.5 proportionally)
  - `totalDebt = principalDebt(~50) + 55 = ~105` — charged for repaying just 50 of 100

The user is charged 55 USDC in "spread" instead of ~2.5. On a subsequent repay of the remaining 50, a further ~5 spread is charged, totaling ~60 in spread instead of 5.

**Impact:** Users are massively overcharged on any partial repayment. This also means `BorrowLogic.repay` pulls far more tokens than owed, potentially causing reverts if the user hasn't approved enough.

**Recommendation:** Pass the user's full `borrowAmount` to both functions and compute proportional amounts only for the Aave repayment:

```solidity
uint256 userPrincipalDebt = _calculateUserPrincipalDebt(
    newPosition.borrowAmount,   // Full borrow amount
    newMarket.totalBorrowed,
    newPool.totalBorrowedAllMarkets,
    input.protocolTotalDebt
);

(uint256 totalDebt, uint256 principalDebt, uint256 spreadDebt) = CoreMath.calculateUserTotalDebt(
    newPosition.borrowAmount,   // Full borrow amount
    newMarket.totalBorrowed,
    userPrincipalDebt,
    newPosition.scaledDebtBalance,
    newMarket.variableBorrowIndex
);

// For partial repay, prorate the debt components
if (actualRepayAmount < newPosition.borrowAmount) {
    uint256 repayRatio = actualRepayAmount.rayDiv(newPosition.borrowAmount);
    principalDebt = principalDebt.rayMul(repayRatio);
    spreadDebt = spreadDebt.rayMul(repayRatio);
    totalDebt = principalDebt + spreadDebt;
}
```

---

## 4. High Findings

### H-01: No Available-Liquidity Check in `processBorrow`

**Location:** `src/core/Core.sol:107-160`

**Description:**
`processBorrow` updates `pool.totalBorrowedAllMarkets += actualBorrowAmount` without verifying that:

```
pool.totalBorrowedAllMarkets + actualBorrowAmount <= pool.totalSupplied
```

The spec in `CLAUDE.md` explicitly lists this as a required invariant. Without this check, the protocol can lend out more than it has, leading to failed Aave borrows (which would revert at the Aave layer) or, worse, over-lending from the Pool's own aToken balance.

**Recommendation:**
Add a liquidity check after calculating `actualBorrowAmount`:

```solidity
uint256 availableLiquidity = pool.totalSupplied > pool.totalBorrowedAllMarkets ?
    pool.totalSupplied - pool.totalBorrowedAllMarkets : 0;
if (actualBorrowAmount > availableLiquidity) {
    actualBorrowAmount = availableLiquidity;
}
require(actualBorrowAmount > 0, "Insufficient liquidity");
```

---

### H-02: Liquidation Bonus Is Never Applied

**Location:** `src/core/Core.sol:245-304`, `DataStruct.sol:70`

**Description:**
`RiskParams` defines a `liquidationBonus` field, but `processLiquidation` never uses it. The collateral seized is computed via `processRepay`, which returns collateral proportional to `repayAmount / borrowAmount`. In standard lending protocols, liquidators receive a bonus (e.g., 5-10% extra collateral) as an incentive. Without this bonus:

1. There is no economic incentive for liquidators to call `liquidate()`.
2. Positions may remain undercollateralized, accumulating bad debt.

**Recommendation:**
Apply the liquidation bonus when calculating seized collateral:

```solidity
uint256 bonusCollateral = collateralSeized.percentMul(params.liquidationBonus);
collateralSeized += bonusCollateral;
```

---

### H-03: 1:1 LP Token Minting Causes Yield Dilution

**Location:** `src/core/CoreMath.sol:246-251`

```solidity
function calculateLPTokensToMint(uint256 supplyAmount) internal pure returns (uint256) {
    return supplyAmount; // 1:1 minting
}
```

**Description:**
LP tokens are always minted 1:1 with the deposit amount. When funds are supplied to Aave, the Pool receives aTokens that appreciate over time. A later depositor who supplies the same nominal amount receives the same number of LP tokens, thereby diluting earlier depositors' claim on accumulated Aave yield.

**Example:**
1. LP-A supplies 1000 USDC → 1000 LP tokens. Aave aToken balance grows to 1050.
2. LP-B supplies 1000 USDC → 1000 LP tokens. Total LP = 2000, total aTokens ≈ 2050.
3. On redemption, each LP can withdraw ~1025 from Aave (50/50 split), but LP-A earned the first 50 alone.

Additionally, during `claimLPPosition`, the Aave withdrawal amount is `lpTokenAmount` (nominal), not the proportional share of aToken balance. This means the actual yield distribution depends on claim ordering and may not properly distribute accumulated Aave interest.

**Recommendation:**
Implement an ERC-4626-style vault share model:
```solidity
function calculateLPTokensToMint(uint256 supplyAmount, uint256 totalAssets, uint256 totalShares)
    internal pure returns (uint256) {
    if (totalShares == 0) return supplyAmount;
    return supplyAmount.mulDiv(totalShares, totalAssets);
}
```

---

### H-04: Market Maturity Not Enforced on Borrow

**Location:** `src/libraries/logic/BorrowLogic.sol:48-129`

**Description:**
`BorrowLogic.borrow()` does not check `market.isMatured`. The `MarketData.isMatured` flag exists, and `checkPositionHealth()` references it, but no borrow-time validation prevents new loans against matured prediction markets. A matured market has deterministic collateral value (collapsed to 0 or 1), making LTV calculations based on oracle prices meaningless.

Additionally, `ReserveLogic.setMarketMatured()` exists but is never called from any public function — there is no way for the curator to mark a market as matured.

**Recommendation:**
1. Add a maturity check in `BorrowLogic.borrow()`:
   ```solidity
   if (market.isMatured) revert PolynanceEE.MarketNotActive();
   ```
2. Expose `setMarketMatured()` as a curator-callable function on `Pool`.

---

## 5. Medium Findings

### M-01: `StorageShell.getResolutionData` Reverts on Empty Data

**Location:** `src/libraries/StorageShell.sol:109-113`

```solidity
function getResolutionData(bytes32 id) internal view returns (ResolutionData memory) {
    bytes32 key = keccak256(abi.encode(DataType.RESOLUTION_DATA, id));
    bytes memory data = _load(key);
    return abi.decode(data, (ResolutionData)); // Reverts if data.length == 0
}
```

**Description:**
Unlike `getPool()`, `getMarketData()`, and `getUserPosition()` which all return default zero-initialized structs when data is empty, `getResolutionData` attempts to `abi.decode` empty bytes, which reverts. Any code path that reads resolution data before it's been written will fail.

**Recommendation:**
Add the same empty-data guard used by other getters:

```solidity
if (data.length == 0) {
    return ResolutionData({
        isMarketResolved: false,
        marketResolvedTimestamp: 0,
        finalCollateralPrice: 0,
        lpPool: 0,
        borrowerPool: 0,
        protocolPool: 0,
        totalCollateralRedeemed: 0,
        liquidityRepaid: 0,
        protocolClaimed: false
    });
}
```

---

### M-02: `getDebtBalance` Ignores `rateMode` Parameter

**Location:** `src/adaptor/AaveModule.sol:195-197`

```solidity
function getDebtBalance(address asset, address user, InterestRateMode rateMode)
    external view override returns (uint256) {
    return AaveLibrary.getTotalDebtBase(asset, user); // rateMode ignored
}
```

**Description:**
The `rateMode` parameter is declared but never used. `getTotalDebtBase` always returns the variable debt token balance. If the protocol ever borrows at a stable rate, this function would return incorrect values.

**Recommendation:**
Use `AaveLibrary.getUserDebtBalance(asset, user, rateMode)` which already handles the mode distinction correctly.

---

### M-03: Hardcoded Aave V3 Addresses

**Location:** `src/adaptor/AaveModule.sol:33-34`

```solidity
IPoolDataProvider constant AAVE_PROTOCOL_DATA_PROVIDER =
    IPoolDataProvider(0x14496b405D62c24F91f04Cda1c69Dc526D56fDE5);
IPool constant POOL = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
```

**Description:**
These are Polygon mainnet Aave V3 addresses. The contract cannot be deployed to any other chain (Ethereum mainnet, Arbitrum, Optimism, etc.) without recompilation. If Aave governance migrates the pool, the contract becomes permanently broken.

**Recommendation:**
Accept the Aave Pool address and DataProvider address as constructor parameters or use Aave's `IPoolAddressesProvider` to resolve them dynamically.

---

### M-04: Global `RiskParams` Shared Across All Markets

**Location:** `src/libraries/DataStruct.sol:57-73`

**Description:**
A single `RiskParams` struct governs all prediction markets: same LTV, same liquidation threshold, same spread curve parameters. In practice, different prediction markets have vastly different risk profiles (e.g., a US election market vs. a sports bet). A high-risk market with the same LTV as a low-risk one will accumulate bad debt.

**Recommendation:**
Move risk parameters (at minimum `ltv`, `liquidationThreshold`, `liquidationCloseFactor`) to per-market storage inside `MarketData`, or create a per-market `MarketRiskParams` struct.

---

### M-05: Scaled-Debt Underflow Can Block Full Repayment

**Location:** `src/core/Core.sol:207-213`

```solidity
uint256 scaledCurrentRepayReduction = CoreMath.calculateScaledDebt(
    actualRepayAmount, newMarket.variableBorrowIndex
);
newPosition.scaledDebtBalance -= scaledCurrentRepayReduction;
```

**Description:**
`calculateScaledDebt` divides `actualRepayAmount` by the current borrow index using `rayDiv`, which rounds *up*. If rounding causes `scaledCurrentRepayReduction` to exceed `newPosition.scaledDebtBalance`, the subtraction reverts (Solidity 0.8+ underflow check). This can permanently trap users who try to fully repay their debt.

Similarly, `newMarket.totalScaledBorrowed -= scaledCurrentRepayReduction` can underflow if the market has multiple borrowers and accumulated rounding errors.

**Recommendation:**
Cap the reduction at the available balance:

```solidity
if (scaledCurrentRepayReduction > newPosition.scaledDebtBalance) {
    scaledCurrentRepayReduction = newPosition.scaledDebtBalance;
}
```

---

### M-06: No LP Withdrawal Mechanism Before Market Resolution

**Location:** `src/Pool.sol`

**Description:**
The `IPool` interface and `Pool` contract provide no function for LPs to withdraw their supplied liquidity before a market resolves. Once supplied, funds are locked until `resolveMarket()` is called by the curator and `claimLPPosition()` becomes available. For long-dated prediction markets, this could mean months or years of locked capital with no exit.

**Recommendation:**
Implement a withdrawal function that allows LPs to redeem their LP tokens for the underlying asset, subject to available liquidity (total supplied minus total borrowed). This is a standard feature in lending pool designs.

---

### M-07: Inconsistent Aave Integration Paths

**Location:**
- `BorrowLogic.sol:110` → `ILiquidityLayer(params.liquidityLayer).borrow(...)` (through AaveModule)
- `MarketResolveLogic.sol:208` → `AaveLibrary.withdraw(...)` (direct library call in Pool context)

**Description:**
Some operations route through `AaveModule` (an external contract), while others call `AaveLibrary` directly. This creates two different execution contexts:

1. **Through AaveModule:** `msg.sender` is Pool, calls are external, tokens flow through AaveModule.
2. **Through AaveLibrary:** Library code runs in Pool's context, `msg.sender` to Aave is Pool directly.

This inconsistency complicates reasoning about token flows and authorization. It also means that changing the Aave integration in AaveModule wouldn't affect the direct AaveLibrary calls, and vice versa.

**Recommendation:**
Standardize all Aave interactions through a single path — either always through `ILiquidityLayer` (AaveModule) or always through `AaveLibrary`.

---

## 6. Low / Informational Findings

### L-01: Misleading Event on Market Initialization

**Location:** `src/Pool.sol:255`

```solidity
emit PolynanceEE.DepositCollateral(address(this), predictionAsset, 0);
```

A `DepositCollateral` event with amount 0 is emitted when a market is initialized. This is semantically incorrect and will confuse indexers and dashboards. Define and emit a proper `MarketInitialized` event instead.

---

### L-02: Typo in Parameter Name

**Location:** `src/core/CoreMath.sol:97`

```solidity
uint256 curremtTimestamp  // should be "currentTimestamp"
```

---

### L-03: Zero-Borrow-Amount Execution Wastes Gas

**Location:** `src/core/Core.sol:136`

```solidity
uint256 actualBorrowAmount = input.borrowAmount > maxBorrow ? maxBorrow : input.borrowAmount;
```

If `maxBorrow` is 0 (e.g., worthless collateral), `actualBorrowAmount` is 0, but execution continues through all state updates. Add a check to revert early if the actual amount is zero.

---

### L-04: Single-Oracle Price Feed With No Sanity Checks

**Location:** `src/libraries/logic/BorrowLogic.sol:72`

```solidity
uint256 currentPriceWad = IOracle(params.priceOracle).getCurrentPrice(predictionAsset);
```

The protocol relies on a single oracle call with no staleness check, no deviation check, and no fallback. The CLAUDE.md spec mentions "multi-feed median" as a mitigation, but the implementation uses a single call. A manipulated oracle (e.g., via a flash-loan attack on an AMM-based oracle) can enable under-collateralized borrowing or unfair liquidations.

**Recommendation:**
Add price sanity bounds (min/max), staleness checks (revert if `block.timestamp - lastOracleUpdate > threshold`), and consider a multi-oracle aggregation pattern.

---

## 7. Architecture Review

### Strengths

1. **Functional-Core / Imperative-Shell Pattern:** Separating pure math (`CoreMath`) from state transitions (`Core`) from storage and I/O (logic libraries) is a strong design. It enables thorough unit testing of financial logic without mocking storage.

2. **Ray-Precision Arithmetic:** Consistent use of Aave's `WadRayMath` and `PercentageMath` libraries prevents common fixed-point pitfalls.

3. **Reentrancy Protection:** All Pool entry points use `ReentrancyGuard`. External calls to untrusted contracts (prediction tokens, oracle) are made after storage updates in most cases.

4. **Event Coverage:** Comprehensive events are emitted for supply, borrow, repay, liquidation, and resolution operations.

5. **Existing Test Suite:** The project includes unit tests, property tests, invariant tests, and fuzz tests for CoreMath and Core — a strong testing foundation.

### Weaknesses

1. **Commented-Out Security Checks:** Multiple critical security checks are commented out (C-01, C-02). Commented-out code should never exist in production contracts.

2. **Storage Pattern Fragility:** Using `abi.encode/decode` with a generic `bytes` mapping is gas-expensive and prone to decode errors. Consider using typed storage with explicit slot calculations or a more conventional mapping-of-structs pattern.

3. **No Upgradeability Pattern:** The contract is not upgradeable. Given the number of bugs found, having a proxy pattern would allow post-deployment fixes. However, upgradeability also introduces centralization risks.

4. **Incomplete Features:** Liquidation logic exists but has no economic incentive (no bonus). Market maturity is tracked but never set. These incomplete features create a false sense of security.

5. **Aave Coupling:** The tight coupling to Aave V3 (hardcoded addresses, direct library calls) makes the protocol brittle. The `ILiquidityLayer` abstraction is partially implemented but not consistently used.

---

## 8. Recommendations

### Priority 1 — Must Fix Before Any Deployment

1. **C-01:** Restore the `_ensureMarketInitialized` guard.
2. **C-02:** Uncomment the `protocolClaimed` check in `claimProtocolRevenue`.
3. **C-03:** Fix the resolution data storage/retrieval key mismatch (use same ID consistently).
4. **C-04:** Fix `processRepay` to use `position.borrowAmount` for debt calculation and proportionally allocate spread for partial repayments.
5. **H-01:** Add the available-liquidity invariant check in `processBorrow`.
6. **M-01:** Add empty-data fallback in `getResolutionData`.
7. **M-05:** Cap scaled-debt reduction to prevent underflow on full repayment.

### Priority 2 — Should Fix Before Mainnet

8. **H-02:** Implement liquidation bonus.
9. **H-03:** Replace 1:1 LP minting with a share-based model.
10. **H-04:** Enforce maturity check on borrow; expose `setMarketMatured` to curator.
11. **M-04:** Add per-market risk parameters.
12. **M-06:** Implement LP withdrawal function.
13. **M-07:** Standardize Aave integration path.

### Priority 3 — Recommended Improvements

14. **M-03:** Make Aave addresses configurable.
15. **L-04:** Implement multi-oracle aggregation with sanity checks.
16. Remove all commented-out code from production contracts.
17. Add comprehensive integration tests covering the full lifecycle: supply → borrow → time passes → repay → resolve → claim.
18. Consider a formal verification pass on `CoreMath` functions.

---

*End of Audit Report*
