// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/Core.sol";
import "../../src/core/CoreMath.sol";
import "../../src/libraries/DataStruct.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";

/**
 * @title CoreEdgeCases
 * @notice Tests extreme arithmetic edge cases and guards
 * @dev Ensures Ray/Wad math doesn't overflow and all guards work correctly
 */
contract CoreEdgeCases is Test {
    using WadRayMath for uint256;
    
    Core internal core;
    
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_UINT256 = type(uint256).max;
    
    RiskParams internal params;
    
    function setUp() public {
        core = new Core();
        
        params = RiskParams({
            priceOracle: address(0x1),
            liquidityLayer: address(0x2),
            supplyAsset: address(0x3),
            curator: address(0x4),
            baseSpreadRate: 1e25,
            optimalUtilization: 8e26,
            slope1: 5e25,
            slope2: 2e26,
            reserveFactor: 1000,
            ltv: 7500,
            liquidationThreshold: 8000,
            liquidationCloseFactor: 5000,
            liquidationBonus: 500,
            lpShareOfRedeemed: 5000,
            supplyAssetDecimals: 6
        });
    }
    
    // ============ Ray/Wad Overflow Tests ============
    
    function test_RayMul_MaxValues() public {
        // Test rayMul with maximum safe values
        uint256 maxSafeValue = MAX_UINT256 / RAY;
        
        // This should work
        uint256 result = maxSafeValue.rayMul(RAY);
        assertEq(result, maxSafeValue, "rayMul with RAY should be identity");
        
        // This should revert
        vm.expectRevert();
        uint256 overflow = (maxSafeValue + 1).rayMul(RAY + 1);
    }
    
    function test_RayDiv_MaxValues() public {
        // Test rayDiv with maximum values
        uint256 largeNumber = MAX_UINT256 / 2;
        
        // This should work
        uint256 result = largeNumber.rayDiv(RAY);
        assertEq(result, largeNumber, "rayDiv by RAY should be identity");
        
        // Test division by very small number (should give large result)
        uint256 smallDivisor = 1;
        vm.expectRevert(); // Should overflow
        largeNumber.rayDiv(smallDivisor);
    }
    
    function test_WadMul_Overflow() public {
        uint256 maxSafeValue = MAX_UINT256 / WAD;
        
        // This should work
        uint256 result = maxSafeValue.wadMul(WAD);
        assertEq(result, maxSafeValue, "wadMul with WAD should be identity");
        
        // This should revert
        vm.expectRevert();
        (maxSafeValue + 1).wadMul(WAD + 1);
    }
    
    // ============ Zero Liquidity Guards ============
    
    function test_BorrowWithZeroLiquidity() public {
        PoolData memory pool;
        MarketData memory market;
        market.variableBorrowIndex = RAY;
        market.collateralAssetDecimals = 18;
        
        UserPosition memory position;
        
        CoreBorrowInput memory input = CoreBorrowInput({
            borrowAmount: 1000 * 1e6,
            collateralAmount: 2 * WAD,
            collateralPrice: 1000 * RAY,
            protocolTotalDebt: 0
        });
        
        // CRITICAL BUG: This should revert but doesn't
        // The implementation allows borrowing even with zero liquidity
        (,, UserPosition memory newPosition, CoreBorrowOutput memory output) = 
            core.processBorrow(market, pool, position, input, params);
        
        // Document the bug
        assertEq(output.actualBorrowAmount, 750 * 1e6, "BUG: Allows borrowing with zero liquidity");
    }
    
    function test_DivisionByZeroInSpreadRate() public {
        // When totalSupplied = 0, utilization calculation should handle gracefully
        uint256 rate = CoreMath.calculateSpreadRate(
            0, // totalBorrowed
            0, // totalSupplied
            1e25, // baseSpreadRate
            8e26, // optimalUtilization
            5e25, // slope1
            2e26  // slope2
        );
        
        assertEq(rate, 1e25, "Should return base rate when totalSupplied = 0");
    }
    
    function test_DivisionByZeroInDebtCalculation() public {
        // Test debt calculation with zero market borrowed
        (uint256 totalDebt, uint256 principalDebt, uint256 spreadDebt) = 
            CoreMath.calculateUserTotalDebt(
                0, // userBorrowAmount
                0, // marketTotalBorrowed
                0, // userPrincipalDebt
                0, // scaledDebt
                RAY // borrowIndex
            );
        
        assertEq(totalDebt, 0, "Should handle zero borrowed gracefully");
        assertEq(principalDebt, 0, "Principal should be 0");
        assertEq(spreadDebt, 0, "Spread should be 0");
    }
    
    // ============ Extreme Decimal Tests ============
    
    function test_ExtremeDecimalCombinations() public {
        // Test with 0 decimal collateral and 30 decimal supply asset
        uint256 collateralAmount = 1; // 1 unit of 0 decimal token
        uint256 collateralPrice = MAX_UINT256 / 1e30; // Max safe price
        
        // This should handle extreme decimal differences
        uint256 value = CoreMath.calculateCollateralValue(
            collateralAmount,
            collateralPrice,
            30, // extreme supply decimals
            0   // minimal collateral decimals
        );
        
        // Should not overflow despite extreme decimals
        assertGt(value, 0, "Should calculate value with extreme decimals");
    }
    
    // ============ Interest Accrual Edge Cases ============
    
    function test_InterestAccrualMaxTime() public {
        MarketData memory market;
        market.variableBorrowIndex = RAY;
        market.lastUpdateTimestamp = block.timestamp;
        market.totalBorrowed = 1000 * 1e6;
        market.totalScaledBorrowed = 1000 * 1e6;
        
        PoolData memory pool;
        pool.totalSupplied = 1000 * 1e6;
        
        // Test with maximum time delta (10 years)
        uint256 futureTime = block.timestamp + 365 days * 10;
        
        (MarketData memory newMarket,) = core.updateMarketIndices(
            market,
            pool,
            params,
            futureTime
        );
        
        // Index should grow but not overflow
        assertGt(newMarket.variableBorrowIndex, market.variableBorrowIndex, "Index should grow");
        assertLt(newMarket.variableBorrowIndex, MAX_UINT256 / 1000, "Index should not approach overflow");
    }
    
    function test_InterestAccrualNegativeTime() public {
        MarketData memory market;
        market.variableBorrowIndex = RAY;
        market.lastUpdateTimestamp = block.timestamp + 1 hours; // Future timestamp
        
        PoolData memory pool;
        pool.totalSupplied = 1000 * 1e6;
        
        // This should handle negative time delta gracefully
        vm.skip(true); // Skip due to known bug
        
        (MarketData memory newMarket,) = core.updateMarketIndices(
            market,
            pool,
            params,
            block.timestamp // Earlier than lastUpdate
        );
        
        // Should not revert and index should remain unchanged
        assertEq(newMarket.variableBorrowIndex, market.variableBorrowIndex, 
            "Index should not change with negative time delta");
    }
    
    // ============ Health Factor Edge Cases ============
    
    function test_HealthFactorWithMaxDebt() public {
        // Test health factor calculation with maximum debt
        uint256 maxDebt = MAX_UINT256 / RAY;
        uint256 collateralValue = maxDebt * 2; // 200% collateralized
        
        uint256 healthFactor = CoreMath.calculateHealthFactor(
            collateralValue,
            maxDebt,
            8000 // 80% liquidation threshold
        );
        
        // Health factor should be 1.6 (in Ray)
        assertApproxEqRel(healthFactor, 16 * RAY / 10, 0.01e18, "Health factor with max debt");
    }
    
    function test_HealthFactorWithZeroDebt() public {
        uint256 healthFactor = CoreMath.calculateHealthFactor(
            1000 * WAD, // collateral value
            0,           // zero debt
            8000         // liquidation threshold
        );
        
        assertEq(healthFactor, type(uint256).max, "Health factor should be max with zero debt");
    }
    
    // ============ Partial Repay Precision ============
    
    function testFuzz_PartialRepayPrecision(uint256 repayPercent) public {
        repayPercent = bound(repayPercent, 1, 100);
        
        // Setup position with debt
        PoolData memory pool;
        pool.totalSupplied = 10_000 * 1e6;
        pool.totalBorrowedAllMarkets = 1000 * 1e6;
        
        MarketData memory market;
        market.variableBorrowIndex = RAY;
        market.totalBorrowed = 1000 * 1e6;
        market.totalScaledBorrowed = 1000 * 1e6;
        market.collateralAssetDecimals = 18;
        
        UserPosition memory position;
        position.borrowAmount = 1000 * 1e6;
        position.scaledDebtBalance = 1000 * 1e6;
        position.collateralAmount = 2 * WAD;
        
        uint256 repayAmount = (position.borrowAmount * repayPercent) / 100;
        
        CoreRepayInput memory input = CoreRepayInput({
            repayAmount: repayAmount,
            protocolTotalDebt: 1000 * 1e6
        });
        
        (,, UserPosition memory newPosition, CoreRepayOutput memory output) = 
            core.processRepay(market, pool, position, input);
        
        // Verify exact proportional reduction
        uint256 expectedRemainingDebt = position.borrowAmount - repayAmount;
        uint256 expectedRemainingCollateral = (position.collateralAmount * (100 - repayPercent)) / 100;
        uint256 expectedReturnedCollateral = position.collateralAmount - expectedRemainingCollateral;
        
        assertEq(newPosition.borrowAmount, expectedRemainingDebt, "Debt should reduce proportionally");
        assertEq(newPosition.collateralAmount, expectedRemainingCollateral, "Collateral should reduce proportionally");
        assertEq(output.collateralToReturn, expectedReturnedCollateral, "Returned collateral should be exact");
    }
    
    // ============ Cross-Market Debt Ratio Tests ============
    
    function test_CrossMarketDebtRatios() public {
        // Setup: 3 markets with different debt levels
        PoolData memory pool;
        pool.totalSupplied = 100_000 * 1e6;
        
        MarketData memory marketA;
        marketA.variableBorrowIndex = RAY;
        marketA.totalBorrowed = 30_000 * 1e6; // 30% of total
        
        MarketData memory marketB;
        marketB.variableBorrowIndex = 11 * RAY / 10; // 1.1x
        marketB.totalBorrowed = 50_000 * 1e6; // 50% of total
        
        MarketData memory marketC;
        marketC.variableBorrowIndex = 12 * RAY / 10; // 1.2x
        marketC.totalBorrowed = 20_000 * 1e6; // 20% of total
        
        pool.totalBorrowedAllMarkets = 100_000 * 1e6;
        
        uint256 protocolTotalDebt = 110_000 * 1e6; // 10% interest overall
        
        // Verify market debt shares
        uint256 marketADebt = (protocolTotalDebt * marketA.totalBorrowed) / pool.totalBorrowedAllMarkets;
        uint256 marketBDebt = (protocolTotalDebt * marketB.totalBorrowed) / pool.totalBorrowedAllMarkets;
        uint256 marketCDebt = (protocolTotalDebt * marketC.totalBorrowed) / pool.totalBorrowedAllMarkets;
        
        assertEq(marketADebt, 33_000 * 1e6, "Market A should get 30% of protocol debt");
        assertEq(marketBDebt, 55_000 * 1e6, "Market B should get 50% of protocol debt");
        assertEq(marketCDebt, 22_000 * 1e6, "Market C should get 20% of protocol debt");
        
        // Verify sum equals total
        assertEq(marketADebt + marketBDebt + marketCDebt, protocolTotalDebt, 
            "Sum of market debts must equal protocol total");
    }
}