# 🔮👻
## Core Concept

PolynanceLend allows users to **borrow traditional assets (like USDC) using prediction market position tokens as collateral**. This is novel because prediction tokens typically have uncertain, time-dependent values that resolve to either 0 or some fixed amount at maturity.

## Key Components

### 1. **Dual-Layer Architecture**
- **Liquidity Layer**: Uses existing lending protocols (Aave V3) as the underlying liquidity source
- **Polynance Layer**: Manages the prediction token collateral and risk parameters on top

### 2. **Main Operations**

**Supply**: 
- Users deposit assets (e.g., USDC) which get supplied to Aave
- Users receive LP tokens representing their share of the pool

**Borrow**:
- Users deposit prediction tokens as collateral
- The protocol values these tokens via an oracle
- Users can borrow up to a certain LTV (loan-to-value) ratio
- The protocol borrows from Aave and passes funds to the user

**Repay**:
- Users repay principal + interest
- Interest has two components:
  - Aave's interest rate (what the protocol pays)
  - Polynance's interest rate (protocol's margin)

**Market Resolution**:
- When prediction markets resolve, the protocol redeems position tokens
- Calculates profit/loss based on redemption value vs outstanding debt
- Handles distribution to lenders and borrowers

### 3. **Risk Management**
- **LTV ratios**: Controls how much can be borrowed against prediction token collateral
- **Dual interest rates**: Both fixed and variable rate modes supported
- **Price oracles**: Values prediction tokens dynamically before resolution
- **Liquidation parameters**: Though liquidation logic isn't fully implemented in this version

## Innovative Aspects

1. **Prediction tokens as collateral**: This is unique because these assets have binary or discrete outcomes and time-dependent values

2. **Interest rate arbitrage**: The protocol can earn spread between what it pays Aave and what it charges borrowers

3. **Resolution mechanism**: Handles the special case where collateral transforms from speculative tokens to resolved assets

4. **Composability**: Built on top of existing DeFi infrastructure (Aave) rather than recreating lending logic

## Current Implementation Status

From the code, it appears this is indeed a beta version with some TODOs:
- Swap functionality after resolution needs implementation
- Full liquidation logic appears incomplete
- LP and loan resolution claim calculations in Core.sol are not yet implemented

This protocol essentially creates a new primitive in DeFi - allowing prediction market participants to access liquidity without selling their positions, while giving lenders exposure to prediction market yields.



# design concept

This repository applies the **Functional Core / Imperative Shell** architecture. All protocol behaviour is defined once, inside a **single Core library** written entirely with **`pure` (and `view`) functions**. Every public‐facing contract simply gathers state, calls the Core, and stores the result.

---

## 1 · Architectural Sketch

```
┌─────────────── Application Layer ───────────────┐
│  Front‑end · SDK · Bot …                        │
└──────────────────────▲──────────────────────────┘
                       │ external calls
┌──────────────────────┴──────────────────────────┐
│  Imperative Shell (stateful contracts)          │
│  • read storage                                  │
│  • call Core                                     │
│  • write storage · emit events                   │
└──────────────────────▲──────────────────────────┘
                       │ internal
┌──────────────────────┴──────────────────────────┐
│  **Core Library** (single file)                 │
│  • 100 % deterministic                          │
│  • business rules = behaviour                   │
│  • accepts/returns only structs & value types   │
└──────────────────────────────────────────────────┘
```

---

## 2 · Core Library Mandate

1. **One file only** –  `CoreLib.sol`.
2. **Pure logic only** – no storage access, external calls, timestamps, or events.
3. **Struct‑first API** – every function receives **exactly one** `struct` argument and returns value types (or another struct). No loose tuples.
4. **Behaviour declaration** – the Core is the single source of truth for pricing, interest accrual, liquidation rules, quota checks, etc.

> Example
>
> ```solidity
> library CoreLib {
>     using WadRayMath for uint256;
>
>     struct AccrualParams {
>         uint256 principal; // 1e18
>         uint256 indexPrev; // 1e27
>         uint256 indexNow;  // 1e27
>     }
>
>     function accrue(AccrualParams memory p)
>         internal pure returns (uint256)
>     {
>         return p.principal.rayMul(p.indexNow) / p.indexPrev;
>     }
> }
> ```

---

## 3 · Directory Layout

```
/contracts
  ├─ CoreLib.sol       # ← pure logic (single file)
  └─ modules/          # shell contracts (Pool, Vault, Router …)
```

---

## 4 · Implementation Rules

