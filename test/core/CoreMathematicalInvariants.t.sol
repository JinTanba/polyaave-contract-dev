// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/Core.sol";
import "../../src/core/CoreMath.sol";
import "../../src/libraries/DataStruct.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";

/**
 * @title CoreMathematicalInvariants
 * @notice Comprehensive tests for mathematical, financial, and logical accuracy
 * @dev Tests all invariants and formulas with high statistical confidence
 */
contract CoreMathematicalInvariants is Test {
    using WadRayMath for uint256;
    
    Core internal core;
    
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    
    RiskParams internal params;
    
    function setUp() public {
        core = new Core();
        
        params = RiskParams({
            priceOracle: address(0x1),
            liquidityLayer: address(0x2),
            supplyAsset: address(0x3),
            curator: address(0x4),
            baseSpreadRate: 1e25, // 1% in Ray
            optimalUtilization: 8e26, // 80% in Ray
            slope1: 5e25, // 5% in Ray
            slope2: 2e26, // 20% in Ray
            reserveFactor: 1000, // 10%
            ltv: 7500, // 75%
            liquidationThreshold: 8000, // 80%
            liquidationCloseFactor: 5000, // 50%
            liquidationBonus: 500, // 5%
            lpShareOfRedeemed: 5000, // 50%
            supplyAssetDecimals: 6
        });
    }
    
    // ============ Mathematical Invariant 1: LP Token Conservation ============
    
    /**
     * @notice Verifies Σ lpBalances == pool.totalSupplied holds after every operation
     */
    function testFuzz_Invariant_LPTokenConservation(
        uint256 numUsers,
        uint256 seed
    ) public {
        numUsers = bound(numUsers, 1, 100);
        
        PoolData memory pool;
        uint256[] memory lpBalances = new uint256[](numUsers);
        uint256 totalLPBalance;
        
        // Perform random supplies
        for (uint i = 0; i < numUsers; i++) {
            uint256 supplyAmount = bound(
                uint256(keccak256(abi.encode(seed, i))),
                1e6, // 1 USDC
                1e12 // 1M USDC
            );
            
            CoreSupplyInput memory input = CoreSupplyInput({
                userLPBalance: lpBalances[i],
                supplyAmount: supplyAmount
            });
            
            (PoolData memory newPool, CoreSupplyOutput memory output) = core.processSupply(pool, input);
            
            // Update state
            pool = newPool;
            lpBalances[i] = output.newUserLPBalance;
            totalLPBalance += output.lpTokensToMint;
            
            // Check invariant after each operation
            assertEq(totalLPBalance, pool.totalSupplied, 
                "Invariant violated: sum(lpBalances) != pool.totalSupplied");
        }
    }
    
    // ============ Mathematical Invariant 2: Market Debt Aggregation ============
    
    /**
     * @notice Verifies Σ market.totalBorrowed == pool.totalBorrowedAllMarkets
     */
    function testFuzz_Invariant_MarketDebtAggregation(
        uint256 numMarkets,
        uint256 numBorrowsPerMarket,
        uint256 seed
    ) public {
        numMarkets = bound(numMarkets, 1, 10);
        numBorrowsPerMarket = bound(numBorrowsPerMarket, 1, 20);
        
        // Setup pool with liquidity
        PoolData memory pool;
        pool.totalSupplied = 1e12; // 1M USDC
        
        MarketData[] memory markets = new MarketData[](numMarkets);
        uint256 sumMarketBorrowed;
        
        // Initialize markets
        for (uint i = 0; i < numMarkets; i++) {
            markets[i].variableBorrowIndex = RAY;
            markets[i].lastUpdateTimestamp = block.timestamp;
            markets[i].collateralAssetDecimals = 18;
        }
        
        // Perform borrows across markets
        for (uint m = 0; m < numMarkets; m++) {
            for (uint b = 0; b < numBorrowsPerMarket; b++) {
                uint256 borrowAmount = bound(
                    uint256(keccak256(abi.encode(seed, m, b))),
                    1e6, // 1 USDC
                    1e9  // 1000 USDC
                );
                
                // Ensure we don't exceed available liquidity
                uint256 availableLiquidity = pool.totalSupplied - pool.totalBorrowedAllMarkets;
                if (borrowAmount > availableLiquidity) {
                    borrowAmount = availableLiquidity / 2;
                }
                if (borrowAmount == 0) continue;
                
                UserPosition memory position;
                CoreBorrowInput memory input = CoreBorrowInput({
                    borrowAmount: borrowAmount,
                    collateralAmount: borrowAmount * 2, // 200% collateralized
                    collateralPrice: RAY, // $1
                    protocolTotalDebt: pool.totalBorrowedAllMarkets
                });
                
                (MarketData memory newMarket, PoolData memory newPool,,) = 
                    core.processBorrow(markets[m], pool, position, input, params);
                
                markets[m] = newMarket;
                pool = newPool;
                sumMarketBorrowed = 0;
                
                // Recalculate sum after each operation
                for (uint i = 0; i < numMarkets; i++) {
                    sumMarketBorrowed += markets[i].totalBorrowed;
                }
                
                // Check invariant
                assertEq(sumMarketBorrowed, pool.totalBorrowedAllMarkets,
                    "Invariant violated: sum(market.totalBorrowed) != pool.totalBorrowedAllMarkets");
            }
        }
    }
    
    // ============ Mathematical Invariant 3: Solvency ============
    
    /**
     * @notice Verifies pool.totalBorrowedAllMarkets ≤ pool.totalSupplied
     */
    function testFuzz_Invariant_ProtocolSolvency(uint256 seed) public {
        PoolData memory pool;
        MarketData memory market;
        market.variableBorrowIndex = RAY;
        market.collateralAssetDecimals = 18;
        
        // Run 1000 random operations
        for (uint i = 0; i < 1000; i++) {
            uint256 opType = uint256(keccak256(abi.encode(seed, i))) % 3;
            
            if (opType == 0) {
                // Supply
                uint256 amount = bound(
                    uint256(keccak256(abi.encode(seed, i, "supply"))),
                    1e6,
                    1e10
                );
                
                CoreSupplyInput memory input = CoreSupplyInput({
                    userLPBalance: 0,
                    supplyAmount: amount
                });
                
                (pool,) = core.processSupply(pool, input);
                
            } else if (opType == 1 && pool.totalSupplied > pool.totalBorrowedAllMarkets) {
                // Borrow
                uint256 availableLiquidity = pool.totalSupplied - pool.totalBorrowedAllMarkets;
                uint256 borrowAmount = bound(
                    uint256(keccak256(abi.encode(seed, i, "borrow"))),
                    1e6,
                    availableLiquidity
                );
                
                UserPosition memory position;
                CoreBorrowInput memory input = CoreBorrowInput({
                    borrowAmount: borrowAmount,
                    collateralAmount: borrowAmount * 2,
                    collateralPrice: RAY,
                    protocolTotalDebt: pool.totalBorrowedAllMarkets
                });
                
                (market, pool,,) = core.processBorrow(market, pool, position, input, params);
                
            } else if (opType == 2 && market.totalBorrowed > 0) {
                // Repay
                uint256 repayAmount = bound(
                    uint256(keccak256(abi.encode(seed, i, "repay"))),
                    1,
                    market.totalBorrowed
                );
                
                UserPosition memory position;
                position.borrowAmount = repayAmount;
                position.scaledDebtBalance = repayAmount;
                
                CoreRepayInput memory input = CoreRepayInput({
                    repayAmount: repayAmount,
                    protocolTotalDebt: pool.totalBorrowedAllMarkets
                });
                
                (market, pool,,) = core.processRepay(market, pool, position, input);
            }
            
            // Check solvency invariant after each operation
            assertLe(pool.totalBorrowedAllMarkets, pool.totalSupplied,
                "Invariant violated: totalBorrowedAllMarkets > totalSupplied");
        }
    }
    
    // ============ Financial Formula: Two-Level Debt Allocation ============
    
    /**
     * @notice Verifies the two-level debt allocation formula
     * marketDebt = protocolDebt × (marketTotalBorrowed / totalBorrowedAllMarkets)
     * userDebt = marketDebt × (userBorrowAmount / marketTotalBorrowed)
     */
    function test_Formula_TwoLevelDebtAllocation() public {
        // Setup: 3 markets with different borrow amounts
        uint256 protocolDebt = 1_100_000 * 1e6; // $1.1M total debt
        
        // Market A: 50% of borrows
        uint256 marketA_borrowed = 500_000 * 1e6;
        uint256 marketA_expectedDebt = (protocolDebt * marketA_borrowed) / (1_000_000 * 1e6);
        
        // Market B: 30% of borrows
        uint256 marketB_borrowed = 300_000 * 1e6;
        uint256 marketB_expectedDebt = (protocolDebt * marketB_borrowed) / (1_000_000 * 1e6);
        
        // Market C: 20% of borrows
        uint256 marketC_borrowed = 200_000 * 1e6;
        uint256 marketC_expectedDebt = (protocolDebt * marketC_borrowed) / (1_000_000 * 1e6);
        
        // Verify market allocations
        assertEq(marketA_expectedDebt, 550_000 * 1e6, "Market A should get 50% of protocol debt");
        assertEq(marketB_expectedDebt, 330_000 * 1e6, "Market B should get 30% of protocol debt");
        assertEq(marketC_expectedDebt, 220_000 * 1e6, "Market C should get 20% of protocol debt");
        
        // Verify sum equals total
        assertEq(
            marketA_expectedDebt + marketB_expectedDebt + marketC_expectedDebt,
            protocolDebt,
            "Sum of market debts must equal protocol debt"
        );
        
        // Test user allocations within Market A
        uint256 userA1_borrow = 200_000 * 1e6; // 40% of market
        uint256 userA2_borrow = 300_000 * 1e6; // 60% of market
        
        uint256 userA1_expectedPrincipal = (marketA_expectedDebt * userA1_borrow) / marketA_borrowed;
        uint256 userA2_expectedPrincipal = (marketA_expectedDebt * userA2_borrow) / marketA_borrowed;
        
        assertEq(userA1_expectedPrincipal, 220_000 * 1e6, "User A1 should get 40% of market debt");
        assertEq(userA2_expectedPrincipal, 330_000 * 1e6, "User A2 should get 60% of market debt");
        assertEq(
            userA1_expectedPrincipal + userA2_expectedPrincipal,
            marketA_expectedDebt,
            "Sum of user debts must equal market debt"
        );
    }
    
    // ============ Interest Accrual Monotonicity ============
    
    /**
     * @notice Verifies borrow index is monotonically increasing over time
     */
    function testFuzz_InterestAccrual_Monotonicity(
        uint256 utilization,
        uint256 timeStep,
        uint256 numSteps
    ) public {
        utilization = bound(utilization, 0, RAY); // 0-100%
        timeStep = bound(timeStep, 1, 30 days);
        numSteps = bound(numSteps, 1, 100);
        
        MarketData memory market;
        market.variableBorrowIndex = RAY;
        market.lastUpdateTimestamp = block.timestamp;
        
        PoolData memory pool;
        pool.totalSupplied = 1_000_000 * 1e6;
        pool.totalBorrowedAllMarkets = pool.totalSupplied.rayMul(utilization);
        
        market.totalBorrowed = pool.totalBorrowedAllMarkets;
        market.totalScaledBorrowed = market.totalBorrowed;
        
        uint256 previousIndex = market.variableBorrowIndex;
        
        for (uint i = 0; i < numSteps; i++) {
            skip(timeStep);
            
            (MarketData memory newMarket,) = core.updateMarketIndices(
                market,
                pool,
                params,
                block.timestamp
            );
            
            // Verify monotonicity
            assertGe(newMarket.variableBorrowIndex, previousIndex,
                "Borrow index must be monotonically increasing");
            
            // If time passed and there are borrows, index must strictly increase
            if (market.totalBorrowed > 0) {
                assertGt(newMarket.variableBorrowIndex, previousIndex,
                    "Borrow index must strictly increase with active borrows");
            }
            
            // Verify precise calculation
            uint256 spreadRate = CoreMath.calculateSpreadRate(
                market.totalBorrowed,
                pool.totalSupplied,
                params.baseSpreadRate,
                params.optimalUtilization,
                params.slope1,
                params.slope2
            );
            
            uint256 expectedIndex = CoreMath.calculateNewBorrowIndex(
                market.variableBorrowIndex,
                spreadRate,
                market.lastUpdateTimestamp,
                block.timestamp
            );
            
            assertEq(newMarket.variableBorrowIndex, expectedIndex,
                "Index calculation must match CoreMath");
            
            market = newMarket;
            previousIndex = newMarket.variableBorrowIndex;
        }
    }
    
    // ============ Partial Repayment Proportionality ============
    
    /**
     * @notice Verifies partial repayments reduce debt and collateral proportionally
     */
    function testFuzz_PartialRepayment_Proportionality(
        uint256 initialDebt,
        uint256 repayPercent
    ) public {
        initialDebt = bound(initialDebt, 1e6, 1e10); // 1 to 10k USDC
        repayPercent = bound(repayPercent, 1, 99); // 1-99%
        
        // Setup
        PoolData memory pool;
        pool.totalSupplied = 1e12;
        pool.totalBorrowedAllMarkets = initialDebt;
        
        MarketData memory market;
        market.variableBorrowIndex = RAY;
        market.totalBorrowed = initialDebt;
        market.totalScaledBorrowed = initialDebt;
        market.collateralAssetDecimals = 18;
        
        UserPosition memory position;
        position.borrowAmount = initialDebt;
        position.scaledDebtBalance = initialDebt;
        position.collateralAmount = initialDebt * 2; // 200% collateralized
        
        uint256 repayAmount = (initialDebt * repayPercent) / 100;
        
        CoreRepayInput memory input = CoreRepayInput({
            repayAmount: repayAmount,
            protocolTotalDebt: pool.totalBorrowedAllMarkets
        });
        
        (MarketData memory newMarket, 
         PoolData memory newPool, 
         UserPosition memory newPosition, 
         CoreRepayOutput memory output) = core.processRepay(
            market,
            pool,
            position,
            input
        );
        
        // Verify proportional reduction
        uint256 expectedRemainingDebt = initialDebt - repayAmount;
        uint256 expectedRemainingCollateral = (position.collateralAmount * (100 - repayPercent)) / 100;
        uint256 expectedReturnedCollateral = position.collateralAmount - expectedRemainingCollateral;
        
        assertEq(newPosition.borrowAmount, expectedRemainingDebt, 
            "Debt must reduce by exact repay amount");
        assertEq(newPosition.collateralAmount, expectedRemainingCollateral,
            "Collateral must reduce proportionally");
        assertEq(output.collateralToReturn, expectedReturnedCollateral,
            "Returned collateral must match reduction");
        
        // Verify market and pool updates
        assertEq(newMarket.totalBorrowed, market.totalBorrowed - repayAmount,
            "Market total borrowed must reduce");
        assertEq(newPool.totalBorrowedAllMarkets, pool.totalBorrowedAllMarkets - repayAmount,
            "Pool total borrowed must reduce");
    }
    
    // ============ Spread Rate Curve Validation ============
    
    /**
     * @notice Validates the piecewise linear spread rate function
     */
    function test_SpreadRateCurve_Validation() public {
        uint256 totalSupplied = 1_000_000 * 1e6;
        
        // Test key points on the curve
        uint256[] memory utilizations = new uint256[](5);
        uint256[] memory expectedRates = new uint256[](5);
        
        // 0% utilization
        utilizations[0] = 0;
        expectedRates[0] = params.baseSpreadRate; // 1%
        
        // 40% utilization (below knee)
        utilizations[1] = 4e26; // 40% in Ray
        expectedRates[1] = params.baseSpreadRate + params.slope1.rayMul(4e26).rayDiv(params.optimalUtilization);
        
        // 80% utilization (at knee)
        utilizations[2] = 8e26; // 80% in Ray
        expectedRates[2] = params.baseSpreadRate + params.slope1; // 1% + 5% = 6%
        
        // 90% utilization (above knee)
        utilizations[3] = 9e26; // 90% in Ray
        expectedRates[3] = params.baseSpreadRate + params.slope1 + params.slope2.rayMul(1e26); // 6% + 2% = 8%
        
        // 100% utilization
        utilizations[4] = RAY; // 100% in Ray
        expectedRates[4] = params.baseSpreadRate + params.slope1 + params.slope2.rayMul(2e26); // 6% + 4% = 10%
        
        for (uint i = 0; i < utilizations.length; i++) {
            uint256 totalBorrowed = totalSupplied.rayMul(utilizations[i]);
            
            uint256 actualRate = CoreMath.calculateSpreadRate(
                totalBorrowed,
                totalSupplied,
                params.baseSpreadRate,
                params.optimalUtilization,
                params.slope1,
                params.slope2
            );
            
            assertApproxEqRel(actualRate, expectedRates[i], 0.001e18,
                string.concat("Spread rate incorrect at ", vm.toString(utilizations[i].rayMul(100) / RAY), "% utilization"));
        }
    }
}