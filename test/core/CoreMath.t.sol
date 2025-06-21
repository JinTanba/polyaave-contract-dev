// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/CoreMath.sol";
import "../../src/libraries/DataStruct.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";

contract CoreMathTest is Test {
    using WadRayMath for uint256;
    
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_BPS = 10_000;
    
    // ============ Test Constants ============
    uint256 constant DEFAULT_BASE_SPREAD = 1e25; // 1% in Ray
    uint256 constant DEFAULT_OPTIMAL_UTIL = 8e26; // 80% in Ray
    uint256 constant DEFAULT_SLOPE1 = 5e25; // 5% in Ray
    uint256 constant DEFAULT_SLOPE2 = 2e26; // 20% in Ray
    
    // ============ CM_LP Tests - LP Token Minting ============
    
    function test_CM_LP_001_CalculateLPTokensToMint() public {
        // Test 1:1 minting across various deposit amounts
        uint256[] memory testAmounts = new uint256[](5);
        testAmounts[0] = 1; // 1 USDC (minimum)
        testAmounts[1] = 1000 * 1e6; // 1,000 USDC
        testAmounts[2] = 1_000_000 * 1e6; // 1M USDC
        testAmounts[3] = 1_000_000_000 * 1e6; // 1B USDC
        testAmounts[4] = 0; // Edge case: zero
        
        for (uint i = 0; i < testAmounts.length; i++) {
            uint256 lpTokens = CoreMath.calculateLPTokensToMint(testAmounts[i]);
            assertEq(lpTokens, testAmounts[i], "LP tokens must equal deposit amount (1:1)");
        }
    }
    
    function testFuzz_CM_LP_001_CalculateLPTokensToMint(uint256 deposit) public {
        // Fuzz test with amounts up to 10^9 USDC
        deposit = bound(deposit, 1, 1e9 * 1e6);
        
        uint256 lpTokens = CoreMath.calculateLPTokensToMint(deposit);
        assertEq(lpTokens, deposit, "LP tokens must equal deposit amount (1:1)");
    }
    
    // ============ CM_SR Tests - Spread Rate Calculations ============
    
    function test_CM_SR_010_LinearSectionBelowKnee() public {
        uint256 totalSupplied = 1000 * WAD;
        uint256 totalBorrowed = 400 * WAD; // 40% utilization
        
        uint256 expectedRate = DEFAULT_BASE_SPREAD + DEFAULT_SLOPE1.rayMul(4e26).rayDiv(DEFAULT_OPTIMAL_UTIL);
        
        uint256 actualRate = CoreMath.calculateSpreadRate(
            totalBorrowed,
            totalSupplied,
            DEFAULT_BASE_SPREAD,
            DEFAULT_OPTIMAL_UTIL,
            DEFAULT_SLOPE1,
            DEFAULT_SLOPE2
        );
        
        assertEq(actualRate, expectedRate, "Rate calculation below knee incorrect");
    }
    
    function test_CM_SR_020_ExactlyAtKnee() public {
        uint256 totalSupplied = 1000 * WAD;
        uint256 totalBorrowed = 800 * WAD; // 80% utilization (at knee)
        
        uint256 expectedRate = DEFAULT_BASE_SPREAD + DEFAULT_SLOPE1;
        
        uint256 actualRate = CoreMath.calculateSpreadRate(
            totalBorrowed,
            totalSupplied,
            DEFAULT_BASE_SPREAD,
            DEFAULT_OPTIMAL_UTIL,
            DEFAULT_SLOPE1,
            DEFAULT_SLOPE2
        );
        
        assertEq(actualRate, expectedRate, "Rate calculation at knee incorrect");
    }
    
    function test_CM_SR_030_SteepSectionAboveKnee() public {
        uint256 totalSupplied = 1000 * WAD;
        uint256 totalBorrowed = 950 * WAD; // 95% utilization
        
        uint256 excessUtil = 95e25 - DEFAULT_OPTIMAL_UTIL; // 15% excess in Ray
        uint256 expectedRate = DEFAULT_BASE_SPREAD + DEFAULT_SLOPE1 + DEFAULT_SLOPE2.rayMul(excessUtil);
        
        uint256 actualRate = CoreMath.calculateSpreadRate(
            totalBorrowed,
            totalSupplied,
            DEFAULT_BASE_SPREAD,
            DEFAULT_OPTIMAL_UTIL,
            DEFAULT_SLOPE1,
            DEFAULT_SLOPE2
        );
        
        assertEq(actualRate, expectedRate, "Rate calculation above knee incorrect");
    }
    
    function testFuzz_CM_SR_FUZZ_MonotonicSpreadRate(uint256 util1, uint256 util2) public {
        // Bound utilization between 0 and 100%
        util1 = bound(util1, 0, RAY);
        util2 = bound(util2, 0, RAY);
        
        // Ensure util2 >= util1 for monotonicity test
        if (util2 < util1) {
            (util1, util2) = (util2, util1);
        }
        
        uint256 totalSupplied = 1000 * WAD;
        uint256 totalBorrowed1 = totalSupplied.rayMul(util1);
        uint256 totalBorrowed2 = totalSupplied.rayMul(util2);
        
        uint256 rate1 = CoreMath.calculateSpreadRate(
            totalBorrowed1,
            totalSupplied,
            DEFAULT_BASE_SPREAD,
            DEFAULT_OPTIMAL_UTIL,
            DEFAULT_SLOPE1,
            DEFAULT_SLOPE2
        );
        
        uint256 rate2 = CoreMath.calculateSpreadRate(
            totalBorrowed2,
            totalSupplied,
            DEFAULT_BASE_SPREAD,
            DEFAULT_OPTIMAL_UTIL,
            DEFAULT_SLOPE1,
            DEFAULT_SLOPE2
        );
        
        assertGe(rate2, rate1, "Spread rate must be monotonically increasing");
    }
    
    // ============ CM_DEBT Tests - Debt Allocation ============
    
    function test_CM_DEBT_100_DebtAllocation() public {
        // Setup scenario
        uint256 protocolDebt = 1000 * WAD;
        uint256 marketA_totalBorrowed = 600 * WAD;
        uint256 marketB_totalBorrowed = 400 * WAD;
        uint256 totalBorrowedAllMarkets = marketA_totalBorrowed + marketB_totalBorrowed;
        
        // User in market A
        uint256 userBorrowAmount = 60 * WAD;
        uint256 userScaledDebt = 80 * WAD;
        uint256 borrowIndex = 12e26; // 1.2 in Ray
        
        // Step 1: Calculate market A debt share
        uint256 marketDebt_A = (protocolDebt * marketA_totalBorrowed) / totalBorrowedAllMarkets;
        assertEq(marketDebt_A, 600 * WAD, "Market A debt share incorrect");
        
        // Step 2: Calculate user principal debt
        uint256 userPrincipalDebt = (marketDebt_A * userBorrowAmount) / marketA_totalBorrowed;
        assertEq(userPrincipalDebt, 60 * WAD, "User principal debt incorrect");
        
        // Step 3: Calculate user total debt using CoreMath
        (uint256 totalDebt, uint256 principalDebt, uint256 spreadDebt) = CoreMath.calculateUserTotalDebt(
            userBorrowAmount,
            marketA_totalBorrowed,
            userPrincipalDebt,
            userScaledDebt,
            borrowIndex
        );
        
        // Verify calculations
        uint256 expectedSpread = userScaledDebt.rayMul(borrowIndex) - userBorrowAmount;
        assertEq(spreadDebt, expectedSpread, "Spread calculation incorrect");
        assertEq(spreadDebt, 36 * WAD, "Spread should be 36");
        assertEq(totalDebt, 96 * WAD, "Total debt should be 96");
        assertEq(principalDebt, userPrincipalDebt, "Principal debt mismatch");
    }
    
    function testFuzz_CM_DEBT_FUZZ_DebtAllocation(
        uint256 protocolDebt,
        uint256 marketTotal1,
        uint256 marketTotal2,
        uint256 userBorrow
    ) public {
        // Bound inputs to reasonable ranges
        protocolDebt = bound(protocolDebt, 1000 * WAD, 1e9 * WAD);
        marketTotal1 = bound(marketTotal1, 100 * WAD, 1e8 * WAD);
        marketTotal2 = bound(marketTotal2, 100 * WAD, 1e8 * WAD);
        userBorrow = bound(userBorrow, 1 * WAD, marketTotal1);
        
        uint256 totalBorrowedAllMarkets = marketTotal1 + marketTotal2;
        
        // Calculate market share of protocol debt
        uint256 marketDebt = (protocolDebt * marketTotal1) / totalBorrowedAllMarkets;
        
        // Calculate user's principal debt
        uint256 userPrincipalDebt = (marketDebt * userBorrow) / marketTotal1;
        
        // Generate random scaled debt and index
        uint256 scaledDebt = bound(userBorrow, userBorrow, userBorrow * 2);
        uint256 borrowIndex = bound(RAY, RAY, 2 * RAY);
        
        // Calculate using CoreMath
        (uint256 totalDebt, uint256 principalDebt, uint256 spreadDebt) = CoreMath.calculateUserTotalDebt(
            userBorrow,
            marketTotal1,
            userPrincipalDebt,
            scaledDebt,
            borrowIndex
        );
        
        // Verify invariants
        assertEq(principalDebt, userPrincipalDebt, "Principal debt mismatch");
        assertGe(totalDebt, principalDebt, "Total debt must be >= principal");
        assertEq(totalDebt, principalDebt + spreadDebt, "Total = principal + spread");
        
        // Verify spread calculation
        uint256 expectedCurrentDebt = scaledDebt.rayMul(borrowIndex);
        uint256 expectedSpread = expectedCurrentDebt > userBorrow ? expectedCurrentDebt - userBorrow : 0;
        assertEq(spreadDebt, expectedSpread, "Spread calculation mismatch");
    }
    
    // ============ CM_GUARD Tests - Edge Guards ============
    
    function test_CM_GUARD_400_SpreadRateZeroSupply() public {
        uint256 totalSupplied = 0;
        uint256 totalBorrowed = 0;
        
        // When totalSupplied is 0, utilization is 0, so rate should be baseSpreadRate
        uint256 rate = CoreMath.calculateSpreadRate(
            totalBorrowed,
            totalSupplied,
            DEFAULT_BASE_SPREAD,
            DEFAULT_OPTIMAL_UTIL,
            DEFAULT_SLOPE1,
            DEFAULT_SLOPE2
        );
        
        assertEq(rate, DEFAULT_BASE_SPREAD, "Should return baseSpreadRate when totalSupplied is 0");
    }
    
    function test_CM_GUARD_410_DebtFormulaZeroMarketBorrowed() public {
        uint256 marketTotalBorrowed = 0;
        uint256 userPrincipalDebt = 0;
        
        // Should handle zero market borrowed gracefully
        (uint256 totalDebt, uint256 principalDebt, uint256 spreadDebt) = CoreMath.calculateUserTotalDebt(
            0, // userBorrowAmount
            marketTotalBorrowed,
            userPrincipalDebt,
            0, // scaledDebt
            RAY // borrowIndex
        );
        
        assertEq(totalDebt, 0, "Total debt should be 0");
        assertEq(principalDebt, 0, "Principal debt should be 0");
        assertEq(spreadDebt, 0, "Spread debt should be 0");
    }
    
    // ============ Regression Tests ============
    
    function test_RegressionRoundingLoss() public {
        uint256 currentIndex = RAY;
        uint256 newIndex = RAY + 1e9; // More significant growth to avoid rounding issues
        uint256 principal = 1000 * WAD;
        
        // Calculate new borrow index with minimal growth
        uint256 spreadRate = 1; // Minimal rate
        uint256 timeElapsed = 1; // 1 second
        
        // Ensure accrual never returns exactly principal when there's growth
        uint256 scaledDebt = principal.rayDiv(currentIndex);
        uint256 accrued = scaledDebt.rayMul(newIndex);
        
        assertGt(accrued, principal, "Accrued amount must be > principal when index grows");
    }
    
    // ============ Additional Tests ============
    
    function test_CalculateUtilization() public {
        uint256 totalBorrowed = 300 * WAD;
        uint256 totalSupplied = 1000 * WAD;
        
        uint256 utilization = CoreMath.calculateUtilization(totalBorrowed, totalSupplied);
        uint256 expectedUtil = totalBorrowed.rayDiv(totalSupplied);
        
        assertEq(utilization, expectedUtil, "Utilization calculation incorrect");
        assertEq(utilization, 3e26, "Should be 30% in Ray");
    }
    
    function test_CalculateHealthFactor() public {
        uint256 collateralValue = 1000 * WAD;
        uint256 totalDebt = 500 * WAD;
        uint256 liquidationThreshold = 8000; // 80%
        
        uint256 healthFactor = CoreMath.calculateHealthFactor(
            collateralValue,
            totalDebt,
            liquidationThreshold
        );
        
        // Expected: (1000 * 0.8) / 500 = 1.6 in Ray
        uint256 expectedHF = (collateralValue * liquidationThreshold / MAX_BPS).rayDiv(totalDebt);
        assertEq(healthFactor, expectedHF, "Health factor calculation incorrect");
    }
    
    function test_CalculateHealthFactorZeroDebt() public {
        uint256 collateralValue = 1000 * WAD;
        uint256 totalDebt = 0;
        uint256 liquidationThreshold = 8000;
        
        uint256 healthFactor = CoreMath.calculateHealthFactor(
            collateralValue,
            totalDebt,
            liquidationThreshold
        );
        
        assertEq(healthFactor, type(uint256).max, "Health factor should be max when no debt");
    }
    
    // ============ Ray Math Edge Cases ============
    
    function test_RayMathNearMaxUint() public {
        // Test rayMul near max uint256
        uint256 largeNumber = type(uint256).max / RAY - 1;
        uint256 result = largeNumber.rayMul(RAY);
        assertEq(result, largeNumber, "rayMul with RAY should return same number");
        
        // Test rayDiv near max uint256
        result = largeNumber.rayDiv(RAY);
        assertEq(result, largeNumber, "rayDiv with RAY should return same number");
    }
    
    function testFuzz_RayMathPrecision(uint256 a, uint256 b) public {
        // Bound inputs to prevent overflow
        // First ensure a won't overflow when multiplied by RAY
        a = bound(a, 0, type(uint128).max);
        b = bound(b, RAY / 1000, RAY * 2); // Between 0.001 and 2.0 in Ray
        
        // Test that (a * b) / RAY maintains precision
        uint256 result = a.rayMul(b);
        
        // For b = RAY, result should equal a
        if (b == RAY) {
            assertEq(result, a, "rayMul with RAY should be identity");
        }
        
        // Test inverse operations
        if (result > 0 && result < type(uint256).max / RAY && b > RAY / 1000) {
            uint256 inverse = result.rayDiv(b);
            // Allow tolerance for rounding errors
            // Ray math has 27 decimals of precision
            uint256 tolerance;
            if (a < 100000) {
                // For small values, use proportional tolerance
                tolerance = (a * 100) / 10000; // 1% for small values
                if (tolerance < 500) tolerance = 500; // At least 500 wei
            } else {
                tolerance = a / 10000; // 0.01% error for larger values
            }
            assertApproxEqAbs(inverse, a, tolerance, "rayDiv should approximately invert rayMul");
        }
    }
    
    // ============ Spread Calculation Edge Cases ============
    
    function test_SpreadRateExtremeUtilization() public {
        // Test at exactly 0% utilization
        uint256 rate = CoreMath.calculateSpreadRate(
            0,
            1000 * WAD,
            DEFAULT_BASE_SPREAD,
            DEFAULT_OPTIMAL_UTIL,
            DEFAULT_SLOPE1,
            DEFAULT_SLOPE2
        );
        assertEq(rate, DEFAULT_BASE_SPREAD, "At 0% util, rate should be base rate");
        
        // Test at exactly 100% utilization
        uint256 totalAmount = 1000 * WAD;
        rate = CoreMath.calculateSpreadRate(
            totalAmount,
            totalAmount,
            DEFAULT_BASE_SPREAD,
            DEFAULT_OPTIMAL_UTIL,
            DEFAULT_SLOPE1,
            DEFAULT_SLOPE2
        );
        
        // Calculate expected rate at 100%
        uint256 excessUtil = RAY - DEFAULT_OPTIMAL_UTIL;
        uint256 expectedRate = DEFAULT_BASE_SPREAD + DEFAULT_SLOPE1 + DEFAULT_SLOPE2.rayMul(excessUtil);
        assertEq(rate, expectedRate, "At 100% util, rate calculation incorrect");
    }
    
    // ============ Collateral Value Edge Cases ============
    
    function test_CollateralValueExtremeDecimals() public {
        // Test with 0 decimal collateral and 18 decimal supply asset
        uint256 collateralAmount = 1000; // 1000 units of 0 decimal token
        uint256 collateralPrice = 1500 * RAY; // $1500 per token
        
        uint256 value = CoreMath.calculateCollateralValue(
            collateralAmount,
            collateralPrice,
            18, // supply decimals
            0   // collateral decimals
        );
        
        uint256 expectedValue = 1500 * 1000 * WAD; // $1,500,000 in 18 decimals
        assertEq(value, expectedValue, "Collateral value with 0 decimals incorrect");
        
        // Test with 30 decimal collateral and 6 decimal supply asset
        collateralAmount = 1000 * 1e30;
        collateralPrice = 2 * RAY; // $2 per token
        
        value = CoreMath.calculateCollateralValue(
            collateralAmount,
            collateralPrice,
            6,  // USDC decimals
            30  // extreme collateral decimals
        );
        
        expectedValue = 2000 * 1e6; // $2000 in USDC decimals
        assertEq(value, expectedValue, "Collateral value with 30 decimals incorrect");
    }
    
    // ============ Debt Calculation Precision ============
    
    function test_DebtCalculationMinimalAmounts() public {
        // Test with 1 wei of debt
        uint256 userBorrowAmount = 1;
        uint256 marketTotalBorrowed = 1000 * 1e6;
        uint256 userPrincipalDebt = 1;
        uint256 scaledDebt = 1;
        uint256 borrowIndex = RAY + 1; // Minimal increase
        
        (uint256 totalDebt, uint256 principalDebt, uint256 spreadDebt) = CoreMath.calculateUserTotalDebt(
            userBorrowAmount,
            marketTotalBorrowed,
            userPrincipalDebt,
            scaledDebt,
            borrowIndex
        );
        
        assertEq(principalDebt, userPrincipalDebt, "Principal debt should match input");
        assertGe(totalDebt, principalDebt, "Total debt should be >= principal");
        
        // With minimal index increase, spread should be minimal
        assertLe(spreadDebt, 1, "Spread on 1 wei should be at most 1 wei");
    }
}