| Topic         | Rule                                         |
| ------------- | -------------------------------------------- |
| Naming        | `CoreLib.sol` only                           |
| Visibility    | `internal` for all Core functions            |
| Units         | Use Wad (`1e18`) / Ray (`1e27`) consistently |
| Safe casting  | Always via `SafeCast`                        |
| Zero‑division | Guard with `require(y != 0)` before division |

---

## 5 · Development Flow

1. **Define maths in Core** – add/modify `CoreLib.sol`.
2. **Shell integration**   – load state → call Core → store.
3. **Review & merge**     – Core diff must be deterministic and gas‑checked.

---

## 6 · Versioning

* **MAJOR** – Behaviour change (function signature or formula).
* **MINOR** – New pure function added.
* **PATCH** – Internal refactor or gas optimisation.

---

Maintainers: @LeadDev · @ProtocolEngineer
Last update: 2025‑05‑31



# PolynanceLend V2 Architecture
## Overview
### Supply Flow
```
User supplies USDC →
Core._processSupply(pool, userBalance, amount) →
CoreMath.calculateLPTokensToMint(amount) → returns amount (1:1)
Updates: pool.totalSupplied += amount
Updates: lpBalances[user] += amount
```

### Borrow Flow
```
User borrows with collateral →
Core._updateMarketIndices(market, pool, params) →
Core._processBorrow(market, pool, position, ..., protocolTotalDebt) →
1. Validate collateral value and max borrow
2. Calculate user's principal debt via _calculateUserPrincipalDebt
3. Borrow from liquidity layer
4. Calculate Polynance scaled debt
Updates: 
- position.borrowAmount += borrowAmount
- position.scaledDebtBalance += scaledPolynanceDebt
- market.totalBorrowed += borrowAmount
- pool.totalBorrowedAllMarkets += borrowAmount
```

### Debt Calculation Flow
```
Get user total debt →
1. Get protocolTotalDebt from variableDebtToken.balanceOf(this)
2. Calculate market's share: marketDebt = protocolTotalDebt × (marketTotalBorrowed / totalBorrowedAllMarkets)
3. Calculate user's share: userPrincipalDebt = marketDebt × (userBorrowAmount / marketTotalBorrowed)
4. Calculate spread: spreadDebt = (scaledDebt × polynanceIndex) - borrowAmount
5. Total debt = userPrincipalDebt + spreadDebt
```

### Repayment Flow
```
User repays debt →
Core._processRepay(market, pool, position, repayAmount, protocolTotalDebt) →
1. Calculate total debt (principal + spread)
2. Repay up to principalDebt to liquidity layer
3. Keep spread in contract
4. Update scaled balances
Updates:
- position.borrowAmount -= borrowReduction
- market.totalBorrowed -= borrowReduction  
- pool.totalBorrowedAllMarkets -= borrowReduction
- Return collateral if fully repaid
```# PolynanceLend V2 Architecture

## Overview
V2 implements a clean separation of concerns with three core components:

1. **CoreMath** - Pure mathematical library
2. **Core** - Abstract contract for state transitions
3. **StorageShell** - Optimized storage layout

## Key V2 Changes

### 1. Pooled Liquidity
- **V1**: Each market has separate liquidity pools
- **V2**: Single pool shared across all markets
- **Result**: Better capital efficiency, no liquidity fragmentation

### 2. Fungible LP Tokens
- **V1**: NFT positions with individual tracking
- **V2**: Simple ERC-20 style LP tokens (1:1 with deposits)
- **Result**: ~40-60% gas savings, secondary market compatibility

### 3. No liquidityIndex
- **V1**: Continuous yield tracking via liquidityIndex
- **V2**: Yield calculated only at resolution (since LPs are locked)
- **Result**: Simpler logic, fewer state updates

### 4. Simplified State Variables
- **Removed**: `totalLPTokenSupply` (redundant - always equals `totalSupplied`)
- **Removed**: `currentAaveSupplyRate`, `currentAaveBorrowRate` (query Aave directly)
- **Removed**: `totalAaveBalance` (query Aave balance directly)
- **Result**: Less storage slots, reduced gas costs

### 5. Single Risk Profile
- **V1**: Per-market risk parameters
- **V2**: Global risk parameters (curator model)
- **Result**: Simplified governance, consistent behavior

## Architecture Details

### CoreMath Library
Pure functions for all financial calculations:
- Interest rate calculations
- Debt and collateral math
- Liquidation calculations
- Resolution distribution
- LP token valuation

**Key principle**: No state access, only mathematical transformations

