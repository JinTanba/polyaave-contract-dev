// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/Core.sol";
import "../../src/core/CoreMath.sol";
import "../../src/libraries/DataStruct.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract CoreTest is Test {
    using WadRayMath for uint256;
    
    Core internal core;
    
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant USDC_DECIMALS = 6;
    uint256 internal constant COLLATERAL_DECIMALS = 18;
    
    // Default risk parameters
    RiskParams internal defaultParams;
    
    function setUp() public {
        core = new Core();
        
        defaultParams = RiskParams({
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
            supplyAssetDecimals: USDC_DECIMALS
        });
    }
    
    // ============ CR_SUP Tests - Process Supply ============
    
    function test_CR_SUP_200_ProcessSupplyEmptyPool() public {
        PoolData memory pool;
        CoreSupplyInput memory input = CoreSupplyInput({
            userLPBalance: 0,
            supplyAmount: 500 * 1e6 // 500 USDC
        });
        
        (PoolData memory newPool, CoreSupplyOutput memory output) = core.processSupply(pool, input);
        
        assertEq(newPool.totalSupplied, 500 * 1e6, "Pool totalSupplied incorrect");
        assertEq(output.newUserLPBalance, 500 * 1e6, "User LP balance incorrect");
        assertEq(output.lpTokensToMint, 500 * 1e6, "LP tokens minted incorrect");
    }
    
    function testFuzz_ProcessSupply(uint256 initialSupply, uint256 supplyAmount) public {
        initialSupply = bound(initialSupply, 0, 1e12 * 1e6); // Up to 1 trillion USDC
        supplyAmount = bound(supplyAmount, 1, 1e9 * 1e6); // 1 to 1 billion USDC
        
        PoolData memory pool;
        pool.totalSupplied = initialSupply;
        
        CoreSupplyInput memory input = CoreSupplyInput({
            userLPBalance: 100 * 1e6,
            supplyAmount: supplyAmount
        });
        
        (PoolData memory newPool, CoreSupplyOutput memory output) = core.processSupply(pool, input);
        
        assertEq(newPool.totalSupplied, initialSupply + supplyAmount, "Pool totalSupplied incorrect");
        assertEq(output.lpTokensToMint, supplyAmount, "LP tokens should be 1:1");
        assertEq(output.newUserLPBalance, 100 * 1e6 + supplyAmount, "User balance incorrect");
    }
    
    // ============ CR_BR Tests - Borrow/Repay Round-trip ============
    
    function test_CR_BR_300_BorrowRepayRoundTrip() public {
        // Step 1: Setup initial pool with liquidity
        PoolData memory pool;
        pool.totalSupplied = 1000 * 1e6; // 1000 USDC supplied
        
        // Step 2: Setup market
        MarketData memory market;
        market.variableBorrowIndex = RAY;
        market.collateralAssetDecimals = COLLATERAL_DECIMALS;
        market.lastUpdateTimestamp = block.timestamp;
        
        // Step 3: User adds collateral and borrows
        UserPosition memory position;
        CoreBorrowInput memory borrowInput = CoreBorrowInput({
            borrowAmount: 400 * 1e6, // 400 USDC
            collateralAmount: 1 * WAD, // 1 collateral token
            collateralPrice: 800 * RAY, // $800 per token in Ray
            protocolTotalDebt: 0
        });
        
        (MarketData memory marketAfterBorrow, 
         PoolData memory poolAfterBorrow, 
         UserPosition memory positionAfterBorrow,
         CoreBorrowOutput memory borrowOutput) = core.processBorrow(
            market, 
            pool, 
            position, 
            borrowInput, 
            defaultParams
        );
        
        // Verify borrow state
        assertEq(marketAfterBorrow.totalBorrowed, 400 * 1e6, "Market totalBorrowed incorrect");
        assertEq(poolAfterBorrow.totalBorrowedAllMarkets, 400 * 1e6, "Pool totalBorrowedAllMarkets incorrect");
        assertEq(positionAfterBorrow.borrowAmount, 400 * 1e6, "User borrowAmount incorrect");
        assertEq(borrowOutput.actualBorrowAmount, 400 * 1e6, "Actual borrow amount incorrect");
        
        // Verify accounting invariant
        assertEq(marketAfterBorrow.totalBorrowed, poolAfterBorrow.totalBorrowedAllMarkets, 
            "Invariant: sum(market.totalBorrowed) == pool.totalBorrowedAllMarkets");
        
        // Step 4: Immediately repay full debt
        CoreRepayInput memory repayInput = CoreRepayInput({
            repayAmount: 400 * 1e6,
            protocolTotalDebt: 400 * 1e6 // Assume no interest accrued yet
        });
        
        (MarketData memory marketAfterRepay,
         PoolData memory poolAfterRepay,
         UserPosition memory positionAfterRepay,
         CoreRepayOutput memory repayOutput) = core.processRepay(
            marketAfterBorrow,
            poolAfterBorrow,
            positionAfterBorrow,
            repayInput
        );
        
        // Verify repay state
        assertEq(positionAfterRepay.borrowAmount, 0, "User debt should be 0");
        assertEq(positionAfterRepay.scaledDebtBalance, 0, "Scaled debt should be 0");
        assertEq(positionAfterRepay.collateralAmount, 0, "Collateral should be returned");
        assertEq(marketAfterRepay.totalBorrowed, 0, "Market totalBorrowed should be 0");
        assertEq(poolAfterRepay.totalBorrowedAllMarkets, 0, "Pool totalBorrowedAllMarkets should be 0");
        assertEq(repayOutput.collateralToReturn, 1 * WAD, "All collateral should be returned");
    }
    
    // ============ Invariant Tests ============
    
    function testFuzz_InvariantSuite(uint256 seed) public {
        // Initialize random state
        uint256 numMarkets = (seed % 5) + 1; // 1 to 5 markets
        uint256 numUsers = 10;
        uint256 totalSupply = 10_000_000 * 1e6; // 10M USDC
        
        // Setup pool
        PoolData memory pool;
        pool.totalSupplied = totalSupply;
        
        // Track markets
        MarketData[] memory markets = new MarketData[](numMarkets);
        uint256[] memory marketBorrowTotals = new uint256[](numMarkets);
        
        // Initialize markets
        for (uint i = 0; i < numMarkets; i++) {
            markets[i].variableBorrowIndex = RAY;
            markets[i].collateralAssetDecimals = COLLATERAL_DECIMALS;
            markets[i].lastUpdateTimestamp = block.timestamp;
        }
        
        // Simulate random operations
        uint256 totalLPBalance = totalSupply; // Initial LP balance equals supply
        uint256 totalBorrowedCheck = 0;
        
        for (uint i = 0; i < 30; i++) {
            uint256 operation = uint256(keccak256(abi.encode(seed, i))) % 3;
            uint256 marketIdx = uint256(keccak256(abi.encode(seed, i, "market"))) % numMarkets;
            uint256 userIdx = uint256(keccak256(abi.encode(seed, i, "user"))) % numUsers;
            
            if (operation == 0 && pool.totalSupplied < type(uint128).max) {
                // Supply operation
                uint256 supplyAmount = bound(
                    uint256(keccak256(abi.encode(seed, i, "supply"))), 
                    1000 * 1e6, 
                    1_000_000 * 1e6
                );
                
                CoreSupplyInput memory input = CoreSupplyInput({
                    userLPBalance: 0,
                    supplyAmount: supplyAmount
                });
                
                (pool, ) = core.processSupply(pool, input);
                totalLPBalance += supplyAmount;
                
            } else if (operation == 1 && pool.totalSupplied > pool.totalBorrowedAllMarkets) {
                // Borrow operation
                uint256 availableLiquidity = pool.totalSupplied - pool.totalBorrowedAllMarkets;
                if (availableLiquidity >= 2 * 1e6) { // Only borrow if at least 2 USDC available
                    uint256 borrowAmount = bound(
                        uint256(keccak256(abi.encode(seed, i, "borrow"))),
                        1 * 1e6,
                        availableLiquidity / 2
                    );
                
                UserPosition memory position;
                CoreBorrowInput memory borrowInput = CoreBorrowInput({
                    borrowAmount: borrowAmount,
                    collateralAmount: borrowAmount * 2, // Over-collateralized
                    collateralPrice: RAY, // $1 per token for simplicity
                    protocolTotalDebt: pool.totalBorrowedAllMarkets
                });
                
                (markets[marketIdx], pool, position, ) = core.processBorrow(
                    markets[marketIdx],
                    pool,
                    position,
                    borrowInput,
                    defaultParams
                );
                
                    marketBorrowTotals[marketIdx] = markets[marketIdx].totalBorrowed;
                }
                
            } else if (operation == 2 && pool.totalBorrowedAllMarkets > 0) {
                // Partial repay operation
                if (markets[marketIdx].totalBorrowed > 1) { // Only repay if more than 1 wei borrowed
                    uint256 repayAmount = bound(
                        uint256(keccak256(abi.encode(seed, i, "repay"))),
                        1,
                        markets[marketIdx].totalBorrowed / 2
                    );
                    
                    UserPosition memory position;
                    position.borrowAmount = repayAmount;
                    position.scaledDebtBalance = repayAmount.rayDiv(markets[marketIdx].variableBorrowIndex);
                    
                    CoreRepayInput memory repayInput = CoreRepayInput({
                        repayAmount: repayAmount,
                        protocolTotalDebt: pool.totalBorrowedAllMarkets
                    });
                    
                    (markets[marketIdx], pool, position, ) = core.processRepay(
                        markets[marketIdx],
                        pool,
                        position,
                        repayInput
                    );
                    
                    marketBorrowTotals[marketIdx] = markets[marketIdx].totalBorrowed;
                }
            }
            
            // Verify invariants after each operation
            totalBorrowedCheck = 0;
            for (uint j = 0; j < numMarkets; j++) {
                totalBorrowedCheck += markets[j].totalBorrowed;
            }
            
            // Key invariants
            assertEq(totalBorrowedCheck, pool.totalBorrowedAllMarkets, 
                "Invariant: sum(market.totalBorrowed) == pool.totalBorrowedAllMarkets");
            assertLe(pool.totalBorrowedAllMarkets, pool.totalSupplied,
                "Invariant: totalBorrowedAllMarkets <= totalSupplied");
            assertEq(totalLPBalance, pool.totalSupplied,
                "Invariant: sum(lpBalances) == pool.totalSupplied");
        }
    }
    
    // ============ Additional Core Tests ============
    
    function test_UpdateMarketIndices() public {
        MarketData memory market;
        market.lastUpdateTimestamp = 0; // Uninitialized
        
        PoolData memory pool;
        pool.totalSupplied = 1000 * 1e6;
        
        uint256 currentTime = 1000;
        
        (MarketData memory newMarket, PoolData memory newPool) = core.updateMarketIndices(
            market,
            pool,
            defaultParams,
            currentTime
        );
        
        assertEq(newMarket.variableBorrowIndex, RAY, "Initial index should be RAY");
        assertEq(newMarket.lastUpdateTimestamp, currentTime, "Timestamp should be updated");
    }
    
    function test_UpdateMarketIndicesWithBorrows() public {
        MarketData memory market;
        market.variableBorrowIndex = RAY;
        market.lastUpdateTimestamp = 1000;
        market.totalBorrowed = 500 * 1e6;
        market.totalScaledBorrowed = 500 * 1e6; // Scaled at RAY
        
        PoolData memory pool;
        pool.totalSupplied = 1000 * 1e6;
        
        uint256 currentTime = 1000 + 365 days; // 1 year later
        
        (MarketData memory newMarket, PoolData memory newPool) = core.updateMarketIndices(
            market,
            pool,
            defaultParams,
            currentTime
        );
        
        assertGt(newMarket.variableBorrowIndex, RAY, "Index should increase over time");
        assertGt(newMarket.accumulatedSpread, 0, "Spread should accumulate");
        assertEq(newMarket.accumulatedSpread, newPool.totalAccumulatedSpread, "Pool spread should match");
    }
    
    function test_GetUserDebt() public {
        MarketData memory market;
        market.variableBorrowIndex = 11e26; // 1.1 in Ray
        market.totalBorrowed = 1000 * 1e6;
        
        PoolData memory pool;
        pool.totalBorrowedAllMarkets = 2000 * 1e6;
        
        UserPosition memory position;
        position.borrowAmount = 100 * 1e6;
        position.scaledDebtBalance = 100 * 1e6 * RAY / 1e27; // Initially scaled at 1.0
        
        uint256 protocolTotalDebt = 2200 * 1e6; // 10% interest on protocol level
        
        (uint256 totalDebt, uint256 principalDebt, uint256 spreadDebt) = core.getUserDebt(
            market,
            pool,
            position,
            protocolTotalDebt
        );
        
        // Market gets 50% of protocol debt (1000/2000)
        // User gets 10% of market debt (100/1000)
        uint256 expectedPrincipal = 110 * 1e6; // 2200 * 0.5 * 0.1 = 110
        assertEq(principalDebt, expectedPrincipal, "Principal debt calculation incorrect");
        
        // Spread = (scaledDebt * 1.1) - borrowAmount = 110 - 100 = 10
        assertEq(spreadDebt, 10 * 1e6, "Spread debt calculation incorrect");
        assertEq(totalDebt, principalDebt + spreadDebt, "Total debt should be principal + spread");
    }
    
    function test_ProcessBorrowMaxLTV() public {
        PoolData memory pool;
        pool.totalSupplied = 1000 * 1e6;
        
        MarketData memory market;
        market.variableBorrowIndex = RAY;
        market.collateralAssetDecimals = COLLATERAL_DECIMALS;
        
        UserPosition memory position;
        
        // Collateral worth $1000, LTV 75% = max borrow $750
        CoreBorrowInput memory input = CoreBorrowInput({
            borrowAmount: 1000 * 1e6, // Try to borrow $1000
            collateralAmount: 1 * WAD,
            collateralPrice: 1000 * RAY, // $1000 per token in Ray
            protocolTotalDebt: 0
        });
        
        (, , , CoreBorrowOutput memory output) = core.processBorrow(
            market,
            pool,
            position,
            input,
            defaultParams
        );
        
        // Should be capped at $750 (75% LTV)
        assertEq(output.actualBorrowAmount, 750 * 1e6, "Borrow should be capped by LTV");
    }
    
    function test_HealthFactorCalculation() public {
        MarketData memory market;
        market.variableBorrowIndex = RAY;
        market.totalBorrowed = 500 * 1e6;
        market.collateralAssetDecimals = COLLATERAL_DECIMALS;
        
        PoolData memory pool;
        pool.totalBorrowedAllMarkets = 500 * 1e6;
        
        UserPosition memory position;
        position.collateralAmount = 1 * WAD;
        position.borrowAmount = 500 * 1e6;
        position.scaledDebtBalance = 500 * 1e6;
        
        uint256 collateralPrice = 800 * RAY; // $800 per token in Ray
        uint256 protocolTotalDebt = 500 * 1e6;
        
        uint256 healthFactor = core.getUserHealthFactor(
            market,
            pool,
            position,
            collateralPrice,
            protocolTotalDebt,
            defaultParams
        );
        
        // Collateral value: $800
        // Liquidation threshold: 80% = $640
        // Debt: $500
        // Health factor: 640/500 = 1.28 in Ray
        uint256 expectedHF = (640 * 1e6 * RAY) / (500 * 1e6); // Convert to Ray
        assertEq(healthFactor, expectedHF, "Health factor calculation incorrect");
    }
    
    // ============ Resolution Tests ============
    
    function test_ProcessResolution() public {
        MarketData memory market;
        market.variableBorrowIndex = 12e26; // 1.2 in Ray
        market.totalBorrowed = 1000 * 1e6;
        market.totalScaledBorrowed = (1000 * 1e6 * RAY) / RAY; // Scaled at 1.0 initially
        
        PoolData memory pool;
        pool.totalSupplied = 2000 * 1e6;
        
        ResolutionData memory resolution;
        
        CoreResolutionInput memory input = CoreResolutionInput({
            totalCollateralRedeemed: 1500 * 1e6, // $1500 redeemed
            liquidityLayerDebt: 1000 * 1e6 // $1000 owed to Aave
        });
        
        (MarketData memory newMarket, 
         PoolData memory newPool, 
         ResolutionData memory newResolution) = core.processResolution(
            market,
            pool,
            resolution,
            input,
            defaultParams
        );
        
        // Verify resolution state
        assertTrue(newResolution.isMarketResolved, "Market should be resolved");
        assertEq(newResolution.totalCollateralRedeemed, 1500 * 1e6, "Total redeemed incorrect");
        assertEq(newResolution.liquidityRepaid, 1000 * 1e6, "Should repay full liquidity debt");
        
        // Remaining $500 should be distributed
        uint256 expectedSpread = 200 * 1e6; // Rough estimate based on 1.2x index
        uint256 protocolShare = expectedSpread * 1000 / 10000; // 10% reserve factor
        uint256 lpShare = expectedSpread - protocolShare;
        
        assertGt(newResolution.protocolPool, 0, "Protocol should get spread share");
        assertGt(newResolution.lpPool, lpShare, "LPs should get spread + excess share");
        assertGt(newResolution.borrowerPool, 0, "Borrowers should get rebate");
        
        // Verify total distribution
        uint256 totalDistributed = newResolution.liquidityRepaid + 
                                  newResolution.protocolPool + 
                                  newResolution.lpPool + 
                                  newResolution.borrowerPool;
        assertEq(totalDistributed, input.totalCollateralRedeemed, "All funds should be distributed");
    }
    
    // ============ Additional Scenario Tests ============
    
    /**
     * @notice Test cross-market interactions
     */
    function test_CrossMarketBorrowing() public {
        // Setup two markets with different parameters
        MarketData memory marketA;
        marketA.variableBorrowIndex = RAY;
        marketA.collateralAssetDecimals = 18;
        marketA.lastUpdateTimestamp = block.timestamp;
        
        MarketData memory marketB;
        marketB.variableBorrowIndex = RAY;
        marketB.collateralAssetDecimals = 8; // Different decimals
        marketB.lastUpdateTimestamp = block.timestamp;
        
        PoolData memory pool;
        pool.totalSupplied = 100_000 * 1e6; // 100k USDC
        
        // User borrows in market A
        UserPosition memory positionA;
        CoreBorrowInput memory borrowInputA = CoreBorrowInput({
            borrowAmount: 10_000 * 1e6,
            collateralAmount: 10 * WAD,
            collateralPrice: 2000 * RAY,
            protocolTotalDebt: 0
        });
        
        (marketA, pool, positionA,) = core.processBorrow(
            marketA, pool, positionA, borrowInputA, defaultParams
        );
        
        // User borrows in market B
        UserPosition memory positionB;
        CoreBorrowInput memory borrowInputB = CoreBorrowInput({
            borrowAmount: 5_000 * 1e6,
            collateralAmount: 50_000 * 1e8, // 50k tokens with 8 decimals
            collateralPrice: RAY / 5, // $0.20 per token
            protocolTotalDebt: pool.totalBorrowedAllMarkets
        });
        
        (marketB, pool, positionB,) = core.processBorrow(
            marketB, pool, positionB, borrowInputB, defaultParams
        );
        
        // Verify pool aggregates
        assertEq(pool.totalBorrowedAllMarkets, 15_000 * 1e6, "Total borrowed should be sum of both markets");
        assertEq(marketA.totalBorrowed + marketB.totalBorrowed, pool.totalBorrowedAllMarkets, 
            "Market totals should sum to pool total");
    }
    
    /**
     * @notice Test liquidation with price shock
     */
    function test_LiquidationPriceShock() public {
        PoolData memory pool;
        pool.totalSupplied = 100_000 * 1e6;
        
        MarketData memory market;
        market.variableBorrowIndex = RAY;
        market.collateralAssetDecimals = COLLATERAL_DECIMALS;
        
        // User borrows at 75% LTV
        UserPosition memory position;
        uint256 initialPrice = 1000 * RAY;
        CoreBorrowInput memory borrowInput = CoreBorrowInput({
            borrowAmount: 750 * 1e6,
            collateralAmount: 1 * WAD,
            collateralPrice: initialPrice,
            protocolTotalDebt: 0
        });
        
        (market, pool, position,) = core.processBorrow(
            market, pool, position, borrowInput, defaultParams
        );
        
        // Price drops 25% - should trigger liquidation
        uint256 shockedPrice = 750 * RAY;
        
        // Check health factor
        uint256 healthFactor = core.getUserHealthFactor(
            market, pool, position, shockedPrice, 750 * 1e6, defaultParams
        );
        
        assertLt(healthFactor, RAY, "Health factor should be below 1 after price shock");
        
        // Attempt liquidation
        CoreLiquidationInput memory liquidationInput = CoreLiquidationInput({
            repayAmount: 375 * 1e6, // 50% of debt
            collateralPrice: shockedPrice,
            protocolTotalDebt: 750 * 1e6
        });
        
        (,, UserPosition memory newPosition, CoreLiquidationOutput memory liquidationOutput) = 
            core.processLiquidation(market, pool, position, liquidationInput, defaultParams);
        
        // actualRepayAmount includes interest, so it will be higher than requested
        assertGe(liquidationOutput.actualRepayAmount, 375 * 1e6, "Should liquidate at least requested amount");
        assertGt(liquidationOutput.collateralSeized, 0, "Should seize collateral");
        assertLt(newPosition.borrowAmount, position.borrowAmount, "Debt should decrease");
    }
    
    /**
     * @notice Test gas usage for hot paths
     */
    function test_GasBenchmarks() public {
        PoolData memory pool;
        pool.totalSupplied = 1_000_000 * 1e6;
        
        MarketData memory market;
        market.variableBorrowIndex = RAY;
        market.collateralAssetDecimals = COLLATERAL_DECIMALS;
        
        // Benchmark supply
        uint256 gasStart = gasleft();
        CoreSupplyInput memory supplyInput = CoreSupplyInput({
            userLPBalance: 0,
            supplyAmount: 1000 * 1e6
        });
        core.processSupply(pool, supplyInput);
        uint256 supplyGas = gasStart - gasleft();
        
        // Benchmark borrow
        UserPosition memory position;
        gasStart = gasleft();
        CoreBorrowInput memory borrowInput = CoreBorrowInput({
            borrowAmount: 500 * 1e6,
            collateralAmount: 1 * WAD,
            collateralPrice: 1000 * RAY,
            protocolTotalDebt: 0
        });
        core.processBorrow(market, pool, position, borrowInput, defaultParams);
        uint256 borrowGas = gasStart - gasleft();
        
        // Log gas usage (these should be monitored for regression)
        emit log_named_uint("Supply gas", supplyGas);
        emit log_named_uint("Borrow gas", borrowGas);
        
        // Set reasonable limits (adjust based on optimization goals)
        assertLt(supplyGas, 50_000, "Supply gas too high");
        assertLt(borrowGas, 200_000, "Borrow gas too high");
    }
    
    /**
     * @notice Test extreme market conditions
     */
    function test_ExtremeMarketConditions() public {
        // Test with very high utilization (99.99%)
        PoolData memory pool;
        pool.totalSupplied = 10_000 * 1e6;
        pool.totalBorrowedAllMarkets = 9_999 * 1e6;
        
        MarketData memory market;
        market.variableBorrowIndex = RAY;
        market.totalBorrowed = 9_999 * 1e6;
        market.lastUpdateTimestamp = block.timestamp;
        
        // Advance time significantly
        uint256 futureTime = block.timestamp + 365 days;
        
        (MarketData memory newMarket, PoolData memory newPool) = core.updateMarketIndices(
            market, pool, defaultParams, futureTime
        );
        
        // At extreme utilization, spread should accumulate significantly
        // Calculate expected spread based on scaled debt
        if (market.totalScaledBorrowed > 0 && newMarket.variableBorrowIndex > market.variableBorrowIndex) {
            uint256 expectedSpread = CoreMath.calculateSpreadEarned(
                market.totalScaledBorrowed,
                newMarket.variableBorrowIndex,
                market.totalBorrowed
            );
            assertEq(newMarket.accumulatedSpread, expectedSpread, "Spread should match calculation");
        }
        assertGt(newMarket.variableBorrowIndex, market.variableBorrowIndex * 11 / 10, 
            "Index should increase significantly at high utilization");
        
        // Test with alternating high/low utilization
        pool.totalBorrowedAllMarkets = 100 * 1e6; // Drop to 1% utilization
        newMarket.totalBorrowed = 100 * 1e6;
        
        futureTime += 365 days;
        (newMarket,) = core.updateMarketIndices(newMarket, pool, defaultParams, futureTime);
        
        // Index should still increase but at a much lower rate
        assertLt(newMarket.variableBorrowIndex, market.variableBorrowIndex * 15 / 10,
            "Index growth should slow at low utilization");
    }
}