### Core Abstract Contract
State transition functions that use CoreMath:
- `_updateMarketIndices()` - Updates borrow index and spread
- `_processSupply()` - Handles LP deposits
- `_processBorrow()` - Handles borrowing with collateral
- `_processRepay()` - Handles debt repayment
- `_processLiquidation()` - Handles liquidations
- `_processResolution()` - Handles market resolution
- `_calculateUserPrincipalDebt()` - Calculates user's share of protocol debt

**Key principle**: Receives state and external data (like protocolTotalDebt), calls CoreMath, updates state

### StorageShell Structure

```solidity
PoolData {
    totalSupplied          // Total USDC from all LPs
    totalLPTokenSupply     // Total LP tokens (= totalSupplied)
    totalAccumulatedSpread // Sum of spread from all markets
    totalAccumulatedReserves
    currentAaveSupplyRate
    currentAaveBorrowRate
    totalAaveBalance
}

MarketData {
    variableBorrowIndex    // Per-market debt tracking
    totalScaledBorrowed
    totalBorrowed
    totalCollateral
    lastUpdateTimestamp
    accumulatedSpread      // This market's spread
    isActive
    isMatured
}

UserPosition {
    collateralAmount       // Only borrowing position
    borrowAmount
    scaledDebtBalance
    lastUpdateTimestamp
}
```

## Debt Calculation Architecture (Simplified)

### Efficient Debt Tracking

V2 uses a clean approach to track user debt without storing redundant data:

1. **Protocol Level**: 
   - `protocolTotalDebt` = Total debt from liquidity layer (`variableDebtToken.balanceOf`)
   - `pool.totalBorrowedAllMarkets` = Sum of all markets' initial borrow amounts

2. **Market Level**:
   - Market's debt share = `protocolTotalDebt × (market.totalBorrowed / pool.totalBorrowedAllMarkets)`
   - Each market tracks its own `totalBorrowed` (sum of initial borrows)

3. **User Level**:
   - User's principal debt = `marketDebt × (user.borrowAmount / market.totalBorrowed)`
   - User's spread debt = `(scaledDebt × polynanceIndex) - borrowAmount`

**Total User Debt Formula:**
```
marketDebt = protocolTotalDebt × (marketTotalBorrowed / totalBorrowedAllMarkets)
userPrincipalDebt = marketDebt × (userBorrowAmount / marketTotalBorrowed)
userSpreadDebt = (userScaledPolynanceDebt × polynanceBorrowIndex) - userBorrowAmount
totalDebt = userPrincipalDebt + userSpreadDebt
```

### Repayment Flow (Simplified)
- User pays total debt amount
- Principal (up to principalDebt) goes to liquidity layer
- Spread stays in the contract
- No complex distribution calculation needed

## Key Design Principles

1. **No Helper Functions**: Instead of internal helper functions that query external contracts, all external data (like `variableDebtToken.balanceOf()`) is passed as parameters to Core functions

2. **Ratio-Based Debt Calculation**: User debt is calculated through two levels of ratios:
   - Market ratio: `marketDebt = protocolTotalDebt × (marketTotalBorrowed / protocolTotalBorrowedAllMarkets)`
   - User ratio: `userDebt = marketDebt × (userBorrowAmount / marketTotalBorrowed)`

3. **Liquidity Layer Agnostic**: The protocol treats the underlying liquidity provider (currently Aave) as a swappable module, avoiding specific naming in variables

4. **Clean Separation**: 
   - CoreMath: Pure calculations only
   - Core: State transitions using CoreMath
   - External integrations: Handled by the implementation contract

## Benefits

1. **Gas Efficiency**: Minimal storage (no redundant variables), no NFT overhead
2. **Simplicity**: No liquidityIndex, no redundant state, single risk profile
3. **Composability**: Standard patterns, easier integrations
4. **Auditability**: Pure functions and minimal state are easier to verify
5. **Flexibility**: Easy to add new markets without fragmenting liquidity
6. **Curator Model**: Single risk parameter set simplifies governance

## Invariants Maintained

1. `sum(lpBalances) == pool.totalSupplied` (LP tokens always 1:1 with supply)
2. `sum(market.totalBorrowed) == pool.totalBorrowedAllMarkets` (Aggregate tracking)
3. `pool.totalBorrowedAllMarkets <= pool.totalSupplied` (Cannot borrow more than supplied)
4. All yield calculations preserve: `initial capital + yield = final distribution`
5. Single risk profile ensures consistent behavior across all markets



Please make the following corrections.
1. Move the type definitions from Storage to DataStruct, and define all type definitions in DataStruct.
2. In Core output, consolidate all items except those that change storage into a single data type.
Example:
3. In Core input, consolidate all items except Storage data into a single data type.
Example:
